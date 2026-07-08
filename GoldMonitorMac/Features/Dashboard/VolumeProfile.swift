import Foundation

/// Session-based Volume Profile indicator: groups candles by calendar day,
/// builds a volume histogram per session, and identifies POC / VAH / VAL.
///
/// Each session's price range is divided into `bucketCount` equal bands;
/// each candle's typical price `(H+L+C)/3` determines which bucket its
/// volume lands in (nil volume → 1, matching the existing `computeVP`
/// convention so bars without Yahoo volume still contribute).
///
/// Uses `Calendar.startOfDay` for session grouping — every pair (including
/// ounce / currency crosses) gets one profile per trading day.
enum VolumeProfile {

    /// One price-level bucket in a session's volume histogram.
    struct Bucket: Hashable {
        let priceLevel: Double
        let volume: Double
    }

    /// One trading day's worth of volume profile data.
    struct SessionVP: Identifiable, Hashable {
        /// Sequential session index (0, 1, 2, … most recent).
        let id: Int
        /// Bar indices (into the input candle array) for the first & last
        /// candle in this session.
        let startBar: Int
        let endBar: Int
        /// Point of Control — price level with the highest volume.
        let poc: Double
        /// Value Area High — top of the value area (default ~70% of volume
        /// centred on the POC).
        let vah: Double
        /// Value Area Low — bottom of the value area.
        let val: Double
        /// Volume histogram buckets covering the session's price range.
        let buckets: [Bucket]
    }

    /// Compute session volume profiles from a candle series.
    ///
    /// - Parameters:
    ///   - candles:      Sorted OHLC candles (newest last).
    ///   - bucketCount:  Number of equal-price bands per session (default 24).
    ///   - valueAreaPct: Percentage of total volume that defines the value
    ///                   area (default 70.0).
    /// - Returns: Up to 5 most-recent session profiles, newest last.
    static func compute(
        _ candles: [Candle],
        bucketCount: Int = 24,
        valueAreaPct: Double = 70.0
    ) -> [SessionVP] {
        guard candles.count >= 2, bucketCount >= 2 else { return [] }

        // 1. Group candles by calendar day.
        let calendar = Calendar.current
        var sessions: [(dayStart: Date, range: Range<Int>)] = []
        var dayStart = calendar.startOfDay(for: candles[0].id)
        var sessionStart = 0
        for (i, c) in candles.enumerated() {
            let d = calendar.startOfDay(for: c.id)
            if d != dayStart {
                sessions.append((dayStart, sessionStart..<i))
                dayStart = d
                sessionStart = i
            }
        }
        // Final session.
        if sessionStart < candles.count {
            sessions.append((dayStart, sessionStart..<candles.count))
        }

        // 2. Compute profile for each session.
        var results: [SessionVP] = []
        for (idx, ses) in sessions.enumerated() {
            let seg = candles[ses.range]
            guard !seg.isEmpty else { continue }

            let priceMin = seg.map(\.low).min()!
            let priceMax = seg.map(\.high).max()!
            guard priceMax > priceMin else { continue }

            let bucketSize = (priceMax - priceMin) / Double(bucketCount)
            var volumes = [Double](repeating: 0, count: bucketCount)
            var totalVol: Double = 0

            for c in seg {
                let typical = (c.high + c.low + c.close) / 3
                let idx2 = min(bucketCount - 1, Int((typical - priceMin) / bucketSize))
                let vol = c.volume.flatMap { $0 > 0 ? $0 : nil } ?? 1
                volumes[idx2] += vol
                totalVol += vol
            }

            // POC = bucket with highest volume.
            let maxVol = volumes.max() ?? 1
            let pocIdx = volumes.firstIndex(of: maxVol) ?? 0
            let poc = priceMin + Double(pocIdx) * bucketSize

            // Value Area: walk outward from POC, adding adjacent buckets
            // until cumulative ≥ valueAreaPct of total.
            let vaThreshold = totalVol * (valueAreaPct / 100.0)
            var cumVol = volumes[pocIdx]
            var loIdx = pocIdx
            var hiIdx = pocIdx

            while cumVol < vaThreshold {
                let leftVol  = loIdx > 0          ? volumes[loIdx - 1] : -1
                let rightVol = hiIdx < bucketCount - 1 ? volumes[hiIdx + 1] : -1
                if leftVol >= rightVol {
                    loIdx -= 1
                    cumVol += volumes[loIdx]
                } else if rightVol >= 0 {
                    hiIdx += 1
                    cumVol += volumes[hiIdx]
                } else {
                    break
                }
            }

            let val = priceMin + Double(loIdx) * bucketSize
            let vah = priceMin + Double(hiIdx + 1) * bucketSize

            // Build bucket list for rendering.
            let buckets: [Bucket] = (0..<bucketCount).map { i in
                Bucket(priceLevel: priceMin + Double(i) * bucketSize,
                       volume: volumes[i])
            }

            let startBar = ses.range.lowerBound
            let endBar   = ses.range.upperBound - 1

            results.append(SessionVP(
                id: idx,
                startBar: startBar,
                endBar: endBar,
                poc: poc,
                vah: vah,
                val: val,
                buckets: buckets
            ))
        }

        // 3. Return the most recent 5 sessions.
        return Array(results.suffix(5))
    }
}
