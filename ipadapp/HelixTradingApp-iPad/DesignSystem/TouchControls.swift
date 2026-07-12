import SwiftUI
import UIKit

/// Reusable touch-first controls shared across the redesigned iPad/iPhone
/// screens. These replace the copy-pasted `Button { } label: { Image… }`
/// blocks scattered through `IPadChartHeaderToolbar` — each of which used a
/// 32×32 hit area (below the 44pt HIG minimum) and no press feedback.

// MARK: - Haptics

enum Haptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    static func select() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

// MARK: - Icon button

/// An SF-Symbol icon button with a guaranteed ≥44pt hit area, an active
/// (selected) state, and light haptic feedback.
struct IconButton: View {
    let systemName: String
    var isActive: Bool = false
    var tint: Color? = nil
    let action: () -> Void

    @Environment(\.metrics) private var metrics

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: metrics.iconGlyph, weight: .semibold))
                .foregroundStyle(resolvedTint)
                .frame(width: metrics.iconHit, height: metrics.iconHit)
                .background(
                    RoundedRectangle(cornerRadius: metrics.controlRadius, style: .continuous)
                        .fill(isActive ? Theme.Color.surfaceMax : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
    }

    private var resolvedTint: Color {
        if let tint { return tint }
        return isActive ? Theme.Color.accentStart : Theme.Color.textSecondary
    }
}

// MARK: - Pill (primary action)

/// The gold gradient capsule used for the primary call-to-action (Analyze).
struct PillButton: View {
    let title: String
    var systemName: String? = nil
    let action: () -> Void

    @Environment(\.metrics) private var metrics

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 6) {
                if let systemName {
                    Image(systemName: systemName)
                        .font(.system(size: metrics.bodySize - 1, weight: .bold))
                }
                Text(title)
                    .font(.system(size: metrics.bodySize - 1, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: metrics.isCompact ? 40 : 34)
            .background(Capsule().fill(Theme.accentGradient))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle())
    }
}

// MARK: - Segmented chips

/// A horizontal segmented control built from equal-weight chips. Generic
/// over any `Identifiable & Hashable` option with a display label.
struct SegmentedChips<Option: Hashable & Identifiable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String

    @Environment(\.metrics) private var metrics

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let isSel = option == selection
                Text(label(option))
                    .font(.system(size: metrics.captionSize, weight: .semibold))
                    .foregroundStyle(isSel ? Theme.Color.canvas : Theme.Color.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: metrics.isCompact ? 32 : 28)
                    .background(
                        RoundedRectangle(cornerRadius: metrics.controlRadius - 2, style: .continuous)
                            .fill(isSel ? Theme.Color.accentStart : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Haptics.select()
                        selection = option
                    }
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: metrics.controlRadius, style: .continuous)
                .strokeBorder(Theme.Color.border, lineWidth: 1)
        )
    }
}

// MARK: - Button style

/// Subtle press-scale used by the touch controls above.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
