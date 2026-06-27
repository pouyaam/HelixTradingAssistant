import Foundation

/// App version metadata, read from the bundle so it always matches what
/// `project.yml` baked into Info.plist (no second source of truth to
/// drift). Used by the About row and the "What's New" popup.
enum AppInfo {
    /// Marketing version, e.g. "1.1" (CFBundleShortVersionString).
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    /// Build number, e.g. "2" (CFBundleVersion).
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}

/// One line in the "What's New" popup — an SF Symbol, a headline, and a
/// one-sentence detail.
struct ReleaseHighlight: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let detail: String
}

/// The release notes shown by the What's New popup after an update.
///
/// To cut a release: bump `version`/`build` in `project.yml`, then update
/// `ReleaseNotes.latest` here with the new `version` + highlights. The
/// popup fires automatically when the running `version` differs from the
/// last one the user dismissed (see `RootView`).
struct ReleaseNotes {
    let version: String
    let tagline: String
    let highlights: [ReleaseHighlight]

    static let latest = ReleaseNotes(
        version: "1.2",
        tagline: "Fair Value Gaps, smarter journal, AI trade post-mortems, and chart fixes.",
        highlights: [
            .init(icon: "rectangle.inset.filled",
                  title: "Fair Value Gap indicator",
                  detail: "LuxAlgo-ported FVG detector overlays bullish and bearish imbalance zones directly on the chart. Each gap extends rightward from where it formed, with a 50% midline and a direction capsule. Mitigated gaps (price closed back inside) dim to lower opacity with dashed borders. Tune the minimum gap size and toggle mitigated zones in Indicator Settings."),
            .init(icon: "calendar",
                  title: "Journal date-range filter",
                  detail: "Filter the journal by Today, This Week, This Month, or a custom date range. The summary cards (entries, win rate, net P/L) and all three analytics charts (daily P/L, cumulative curve, win-rate trend) update live to reflect only the selected window."),
            .init(icon: "sparkles",
                  title: "AI trade post-mortem",
                  detail: "Tap the ✦ AI button on any journal entry to open a post-mortem sheet. Pick your engine, model, and reasoning effort, then let the AI walk through Why it won/lost, What Went Right, What Could Have Been Better, What You Should Have Done, and a Key Takeaway — each as a styled card."),
            .init(icon: "chart.xyaxis.line",
                  title: "Candlestick chart in AI review",
                  detail: "The AI post-mortem sheet now loads real OHLC candles from the database for the trade's pair and time period, rendered as a mini candlestick chart behind the entry/TP/SL/close level lines. The timeframe is auto-selected based on trade duration (1m up to 4h)."),
            .init(icon: "arrow.up.and.down.square",
                  title: "Reset button now fits Y axis",
                  detail: "The chart reset button (↺) now correctly re-fits the vertical scale to show all candles in the reset window, even after manually dragging the price axis. Continuous auto-fit is restored after the reset animation completes."),
            .init(icon: "chart.bar.doc.horizontal",
                  title: "Trade metrics + save to journal",
                  detail: "The AI review sheet shows a live R:R ratio bar, price move in points, lot size, and trade duration. After analysis completes, hit Save to Journal to append the full report to the entry's notes with a timestamp."),
        ]
    )

    /// Archive of past release notes. Not shown in the popup, but kept here
    /// as a source of truth for the changelog history.
    static let v1_1 = ReleaseNotes(
        version: "1.1",
        tagline: "Charting controls, smarter AI analysis, and more data sources.",
        highlights: [
            .init(icon: "squareshape.split.2x2.dotted",
                  title: "Order Blocks indicator",
                  detail: "Institutional bullish/bearish order-block zones with an equilibrium midline — toggle it from the indicators menu and tune it in indicator settings."),
            .init(icon: "clock",
                  title: "Trading Sessions indicator",
                  detail: "Shades the Tokyo, London, and New York sessions as per-day high/low boxes with open/close and average lines — toggle it from the indicators menu and choose which sessions and lines show in settings."),
            .init(icon: "scope",
                  title: "NY Open Setup",
                  detail: "Detects the New York 5-minute opening-range breakout with an FVG retest on the 1m and 5m charts — marks the range, the breakout gap, and the entry/stop/target, alerts you on the retest, and activates as a trade in one click."),
            .init(icon: "arrow.up.and.down",
                  title: "Vertical price scaling",
                  detail: "Drag the price axis to compress or expand the candles, TradingView-style. Double-click the axis to snap back to auto-fit."),
            .init(icon: "hand.draw",
                  title: "Free chart panning",
                  detail: "Click and drag anywhere on the chart to move through time and price together — in any direction."),
            .init(icon: "slider.horizontal.3",
                  title: "Model + effort on the analysis page",
                  detail: "Click an engine icon to pick its model and reasoning effort. Opus 4.8 added; Codex models now show too."),
            .init(icon: "brain",
                  title: "Consistent reasoning trace",
                  detail: "The thinking stream now shows for every model, not just Sonnet."),
            .init(icon: "bitcoinsign.circle",
                  title: "Faraz for crypto",
                  detail: "Bitcoin, Solana, and Ethereum can now be sourced from Faraz, just like gold."),
        ]
    )
}
