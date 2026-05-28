import Foundation

/// One-shot snapshot of the indicator readings the AI prompt should
/// see. Computed locally from the candles array via the same
/// `Indicators` / `Oscillators` / `UTBot` helpers the chart uses —
/// Claude is poor at running RSI / MACD math from raw closes, so we
/// pre-compute and hand it the numbers instead of asking it to
/// estimate. Same numbers the user sees on their chart, which keeps
/// the analysis grounded in the visible state.
///
/// All fields are optional because a series may be shorter than the
/// indicator's lookback (e.g. EMA200 needs 200 bars; intraday TFs
/// often have fewer). The `markdownBlock` skips fields that are nil
/// rather than printing "EMA200: —" placeholders that would just
/// crowd the prompt.
struct MarketSnapshot {
    let lastClose: Double
    let rsi14: Double?
    let macdLine: Double?
    let macdSignal: Double?
    let macdHist: Double?
    let ema50: Double?
    let ema200: Double?
    let atr14: Double?
    /// Distance from last close to the most recent EMA50 / EMA200, in
    /// raw price units. Negative ⇒ price below the EMA. Surfaced
    /// separately from the EMA values themselves because Claude reads
    /// "price is 32 above EMA50" much better than two raw numbers it
    /// has to subtract.
    let priceVsEMA50: Double?
    let priceVsEMA200: Double?
    /// UT Bot trailing stop value at the latest bar + its current
    /// bias (`true` = long-side stop, `false` = short-side stop).
    /// `nil` until the indicator has seeded.
    let utBotStop: Double?
    let utBotIsLong: Bool?
    /// Average volume across the last 20 bars (when available) and
    /// the latest bar's volume. Ratio surfaced in markdownBlock so
    /// Claude can call out volume confluence on breakouts.
    let avgVolume20: Double?
    let lastVolume: Double?

    /// Compute every field from a fresh candle series. Safe on short
    /// series — any indicator that can't seed simply yields nil.
    static func compute(_ candles: [Candle], config: OscillatorConfig = .load()) -> MarketSnapshot {
        guard let last = candles.last else {
            return MarketSnapshot(
                lastClose: 0, rsi14: nil,
                macdLine: nil, macdSignal: nil, macdHist: nil,
                ema50: nil, ema200: nil, atr14: nil,
                priceVsEMA50: nil, priceVsEMA200: nil,
                utBotStop: nil, utBotIsLong: nil,
                avgVolume20: nil, lastVolume: nil
            )
        }

        let rsi = Oscillators.rsi(candles, period: config.rsiPeriod).last?.value
        let macdSeries = Oscillators.macd(
            candles,
            fast: config.macdFast,
            slow: config.macdSlow,
            signal: config.macdSignal
        )
        // Oscillators.macd returns a single value series — the MACD
        // histogram. We'd need to compute the line + signal
        // separately to get the full picture; for the prompt the
        // histogram alone is usually enough ("MACD histogram
        // negative, momentum bearish"). Plumb line/signal as nil for
        // now; can wire them later if Claude asks.
        let macdHist = macdSeries.last?.value

        let ema50  = Indicators.ema(candles, period: 50 ).last?.value
        let ema200 = Indicators.ema(candles, period: 200).last?.value

        let atr = Self.atr(candles, period: 14)

        // UT Bot: reuse the chart's compute() and pick off the
        // trailing-stop + position at the latest bar. `positions`
        // is -1 / 0 / +1 per bar; we read the last non-zero value to
        // get the current bias even when the latest bar didn't flip.
        let ut = UTBot.compute(
            candles,
            keyValue: config.utKeyValue,
            atrPeriod: config.utATRPeriod,
            useHeikinAshi: config.utUseHeikinAshi
        )
        let utStop = ut.trailingStop.last.flatMap { $0 }
        var utLong: Bool? = nil
        for pos in ut.positions.reversed() where pos != 0 {
            utLong = pos > 0
            break
        }

        // Candle.volume is optional and many Iran pairs report 0
        // (snapshot fetcher doesn't have a volume number) — skip
        // zeros so the avg doesn't get dragged toward 0 on
        // mixed-source data.
        let volumes = candles.suffix(20).compactMap { $0.volume }.filter { $0 > 0 }
        let avgVol: Double? = volumes.isEmpty ? nil : volumes.reduce(0, +) / Double(volumes.count)

        return MarketSnapshot(
            lastClose: last.close,
            rsi14: rsi,
            macdLine: nil,
            macdSignal: nil,
            macdHist: macdHist,
            ema50: ema50,
            ema200: ema200,
            atr14: atr,
            priceVsEMA50:  ema50.map  { last.close - $0 },
            priceVsEMA200: ema200.map { last.close - $0 },
            utBotStop: utStop,
            utBotIsLong: utLong,
            avgVolume20: avgVol,
            lastVolume: last.volume.flatMap { $0 > 0 ? $0 : nil }
        )
    }

    /// Render the snapshot as a compact markdown bullet list. Skips
    /// nil rows so the section stays tight on short series. Returns
    /// an empty string when literally nothing's available — the
    /// caller can use that to omit the whole section heading.
    func markdownBlock() -> String {
        var lines: [String] = []
        if let rsi = rsi14 {
            let tag: String
            if rsi >= 70      { tag = "overbought" }
            else if rsi <= 30 { tag = "oversold" }
            else if rsi >= 55 { tag = "bullish bias" }
            else if rsi <= 45 { tag = "bearish bias" }
            else              { tag = "neutral" }
            lines.append("- **RSI(14):** \(fmt(rsi)) (\(tag))")
        }
        if let h = macdHist {
            let tag = h > 0 ? "bullish momentum" : (h < 0 ? "bearish momentum" : "flat")
            lines.append("- **MACD histogram:** \(fmt(h)) (\(tag))")
        }
        if let ema = ema50, let d = priceVsEMA50 {
            let dir = d > 0 ? "above" : "below"
            lines.append("- **EMA50:** \(fmt(ema)) — price \(fmt(abs(d))) \(dir)")
        }
        if let ema = ema200, let d = priceVsEMA200 {
            let dir = d > 0 ? "above" : "below"
            lines.append("- **EMA200:** \(fmt(ema)) — price \(fmt(abs(d))) \(dir)")
        }
        if let a = atr14 {
            lines.append("- **ATR(14):** \(fmt(a)) (volatility unit for SL sizing — typical stop = 1.0–1.5×ATR)")
        }
        if let stop = utBotStop, let long = utBotIsLong {
            lines.append("- **UT Bot:** \(long ? "LONG" : "SHORT") · trailing stop \(fmt(stop))")
        }
        if let avg = avgVolume20, let v = lastVolume, avg > 0 {
            let ratio = v / avg
            let tag: String
            if ratio >= 1.5      { tag = "high — \(String(format: "%.1f", ratio))× avg" }
            else if ratio >= 1.1 { tag = "above avg — \(String(format: "%.1f", ratio))× avg" }
            else if ratio <= 0.6 { tag = "thin — \(String(format: "%.1f", ratio))× avg" }
            else                 { tag = "near avg — \(String(format: "%.1f", ratio))× avg" }
            lines.append("- **Volume:** last bar \(fmt(v)), 20-bar avg \(fmt(avg)) (\(tag))")
        }
        return lines.joined(separator: "\n")
    }

    /// One-line trend summary for the HTF context block — much
    /// shorter than `markdownBlock` because the higher-TF context
    /// shouldn't dominate the prompt. Reads like
    /// `bullish · last 4,705, EMA50 4,680, RSI 58, ATR 32`.
    func oneLineSummary() -> String {
        let bias: String
        if let h = macdHist, h > 0, let d = priceVsEMA50, d > 0 {
            bias = "bullish"
        } else if let h = macdHist, h < 0, let d = priceVsEMA50, d < 0 {
            bias = "bearish"
        } else {
            bias = "mixed"
        }
        var parts = ["**\(bias)**", "last \(fmt(lastClose))"]
        if let ema = ema50 { parts.append("EMA50 \(fmt(ema))") }
        if let rsi = rsi14 { parts.append("RSI \(String(format: "%.0f", rsi))") }
        if let atr = atr14 { parts.append("ATR \(fmt(atr))") }
        if let stop = utBotStop, let long = utBotIsLong {
            parts.append("UT Bot \(long ? "LONG" : "SHORT") @ \(fmt(stop))")
        }
        return parts.joined(separator: " · ")
    }

    // ── Helpers ────────────────────────────────────────────────────

    /// Wilder's ATR — same formula UTBot uses internally, lifted out
    /// here so MarketSnapshot doesn't depend on UTBot's private
    /// helper. Returns the latest ATR value or nil for series shorter
    /// than `period`.
    private static func atr(_ candles: [Candle], period: Int) -> Double? {
        guard period > 0, candles.count >= period else { return nil }
        let n = candles.count
        var trs: [Double] = Array(repeating: 0, count: n)
        trs[0] = candles[0].high - candles[0].low
        for i in 1..<n {
            let c = candles[i]
            let prevClose = candles[i - 1].close
            trs[i] = max(
                c.high - c.low,
                abs(c.high - prevClose),
                abs(c.low  - prevClose)
            )
        }
        var atrVal = trs[0..<period].reduce(0, +) / Double(period)
        let p = Double(period)
        for i in period..<n {
            atrVal = (atrVal * (p - 1) + trs[i]) / p
        }
        return atrVal
    }

    /// Match the price rounding the rest of the prompt uses.
    private func fmt(_ v: Double) -> String {
        if v >= 10_000 { return String(format: "%.0f", v) }
        if v >= 100    { return String(format: "%.2f", v) }
        if v >= 1      { return String(format: "%.4f", v) }
        return String(format: "%.5f", v)
    }
}
