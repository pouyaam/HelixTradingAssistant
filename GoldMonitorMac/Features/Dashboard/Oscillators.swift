import Foundation
import SwiftUI

/// Oscillator-class technical indicators. Unlike SMA/EMA/Bollinger
/// (overlaid on the price chart), these run on their own Y scale —
/// RSI/Stoch are 0-100, MACD oscillates around zero — so they render in
/// their own sub-panels below the main chart.
enum OscillatorKind: String, CaseIterable, Identifiable, Hashable {
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

    // Bump the storage key when we add new required fields — old
    // payloads that lack the new keys would fail to decode otherwise
    // and the load() fallback would silently lose the user's saved
    // values. v2 has the UT Bot fields baked in.
    private static let storageKey = "dashboard.indicator.config.v2"

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
    static func stochastic(_ candles: [Candle], kPeriod: Int, dPeriod: Int) -> [IndicatorPoint] {
        guard kPeriod > 0, dPeriod > 0, candles.count >= kPeriod else { return [] }

        var kVals: [Double?] = Array(repeating: nil, count: candles.count)
        for i in (kPeriod - 1)..<candles.count {
            let window = candles[(i - kPeriod + 1)...i]
            // Tracking high/low via min/max keeps this O(period) per bar;
            // a deque would push it to O(1) but isn't worth it at our
            // chart sizes.
            let lo = window.map(\.low).min()  ?? 0
            let hi = window.map(\.high).max() ?? 0
            let span = hi - lo
            kVals[i] = span > 0 ? (candles[i].close - lo) / span * 100 : 50
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
