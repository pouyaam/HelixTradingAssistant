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
