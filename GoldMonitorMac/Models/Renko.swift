import Foundation

/// Configuration for Renko brick generation.
struct RenkoConfig: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case atr = "ATR"
        case fixed = "Fixed"

        var id: String { rawValue }
    }

    var mode: Mode
    var atrPeriod: Int
    var fixedBoxSize: Double

    init(
        mode: Mode = .atr,
        atrPeriod: Int = 14,
        fixedBoxSize: Double = 1.0
    ) {
        self.mode = mode
        self.atrPeriod = max(1, atrPeriod)
        self.fixedBoxSize = max(0.01, fixedBoxSize)
    }

    static let `default` = RenkoConfig()

    /// Declared explicitly, and it matters for both correctness and speed.
    ///
    /// This type is `RawRepresentable` (so it can live in `@AppStorage`), and
    /// the standard library supplies `==` for every `RawRepresentable` whose
    /// `RawValue` is `Equatable`. That overload wins over the synthesized
    /// memberwise one, which means equality would compare *encoded JSON
    /// strings*:
    ///
    ///   • **Wrong** — `JSONEncoder` makes no key-ordering guarantee, so two
    ///     structurally identical configs can compare unequal. That is exactly
    ///     what made `testRenkoConfigRawValueEncodingAndEquality` flaky.
    ///   • **Slow** — every comparison ran two full encodes: ~3.7 µs versus
    ///     ~95 ns for a plain struct. `ChartDerivedCache.BaseDisplaySig`
    ///     embeds a `RenkoConfig`, and the chart checks that signature on
    ///     every `displayCandles` call — 23 call sites per `ChartView` body,
    ///     times one cache per pane. A cache *hit* cost 4089 ns in Renko mode
    ///     against 240 ns in candle mode, which is why Renko felt laggy in the
    ///     2-column / 2-row / grid layouts specifically.
    static func == (lhs: RenkoConfig, rhs: RenkoConfig) -> Bool {
        lhs.mode == rhs.mode
            && lhs.atrPeriod == rhs.atrPeriod
            && lhs.fixedBoxSize == rhs.fixedBoxSize
    }
}

extension RenkoConfig: RawRepresentable {
    /// Persisted shape. A previously-stored payload may still carry a
    /// `showWicks` key from when bricks could draw shadows — `JSONDecoder`
    /// ignores unknown keys, so old values keep decoding cleanly.
    private struct Storage: Codable {
        let mode: Mode
        let atrPeriod: Int
        let fixedBoxSize: Double
    }

    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Storage.self, from: data) else {
            return nil
        }
        self.init(
            mode: decoded.mode,
            atrPeriod: decoded.atrPeriod,
            fixedBoxSize: decoded.fixedBoxSize
        )
    }

    var rawValue: String {
        let storage = Storage(
            mode: mode,
            atrPeriod: atrPeriod,
            fixedBoxSize: fixedBoxSize
        )
        guard let data = try? JSONEncoder().encode(storage),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

/// Renko brick transformation engine.
///
/// Converts time-series candles into price-based Renko bricks using the
/// canonical *traditional* Renko rules:
///
///   • A brick is exactly `boxSize` tall (`|close − open| == boxSize`).
///   • In a trend, each new brick opens where the previous one closed —
///     up bricks and down bricks are contiguous.
///   • A reversal needs a `2 × boxSize` move against the trend. The
///     reversal series starts one box *away* from the last brick's close
///     (the traditional one-box gap), so we never emit a brick straddling
///     the turning point.
///   • **No shadows.** A Renko brick is a pure box: its high/low are its
///     own body bounds. Shadows are a time-candle concept — a brick
///     represents a fixed price move, not a time period, so there is no
///     intrabar excursion for a wick to describe.
///
/// The close price of each candle is the only trigger signal (matching
/// how virtually every charting library builds Renko from OHLC input);
/// a candle's high/low never spawn bricks.
enum Renko {
    /// Maximum bricks emitted from a single candle to prevent runaway
    /// memory when boxSize is tiny relative to a single-bar price swing.
    private static let maxBricksPerCandle = 500
    /// Hard ceiling on total output bricks (prevents multi-GB arrays).
    private static let maxTotalBricks = 200_000

    /// Average True Range over the input — the simple mean of the last
    /// `period` true ranges.
    ///
    /// `TR[i]` depends only on `candles[i]` and `candles[i-1]`, and only
    /// the trailing `period` values are averaged, so we walk just the last
    /// `period` bars instead of building (and immediately discarding) an
    /// O(n) array of every true range. O(period) time, O(1) space.
    static func computeATR(_ candles: [Candle], period: Int) -> Double {
        let n = candles.count
        guard n >= 2, period >= 1 else { return 0.0 }
        let start = max(1, n - period)      // first index of the trailing window
        var sum = 0.0
        for i in start..<n {
            let c = candles[i]
            let prevClose = candles[i - 1].close
            sum += max(c.high - c.low, max(abs(c.high - prevClose), abs(c.low - prevClose)))
        }
        return sum / Double(n - start)
    }

    /// Resolve the effective box size for a config against a candle series.
    /// ATR mode floors to a small positive value so a degenerate (flat)
    /// series can't produce a zero box; falls back to the fixed size when
    /// ATR is unavailable.
    static func boxSize(for candles: [Candle], config: RenkoConfig) -> Double {
        switch config.mode {
        case .fixed:
            return config.fixedBoxSize
        case .atr:
            let atr = computeATR(candles, period: config.atrPeriod)
            return atr > 0 ? max(atr, 0.01) : config.fixedBoxSize
        }
    }

    /// Transform raw candles into Renko bricks. Returns the input
    /// unchanged if a valid box size can't be derived (so the caller never
    /// renders an empty chart).
    static func transform(_ candles: [Candle], config: RenkoConfig = .default) -> [Candle] {
        guard !candles.isEmpty else { return [] }

        let box = boxSize(for: candles, config: config)
        guard box > 0, box.isFinite else { return candles }

        var bricks: [Candle] = []
        // Bricks in a trend roughly track price-range/box; reserve the bar
        // count as a reasonable lower bound to avoid early re-allocations.
        bricks.reserveCapacity(candles.count)

        // `anchor` is the close of the most recent brick (grid-aligned once
        // the first brick forms). `direction`: 0 = none yet, +1 up, −1 down.
        var anchor = candles[0].close
        var direction = 0
        var brickSeq = 0    // strictly increasing → unique, sorted brick ids

        // Emit `n` bricks stepping by `step` (±box) from `open0`, sharing
        // `candle`'s volume equally. `direction`/`anchor` are updated by the
        // caller; this only appends. Returns the close of the last brick.
        //
        // High/low are the body bounds — a brick has no shadows, so there's
        // nothing to accumulate across the bars feeding it.
        func emitRun(count n: Int, from open0: Double, step: Double,
                     candle c: Candle) -> Double {
            let per = (c.volume ?? 0.0) / Double(n)
            var open = open0
            for _ in 0..<n {
                let close = open + step
                bricks.append(Candle(
                    id: c.bucketStart.addingTimeInterval(Double(brickSeq) * 0.001),
                    open: open,
                    high: max(open, close),
                    low: min(open, close),
                    close: close,
                    volume: per
                ))
                brickSeq += 1
                open = close
            }
            return open
        }

        for c in candles {
            if bricks.count >= maxTotalBricks { break }
            let price = c.close

            switch direction {
            case 1:   // up trend
                if price >= anchor + box {
                    let n = min(Int((price - anchor) / box), maxBricksPerCandle)
                    anchor = emitRun(count: n, from: anchor, step: box, candle: c)
                } else if price <= anchor - 2 * box {
                    // Reversal down: one-box gap, then floor(move/box)−1 bricks.
                    let n = min(Int((anchor - price) / box) - 1, maxBricksPerCandle)
                    anchor = emitRun(count: n, from: anchor - box, step: -box, candle: c)
                    direction = -1
                }
            case -1:  // down trend
                if price <= anchor - box {
                    let n = min(Int((anchor - price) / box), maxBricksPerCandle)
                    anchor = emitRun(count: n, from: anchor, step: -box, candle: c)
                } else if price >= anchor + 2 * box {
                    // Reversal up: one-box gap, then floor(move/box)−1 bricks.
                    let n = min(Int((price - anchor) / box) - 1, maxBricksPerCandle)
                    anchor = emitRun(count: n, from: anchor + box, step: box, candle: c)
                    direction = 1
                }
            default:  // no direction established yet
                if price >= anchor + box {
                    let n = min(Int((price - anchor) / box), maxBricksPerCandle)
                    anchor = emitRun(count: n, from: anchor, step: box, candle: c)
                    direction = 1
                } else if price <= anchor - box {
                    let n = min(Int((anchor - price) / box), maxBricksPerCandle)
                    anchor = emitRun(count: n, from: anchor, step: -box, candle: c)
                    direction = -1
                }
            }
        }

        return bricks.isEmpty ? candles : bricks
    }
}
