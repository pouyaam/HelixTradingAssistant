import Foundation

/// Shared helpers for rendering only the *visible* slice of a candle
/// series on the bar-index charts (price, volume, oscillators).
///
/// Why this exists: Swift Charts renders every mark you hand it, clipping
/// to the X domain afterwards — it does NOT skip off-screen marks. With
/// deep history loaded (years of 1h/1d, months of 5m) that's tens of
/// thousands of marks per frame, which pins the main thread on pan/zoom.
/// These helpers turn the visible `xDomain` into the set of bar indices
/// actually worth drawing, so mark count stays bounded no matter how deep
/// the underlying array is.
///
/// All charts plot at the *global* bar index (`Double(i)`), so windowing
/// only changes WHICH indices get a mark — the X positions, overlays,
/// drawings (date→index), hover, and replay cursor all keep working in
/// the same global index space.
enum ChartWindow {
    /// Default number of trailing bars to show when the user hasn't
    /// pinned a zoom window. Trading-app convention: open on recent price
    /// action, pan left for history — never dump the entire (possibly
    /// 10-year) series on screen at once.
    static let defaultVisibleBars = 180

    /// Upper bound on how many bars we hand to Swift Charts in one frame.
    /// Beyond this we stride-decimate (see `renderIndices`). Swift Charts
    /// renders every mark handed to it (≈2 marks/bar for candles), so this
    /// directly caps per-frame layout cost on a deep zoom-out. iPad GPUs/CPUs
    /// are weaker than the Macs the desktop app targets, so cap lower there —
    /// 700 bars still reads as continuous while roughly halving the mark
    /// count vs the 1500 the Mac uses.
    #if os(iOS)
    static let maxRenderedBars = 700
    #else
    static let maxRenderedBars = 1500
    #endif

    /// Domain to use when the caller hasn't pinned one: the most recent
    /// `visible` bars (with the usual half-bar edge padding), clamped to
    /// what actually exists.
    static func defaultDomain(count: Int, visible: Int = defaultVisibleBars) -> ClosedRange<Double> {
        guard count > 0 else { return 0 ... 1 }
        if count == 1 { return -0.5 ... 0.5 }
        let hi = Double(count - 1) + 0.5
        let lo = max(-0.5, Double(count - visible) - 0.5)
        return lo ... hi
    }

    /// The visible bar-index bounds for `domain` over a `count`-bar
    /// series, clamped to `0...count-1`. nil when nothing is visible
    /// (empty series or a domain entirely off either edge).
    static func visibleBounds(domain: ClosedRange<Double>, count: Int) -> (lo: Int, hi: Int)? {
        guard count > 0 else { return nil }
        let lo = max(0, Int(domain.lowerBound.rounded(.down)))
        let hi = min(count - 1, Int(domain.upperBound.rounded(.up)))
        guard hi >= lo else { return nil }
        return (lo, hi)
    }

    /// Bar indices to actually render this frame: the visible range padded
    /// by a margin (so a fast flick doesn't reveal an undrawn gap before
    /// the next layout pass), stride-decimated down to `maxRenderedBars`
    /// when the window is enormous (deep zoom-out). The most recent
    /// visible bar is always included so the live edge never drops.
    static func renderIndices(
        domain: ClosedRange<Double>,
        count: Int,
        maxBars: Int = maxRenderedBars
    ) -> [Int] {
        guard let (vlo, vhi) = visibleBounds(domain: domain, count: count) else { return [] }
        let span = vhi - vlo
        let margin = max(8, span / 4)
        let lo = max(0, vlo - margin)
        let hi = min(count - 1, vhi + margin)
        let width = hi - lo + 1
        if width <= maxBars { return Array(lo ... hi) }
        let step = Int((Double(width) / Double(maxBars)).rounded(.up))
        var out = Array(stride(from: lo, through: hi, by: step))
        if out.last != hi { out.append(hi) }
        return out
    }
}
