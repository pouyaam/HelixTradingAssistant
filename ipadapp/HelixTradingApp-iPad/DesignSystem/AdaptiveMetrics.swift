import SwiftUI

/// Size-class-aware layout metrics.
///
/// Read from the environment (`@Environment(\.metrics)`) so any view gets
/// the right values for the current form factor automatically:
/// - **regular** width → iPad (and big iPhone landscape): roomier spacing,
///   smaller relative controls (there's plenty of screen).
/// - **compact** width → iPhone portrait: tighter margins, larger touch
///   controls, single-column layouts.
///
/// This replaces the near-unused `ThemeiPad` constants with one source of
/// truth that actually adapts instead of hardcoding iPad sizes.
struct AppMetrics: Equatable {
    /// True on iPhone portrait (and any compact-width context).
    let isCompact: Bool

    /// Apple HIG minimum touch target. Never go below this for a tappable.
    let tap: CGFloat = 44

    // MARK: Spacing

    var screenPadding: CGFloat { isCompact ? 12 : 16 }
    var cardPadding: CGFloat { isCompact ? 14 : 20 }
    var sectionGap: CGFloat { isCompact ? 12 : 16 }
    var rowGap: CGFloat { isCompact ? 8 : 12 }
    var chromePadding: CGFloat { isCompact ? 10 : 12 }

    // MARK: Corner radii

    var cardRadius: CGFloat { isCompact ? 14 : 16 }
    var controlRadius: CGFloat { 10 }

    // MARK: Icon / control sizing

    /// Glyph point size for toolbar/action icons.
    var iconGlyph: CGFloat { isCompact ? 19 : 16 }
    /// Hit-area side for an icon button — always ≥ tap on compact.
    var iconHit: CGFloat { isCompact ? 44 : 34 }

    // MARK: Type ramp

    var titleSize: CGFloat { isCompact ? 17 : 18 }
    var priceSize: CGFloat { isCompact ? 20 : 22 }
    var bodySize: CGFloat { isCompact ? 15 : 14 }
    var captionSize: CGFloat { isCompact ? 12 : 12 }
    var labelSize: CGFloat { isCompact ? 11 : 11 }
}

private struct AppMetricsKey: EnvironmentKey {
    static let defaultValue = AppMetrics(isCompact: false)
}

extension EnvironmentValues {
    var metrics: AppMetrics {
        get { self[AppMetricsKey.self] }
        set { self[AppMetricsKey.self] = newValue }
    }
}

extension View {
    /// Inject `AppMetrics` derived from the current horizontal size class.
    /// Apply once near the root; every descendant reads `\.metrics`.
    func provideAdaptiveMetrics() -> some View {
        modifier(AdaptiveMetricsProvider())
    }
}

private struct AdaptiveMetricsProvider: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        content.environment(\.metrics, AppMetrics(isCompact: sizeClass == .compact))
    }
}
