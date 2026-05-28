import SwiftUI

/// Gradient-filled call to action. Mirrors CleanMyMac X's primary buttons —
/// large rounded pill with the brand gradient and a soft shadow.
struct PrimaryButton: View {
    let title: String
    let systemImage: String?
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                if let icon = systemImage {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.md)
            .background(
                Capsule()
                    .fill(Theme.accentGradient)
            )
            .shadow(color: Theme.Color.accentEnd.opacity(0.35), radius: 10, x: 0, y: 6)
        }
        .buttonStyle(.plain)
    }
}

/// Secondary action — bordered, no fill. Use next to a PrimaryButton for
/// cancel / dismiss actions.
struct SecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.Color.textSecondary)
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)
                .background(
                    Capsule().strokeBorder(Theme.Color.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
