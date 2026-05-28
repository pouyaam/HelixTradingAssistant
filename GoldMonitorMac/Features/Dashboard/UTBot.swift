import Foundation

/// UT Bot Alerts — ATR-based trailing stop with buy/sell signal detection.
///
/// Ported from QuantNomad's PineScript v4 indicator. The trailing stop
/// follows price by `keyValue * ATR(atrPeriod)`. When price crosses the
/// stop, position flips long (buy) or short (sell) and we emit a label.
///
/// Optional Heikin Ashi mode (the `useHeikinAshi` switch in PineScript's
/// `h` input) feeds the signal logic with HA close prices instead of raw
/// closes. The chart visuals stay independent of this — chart-wide HA is
/// a separate toggle.
enum UTBot {
    /// One emitted long/short signal at a specific bar.
    struct Signal: Identifiable, Hashable {
        let index: Int
        let isBuy: Bool
        var id: String { "\(index)-\(isBuy ? "B" : "S")" }
    }

    /// Full computation result. Trailing stop is a per-bar value (nil
    /// until ATR is ready); signals are sparse — only the bars where a
    /// flip actually happened.
    struct Output {
        let trailingStop: [Double?]
        let positions: [Int]          // -1 / 0 / +1 per bar
        let signals: [Signal]
    }

    /// Compute trailing stop, position, and crossover signals.
    /// `keyValue` is PineScript's `a` (multiplier), `atrPeriod` is `c`.
    static func compute(
        _ candles: [Candle],
        keyValue: Double,
        atrPeriod: Int,
        useHeikinAshi: Bool
    ) -> Output {
        // Either feed raw closes or HA closes into the signal logic. The
        // ATR is always computed on raw OHLC since traders expect the
        // stop distance to reflect real range, not smoothed range.
        let signalCandles = useHeikinAshi ? HeikinAshi.transform(candles) : candles
        let src = signalCandles.map(\.close)

        let atrValues = atr(candles, period: atrPeriod)

        let n = candles.count
        var trail: [Double?] = Array(repeating: nil, count: n)
        var positions: [Int] = Array(repeating: 0, count: n)
        var signals: [Signal] = []

        for i in 0..<n {
            guard let atrV = atrValues[i] else { continue }
            let nLoss = keyValue * atrV
            let prevTrail = (i > 0 ? trail[i - 1] : nil) ?? 0
            let curSrc = src[i]
            let prevSrc = i > 0 ? src[i - 1] : curSrc

            // Same iff-chain as the Pine source.
            let newTrail: Double
            if curSrc > prevTrail && prevSrc > prevTrail {
                newTrail = max(prevTrail, curSrc - nLoss)
            } else if curSrc < prevTrail && prevSrc < prevTrail {
                newTrail = min(prevTrail, curSrc + nLoss)
            } else if curSrc > prevTrail {
                newTrail = curSrc - nLoss
            } else {
                newTrail = curSrc + nLoss
            }
            trail[i] = newTrail

            // Position: flips long on src crossing above prev trail,
            // flips short on src crossing below prev trail, otherwise
            // carries over.
            let prevPos = i > 0 ? positions[i - 1] : 0
            let pos: Int
            if i > 0 && prevSrc < prevTrail && curSrc > prevTrail {
                pos = 1
            } else if i > 0 && prevSrc > prevTrail && curSrc < prevTrail {
                pos = -1
            } else {
                pos = prevPos
            }
            positions[i] = pos

            // Buy / sell — same crossover predicate the Pine uses, with
            // the side constraint that the current src must already be
            // on the right side of the trailing stop.
            //
            // Pine's `crossover(ema, x)` with ema = ema(src, 1) ≡ src
            // collapses to "prevSrc <= prevTrail && curSrc > curTrail"
            // for above, mirrored for below.
            if i > 0,
               let prevTrailReal = trail[i - 1]
            {
                let above = prevSrc <= prevTrailReal && curSrc > newTrail
                let below = prevSrc >= prevTrailReal && curSrc < newTrail
                if curSrc > newTrail && above {
                    signals.append(Signal(index: i, isBuy: true))
                } else if curSrc < newTrail && below {
                    signals.append(Signal(index: i, isBuy: false))
                }
            }
        }
        return Output(trailingStop: trail, positions: positions, signals: signals)
    }

    /// Wilder's ATR (RMA-smoothed True Range). PineScript's `atr()` uses
    /// this smoothing, not a plain SMA — the difference matters for the
    /// trailing-stop distance.
    ///
    /// Returns one optional per input candle (nil until the first
    /// `period` bars are accumulated).
    private static func atr(_ candles: [Candle], period: Int) -> [Double?] {
        guard period > 0, candles.count >= 1 else { return [] }
        let n = candles.count
        var trs: [Double] = Array(repeating: 0, count: n)
        // True range = max(H-L, |H-prevC|, |L-prevC|). First bar has no
        // prev close, so TR collapses to the bar's range.
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
        var out: [Double?] = Array(repeating: nil, count: n)
        guard n >= period else { return out }
        // Seed with the simple mean of the first `period` TRs, then
        // apply Wilder's recursive smoothing.
        var atrVal = trs[0..<period].reduce(0, +) / Double(period)
        out[period - 1] = atrVal
        let p = Double(period)
        for i in period..<n {
            atrVal = (atrVal * (p - 1) + trs[i]) / p
            out[i] = atrVal
        }
        return out
    }
}
