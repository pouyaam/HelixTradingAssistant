import Foundation

/// OB+FVG Sweep — confluence detector that finds Order Blocks whose
/// following run leaves a Fair Value Gap, and where price later sweeps
/// the prior swing high/low liquidity before reclaiming the level.
///
/// What it draws:
///   • The originating bullish/bearish Order Block zone.
///   • The matching FVG left behind by the impulse.
///   • The liquidity-sweep point (wick through the prior swing extreme).
///   • A trade plan: entry, stop-loss beyond the sweep, and a take-profit
///     at the configured risk:reward multiple.
///
/// The idea is the same as the classic ICT breaker-block / liquidity-grab
/// model: smart money pushes price past the local extreme to run stops,
/// then reverses, leaving the OB+FVG area as the reload zone.
enum OBFVGSweep {

    enum Status: String, Codable, Hashable {
        case fresh
        case tested
        case exhausted
    }

    struct Zone: Identifiable, Hashable {
        /// Bar index of the originating OB candle.
        let index: Int
        /// Bar index of the middle candle of the confirming FVG.
        let fvgIndex: Int
        /// Bar index where price swept the prior swing extreme.
        let sweepIndex: Int
        /// Bar index where price reclaimed the swept level (confirmation).
        let reclaimIndex: Int
        /// OB zone bounds.
        let high: Double
        let low: Double
        /// Confirming FVG bounds.
        let fvgHigh: Double
        let fvgLow: Double
        /// Wick price that took the prior swing liquidity.
        let sweepPrice: Double
        /// Suggested entry price.
        let entry: Double
        let stopLoss: Double
        let takeProfit: Double
        let isBullish: Bool
        var status: Status
        var testCount: Int

        var id: String {
            "obfvg-\(index)-\(fvgIndex)-\(sweepIndex)-\(isBullish ? "bull" : "bear")"
        }
    }

    /// Scan for OB+FVG liquidity-sweep setups.
    ///
    /// - obPeriods:          required same-direction run after the OB candle.
    /// - obThreshold:        minimum % move from the OB close to the run's end.
    /// - useWicks:           use the full high/low range for the OB zone.
    /// - fvgThreshold:       minimum FVG gap size as % of the gap floor.
    /// - detectVolume:       filter OBs by volume (≥ `volumeMultiplier` × SMA).
    /// - volumeMultiplier:   volume-filter multiplier.
    /// - swingLookback:      how many bars before the OB to define the prior
    ///                       swing high/low that gets swept.
    /// - maxSweepLookahead:  how many bars after the FVG to look for the sweep.
    /// - riskReward:         take-profit multiplier versus entry→stop distance.
    /// - entryMode:          "FVG 50%" / "OB mid" / "Sweep reclaim".
    /// - maxZones:           cap on the number of setups kept on chart.
    static func compute(
        _ candles: [Candle],
        obPeriods: Int = 5,
        obThreshold: Double = 0.0,
        useWicks: Bool = false,
        fvgThreshold: Double = 0.0,
        detectVolume: Bool = false,
        volumeMultiplier: Double = 1.2,
        swingLookback: Int = 10,
        maxSweepLookahead: Int = 30,
        riskReward: Double = 2.0,
        entryMode: String = "FVG 50%",
        maxZones: Int = 10
    ) -> [Zone] {
        guard candles.count >= max(5, swingLookback + obPeriods + 5) else { return [] }

        let obZones = OrderBlocks.compute(
            candles,
            periods: obPeriods,
            threshold: obThreshold,
            useWicks: useWicks,
            detectSteroids: detectVolume,
            volumeMultiplier: volumeMultiplier
        )
        let fvgZones = FairValueGap.compute(candles, threshold: fvgThreshold, maxZones: 50)
        guard !obZones.isEmpty, !fvgZones.isEmpty else { return [] }

        let maxOBWindow = obPeriods + 5
        let reclaimWindow = 3
        var detected: [Zone] = []

        for ob in obZones {
            guard ob.index >= swingLookback else { continue }

            guard let fvg = fvgZones.first(where: {
                $0.isBullish == ob.isBullish &&
                $0.index > ob.index &&
                $0.index <= ob.index + maxOBWindow
            }) else { continue }

            let windowStart = ob.index - swingLookback
            let priorLow  = candles[windowStart...ob.index].map(\.low).min()  ?? ob.low
            let priorHigh = candles[windowStart...ob.index].map(\.high).max() ?? ob.high

            let searchStart = fvg.index + 2
            let searchEnd   = min(searchStart + maxSweepLookahead, candles.count)
            guard searchStart < searchEnd else { continue }

            var found: (sweep: Int, reclaim: Int, sweepPrice: Double)? = nil

            if ob.isBullish {
                for s in searchStart..<searchEnd {
                    if candles[s].low < priorLow {
                        let reclaimEnd = min(s + reclaimWindow + 1, candles.count)
                        for r in (s + 1)..<reclaimEnd {
                            if candles[r].close > priorLow {
                                found = (s, r, candles[s].low)
                                break
                            }
                        }
                        if found != nil { break }
                    }
                }
            } else {
                for s in searchStart..<searchEnd {
                    if candles[s].high > priorHigh {
                        let reclaimEnd = min(s + reclaimWindow + 1, candles.count)
                        for r in (s + 1)..<reclaimEnd {
                            if candles[r].close < priorHigh {
                                found = (s, r, candles[s].high)
                                break
                            }
                        }
                        if found != nil { break }
                    }
                }
            }

            guard let f = found else { continue }

            let entry = entryPrice(
                candles: candles,
                ob: ob,
                fvg: fvg,
                reclaimIndex: f.reclaim,
                mode: entryMode
            )
            let sl = stopLossFor(sweepPrice: f.sweepPrice, isBullish: ob.isBullish)
            let tp = takeProfitFor(entry: entry, stopLoss: sl, isBullish: ob.isBullish, riskReward: riskReward)

            detected.append(Zone(
                index: ob.index,
                fvgIndex: fvg.index,
                sweepIndex: f.sweep,
                reclaimIndex: f.reclaim,
                high: ob.high,
                low: ob.low,
                fvgHigh: fvg.high,
                fvgLow: fvg.low,
                sweepPrice: f.sweepPrice,
                entry: entry,
                stopLoss: sl,
                takeProfit: tp,
                isBullish: ob.isBullish,
                status: .fresh,
                testCount: 0
            ))
        }

        guard !detected.isEmpty else { return [] }

        // Lifecycle: after the sweep is confirmed, the setup is tested when
        // price revisits the OB zone, and exhausted when it closes through
        // the stop-loss.
        var statuses = [Status](repeating: .fresh, count: detected.count)
        var testCounts = [Int](repeating: 0, count: detected.count)

        for ci in 0..<candles.count {
            let c = candles[ci]
            for zi in 0..<detected.count {
                guard statuses[zi] != .exhausted else { continue }
                let z = detected[zi]
                guard ci > z.reclaimIndex else { continue }

                if z.isBullish {
                    if c.close >= z.low && c.close <= z.high {
                        testCounts[zi] += 1
                        statuses[zi] = .tested
                    }
                    if c.close < z.stopLoss {
                        statuses[zi] = .exhausted
                    }
                } else {
                    if c.close >= z.low && c.close <= z.high {
                        testCounts[zi] += 1
                        statuses[zi] = .tested
                    }
                    if c.close > z.stopLoss {
                        statuses[zi] = .exhausted
                    }
                }
            }
        }

        return (0..<detected.count).map { i in
            var z = detected[i]
            z.status = statuses[i]
            z.testCount = testCounts[i]
            return z
        }
        .suffix(maxZones)
    }

    private static func entryPrice(
        candles: [Candle],
        ob: OrderBlocks.Zone,
        fvg: FairValueGap.Zone,
        reclaimIndex: Int,
        mode: String
    ) -> Double {
        switch mode {
        case "OB mid":
            return ob.avg
        case "Sweep reclaim":
            return candles[reclaimIndex].close
        default:
            return (fvg.high + fvg.low) / 2.0
        }
    }

    /// Stop sits a small buffer beyond the sweep extreme so a simple wick
    /// through the liquidity doesn't immediately invalidate the plan.
    private static func stopLossFor(sweepPrice: Double, isBullish: Bool) -> Double {
        let buffer = 0.001
        return isBullish
            ? sweepPrice * (1.0 - buffer)
            : sweepPrice * (1.0 + buffer)
    }

    private static func takeProfitFor(
        entry: Double,
        stopLoss: Double,
        isBullish: Bool,
        riskReward: Double
    ) -> Double {
        let risk = isBullish ? entry - stopLoss : stopLoss - entry
        return isBullish
            ? entry + risk * riskReward
            : entry - risk * riskReward
    }
}
