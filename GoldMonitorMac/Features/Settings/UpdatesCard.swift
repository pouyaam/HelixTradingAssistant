import SwiftUI

struct UpdatesCard: View {
    @StateObject private var updater = UpdateChecker()

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
                    actionButton
                }

                statusRow
            }
        }
        .alert("Update Error", isPresented: Binding(
            get: { if case .error = updater.state { return true } else { return false } },
            set: { if !$0 { updater.state = .idle } }
        )) {
            Button("OK", role: .cancel) { updater.state = .idle }
        } message: {
            if case .error(let msg) = updater.state {
                Text(msg)
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch updater.state {
        case .idle:
            SecondaryButton(title: "Check for updates\u{2026}") {
                Task { await updater.checkForUpdates() }
            }
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking\u{2026}")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textMuted)
            }
        case .updateAvailable:
            PrimaryButton("Download & Install") {
                Task { await updater.downloadAndUpdate() }
            }
        case .downloading:
            VStack(alignment: .trailing, spacing: 4) {
                ProgressView(value: updater.downloadProgress)
                    .frame(width: 120)
                Text("Downloading\u{2026}")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textMuted)
            }
        case .upToDate:
            SecondaryButton(title: "Check again") {
                Task { await updater.checkForUpdates() }
            }
        case .error:
            SecondaryButton(title: "Retry") {
                Task { await updater.checkForUpdates() }
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch updater.state {
        case .idle:
            EmptyView()
        case .checking:
            EmptyView()
        case .updateAvailable(let ver, _):
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.green)
                Text("Version \(ver) is available.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textSecondary)
            }
        case .downloading:
            EmptyView()
        case .upToDate:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("You\u{2019}re up to date.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textSecondary)
            }
        case .error:
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Update check failed. Tap Retry.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textSecondary)
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
