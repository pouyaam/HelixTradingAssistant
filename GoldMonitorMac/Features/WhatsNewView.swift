import SwiftUI

/// "What's New" popup shown after the app updates to a new version
/// (`RootView` compares the running version against the last one the
/// user dismissed). Lists the release's highlights and, on dismiss,
/// marks this version as seen so it doesn't reappear.
struct WhatsNewView: View {
    let notes: ReleaseNotes
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    ForEach(notes.highlights) { item in
                        highlightRow(item)
                    }
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.lg)
            }
            .frame(maxHeight: 360)

            Divider().background(Theme.Color.border)

            HStack {
                Spacer()
                PrimaryButton("Got it", systemImage: "checkmark") { onDismiss() }
            }
            .padding(Theme.Spacing.xl)
        }
        .frame(width: 460)
        .background(Theme.Color.surfaceHi)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.accentGradient)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("What's New")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Theme.Color.textPrimary)
                    Text("v\(notes.version)")
                        .font(.system(size: 11, weight: .heavy).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Theme.accentGradient))
                }
                Text(notes.tagline)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.md)
    }

    private func highlightRow(_ item: ReleaseHighlight) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: item.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Color.accentStart)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Theme.Color.surface)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(item.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
