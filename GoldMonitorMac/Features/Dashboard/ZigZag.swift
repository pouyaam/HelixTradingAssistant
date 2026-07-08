import Foundation

/// ZigZag indicator: identifies swing highs and lows by walking through
/// candles and tracking the strongest move within each `depth`-bar window.
/// A pivot is confirmed when price reverses by at least `minChangePct`
/// percent from the current extreme.
///
/// The output is an ordered list of pivot points (oldest first), alternating
/// between swing highs and swing lows. Each pivot carries the bar index and
/// price, so downstream consumers (like trend-based Volume Profile) can
/// define segments between consecutive pivots.
enum ZigZag {

    struct Pivot: Hashable, Identifiable {
        let id: Int          // sequential index (0, 1, 2, …)
        let barIndex: Int    // candle index in the source array
        let price: Double    // high for swing-high pivots, low for swing-low
        let isHigh: Bool     // true = swing high, false = swing low
    }

    /// Detect ZigZag pivots in a candle series.
    ///
    /// - Parameters:
    ///   - candles:       Sorted OHLC candles (newest last).
    ///   - depth:         Minimum number of bars between two pivots.
    ///                    Higher → fewer, more significant pivots.
    ///   - minChangePct:  Minimum % price move from one pivot to the next
    ///                    to confirm a reversal. Filters noise.
    /// - Returns: Ordered pivots (oldest first), alternating high/low.
    static func compute(
        _ candles: [Candle],
        depth: Int = 5,
        minChangePct: Double = 1.0
    ) -> [Pivot] {
        guard candles.count >= depth * 2 else { return [] }
        let n = candles.count

        // Phase 1: find raw local extremes using a depth-bar window.
        // A bar is a local high if its high is the max in [i-depth, i+depth].
        // Same for local low.
        var highs: [(index: Int, price: Double)] = []
        var lows: [(index: Int, price: Double)] = []

        for i in depth..<(n - depth) {
            let hi = candles[i].high
            let lo = candles[i].low

            var isMax = true
            var isMin = true
            for j in (i - depth)...(i + depth) {
                if candles[j].high > hi { isMax = false }
                if candles[j].low  < lo { isMin = false }
                if !isMax && !isMin { break }
            }
            if isMax { highs.append((i, hi)) }
            if isMin { lows.append((i, lo)) }
        }

        // Phase 2: merge highs and lows into an alternating sequence,
        // keeping the most extreme when consecutive same-type pivots appear.
        var raw: [(index: Int, price: Double, isHigh: Bool)] = []
        for h in highs { raw.append((h.index, h.price, true)) }
        for l in lows  { raw.append((l.index, l.price, false)) }
        raw.sort { $0.index < $1.index }

        guard !raw.isEmpty else { return [] }

        // Collapse consecutive same-type pivots: keep the more extreme one.
        var merged: [(index: Int, price: Double, isHigh: Bool)] = [raw[0]]
        for p in raw.dropFirst() {
            let last = merged[merged.count - 1]
            if p.isHigh == last.isHigh {
                // Same type — keep the more extreme.
                if p.isHigh {
                    if p.price > last.price { merged[merged.count - 1] = p }
                } else {
                    if p.price < last.price { merged[merged.count - 1] = p }
                }
            } else {
                merged.append(p)
            }
        }

        // Phase 3: filter by minChangePct — drop pivots where the move
        // from the previous confirmed pivot is too small.
        guard merged.count >= 2 else {
            return merged.enumerated().map { i, p in
                Pivot(id: i, barIndex: p.index, price: p.price, isHigh: p.isHigh)
            }
        }

        var filtered: [(index: Int, price: Double, isHigh: Bool)] = [merged[0]]
        for p in merged.dropFirst() {
            let prev = filtered[filtered.count - 1]
            let changePct = abs(p.price - prev.price) / prev.price * 100
            if changePct >= minChangePct {
                filtered.append(p)
            } else {
                // Move too small — merge into the previous pivot if it
                // improves the extreme.
                if p.isHigh && p.price > prev.price {
                    filtered[filtered.count - 1] = p
                } else if !p.isHigh && p.price < prev.price {
                    filtered[filtered.count - 1] = p
                }
            }
        }

        return filtered.enumerated().map { i, p in
            Pivot(id: i, barIndex: p.index, price: p.price, isHigh: p.isHigh)
        }
    }

    /// Convert pivots into bar-index ranges for Volume Profile segment
    /// computation. Each range spans from one pivot to the next.
    /// The last segment extends to `candleCount` (the end of the series).
    static func segments(from pivots: [Pivot], candleCount: Int) -> [Range<Int>] {
        guard pivots.count >= 2 else { return [] }
        var ranges: [Range<Int>] = []
        for i in 0..<(pivots.count - 1) {
            let start = pivots[i].barIndex
            let end = pivots[i + 1].barIndex
            if end > start {
                ranges.append(start..<end)
            }
        }
        // Last segment: from the last pivot to the end of the candle array.
        if let last = pivots.last, last.barIndex < candleCount {
            ranges.append(last.barIndex..<candleCount)
        }
        return ranges
    }
}
