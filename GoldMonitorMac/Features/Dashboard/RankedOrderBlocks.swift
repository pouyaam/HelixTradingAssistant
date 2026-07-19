import Foundation

/// Ranked Order Blocks [VP + Ichimoku].
///
/// A faithful port of the PineScript v6 indicator of the same name. An
/// order block is detected as the last opposite-colour candle before a
/// strong displacement move (body > `dispMult` × ATR), optionally gated by
/// a break of structure. Each freshly-formed block is then *ranked* by two
/// confluences and graded A / B / C:
///   • **Volume Profile** (0–2) — how much traded volume sits inside the
///     block's price band relative to the busiest node over the lookback.
///   • **Ichimoku** (0–3) — the block's position vs the Kumo cloud (fully
///     above/below = strong) plus Tenkan/Kijun alignment.
/// The grade is the confluence score as a percentage of the max possible
/// (which depends on which rankings are enabled): ≥70 % = A, ≥40 % = B,
/// else C. When neither ranking is used the grade is "–".
///
/// The engine walks the series bar-by-bar exactly like the Pine runtime so
/// the block lifecycle — creation, right-edge extension, mitigation
/// (remove or grey-out), and the `maxOBs` cap — matches candle-for-candle.
/// Pure-function, no rendering: `ChartView` maps `Output` into
/// `RectangleMark`s, the Ichimoku overlay, and the right-margin volume
/// profile.
enum RankedOrderBlocks {
    /// One graded order block in its final (last-bar) state.
    struct Zone: Identifiable, Hashable {
        /// The OB candle (one bar before the impulse that validated it).
        let startIndex: Int
        /// Right edge — the last bar it extended to (live blocks reach the
        /// latest bar; mitigated-but-kept blocks freeze at their mitigation
        /// bar).
        let endIndex: Int
        let high: Double
        let low: Double
        let isBullish: Bool
        /// "A" / "B" / "C" / "–".
        let grade: String
        /// Raw confluence score and the max it could have reached.
        let score: Int
        let maxScore: Int
        /// True when price has mitigated the block but `removeMit` is off,
        /// so it stays on the chart greyed out.
        let mitigated: Bool

        var id: String { "\(startIndex)-\(isBullish ? "bull" : "bear")" }
    }

    /// The volume-profile histogram over the last `vpLookback` bars, used
    /// both for scoring and for the right-margin drawing.
    struct VPProfile: Hashable {
        let lo: Double
        let step: Double
        let volumes: [Double]
        let pocIndex: Int
        let maxVolume: Double
    }

    struct Output: Hashable {
        var zones: [Zone]
        var vp: VPProfile?
        static let empty = Output(zones: [], vp: nil)
    }

    // MARK: - Compute

    static func compute(
        _ candles: [Candle],
        dispMult: Double,
        atrLen: Int,
        zoneSrc: String,     // "Wicks" | "Body"
        mitBy: String,       // "Close" | "Wick"
        useBOS: Bool,
        bosLen: Int,
        maxOBs: Int,
        removeMit: Bool,
        useVP: Bool,
        vpLookback: Int,
        vpRows: Int,
        useIchi: Bool,
        tenkan: Int,
        kijun: Int,
        senkouB: Int,
        ichiDisp: Int
    ) -> Output {
        let n = candles.count
        guard n > 0 else { return .empty }

        // Wilder's ATR (ta.atr): RMA of true range.
        let atr = wilderATR(candles, length: atrLen)
        // Rolling structure extremes for the optional BOS gate.
        let (bosHi, bosLo) = rollingExtremes(candles, length: bosLen)
        // Per-bar Ichimoku snapshot (Tenkan/Kijun + displaced cloud edges).
        let snaps: [Ichimoku.Snapshot] = useIchi
            ? Ichimoku.snapshots(candles, tenkan: tenkan, kijun: kijun, senkouB: senkouB, displacement: ichiDisp)
            : []

        let maxS = (useVP ? 2 : 0) + (useIchi ? 3 : 0)

        // A block while the series is still being walked.
        struct WorkOB {
            let startIndex: Int
            var endIndex: Int
            let top: Double
            let bot: Double
            let dir: Int      // +1 bullish, -1 bearish
            var live: Bool
            var mitigated: Bool
            let grade: String
            let score: Int
            let maxScore: Int
        }
        var obs: [WorkOB] = []

        func makeOB(dir: Int, top: Double, bot: Double, at i: Int) {
            var score = 0
            if useVP, let vp = vpWindow(candles, endBar: i, rows: vpRows, lookback: vpLookback) {
                score += volScore(top: top, bot: bot, vp: vp)
            }
            if useIchi, i < snaps.count {
                score += ichiScore(dir: dir, top: top, bot: bot, snap: snaps[i])
            }
            let pct = maxS > 0 ? Double(score) / Double(maxS) : 0
            let grade = maxS > 0 ? (pct >= 0.7 ? "A" : (pct >= 0.4 ? "B" : "C")) : "–"
            obs.append(WorkOB(
                startIndex: i - 1, endIndex: i + 2, top: top, bot: bot, dir: dir,
                live: true, mitigated: false, grade: grade, score: score, maxScore: maxS
            ))
            if obs.count > maxOBs { obs.removeFirst() }
        }

        for i in 0..<n {
            let c = candles[i]
            let bodySz = abs(c.close - c.open)
            var bullImp = false
            var bearImp = false
            if let a = atr[i] {
                bullImp = c.close > c.open && bodySz > a * dispMult
                bearImp = c.close < c.open && bodySz > a * dispMult
            }
            // BOS uses the *previous* bar's structure extreme (bosHi[1]).
            let bHi1 = i >= 1 ? bosHi[i - 1] : nil
            let bLo1 = i >= 1 ? bosLo[i - 1] : nil
            let bosB = !useBOS || (bHi1.map { c.close > $0 } ?? false)
            let bosS = !useBOS || (bLo1.map { c.close < $0 } ?? false)

            if i >= 1 {
                let prev = candles[i - 1]
                let zTop = zoneSrc == "Wicks" ? prev.high : max(prev.open, prev.close)
                let zBot = zoneSrc == "Wicks" ? prev.low  : min(prev.open, prev.close)
                // Bullish OB: bearish candle then a bullish impulse.
                if bullImp && prev.close < prev.open && bosB {
                    makeOB(dir: 1, top: zTop, bot: zBot, at: i)
                }
                // Bearish OB: bullish candle then a bearish impulse.
                if bearImp && prev.close > prev.open && bosS {
                    makeOB(dir: -1, top: zTop, bot: zBot, at: i)
                }
            }

            // Extension + mitigation, walked back-to-front so in-place
            // removal keeps earlier indices valid (mirrors the Pine loop).
            if !obs.isEmpty {
                var idx = obs.count - 1
                while idx >= 0 {
                    let d = obs[idx].dir
                    let t = obs[idx].top
                    let bt = obs[idx].bot
                    let mit: Bool
                    if d == 1 {
                        mit = mitBy == "Close" ? c.close < bt : c.low < bt
                    } else {
                        mit = mitBy == "Close" ? c.close > t : c.high > t
                    }
                    if mit {
                        if removeMit {
                            obs.remove(at: idx)
                        } else if obs[idx].live {
                            obs[idx].live = false
                            obs[idx].mitigated = true
                            obs[idx].endIndex = i
                        }
                    } else if obs[idx].live {
                        obs[idx].endIndex = i + 2
                    }
                    idx -= 1
                }
            }
        }

        let lastIndex = n - 1
        var zones: [Zone] = []
        zones.reserveCapacity(obs.count)
        for ob in obs {
            let start = max(0, ob.startIndex)
            let end = min(max(start, ob.endIndex), lastIndex)
            zones.append(Zone(
                startIndex: start, endIndex: end, high: ob.top, low: ob.bot,
                isBullish: ob.dir == 1, grade: ob.grade, score: ob.score,
                maxScore: ob.maxScore, mitigated: ob.mitigated
            ))
        }

        // Volume profile over the final lookback window, for drawing.
        var profile: VPProfile? = nil
        if let vp = vpWindow(candles, endBar: lastIndex, rows: vpRows, lookback: vpLookback) {
            profile = VPProfile(
                lo: vp.lo, step: vp.step, volumes: vp.bins,
                pocIndex: vp.pocIndex, maxVolume: vp.maxV
            )
        }

        return Output(zones: zones, vp: profile)
    }

    // MARK: - Scoring helpers

    /// Volume-profile score (0–2): the busiest bucket overlapping the
    /// block's price band, relative to the busiest bucket overall.
    private static func volScore(
        top: Double, bot: Double,
        vp: (lo: Double, step: Double, bins: [Double], pocIndex: Int, maxV: Double)
    ) -> Int {
        guard vp.step > 0, vp.maxV > 0, !vp.bins.isEmpty else { return 0 }
        let rows = vp.bins.count
        var b0 = Int((bot - vp.lo) / vp.step)
        var b1 = Int((top - vp.lo) / vp.step)
        b0 = max(0, min(rows - 1, b0))
        b1 = max(0, min(rows - 1, b1))
        if b0 > b1 { swap(&b0, &b1) }
        var localMax = 0.0
        for b in b0...b1 { localMax = max(localMax, vp.bins[b]) }
        let r = localMax / vp.maxV
        return r >= 0.7 ? 2 : (r >= 0.4 ? 1 : 0)
    }

    /// Ichimoku score (0–3): cloud position (2/1/0) + Tenkan/Kijun
    /// alignment (+1). Mirrors the Pine `ichiScore` using the displaced
    /// cloud edges the snapshot already exposes.
    private static func ichiScore(dir: Int, top: Double, bot: Double, snap: Ichimoku.Snapshot) -> Int {
        guard let cTop = snap.cloudTop, let cBot = snap.cloudBottom else { return 0 }
        var s = 0
        if dir == 1 {
            s = bot > cTop ? 2 : (top < cBot ? 0 : 1)
            if let t = snap.tenkan, let k = snap.kijun, t > k { s += 1 }
        } else {
            s = top < cBot ? 2 : (bot > cTop ? 0 : 1)
            if let t = snap.tenkan, let k = snap.kijun, t < k { s += 1 }
        }
        return s
    }

    // MARK: - Series helpers

    /// Wilder's ATR: RMA of the true range, seeded with the SMA of the
    /// first `length` true-range values. `nil` until enough history.
    private static func wilderATR(_ candles: [Candle], length: Int) -> [Double?] {
        let n = candles.count
        var out = [Double?](repeating: nil, count: n)
        guard length > 0, n >= length else { return out }
        var tr = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let h = candles[i].high, l = candles[i].low
            if i == 0 { tr[i] = h - l }
            else {
                let pc = candles[i - 1].close
                tr[i] = max(h - l, max(abs(h - pc), abs(l - pc)))
            }
        }
        var sum = 0.0
        for i in 0..<length { sum += tr[i] }
        var prev = sum / Double(length)
        out[length - 1] = prev
        for i in length..<n {
            prev = (prev * Double(length - 1) + tr[i]) / Double(length)
            out[i] = prev
        }
        return out
    }

    /// Rolling highest-high / lowest-low over the trailing `length` bars.
    /// `nil` until `length` bars exist.
    private static func rollingExtremes(_ candles: [Candle], length: Int) -> ([Double?], [Double?]) {
        let n = candles.count
        var hi = [Double?](repeating: nil, count: n)
        var lo = [Double?](repeating: nil, count: n)
        guard length > 0 else { return (hi, lo) }
        for i in 0..<n where i >= length - 1 {
            var mx = -Double.greatestFiniteMagnitude
            var mn = Double.greatestFiniteMagnitude
            for k in (i - length + 1)...i {
                mx = max(mx, candles[k].high)
                mn = min(mn, candles[k].low)
            }
            hi[i] = mx
            lo[i] = mn
        }
        return (hi, lo)
    }

    /// Volume-profile histogram over `[endBar - lookback + 1, endBar]`:
    /// `rows` equal-price buckets between the window high and low, filled
    /// by each bar's typical-price × volume (nil volume → 0, TPO-style).
    private static func vpWindow(
        _ candles: [Candle], endBar i: Int, rows: Int, lookback: Int
    ) -> (lo: Double, step: Double, bins: [Double], pocIndex: Int, maxV: Double)? {
        guard rows > 0, lookback > 0, i >= 0, i < candles.count else { return nil }
        let start = max(0, i - lookback + 1)
        var hi = -Double.greatestFiniteMagnitude
        var lo = Double.greatestFiniteMagnitude
        for k in start...i {
            hi = max(hi, candles[k].high)
            lo = min(lo, candles[k].low)
        }
        let step = (hi - lo) / Double(rows)
        var bins = [Double](repeating: 0, count: rows)
        if step > 0 {
            for k in start...i {
                let typ = (candles[k].high + candles[k].low + candles[k].close) / 3.0
                let v = candles[k].volume ?? 0
                var b = Int((typ - lo) / step)
                b = max(0, min(rows - 1, b))
                bins[b] += v
            }
        }
        var maxV = 0.0
        var pocIndex = 0
        for (idx, val) in bins.enumerated() where val > maxV {
            maxV = val
            pocIndex = idx
        }
        return (lo, step, bins, pocIndex, maxV)
    }
}
