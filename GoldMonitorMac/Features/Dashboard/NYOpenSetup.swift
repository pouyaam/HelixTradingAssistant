import Foundation

/// New York Open 5-minute Opening-Range Breakout with an FVG-retest entry
/// — an ICT-style intraday setup, detected deterministically in Swift.
///
/// The play (per the user's spec):
///   1. New York session opens (09:30 America/New_York, DST-aware).
///   2. Wait for the first 5-minute candle to close (09:30–09:35) — its
///      high/low is the **opening range** (OR).
///   3. On the 1-minute series, hunt for a **power breakout**: an
///      impulse that closes beyond the OR (above OR high → long, below OR
///      low → short), is strong (body ≥ `atrMultiple` × ATR(14)), and
///      leaves a 3-bar **fair-value gap**.
///   4. Wait for price to **retest** back into the gap, then enter.
///
/// Trade geometry (locked-in defaults): entry at the FVG midpoint
/// (consequent encroachment / "50%"), stop below the OR (long) / above it
/// (short), take-profit at **2R**. One setup per day (the first valid),
/// either direction, hunted only inside the morning kill-zone
/// (09:35–11:00 ET) unless `amOnly` is off.
///
/// This is a pure function over the displayed candles — `ChartView` maps
/// the `Result` into overlay marks (OR box, FVG, entry/SL/TP) and
/// `DashboardView` turns the live day's plan into a `TAScenario` for the
/// alert + activate-trade hooks. Mirrors `OrderBlocks` / `TradingSessions`.
///
/// Runs on **1-minute and 5-minute** charts — the two timeframes the
/// opening range resolves cleanly on. On 1m the OR is the five bars of the
/// 09:30–09:35 window; on 5m it's the single 09:30 candle (the literal
/// "first 5-minute candle"), and the FVG/breakout are read at 5-minute
/// resolution. Coarser bars (15m+) can't resolve the opening range, so
/// `compute` returns `[]` there. Detection is timeframe-relative: it works
/// on whatever bars it's handed, so the overlay tracks the chart you're on.
enum NYOpenSetup {

    enum Direction: String, Hashable { case long, short }

    /// Lifecycle of a day's setup, as far as the data reveals it.
    enum Stage: String, Hashable {
        case awaitingBreakout   // OR marked; no qualifying breakout yet
        case pendingRetest      // breakout + FVG found; waiting for the retest
        case entered            // price returned to the entry; trade live
        case hitTP              // resolved at target
        case hitSL              // resolved at stop
        case timedOut           // kill-zone closed with no setup
    }

    /// One day's setup. The OR is always present; everything from
    /// `direction` down is filled once a qualifying breakout appears.
    struct Result: Identifiable, Hashable {
        let dayKey: Int
        /// Bar indices of the first/last 1-minute bar of the OR window.
        let orStartIndex: Int
        let orEndIndex: Int
        let orHigh: Double
        let orLow: Double

        var direction: Direction?
        /// Bar where the FVG completes (the breakout's third bar).
        var breakoutIndex: Int?
        var fvgStartIndex: Int?
        var fvgEndIndex: Int?
        var fvgLow: Double?
        var fvgHigh: Double?

        var entry: Double?
        var stopLoss: Double?
        var takeProfit: Double?

        /// Bar where price first returned to the entry (the retest fill).
        var retestIndex: Int?
        /// Bar where the trade hit TP or SL.
        var resolveIndex: Int?
        var stage: Stage

        var id: Int { dayKey }

        /// True once entry/SL/TP are known (a breakout was found).
        var hasPlan: Bool { entry != nil && stopLoss != nil && takeProfit != nil }
        /// True while the plan is still actionable (waiting for the
        /// retest or managing an open position) — what the live-trading
        /// hooks care about.
        var isActionable: Bool { stage == .pendingRetest || stage == .entered }
    }

    // Session clock landmarks, in ET minutes-of-day.
    private static let orStartMin = 9 * 60 + 30    // 09:30 — NY open
    private static let orEndMin   = 9 * 60 + 35    // 09:35 — first 5m candle closed
    private static let amEndMin   = 11 * 60        // 11:00 — AM kill-zone close
    private static let pmEndMin   = 16 * 60        // 16:00 — NY session close
    private static let atrPeriod  = 14

    /// Detect the setup for every NY-session day present in `candles`.
    /// Returns one `Result` per day (chronological); panning back through
    /// history shows past days' setups, the last element is "today".
    static func compute(_ candles: [Candle], atrMultiple: Double = 1.0, amOnly: Bool = true) -> [Result] {
        let n = candles.count
        guard n >= atrPeriod + 5 else { return [] }
        // Resolution guard — supported on 1m and 5m (≤ 5-minute bars). The
        // opening range needs to land inside the 09:30–09:35 window, which
        // 15m+ bars straddle, so detection backs off above 5-minute bars.
        guard medianSpacingSeconds(candles) <= 360 else { return [] }

        let atr = atrSeries(candles, period: atrPeriod)
        let breakoutEndMin = amOnly ? amEndMin : pmEndMin
        let tz = TimeZone(identifier: "America/New_York") ?? TimeZone(secondsFromGMT: -5 * 3600)!

        // ET day-key + minute-of-day per bar, computed once.
        var dayKeys = [Int](repeating: 0, count: n)
        var minutes = [Int](repeating: 0, count: n)
        for i in 0..<n {
            let (d, m) = clock(candles[i].id, tz: tz)
            dayKeys[i] = d
            minutes[i] = m
        }

        // Walk contiguous same-day spans (candles are chronological).
        var results: [Result] = []
        var i = 0
        while i < n {
            let day = dayKeys[i]
            var j = i
            while j < n && dayKeys[j] == day { j += 1 }
            if let r = detectDay(candles, atr: atr, minutes: minutes,
                                 range: i..<j, dayKey: day,
                                 atrMultiple: atrMultiple, breakoutEndMin: breakoutEndMin) {
                results.append(r)
            }
            i = j
        }
        return results
    }

    // MARK: - Per-day detection

    private static func detectDay(
        _ candles: [Candle], atr: [Double?], minutes: [Int],
        range: Range<Int>, dayKey: Int,
        atrMultiple: Double, breakoutEndMin: Int
    ) -> Result? {
        // 1) Opening range = bars stamped in [09:30, 09:35).
        var orStart = -1, orEnd = -1
        var orHigh = -Double.greatestFiniteMagnitude
        var orLow  =  Double.greatestFiniteMagnitude
        for k in range where minutes[k] >= orStartMin && minutes[k] < orEndMin {
            if orStart < 0 { orStart = k }
            orEnd = k
            orHigh = max(orHigh, candles[k].high)
            orLow  = min(orLow,  candles[k].low)
        }
        guard orStart >= 0 else { return nil }   // no NY open in this day's data

        var r = Result(
            dayKey: dayKey,
            orStartIndex: orStart, orEndIndex: orEnd,
            orHigh: orHigh, orLow: orLow,
            stage: .awaitingBreakout
        )

        // 2) First qualifying breakout + FVG, post-OR and inside the
        //    hunting window. An FVG completes at bar k (using k-2,k-1,k);
        //    the displacement bar k-1 is the impulse we strength-gate.
        let scanLo = orEnd + 2
        let scanHi = range.upperBound - 1
        if scanLo <= scanHi {
            for k in scanLo...scanHi {
                let impulse = k - 1
                let mMin = minutes[impulse]
                if mMin >= breakoutEndMin { break }    // past the window — done
                guard mMin >= orEndMin else { continue }

                // "Power" gate — the displacement body vs ATR.
                guard let a = atr[impulse], a > 0 else { continue }
                let body = abs(candles[impulse].close - candles[impulse].open)
                guard body >= atrMultiple * a else { continue }

                // Long: bullish FVG above a close that broke the OR high.
                if candles[k].low > candles[k - 2].high,
                   candles[impulse].close > orHigh {
                    applyPlan(&r, dir: .long, breakout: k,
                              gapLow: candles[k - 2].high, gapHigh: candles[k].low)
                    break
                }
                // Short: bearish FVG below a close that broke the OR low.
                if candles[k].high < candles[k - 2].low,
                   candles[impulse].close < orLow {
                    applyPlan(&r, dir: .short, breakout: k,
                              gapLow: candles[k].high, gapHigh: candles[k - 2].low)
                    break
                }
            }
        }

        // 3) Retest → resolution, or classify the no-breakout outcome.
        if r.hasPlan,
           let entry = r.entry, let sl = r.stopLoss, let tp = r.takeProfit,
           let dir = r.direction, let bk = r.breakoutIndex {
            r.stage = .pendingRetest
            for k in (bk + 1)..<range.upperBound {
                let touched = dir == .long ? candles[k].low <= entry : candles[k].high >= entry
                if touched { r.retestIndex = k; break }
            }
            if let rt = r.retestIndex {
                r.stage = .entered
                for k in rt..<range.upperBound {
                    // Conservative on an ambiguous bar: check the stop first.
                    let hitSL = dir == .long ? candles[k].low <= sl : candles[k].high >= sl
                    let hitTP = dir == .long ? candles[k].high >= tp : candles[k].low <= tp
                    if hitSL { r.resolveIndex = k; r.stage = .hitSL; break }
                    if hitTP { r.resolveIndex = k; r.stage = .hitTP; break }
                }
            }
        } else if minutes[range.upperBound - 1] >= breakoutEndMin {
            // The day's data already ran past the window with no setup.
            r.stage = .timedOut
        }
        return r
    }

    /// Fill the trade geometry from a detected breakout: entry at the FVG
    /// midpoint, stop at the opposing OR edge, target at 2R.
    private static func applyPlan(
        _ r: inout Result, dir: Direction, breakout k: Int,
        gapLow: Double, gapHigh: Double
    ) {
        r.direction = dir
        r.breakoutIndex = k
        r.fvgStartIndex = k - 2
        r.fvgEndIndex = k
        r.fvgLow = gapLow
        r.fvgHigh = gapHigh

        let entry = (gapLow + gapHigh) / 2            // FVG 50% (CE)
        let sl = dir == .long ? r.orLow : r.orHigh    // stop beyond the OR
        let risk = abs(entry - sl)
        let tp = dir == .long ? entry + 2 * risk : entry - 2 * risk
        r.entry = entry
        r.stopLoss = sl
        r.takeProfit = tp
    }

    // MARK: - Helpers

    /// Wilder ATR series aligned to `candles` (nil before the seed window).
    private static func atrSeries(_ candles: [Candle], period: Int) -> [Double?] {
        let n = candles.count
        guard n > period else { return Array(repeating: nil, count: n) }
        var tr = [Double](repeating: 0, count: n)
        for i in 1..<n {
            let h = candles[i].high, l = candles[i].low, pc = candles[i - 1].close
            tr[i] = max(h - l, max(abs(h - pc), abs(l - pc)))
        }
        var out = [Double?](repeating: nil, count: n)
        // Seed = mean TR over the first `period` true ranges (indices 1...period).
        var prev = tr[1...period].reduce(0, +) / Double(period)
        out[period] = prev
        let p = Double(period)
        for i in (period + 1)..<n {
            prev = (prev * (p - 1) + tr[i]) / p
            out[i] = prev
        }
        return out
    }

    /// ET day-index (days since epoch) + minute-of-day for `date`, using
    /// the instant's true offset so DST is handled without a Calendar
    /// round-trip per bar.
    private static func clock(_ date: Date, tz: TimeZone) -> (day: Int, minute: Int) {
        let local = date.timeIntervalSince1970 + Double(tz.secondsFromGMT(for: date))
        let day = Int((local / 86_400).rounded(.down))
        let minute = Int((local - Double(day) * 86_400) / 60)
        return (day, min(1439, max(0, minute)))
    }

    /// Median consecutive-bar gap (seconds), sampled from the tail.
    private static func medianSpacingSeconds(_ candles: [Candle]) -> TimeInterval {
        let n = candles.count
        let sampleCount = min(20, n - 1)
        guard sampleCount > 0 else { return .greatestFiniteMagnitude }
        var deltas: [TimeInterval] = []
        deltas.reserveCapacity(sampleCount)
        for k in 0..<sampleCount {
            let i = n - 1 - k
            deltas.append(candles[i].id.timeIntervalSince1970 - candles[i - 1].id.timeIntervalSince1970)
        }
        deltas.sort()
        return deltas[deltas.count / 2]
    }
}
