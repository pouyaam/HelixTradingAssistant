import SwiftUI

/// Settings card for the cTrader bridge — toggle, port, live status,
/// last-tick chip. Mirrors the visual language of APIKeysCard and
/// UpdatesCard so it slots into the existing Settings stack without
/// looking grafted on.
///
/// The card binds directly to the shared `CTraderScheduler` via
/// `@EnvironmentObject`. Edits go through `updateConfig(...)` which
/// restarts the receiver if connection-affecting fields changed.
struct CTraderBridgeCard: View {
    @EnvironmentObject private var ctrader: CTraderScheduler

    /// Local copies of the editable fields. We keep them as @State so
    /// the user can type/tweak without firing a restart on every
    /// keystroke — the changes are committed on focus loss or "Apply".
    @State private var enabledDraft: Bool = false
    @State private var portDraft: String = ""
    @State private var dirty: Bool = false
    /// Ticker that refreshes the "X seconds ago" label without paying
    /// the cost of an ObservableObject @Published date every second.
    @State private var nowTick: Date = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                header

                Divider().background(Theme.Color.border)

                // ── Master toggle ────────────────────────────
                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: enabledDraft ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                        .foregroundStyle(enabledDraft ? Theme.Color.success : Theme.Color.textMuted)
                        .font(.system(size: 14))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bridge enabled")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.Color.textPrimary)
                        Text("Accept XAU/USD ticks + bars from the cTrader cBot. When connected, takes precedence over TwelveData and Yahoo.")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.Color.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: $enabledDraft)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: enabledDraft) { _ in dirty = true }
                }

                // ── Port ────────────────────────────────────
                HStack(spacing: Theme.Spacing.md) {
                    Text("LOOPBACK PORT")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.Color.textMuted)
                        .frame(width: 120, alignment: .leading)
                    TextField("7878", text: $portDraft)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                .fill(Theme.Color.surface)
                        )
                        .frame(width: 100)
                        .foregroundStyle(Theme.Color.textPrimary)
                        .font(.system(size: 12, design: .monospaced))
                        .onChange(of: portDraft) { _ in dirty = true }
                    Spacer()
                    if dirty {
                        Button("Apply") { applyChanges() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }

                Divider().background(Theme.Color.border)

                // ── Live status ────────────────────────────
                statusRow
                lastHelloRow
                lastTickRow
            }
        }
        .onAppear { hydrate() }
        .onChange(of: ctrader.config) { _ in hydrate() }
        .onReceive(timer) { nowTick = $0 }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: "bolt.horizontal")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.accentGradient)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("cTrader bridge")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text("Live XAU/USD price + bars from your cTrader account, via the companion cBot.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    // MARK: - Status rows

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Color.textPrimary)
            Spacer()
        }
    }

    @ViewBuilder
    private var lastHelloRow: some View {
        if let h = ctrader.lastHello {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.square")
                    .foregroundStyle(Theme.Color.textMuted)
                    .font(.system(size: 10))
                Text("\(h.account ?? "unknown") · cBot \(h.bot ?? "?") · \(h.symbol)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.Color.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var lastTickRow: some View {
        if let last = ctrader.lastTickAt {
            let secs = Int(nowTick.timeIntervalSince(last))
            let isFresh = secs < 10
            HStack(spacing: 8) {
                Image(systemName: isFresh ? "wave.3.right" : "clock")
                    .foregroundStyle(isFresh ? Theme.Color.success : Theme.Color.warn)
                    .font(.system(size: 10))
                Text("Last tick \(secs)s ago")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textSecondary)
            }
        }
    }

    private var statusColor: Color {
        switch ctrader.status {
        case .connected:  return Theme.Color.success
        case .listening:  return Theme.Color.info
        case .stopped:    return Theme.Color.textMuted
        case .error:      return Theme.Color.danger
        }
    }

    private var statusLabel: String {
        switch ctrader.status {
        case .connected(let remote):  return "Connected · \(remote)"
        case .listening(let port):    return "Listening on 127.0.0.1:\(port) (waiting for cBot)"
        case .stopped:                return "Disabled"
        case .error(let msg):         return "Error · \(msg)"
        }
    }

    // MARK: - State sync

    /// Pull the persisted config into the draft fields. Called on
    /// first appear and whenever the published config changes (e.g.
    /// programmatic enable from a debug command).
    private func hydrate() {
        enabledDraft = ctrader.config.enabled
        portDraft = String(ctrader.config.port)
        dirty = false
    }

    private func applyChanges() {
        let port = UInt16(portDraft) ?? ctrader.config.port
        let next = CTraderConfig(enabled: enabledDraft, port: port)
        ctrader.updateConfig(next)
        dirty = false
    }
}
