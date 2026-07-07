import Foundation

/// Sonarlab Order Blocks — momentum-based institutional order-block detection.
///
/// Ported from ClayeWeight's PineScript v5 "Sonarlab - Order Blocks" (MPL 2.0).
/// An order block is the last counter-trend candle before a high-momentum
/// move in the opposite direction, detected via a custom Rate of Change (ROC):
///
///     pc = (open - open[4]) / open[4] * 100
///
///   • Bullish OB — when ROC crosses *above* the positive sensitivity
///     threshold, locate the most recent RED (bearish) candle within
///     bars 4–15 and mark its high/low range.
///   • Bearish OB — when ROC crosses *below* the negative sensitivity
///     threshold, locate the most recent GREEN (bullish) candle within
///     bars 4–15 and mark its high/low range.
///
/// Mitigation:
///   • "Close" mode — a bearish OB is removed when the prior close
///     exceeds its top; a bullish OB when the prior close drops below
///     its bottom.
///   • "Wick" mode — uses the current bar's high/low instead.
///
/// Pure-function, no state. `ChartView` maps the result into
/// `RectangleMark`s.
enum SonarlabOrderBlocks {

    enum MitigationType: String, Codable, Hashable {
        case close
        case wick
    }

    /// One detected Sonarlab order block.
    struct Zone: Identifiable, Hashable {
        /// Bar index of the OB candle within the input series.
        let index: Int
        let high: Double
        let low: Double
        let isBullish: Bool

        var id: String { "sonar-\(index)-\(isBullish ? "bull" : "bear")" }
    }

    /// Scan `candles` for Sonarlab order blocks.
    ///
    /// - sensitivity: ROC threshold (Pine default 26 → 0.26 after /100).
    ///   Lower values produce more OBs; higher values filter noise.
    /// - mitigationType: "Close" (default) or "Wick" — how a block is
    ///   invalidated once price revisits it.
    /// - maxZones: cap on retained zones (most recent kept).
    static func compute(
        _ candles: [Candle],
        sensitivity: Double,
        mitigationType: MitigationType,
        maxZones: Int = 20
    ) -> [Zone] {
        // Need at least 16 bars: 4 for ROC lookback + up to 15 for OB search + 1 eval.
        guard candles.count >= 16, sensitivity > 0 else { return [] }

        // Mirrors Pine's `sens /= 100` — the UI/config value is the raw
        // Pine `input.int` (e.g. 26), but `pc` below is already a percentage,
        // so the threshold must be scaled down to match.
        let sens = sensitivity / 100
        var zones: [Zone] = []
        // Track the bar index of the last trigger to enforce the 5-bar cooldown.
        var lastTriggerIndex: Int = -10

        for i in 5..<candles.count {
            // ROC of open price over 4 bars.
            let openNow  = candles[i].open
            let openPrev = candles[i - 4].open
            guard openPrev != 0 else { continue }
            let pc = (openNow - openPrev) / openPrev * 100
            let pcPrev = {
                let oN = candles[i - 1].open
                let oP = candles[i - 5].open
                guard oP != 0 else { return 0.0 }
                return (oN - oP) / oP * 100
            }()

            var triggered = false
            var isBullish = false

            // Crossover pc above +sens → bullish OB
            if pcPrev <= sens && pc > sens {
                triggered = true
                isBullish = true
            }
            // Crossunder pc below -sens → bearish OB
            else if pcPrev >= -sens && pc < -sens {
                triggered = true
                isBullish = false
            }

            guard triggered, (i - lastTriggerIndex) > 5 else { continue }
            lastTriggerIndex = i

            // Search bars 4..15 back for the first counter-trend candle.
            var obIdx: Int? = nil
            for j in 4...min(15, i) {
                let c = candles[i - j]
                if isBullish {
                    // Need a RED (bearish) candle.
                    if c.close < c.open {
                        obIdx = i - j
                        break
                    }
                } else {
                    // Need a GREEN (bullish) candle.
                    if c.close > c.open {
                        obIdx = i - j
                        break
                    }
                }
            }
            guard let idx = obIdx else { continue }

            let ob = candles[idx]
            zones.append(Zone(
                index: idx,
                high: ob.high,
                low: ob.low,
                isBullish: isBullish
            ))
        }

        // Mitigation pass: remove zones that have been invalidated.
        var active: [Zone] = []
        for zone in zones {
            var mitigated = false
            for ci in (zone.index + 1)..<candles.count {
                let c = candles[ci]
                if mitigationType == .close {
                    // Close mode: use the *prior* bar's close (ci - 1) to match Pine's
                    // `close[1]` semantics — the OB is evaluated at bar open, so the
                    // mitigation check uses the close of the bar before the current one.
                    if ci >= 1 {
                        let prevClose = candles[ci - 1].close
                        if zone.isBullish {
                            if prevClose < zone.low { mitigated = true; break }
                        } else {
                            if prevClose > zone.high { mitigated = true; break }
                        }
                    }
                } else {
                    // Wick mode: current bar's extremes.
                    if zone.isBullish {
                        if c.low < zone.low { mitigated = true; break }
                    } else {
                        if c.high > zone.high { mitigated = true; break }
                    }
                }
            }
            if !mitigated {
                active.append(zone)
            }
        }

        return Array(active.suffix(maxZones))
    }
}
