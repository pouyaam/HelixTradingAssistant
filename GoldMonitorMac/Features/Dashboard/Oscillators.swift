import Foundation
import SwiftUI

/// Oscillator-class technical indicators. Unlike SMA/EMA/Bollinger
/// (overlaid on the price chart), these run on their own Y scale —
/// RSI/Stoch are 0-100, MACD oscillates around zero — so they render in
/// their own sub-panels below the main chart.
enum OscillatorKind: String, CaseIterable, Identifiable, Hashable, Codable {
    case rsi
    case macd
    case stochastic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rsi:        return "RSI"
        case .macd:       return "MACD"
        case .stochastic: return "Stochastic"
        }
    }

    /// Section title in `IndicatorSettingsSheet` for scroll-to routing.
    var settingsSection: String {
        switch self {
        case .rsi:        return "RSI"
        case .macd:       return "MACD"
        case .stochastic: return "Stochastic"
        }
    }

    /// Pretty header rendered above each panel, with the user's
    /// configured parameters baked in so it's clear at a glance that
    /// "RSI 14" is what's actually being plotted.
    func displayName(config: OscillatorConfig) -> String {
        switch self {
        case .rsi:
            return "RSI (\(config.rsiPeriod))"
        case .macd:
            return "MACD (\(config.macdFast), \(config.macdSlow), \(config.macdSignal))"
        case .stochastic:
            return "Stochastic (\(config.stochK), \(config.stochD))"
        }
    }
}

/// Tunable parameters for every oscillator. Persisted to UserDefaults so
/// the user's preferred period sticks across launches. All ints — these
/// indicators don't have non-integer parameters in practice.
struct OscillatorConfig: Codable, Equatable {
    var rsiPeriod: Int = 14
    var macdFast: Int = 12
    var macdSlow: Int = 26
    var macdSignal: Int = 9
    var stochK: Int = 14
    var stochD: Int = 3

    // UT Bot Alerts parameters (PineScript v4 port). `keyValue` is the
    // sensitivity multiplier (`a` in Pine), `atrPeriod` is the ATR
    // window (`c`), and `utUseHeikinAshi` swaps the signal source from
    // raw closes to Heikin Ashi closes (Pine's `h` input).
    var utKeyValue: Double = 1.0
    var utATRPeriod: Int = 10
    var utUseHeikinAshi: Bool = false
    /// Visibility of the amber trailing-stop line itself. When off, the
    /// UT Bot still computes positions and emits buy/sell labels — just
    /// the visual stop line is hidden. Some traders want the signals
    /// without the clutter of the stepped line behind their candles.
    var utShowTrailingStop: Bool = true

    // Order Block Finder parameters (PineScript v4 port). `obPeriods` is
    // the required same-direction run length after the OB candle (Pine's
    // `periods`), `obThreshold` the minimum % move that validates the
    // block (`threshold`), and `obUseWicks` marks the candle's full
    // high/low range instead of open→low (bull) / open→high (bear).
    var obPeriods: Int = 5
    var obThreshold: Double = 0.0
    var obUseWicks: Bool = false
    var obShowExhausted: Bool = true
    var obDetectSteroids: Bool = false
    /// Fire a system notification when an Order Block appears, gets its
    /// first retest, or is exhausted. Opt-in (default off) — evaluating
    /// this costs an extra full-history `OrderBlocks.compute` on every
    /// candle refresh, so users who don't care about the alerts pay
    /// nothing. See `AlertStore.evaluateOrderBlocks`.
    var obNotifyEvents: Bool = false

    // Steroid Order Blocks parameters.
    var sobPeriods: Int = 5
    var sobThreshold: Double = 0.0
    var sobUseWicks: Bool = false
    var sobVolumeMultiplier: Double = 1.2
    var sobShowExhausted: Bool = true
    var sobDetectSteroids: Bool = true
    /// Same lifecycle notifications as `obNotifyEvents`, for Steroid
    /// Order Blocks.
    var sobNotifyEvents: Bool = false

    // Trading Sessions overlay (Pine v6 "Trading Sessions" port). The
    // four `sessShow…` flags mirror the Pine display inputs; the three
    // per-session flags let the user show only the venues they trade.
    // Session times / timezones / colours are baked to the canonical
    // Tokyo / London / New York presets — see `TradingSessions.catalog`.
    var sessShowNames: Bool = true
    var sessShowOpenClose: Bool = true
    var sessShowRange: Bool = true
    var sessShowAverage: Bool = true
    var sessShowTokyo: Bool = true
    var sessShowLondon: Bool = true
    var sessShowNewYork: Bool = true

    // NY Open Setup (5m opening-range breakout + FVG-retest). `nyAtrMult`
    // is the "power breakout" gate — the displacement body must be at
    // least this many ATR(14). `nyAMOnly` limits the hunt to the morning
    // kill-zone (09:35–11:00 ET) vs the whole NY session. Entry (FVG 50%),
    // stop (beyond the OR) and target (2R) are fixed — see `NYOpenSetup`.
    var nyAtrMult: Double = 1.0
    var nyAMOnly: Bool = true

    // Fair Value Gap parameters (LuxAlgo port). `fvgThreshold` is the
    // minimum gap size as a % of the gap floor (0 = no filter, the default).
    // `fvgShowMitigated` keeps absorbed gaps visible at reduced opacity;
    // when false they are removed from the chart once mitigated.
    var fvgThreshold: Double = 0.0
    var fvgShowMitigated: Bool = true

    // Sonarlab Order Blocks parameters (ClayeWeight PineScript v5 port).
    // `sonarlabSensitivity` is the ROC threshold (Pine default 26 → 0.26
    // after /100). `sonarlabMitigationType` is "Close" (default) or "Wick"
    // — how a block is invalidated once price revisits it.
    var sonarlabSensitivity: Double = 26.0
    var sonarlabMitigationType: String = "Close"

    // FVG→OB parameters.
    var fvobFVGThreshold: Double = 0.0
    var fvobShowMitigated: Bool = false
    var fvobSearchMin: Int = 4
    var fvobSearchMax: Int = 15
    var fvobShowExhausted: Bool = true
    var fvobDetectVolume: Bool = false
    var fvobVolumeMultiplier: Double = 1.2
    var fvobNotifyEvents: Bool = false

    // We decode every field with `decodeIfPresent` (see init(from:)) so
    // adding a field no longer requires bumping this key — an older
    // payload that predates the field just falls back to its default
    // instead of failing to decode and wiping the user's whole config.
    private static let storageKey = "dashboard.indicator.config.v2"

    init() {}

    /// Lenient decode: any key missing from an older saved payload falls
    /// back to the property's default rather than throwing. This is what
    /// lets us extend the config (e.g. the Order Block fields) without
    /// resetting the user's existing RSI / MACD / UT Bot tuning. See
    /// CLAUDE.md "Added a Codable field to a persisted struct".
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rsiPeriod          = try c.decodeIfPresent(Int.self,    forKey: .rsiPeriod)          ?? 14
        macdFast           = try c.decodeIfPresent(Int.self,    forKey: .macdFast)           ?? 12
        macdSlow           = try c.decodeIfPresent(Int.self,    forKey: .macdSlow)           ?? 26
        macdSignal         = try c.decodeIfPresent(Int.self,    forKey: .macdSignal)         ?? 9
        stochK             = try c.decodeIfPresent(Int.self,    forKey: .stochK)             ?? 14
        stochD             = try c.decodeIfPresent(Int.self,    forKey: .stochD)             ?? 3
        utKeyValue         = try c.decodeIfPresent(Double.self, forKey: .utKeyValue)         ?? 1.0
        utATRPeriod        = try c.decodeIfPresent(Int.self,    forKey: .utATRPeriod)        ?? 10
        utUseHeikinAshi    = try c.decodeIfPresent(Bool.self,   forKey: .utUseHeikinAshi)    ?? false
        utShowTrailingStop = try c.decodeIfPresent(Bool.self,   forKey: .utShowTrailingStop) ?? true
        obPeriods          = try c.decodeIfPresent(Int.self,    forKey: .obPeriods)          ?? 5
        obThreshold        = try c.decodeIfPresent(Double.self, forKey: .obThreshold)        ?? 0.0
        obUseWicks         = try c.decodeIfPresent(Bool.self,   forKey: .obUseWicks)         ?? false
        obShowExhausted    = try c.decodeIfPresent(Bool.self,   forKey: .obShowExhausted)    ?? true
        obDetectSteroids   = try c.decodeIfPresent(Bool.self,   forKey: .obDetectSteroids)   ?? false
        obNotifyEvents     = try c.decodeIfPresent(Bool.self,   forKey: .obNotifyEvents)     ?? false
        sobPeriods         = try c.decodeIfPresent(Int.self,    forKey: .sobPeriods)         ?? 5
        sobThreshold       = try c.decodeIfPresent(Double.self, forKey: .sobThreshold)       ?? 0.0
        sobUseWicks        = try c.decodeIfPresent(Bool.self,   forKey: .sobUseWicks)        ?? false
        sobVolumeMultiplier = try c.decodeIfPresent(Double.self, forKey: .sobVolumeMultiplier) ?? 1.2
        sobShowExhausted   = try c.decodeIfPresent(Bool.self,   forKey: .sobShowExhausted)   ?? true
        sobDetectSteroids  = try c.decodeIfPresent(Bool.self,   forKey: .sobDetectSteroids)  ?? true
        sobNotifyEvents    = try c.decodeIfPresent(Bool.self,   forKey: .sobNotifyEvents)    ?? false
        sessShowNames      = try c.decodeIfPresent(Bool.self,   forKey: .sessShowNames)      ?? true
        sessShowOpenClose  = try c.decodeIfPresent(Bool.self,   forKey: .sessShowOpenClose)  ?? true
        sessShowRange      = try c.decodeIfPresent(Bool.self,   forKey: .sessShowRange)      ?? true
        sessShowAverage    = try c.decodeIfPresent(Bool.self,   forKey: .sessShowAverage)    ?? true
        sessShowTokyo      = try c.decodeIfPresent(Bool.self,   forKey: .sessShowTokyo)      ?? true
        sessShowLondon     = try c.decodeIfPresent(Bool.self,   forKey: .sessShowLondon)     ?? true
        sessShowNewYork    = try c.decodeIfPresent(Bool.self,   forKey: .sessShowNewYork)    ?? true
        nyAtrMult          = try c.decodeIfPresent(Double.self, forKey: .nyAtrMult)          ?? 1.0
        nyAMOnly           = try c.decodeIfPresent(Bool.self,   forKey: .nyAMOnly)           ?? true
        fvgThreshold       = try c.decodeIfPresent(Double.self, forKey: .fvgThreshold)       ?? 0.0
        fvgShowMitigated   = try c.decodeIfPresent(Bool.self,   forKey: .fvgShowMitigated)   ?? true
        sonarlabSensitivity = try c.decodeIfPresent(Double.self, forKey: .sonarlabSensitivity) ?? 26.0
        sonarlabMitigationType = try c.decodeIfPresent(String.self, forKey: .sonarlabMitigationType) ?? "Close"
        fvobFVGThreshold   = try c.decodeIfPresent(Double.self, forKey: .fvobFVGThreshold)   ?? 0.0
        fvobShowMitigated  = try c.decodeIfPresent(Bool.self,   forKey: .fvobShowMitigated)  ?? false
        fvobSearchMin      = try c.decodeIfPresent(Int.self,    forKey: .fvobSearchMin)      ?? 4
        fvobSearchMax      = try c.decodeIfPresent(Int.self,    forKey: .fvobSearchMax)      ?? 15
        fvobShowExhausted  = try c.decodeIfPresent(Bool.self,   forKey: .fvobShowExhausted)  ?? true
        fvobDetectVolume   = try c.decodeIfPresent(Bool.self,   forKey: .fvobDetectVolume)   ?? false
        fvobVolumeMultiplier = try c.decodeIfPresent(Double.self, forKey: .fvobVolumeMultiplier) ?? 1.2
        fvobNotifyEvents   = try c.decodeIfPresent(Bool.self,   forKey: .fvobNotifyEvents)   ?? false
    }

    /// Whether the given `TradingSessions` preset id is toggled on. Used
    /// by ChartView to filter the (data-keyed, always-all-sessions)
    /// memoized run list down to what the user wants drawn.
    func showsSession(_ id: String) -> Bool {
        switch id {
        case "tokyo":   return sessShowTokyo
        case "london":  return sessShowLondon
        case "newYork": return sessShowNewYork
        default:        return true
        }
    }

    static func load() -> OscillatorConfig {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let cfg = try? JSONDecoder().decode(OscillatorConfig.self, from: data)
        else { return OscillatorConfig() }
        return cfg
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

/// Pure-function oscillator computations. Each returns
/// `[IndicatorPoint]` keyed by candle index + band, matching the rest of
/// the chart's plotting conventions.
enum Oscillators {
    // MARK: - RSI (Wilder smoothing)
    //
    // Standard 14-period RSI using Wilder's exponential smoothing (the
    // canonical definition — not the SMA variant some libraries use).
    // First value lands at index = period; everything before is nil.
    static func rsi(_ candles: [Candle], period: Int) -> [IndicatorPoint] {
        guard period > 0, candles.count > period else { return [] }
        // Step 1: per-bar gain/loss against prior close.
        var gains:  [Double] = [0]
        var losses: [Double] = [0]
        for i in 1..<candles.count {
            let diff = candles[i].close - candles[i - 1].close
            gains.append(max(0,  diff))
            losses.append(max(0, -diff))
        }
        // Step 2: seed averages = simple mean over the first `period` bars.
        var avgGain = gains[1...period].reduce(0, +) / Double(period)
        var avgLoss = losses[1...period].reduce(0, +) / Double(period)

        var out: [IndicatorPoint] = []
        out.reserveCapacity(candles.count - period)
        out.append(IndicatorPoint(index: period, value: rsiFrom(avgGain, avgLoss), band: "rsi"))

        // Step 3: Wilder's smoothing for the rest of the series.
        // new_avg = (old_avg * (period - 1) + new_value) / period
        let p = Double(period)
        for i in (period + 1)..<candles.count {
            avgGain = (avgGain * (p - 1) + gains[i])  / p
            avgLoss = (avgLoss * (p - 1) + losses[i]) / p
            out.append(IndicatorPoint(index: i, value: rsiFrom(avgGain, avgLoss), band: "rsi"))
        }
        return out
    }

    /// RSI = 100 - 100/(1 + RS); guard zero loss (means RSI=100 by
    /// convention) so the divide doesn't NaN.
    private static func rsiFrom(_ gain: Double, _ loss: Double) -> Double {
        guard loss > 0 else { return 100 }
        let rs = gain / loss
        return 100 - 100 / (1 + rs)
    }

    // MARK: - MACD
    //
    // MACD line  = EMA(close, fast) - EMA(close, slow)
    // Signal     = EMA(MACD line, signal)
    // Histogram  = MACD line - signal
    // All three series get emitted; OscillatorPanel renders the line+signal
    // as curves and the histogram as a small bar series.
    static func macd(_ candles: [Candle], fast: Int, slow: Int, signal: Int) -> [IndicatorPoint] {
        guard fast > 0, slow > fast, signal > 0, candles.count >= slow else { return [] }
        let closes = candles.map(\.close)
        let emaFast = emaSeries(closes, period: fast)
        let emaSlow = emaSeries(closes, period: slow)

        // MACD line is defined wherever both EMAs are defined.
        var macdLine: [Double?] = Array(repeating: nil, count: candles.count)
        for i in 0..<candles.count {
            if let f = emaFast[i], let s = emaSlow[i] { macdLine[i] = f - s }
        }

        // Signal = EMA of the (defined) MACD-line tail.
        let firstMACD = macdLine.firstIndex { $0 != nil } ?? candles.count
        let macdTail = macdLine[firstMACD..<candles.count].compactMap { $0 }
        let signalRel = emaSeries(macdTail, period: signal)

        var out: [IndicatorPoint] = []
        for i in 0..<candles.count {
            if let m = macdLine[i] {
                out.append(IndicatorPoint(index: i, value: m, band: "macd"))
            }
            let rel = i - firstMACD
            if rel >= 0, rel < signalRel.count, let s = signalRel[rel] {
                out.append(IndicatorPoint(index: i, value: s, band: "signal"))
                if let m = macdLine[i] {
                    out.append(IndicatorPoint(index: i, value: m - s, band: "histogram"))
                }
            }
        }
        return out
    }

    // MARK: - Stochastic Oscillator
    //
    // %K = 100 * (close - low_N)  / (high_N - low_N)   over `kPeriod`
    // %D = SMA(%K, dPeriod)
    //
    // Uses a deque-based sliding window for O(1) amortised min/max per
    // bar — replaces the prior O(kPeriod) per-bar scan.
    static func stochastic(_ candles: [Candle], kPeriod: Int, dPeriod: Int) -> [IndicatorPoint] {
        guard kPeriod > 0, dPeriod > 0, candles.count >= kPeriod else { return [] }

        var kVals: [Double?] = Array(repeating: nil, count: candles.count)
        // Deques store indices; front is always the current min/max.
        // Low deque: increasing values (front = min).
        // High deque: decreasing values (front = max).
        var lowDeque: [Int] = []
        var highDeque: [Int] = []

        for i in 0..<candles.count {
            // Remove elements that fall outside the window (left side).
            let windowStart = i - kPeriod + 1
            if let first = lowDeque.first, first < windowStart {
                lowDeque.removeFirst()
            }
            if let first = highDeque.first, first < windowStart {
                highDeque.removeFirst()
            }
            // Add current bar: remove from back while worse than new element.
            let lo = candles[i].low
            let hi = candles[i].high
            while let last = lowDeque.last, candles[last].low >= lo {
                lowDeque.removeLast()
            }
            lowDeque.append(i)
            while let last = highDeque.last, candles[last].high <= hi {
                highDeque.removeLast()
            }
            highDeque.append(i)
            // Compute %K once the window is full.
            if i >= kPeriod - 1 {
                let windowLow  = candles[lowDeque[0]].low
                let windowHigh = candles[highDeque[0]].high
                let span = windowHigh - windowLow
                kVals[i] = span > 0 ? (candles[i].close - windowLow) / span * 100 : 50
            }
        }

        var dVals: [Double?] = Array(repeating: nil, count: candles.count)
        let firstK = kPeriod - 1
        if candles.count >= firstK + dPeriod {
            for i in (firstK + dPeriod - 1)..<candles.count {
                var sum = 0.0
                for j in (i - dPeriod + 1)...i {
                    sum += kVals[j] ?? 0
                }
                dVals[i] = sum / Double(dPeriod)
            }
        }

        var out: [IndicatorPoint] = []
        for i in 0..<candles.count {
            if let k = kVals[i] { out.append(IndicatorPoint(index: i, value: k, band: "k")) }
            if let d = dVals[i] { out.append(IndicatorPoint(index: i, value: d, band: "d")) }
        }
        return out
    }

    // MARK: - Internal helpers

    /// EMA over a flat `[Double]` series, returning a [Double?] aligned
    /// to input indices (nil before the seed window). Used by MACD which
    /// needs to EMA a non-Candle series (the MACD line itself).
    private static func emaSeries(_ values: [Double], period: Int) -> [Double?] {
        guard period > 0, values.count >= period else {
            return Array(repeating: nil, count: values.count)
        }
        var out: [Double?] = Array(repeating: nil, count: values.count)
        let alpha = 2.0 / (Double(period) + 1.0)
        var prev = values[0..<period].reduce(0, +) / Double(period)
        out[period - 1] = prev
        for i in period..<values.count {
            prev = alpha * values[i] + (1 - alpha) * prev
            out[i] = prev
        }
        return out
    }
}
