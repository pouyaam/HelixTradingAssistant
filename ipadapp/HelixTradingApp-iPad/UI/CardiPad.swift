import SwiftUI

/// iPad-adapted card with larger touch targets.
struct CardiPad<Content: View>: View {
    let content: Content
    var padding: CGFloat = ThemeiPad.Spacing.xl

    init(padding: CGFloat = ThemeiPad.Spacing.xl, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .fill(Theme.Color.surfaceHi)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                            .strokeBorder(Theme.Color.border, lineWidth: 1)
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            .shadow(
                color: Theme.Shadow.card.color,
                radius: Theme.Shadow.card.radius,
                x: Theme.Shadow.card.x,
                y: Theme.Shadow.card.y
            )
    }
}
