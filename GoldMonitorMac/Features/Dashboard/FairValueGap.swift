import Foundation

/// Fair Value Gap (FVG) detector — ported from LuxAlgo's PineScript v5
/// "Fair Value Gap" indicator (CC BY-NC-SA 4.0).
///
/// An FVG is a three-candle imbalance where price moves so fast that a
/// price "gap" opens between candle 1's extreme and candle 3's extreme:
///   • Bullish FVG — bar[2].high < bar[0].low and bar[1] closed above bar[2].high.
///     The gap runs from bar[2].high (the floor) to bar[0].low (the ceiling).
///   • Bearish FVG — bar[2].low > bar[0].high and bar[1] closed below bar[2].low.
///     The gap runs from bar[0].high (the floor) to bar[2].low (the ceiling).
///
/// An FVG is "mitigated" when price revisits and closes inside it after
/// the fact — a signal that the imbalance has been absorbed.
///
/// Pure-function, no state.  `ChartView` maps the result into
/// `RectangleMark`s, mirroring how `OrderBlocks` / AI FVG overlays work.
enum FairValueGap {

    /// One detected gap zone.
    struct Zone: Identifiable, Hashable {
        /// Bar index of candle[1] (the middle candle of the three-bar pattern)
        /// in the input series. Used as the left edge of the rectangle.
        let index: Int
        /// Upper boundary of the gap (ceiling).
        let high: Double
        /// Lower boundary of the gap (floor).
        let low: Double
        let isBullish: Bool
        /// True once a subsequent bar closed inside the zone.
        var isMitigated: Bool = false

        var id: String { "\(index)-\(isBullish ? "bull" : "bear")" }
        var mid: Double { (high + low) / 2 }
    }

    /// Scan `candles` for all FVG patterns, optionally filtered by a
    /// minimum gap size expressed as a percentage of the gap floor.
    ///
    /// - threshold:  minimum (high - low) / low * 100 for the gap to pass.
    ///               0 ⇒ no filter (the LuxAlgo default).
    /// - maxZones:   cap on the number of the most-recent zones to keep;
    ///               older zones have usually been mitigated already and
    ///               piling them up creates visual noise.
    static func compute(
        _ candles: [Candle],
        threshold: Double = 0,
        maxZones: Int = 20
    ) -> [Zone] {
        guard candles.count >= 3 else { return [] }

        var zones: [Zone] = []

        // Walk bars starting at index 2 so we can always look back 2 bars.
        for i in 2..<candles.count {
            let c0 = candles[i]     // current (newest of the three)
            let c1 = candles[i - 1] // middle candle
            let c2 = candles[i - 2] // oldest of the three

            // Bullish: gap between c2.high (bar[2]) and c0.low (bar[0]),
            // validated by c1 closing above c2.high.
            if c0.low > c2.high && c1.close > c2.high {
                let gapHigh = c0.low
                let gapLow  = c2.high
                let pct = c2.high > 0 ? (gapHigh - gapLow) / c2.high * 100 : 0
                if pct >= threshold {
                    zones.append(Zone(index: i - 1, high: gapHigh, low: gapLow, isBullish: true))
                }
            }
            // Bearish: gap between c0.high (bar[0]) and c2.low (bar[2]),
            // validated by c1 closing below c2.low.
            else if c0.high < c2.low && c1.close < c2.low {
                let gapHigh = c2.low
                let gapLow  = c0.high
                let pct = c0.high > 0 ? (gapHigh - gapLow) / c0.high * 100 : 0
                if pct >= threshold {
                    zones.append(Zone(index: i - 1, high: gapHigh, low: gapLow, isBullish: false))
                }
            }
        }

        // Mark mitigated zones: a zone is absorbed when a later bar closes
        // inside the gap range (close crossed the midpoint from outside).
        for zi in zones.indices {
            let z = zones[zi]
            // Only look at bars after the gap formed (bar index > z.index + 1).
            for ci in (z.index + 2)..<candles.count {
                let close = candles[ci].close
                if z.isBullish {
                    if close < z.low {
                        zones[zi].isMitigated = true
                        break
                    }
                } else {
                    if close > z.high {
                        zones[zi].isMitigated = true
                        break
                    }
                }
            }
        }

        // Most-recent zones last, capped to avoid O(n²) mark flooding on
        // deep histories. Caller can filter mitigated if they want.
        return Array(zones.suffix(maxZones))
    }
}
