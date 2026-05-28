import SwiftUI

/// Updates section. Sparkle integration is deferred — see
/// [`docs/MACOS_APP.md`](../../../../docs/MACOS_APP.md) "Phase F" for the
/// step-by-step setup. For now this card just shows the current version
/// and a one-click "Open releases page" affordance.
struct UpdatesCard: View {
    private var version: String {
        let dict = Bundle.main.infoDictionary ?? [:]
        let short = dict["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = dict["CFBundleVersion"] as? String ?? "0"
        return "\(short) (build \(build))"
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                header

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Current version")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Color.textMuted)
                        Text(version)
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.Color.textPrimary)
                    }
                    Spacer()
                    SecondaryButton(title: "Check for updates…") {
                        // Placeholder — once Sparkle is wired in (Phase F.2),
                        // this calls `SUUpdater.shared().checkForUpdates(nil)`.
                        // For now, surface the manual link.
                        if let url = URL(string: "https://github.com/your-org/gold-monitor-mac/releases") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }

                Text("Auto-updates via Sparkle will land in a follow-up build. For now, check the releases page manually.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textMuted)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.accentGradient)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("Updates")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text("Check for and install new versions of Helix Trading App.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            Spacer()
        }
    }
}
