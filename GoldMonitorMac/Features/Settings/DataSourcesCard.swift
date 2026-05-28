import SwiftUI

/// Editable mirror of the wizard's "Data sources" step. Every value
/// the wizard collects (Twelve Data API key, ForexFactory calendar
/// URL, Claude binary path override) is also editable here — the
/// wizard is one-shot first-run UX; this card is the ongoing
/// settings surface.
struct DataSourcesCard: View {
    @EnvironmentObject private var dataConfig: DataSourceConfig

    @State private var twelveDataKeyDraft: String = ""
    @State private var forexURLDraft: String = ""
    @State private var claudePathDraft: String = ""
    @State private var isDirty: Bool = false
    @State private var savedFlash: Bool = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                sectionTitle

                twelveDataField
                forexField
                claudeField

                actionRow
            }
        }
        .onAppear { seedFromConfig() }
    }

    private var sectionTitle: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.accentGradient)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("Data sources")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text("Endpoints + keys for the live data feeds. These mirror what the setup wizard captures — change them here any time.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            Spacer()
        }
    }

    private var twelveDataField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("TWELVE DATA API KEY")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Color.textMuted)
                Spacer()
                Button("Get a free key →") {
                    if let url = URL(string: "https://twelvedata.com/pricing") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.Color.accentStart)
            }
            SecureField("Paste your Twelve Data API key", text: $twelveDataKeyDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12).monospaced())
                .onChange(of: twelveDataKeyDraft) { _ in isDirty = true }
            Text("Free tier covers crypto + forex WebSocket streams. Without a key, the live ticker for BTC / ETH / SOL stays offline; the chart still works from Yahoo history.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.Color.textMuted)
        }
    }

    private var forexField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FOREXFACTORY CALENDAR URL")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)
            TextField("https://nfs.faireconomy.media/ff_calendar_thisweek.xml", text: $forexURLDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12).monospaced())
                .onChange(of: forexURLDraft) { _ in isDirty = true }
            Text("Weekly high-impact macro events. Drives the warning banner that appears in the AI analysis page when an FOMC / CPI / NFP release is < 30 minutes away.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.Color.textMuted)
        }
    }

    private var claudeField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CLAUDE BINARY PATH (OPTIONAL)")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)
            TextField("/usr/local/bin/claude   (leave blank to auto-detect)", text: $claudePathDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12).monospaced())
                .onChange(of: claudePathDraft) { _ in isDirty = true }
            Text("Auto-detection walks a list of common install paths (Homebrew, npm-global, ~/.claude/local/, …). Override here only if your install is in an unusual place.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.Color.textMuted)
        }
    }

    private var actionRow: some View {
        HStack {
            if savedFlash {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.Color.success)
                    .font(.system(size: 11, weight: .medium))
            }
            Spacer()
            SecondaryButton(title: "Reset") { seedFromConfig() }
                .disabled(!isDirty)
                .opacity(isDirty ? 1 : 0.4)
            PrimaryButton(isDirty ? "Save" : "Saved",
                          systemImage: isDirty ? "checkmark" : nil) {
                save()
            }
            .disabled(!isDirty)
            .opacity(isDirty ? 1 : 0.5)
        }
    }

    private func seedFromConfig() {
        twelveDataKeyDraft = dataConfig.twelveDataAPIKey
        forexURLDraft      = dataConfig.forexFactoryURL
        claudePathDraft    = dataConfig.claudeBinaryPath
        isDirty = false
    }

    private func save() {
        dataConfig.update(
            twelveDataAPIKey: twelveDataKeyDraft,
            forexFactoryURL:  forexURLDraft,
            claudeBinaryPath: claudePathDraft
        )
        isDirty = false
        savedFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            savedFlash = false
        }
    }
}
