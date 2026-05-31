import Foundation

/// Per-chart memoization of the expensive, *data-derived* arrays:
/// Heikin-Ashi display candles, indicator series, UT Bot output, and
/// oscillator points.
///
/// Why this exists: these all depend only on the candle data + indicator
/// settings — NOT on the visible window. During a pan/zoom only
/// `xDomain` changes, yet SwiftUI re-evaluates the chart body every
/// frame, which (without caching) re-runs every one of these O(n)
/// computations over the *entire* loaded history and throws the results
/// away. On deep history that's megabytes of transient allocations per
/// frame — the main-thread churn that makes panning feel laggy.
///
/// We key each result on a cheap signature of its inputs and recompute
/// only when that signature actually changes (data reload, the 1 Hz
/// live-tick trailing update, an indicator toggle, a settings tweak).
///
/// Held as `@State` in the owning view so it survives the view struct
/// being re-created on each render. It is a plain class (deliberately
/// NOT `ObservableObject`): we mutate it as a read-through cache during
/// `body` evaluation, which is safe precisely because it publishes
/// nothing — mutating it can't trigger another invalidation pass.
final class ChartDerivedCache {

    // ── Display candles (Heikin-Ashi + live-price patch) ──────────────

    private struct DisplaySig: Equatable {
        let count: Int
        let firstTS: TimeInterval
        let lastTS: TimeInterval
        let lastClose: Double
        let lastHigh: Double
        let lastLow: Double
        let heikinAshi: Bool
        let livePrice: Double?
    }
    private var displaySig: DisplaySig?
    private var displayCache: [Candle] = []

    /// Candles actually drawn: HA-transformed when requested, with the
    /// in-progress (last) bar patched to the live price. Mirrors the old
    /// inline `displayCandles` logic exactly — just memoized.
    func displayCandles(candles: [Candle], heikinAshi: Bool, livePrice: Double?) -> [Candle] {
        let last = candles.last
        let sig = DisplaySig(
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0,
            lastTS: last?.id.timeIntervalSince1970 ?? 0,
            lastClose: last?.close ?? 0,
            lastHigh: last?.high ?? 0,
            lastLow: last?.low ?? 0,
            heikinAshi: heikinAshi,
            livePrice: livePrice
        )
        if sig == displaySig { return displayCache }

        let base = heikinAshi ? HeikinAshi.transform(candles) : candles
        let result: [Candle]
        if let live = livePrice, let b = base.last, b.close != 0,
           abs(live - b.close) / b.close < 0.10 {
            var patched = base
            patched[patched.count - 1] = Candle(
                id: b.id,
                open: b.open,
                high: max(b.high, live),
                low: min(b.low, live),
                close: live,
                volume: b.volume
            )
            result = patched
        } else {
            result = base
        }
        displaySig = sig
        displayCache = result
        return result
    }

    // ── Indicators (SMA / EMA / Bollinger) ────────────────────────────

    private struct IndicatorSig: Equatable {
        let count: Int
        let firstTS: TimeInterval
        let lastTS: TimeInterval
        let lastClose: Double
        let enabled: Set<IndicatorKind>
    }
    private var indicatorSig: IndicatorSig?
    private var indicatorCache: [(kind: IndicatorKind, points: [IndicatorPoint])] = []

    func indicators(enabled: Set<IndicatorKind>, candles: [Candle])
        -> [(kind: IndicatorKind, points: [IndicatorPoint])]
    {
        let sig = IndicatorSig(
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0,
            lastTS: candles.last?.id.timeIntervalSince1970 ?? 0,
            lastClose: candles.last?.close ?? 0,
            enabled: enabled
        )
        if sig == indicatorSig { return indicatorCache }
        let result = Indicators.compute(enabled, candles: candles)
        indicatorSig = sig
        indicatorCache = result
        return result
    }

    // ── UT Bot ────────────────────────────────────────────────────────

    private struct UTSig: Equatable {
        let count: Int
        let firstTS: TimeInterval
        let lastTS: TimeInterval
        let lastClose: Double
        let keyValue: Double
        let atrPeriod: Int
        let useHeikinAshi: Bool
    }
    private var utSig: UTSig?
    private var utCache: UTBot.Output?

    func utBot(candles: [Candle], keyValue: Double, atrPeriod: Int, useHeikinAshi: Bool) -> UTBot.Output {
        let sig = UTSig(
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0,
            lastTS: candles.last?.id.timeIntervalSince1970 ?? 0,
            lastClose: candles.last?.close ?? 0,
            keyValue: keyValue,
            atrPeriod: atrPeriod,
            useHeikinAshi: useHeikinAshi
        )
        if sig == utSig, let cached = utCache { return cached }
        let result = UTBot.compute(candles, keyValue: keyValue, atrPeriod: atrPeriod, useHeikinAshi: useHeikinAshi)
        utSig = sig
        utCache = result
        return result
    }

    // ── Oscillator points (RSI / MACD / Stochastic) ───────────────────

    private struct OscSig: Equatable {
        let kind: OscillatorKind
        let count: Int
        let firstTS: TimeInterval
        let lastTS: TimeInterval
        let lastClose: Double
        let rsiPeriod: Int
        let macdFast: Int
        let macdSlow: Int
        let macdSignal: Int
        let stochK: Int
        let stochD: Int
    }
    private var oscSig: OscSig?
    private var oscCache: [IndicatorPoint] = []

    func oscillatorPoints(kind: OscillatorKind, candles: [Candle], config: OscillatorConfig) -> [IndicatorPoint] {
        let sig = OscSig(
            kind: kind,
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0,
            lastTS: candles.last?.id.timeIntervalSince1970 ?? 0,
            lastClose: candles.last?.close ?? 0,
            rsiPeriod: config.rsiPeriod,
            macdFast: config.macdFast,
            macdSlow: config.macdSlow,
            macdSignal: config.macdSignal,
            stochK: config.stochK,
            stochD: config.stochD
        )
        if sig == oscSig { return oscCache }
        let result: [IndicatorPoint]
        switch kind {
        case .rsi:
            result = Oscillators.rsi(candles, period: config.rsiPeriod)
        case .macd:
            result = Oscillators.macd(candles, fast: config.macdFast,
                                      slow: config.macdSlow, signal: config.macdSignal)
        case .stochastic:
            result = Oscillators.stochastic(candles, kPeriod: config.stochK, dPeriod: config.stochD)
        }
        oscSig = sig
        oscCache = result
        return result
    }
}
