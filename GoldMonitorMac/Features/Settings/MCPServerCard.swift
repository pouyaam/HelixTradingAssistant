import SwiftUI

/// Settings card for the local MCP server.
///
/// The job of this screen is to get a working client config into the
/// user's clipboard. Everything else — the toggle, the port, the token —
/// is in service of that, so the copyable command sits directly under the
/// status line rather than behind a disclosure.
struct MCPServerCard: View {
    @EnvironmentObject private var settings: MCPServerSettings
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Card {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    header
                    Divider().overlay(Theme.Color.border)
                    enableRow
                    if settings.isEnabled {
                        statusRow
                        portRow
                    }
                }
            }

            if settings.isEnabled {
                Card {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        sectionTitle("Connect a client", symbol: "link")
                        copyBlock(
                            label: "Claude Code",
                            value: settings.claudeCodeCommand,
                            hint: "Run this in a terminal, then restart Claude Code."
                        )
                        copyBlock(
                            label: "Cursor / Claude Desktop / Windsurf",
                            value: settings.jsonConfig,
                            hint: "Merge into the client's mcpServers config."
                        )
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        sectionTitle("Access", symbol: "lock.shield")
                        tokenRow
                        barsRow
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        sectionTitle("Tools", symbol: "wrench.and.screwdriver")
                        ForEach(Self.toolSummaries, id: \.name) { tool in
                            HStack(alignment: .top, spacing: 8) {
                                Text(tool.name)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Theme.Color.accentStart)
                                    .frame(width: 150, alignment: .leading)
                                Text(tool.blurb)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.Color.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Rows

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.accentGradient)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("MCP server")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text("Serve this app's market data and SMC engines to other AI tools over the Model Context Protocol. Loopback only — read-only, and nothing leaves this machine.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private var enableRow: some View {
        Toggle(isOn: $settings.isEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Run the server")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text("Available while Helix Trading App is open.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textMuted)
            }
        }
        .toggleStyle(.switch)
        .tint(Theme.Color.accentStart)
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(settings.statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(statusColor == Theme.Color.danger ? Theme.Color.danger : Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let activity = settings.lastActivity {
                Text(activity)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.Color.textMuted)
            }
        }
    }

    private var statusColor: Color {
        switch settings.state {
        case .running: return Theme.Color.success
        case .failed:  return Theme.Color.danger
        default:       return Theme.Color.textMuted
        }
    }

    private var portRow: some View {
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Port")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textMuted)
                TextField("4321", text: $settings.portText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .font(.system(size: 12, design: .monospaced))
            }
            if !settings.isPortValid {
                Text("Must be 1024–65535.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.danger)
            }
            Spacer()
            SecondaryButton(title: "Apply & restart") { settings.restart() }
                .disabled(!settings.isPortValid)
        }
    }

    private var tokenRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Bearer token (optional)")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textMuted)
            HStack(spacing: 8) {
                TextField("none — any local process may connect", text: $settings.token)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                SecondaryButton(title: "Generate") { settings.generateToken() }
                SecondaryButton(title: "Apply") { settings.restart() }
            }
            Text("The server already refuses non-loopback connections and cross-origin requests. Set a token only if other user accounts or containers share this machine.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.Color.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var barsRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Max bars per request")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textMuted)
                Text("Caps how much history one call can pull. \(settings.maxBars)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textMuted)
            }
            Spacer()
            Stepper("", value: $settings.maxBars, in: 500...20000, step: 500)
                .labelsHidden()
        }
    }

    // MARK: - Building blocks

    private func sectionTitle(_ text: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Color.accentStart)
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Color.textPrimary)
            Spacer()
        }
    }

    private func copyBlock(label: String, value: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Color.textSecondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    copied = label
                    // Reset the confirmation without a timer object —
                    // the card is transient and a stray Task is cheaper
                    // than owning cancellation here.
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        if copied == label { copied = nil }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied == label ? "checkmark" : "doc.on.doc")
                        Text(copied == label ? "Copied" : "Copy")
                    }
                    .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied == label ? Theme.Color.success : Theme.Color.accentStart)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(value)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.Color.textPrimary)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.Color.surface)
            )
            Text(hint)
                .font(.system(size: 10))
                .foregroundStyle(Theme.Color.textMuted)
        }
    }

    /// Mirrors `MCPToolbox.tools`. Duplicated as display copy rather than
    /// read off the toolbox, which needs a live database handle this view
    /// has no business holding.
    private static let toolSummaries: [(name: String, blurb: String)] = [
        ("list_symbols", "Symbols and timeframes this server can analyse."),
        ("history_data", "Raw OHLCV candles, folded to any timeframe."),
        ("rank_ob", "Ranked order blocks graded A/B/C on Volume Profile + Ichimoku, with ATR distances."),
        ("algosmart_assist", "ALGOSMART ASSIST v2 — BOS / CHoCH / IDM / sweeps, POI zones, equilibrium, qualified setups."),
        ("previous_day_levels", "Previous session PDH / PDL / mid / POC / VAH / VAL and unswept liquidity."),
        ("smc_brief", "All of the above across two timeframes, plus the desk's analysis method."),
    ]
}
