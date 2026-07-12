import SwiftUI

/// Unified card surface for the touch app. Adaptive padding/radius via
/// `AppMetrics`, built on the shared `Theme.Color` tokens (the dark
/// CleanMyMac-style palette is kept). Supersedes `CardiPad`, whose fixed
/// padding didn't adapt between iPad and iPhone.
struct Surface<Content: View>: View {
    var padding: CGFloat? = nil
    var elevated: Bool = true
    @ViewBuilder var content: () -> Content

    @Environment(\.metrics) private var metrics

    var body: some View {
        content()
            .padding(padding ?? metrics.cardPadding)
            .background(
                RoundedRectangle(cornerRadius: metrics.cardRadius, style: .continuous)
                    .fill(Theme.Color.surfaceHi)
                    .overlay(
                        RoundedRectangle(cornerRadius: metrics.cardRadius, style: .continuous)
                            .strokeBorder(Theme.Color.border, lineWidth: 1)
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: metrics.cardRadius, style: .continuous))
            .modifier(ConditionalCardShadow(enabled: elevated))
    }
}

private struct ConditionalCardShadow: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.cardShadow() } else { content }
    }
}

/// A section label used above grouped content — small, tracked, muted.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(Theme.Color.textMuted)
    }
}
