import SwiftUI

/// CleanMyMac-style elevated panel. Use as the container for chart, AI
/// report, settings sections, etc. Padding is opinionated — callers should
/// not add their own padding inside.
struct Card<Content: View>: View {
    let content: Content
    var padding: CGFloat = Theme.Spacing.xl

    init(padding: CGFloat = Theme.Spacing.xl, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .fill(Theme.Color.surfaceHi)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                            .strokeBorder(Theme.Color.border, lineWidth: 1)
                    )
            )
            // Mask content to the rounded shape so children (like Apple
            // Charts, which sometimes renders marks an extra pixel past
            // its own frame during pan/zoom) can never visibly extend
            // beyond the card's silhouette.
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            .cardShadow()
    }
}
