import SwiftUI

/// CleanMyMac-style elevated panel. Use as the container for chart, AI
/// report, settings sections, etc. Padding is opinionated — callers should
/// not add their own padding inside.
struct Card<Content: View>: View {
    let content: Content
    var padding: CGFloat = Theme.Spacing.xl
    /// Renders bare — no background fill, border, shadow, or corner
    /// clip — just the padded content. Exists so a caller that toggles
    /// chrome on/off (e.g. a chart going fullscreen) can vary this value
    /// on one `Card` call instead of switching between `Card { X }` and
    /// bare `X` in an `if/else`. SwiftUI treats the latter as two
    /// different views and tears down `X` (and any `@StateObject` it
    /// owns, like `ChartView`'s indicator cache) every time — see the
    /// call sites in `DashboardView.chartCard` / `ChartPaneView.content`.
    var chromeless: Bool = false

    init(padding: CGFloat = Theme.Spacing.xl, chromeless: Bool = false, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.chromeless = chromeless
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background {
                if !chromeless {
                    RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                        .fill(Theme.Color.surfaceHi)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                                .strokeBorder(Theme.Color.border, lineWidth: 1)
                        )
                }
            }
            // Mask content to the rounded shape so children (like Apple
            // Charts, which sometimes renders marks an extra pixel past
            // its own frame during pan/zoom) can never visibly extend
            // beyond the card's silhouette. The conditional branches here
            // only vary the *background*/*shadow* siblings, never
            // `content`'s own ancestor chain, so `content`'s identity
            // (and any `@StateObject` it owns) survives a chrome toggle.
            .clipShape(RoundedRectangle(cornerRadius: chromeless ? 0 : Theme.Radius.lg, style: .continuous))
            // Same reasoning as `.background` above: `.shadow` is applied
            // unconditionally with its parameters varying (a zero-radius,
            // clear shadow is invisible) rather than branching on
            // `content` itself, which would break its identity.
            .shadow(
                color: chromeless ? .clear : Theme.Shadow.card.color,
                radius: chromeless ? 0 : Theme.Shadow.card.radius,
                x: chromeless ? 0 : Theme.Shadow.card.x,
                y: chromeless ? 0 : Theme.Shadow.card.y
            )
    }
}
