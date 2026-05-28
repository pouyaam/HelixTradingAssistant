import SwiftUI

/// Settings page — macOS System Settings-style two-column layout:
/// a left rail of category buttons plus the selected category's
/// cards on the right. Every wizard-collected value is also
/// editable here, plus everything that was only ever in settings
/// (markets toggles, Claude model + effort, SOCKS5 proxy, cTrader
/// bridge).
struct SettingsView: View {
    @EnvironmentObject private var app: AppState

    // ── State ─────────────────────────────────────────────────────

    /// Source of truth lifted to `AppState.settingsCategory` so
    /// the dashboard's auto-trader gear button can deep-link
    /// into a specific category (e.g. jump straight to
    /// Auto-trader with the current symbol's row expanded).
    /// Sidebar clicks below set it through the same path.
    private var selectedSettingsCategory: SettingsCategory {
        get { app.settingsCategory }
        nonmutating set { app.settingsCategory = newValue }
    }

    @State private var proxy: ProxyConfig = ProxyConfig.load()
    @State private var proxyDirty = false
    @State private var proxyTestState: TestState = .idle

    enum TestState { case idle, working, ok, failed(String) }

    // Markets — toggles read by the sidebar's pair filter.
    @AppStorage("markets.forex.enabled")   private var forexEnabled: Bool = true
    @AppStorage("markets.crypto.enabled")  private var cryptoEnabled: Bool = true
    @AppStorage("markets.indices.enabled") private var indicesEnabled: Bool = true

    // Claude model + effort.
    @AppStorage("ai.claude.model")  private var claudeModel: String = "claude-opus-4-7"
    @AppStorage("ai.claude.effort") private var claudeEffort: String = "medium"

    // Codex model + effort. Mirrors the Claude keys; read by
    // CodexEngine at run time. Defaults match the user's frontier
    // Codex model + a high reasoning effort.
    @AppStorage("ai.codex.model")  private var codexModel: String = "gpt-5.5"
    @AppStorage("ai.codex.effort") private var codexEffort: String = "high"

    // Token usage counters (rolled per-render).
    @AppStorage("ai.claude.tokens.today")   private var tokensToday: Int = 0
    @AppStorage("ai.claude.tokens.week")    private var tokensWeek: Int = 0
    @AppStorage("ai.claude.tokens.dayKey")  private var tokensDayKey: String = ""
    @AppStorage("ai.claude.tokens.weekKey") private var tokensWeekKey: String = ""

    // ── Layout ────────────────────────────────────────────────────

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().background(Theme.Color.border)
            content
        }
        .background(Theme.Color.canvas)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            sidebarHeader
            Divider().background(Theme.Color.border)
                .padding(.vertical, Theme.Spacing.sm)
            ForEach(SettingsCategory.allCases) { cat in
                categoryRow(cat)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.md)
        .frame(width: 220)
        .background(Theme.Color.surface)
    }

    private var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Settings")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Theme.Color.textPrimary)
            Text("Configure data sources, AI, and network.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textSecondary)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.top, Theme.Spacing.sm)
    }

    private func categoryRow(_ cat: SettingsCategory) -> some View {
        let isSelected = selectedSettingsCategory == cat
        return Button {
            selectedSettingsCategory = cat
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: cat.symbol)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .frame(width: 20)
                Text(cat.label)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                Spacer()
            }
            .foregroundStyle(isSelected ? Theme.Color.textPrimary : Theme.Color.textSecondary)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(isSelected ? Theme.Color.surfaceHi : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                contentHeader
                contentBody
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var contentHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: selectedSettingsCategory.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.accentGradient)
                Text(selectedSettingsCategory.label)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.Color.textPrimary)
            }
            Text(selectedSettingsCategory.blurb)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Color.textSecondary)
        }
        .padding(.bottom, Theme.Spacing.sm)
    }

    @ViewBuilder
    private var contentBody: some View {
        switch selectedSettingsCategory {
        case .general:    generalSection
        case .data:       DataSourcesCard()
        case .ai:         aiSection
        case .network:    proxyCard
        case .ctrader:    CTraderBridgeCard()
        case .autoTrader: AutoTraderCard()
        case .about:      UpdatesCard()
        }
    }

    // ── General section ───────────────────────────────────────────

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            wizardCard
            marketsCard
        }
    }

    private var wizardCard: some View {
        Card {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.accentGradient)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Setup wizard")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.Color.textPrimary)
                    Text("Re-run the first-launch flow to re-detect Claude, swap your Twelve Data key, or reconfigure the cTrader bridge.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Color.textSecondary)
                }
                Spacer()
                SecondaryButton(title: "Re-run") {
                    app.showWizard = true
                }
            }
        }
    }

    private var marketsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                sectionTitle(
                    icon: "square.grid.2x2",
                    title: "Markets",
                    subtitle: "Toggle which categories appear in the sidebar. Off markets stay in the catalog — re-enabling restores them immediately."
                )

                Toggle(isOn: $forexEnabled) {
                    marketRow(
                        symbol: "dollarsign.circle.fill",
                        title: "Forex",
                        subtitle: "XAU/USD ounce via Yahoo / Twelve Data / cTrader"
                    )
                }
                .toggleStyle(.switch)
                .tint(Theme.Color.accentStart)

                Toggle(isOn: $cryptoEnabled) {
                    marketRow(
                        symbol: "bitcoinsign.circle.fill",
                        title: "Crypto",
                        subtitle: "BTC / SOL / ETH via Twelve Data"
                    )
                }
                .toggleStyle(.switch)
                .tint(Theme.Color.accentStart)

                Toggle(isOn: $indicesEnabled) {
                    marketRow(
                        symbol: "chart.line.uptrend.xyaxis",
                        title: "Indices",
                        subtitle: "Dow Jones (DJI) via Yahoo polling — 15m delayed"
                    )
                }
                .toggleStyle(.switch)
                .tint(Theme.Color.accentStart)
            }
        }
    }

    private func marketRow(symbol: String, title: String, subtitle: String) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Color.textSecondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textMuted)
            }
        }
    }

    // ── AI section (Claude + Codex) ───────────────────────────────

    /// Both engine cards stacked. The analysis page's engine picker
    /// chooses which one runs; these cards configure each.
    private var aiSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            claudeCard
            codexCard
        }
    }

    // ── Codex card ────────────────────────────────────────────────

    private var codexCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                sectionTitle(
                    icon: "chevron.left.forwardslash.chevron.right",
                    title: "Codex (AI analysis)",
                    subtitle: "Model + reasoning effort for the Codex CLI engine. Uses your local `codex` login — no API key. Pick Codex in the engine selector on the analysis page."
                )

                if !codexInstalled {
                    Label("Codex CLI not found on this machine. Install with `npm i -g @openai/codex` (or `brew install codex`), then restart.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.Color.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }

                codexModelPicker
                codexEffortPicker
            }
        }
    }

    private var codexInstalled: Bool { CodexEngine.locateBinary() != nil }

    private var codexModelPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MODEL")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)
            Picker("", selection: $codexModel) {
                ForEach(Self.availableCodexModels, id: \.id) { m in
                    Text(m.label).tag(m.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 320, alignment: .leading)

            Text("Passed to `codex exec -m`. Anything your `codex` login can run works here — edit the list in code to add more.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.Color.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var codexEffortPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("REASONING EFFORT")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)
            HStack(spacing: 6) {
                ForEach(Self.codexEffortLevels, id: \.id) { e in
                    Button {
                        codexEffort = e.id
                    } label: {
                        Text(e.label)
                            .font(.system(size: 11, weight: codexEffort == e.id ? .bold : .medium))
                            .foregroundStyle(codexEffort == e.id ? .white : Theme.Color.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(codexEffort == e.id
                                          ? AnyShapeStyle(Theme.accentGradient)
                                          : AnyShapeStyle(Theme.Color.surface))
                            )
                    }
                    .buttonStyle(.plain)
                    .help(e.tooltip)
                }
                Spacer()
            }
        }
    }

    /// User-visible Codex models (from the CLI's models cache). Codex
    /// passes these straight to `-m`; the effort levels include
    /// `xhigh` which the GPT-5.x line supports beyond Claude's three.
    private static let availableCodexModels: [ClaudeModelOption] = [
        .init(id: "gpt-5.5",        label: "GPT-5.5 (frontier)"),
        .init(id: "gpt-5.4",        label: "GPT-5.4"),
        .init(id: "gpt-5.4-mini",   label: "GPT-5.4 Mini"),
        .init(id: "gpt-5.3-codex",  label: "GPT-5.3 Codex"),
        .init(id: "gpt-5.2",        label: "GPT-5.2"),
    ]

    private static let codexEffortLevels: [EffortOption] = [
        .init(id: "low",     label: "Low",     tooltip: "Fast, lighter reasoning."),
        .init(id: "medium",  label: "Medium",  tooltip: "Balanced default."),
        .init(id: "high",    label: "High",    tooltip: "Deeper reasoning."),
        .init(id: "xhigh",   label: "X-High",  tooltip: "Maximum reasoning depth (GPT-5.x)."),
    ]

    // ── AI / Claude card ──────────────────────────────────────────

    private var claudeCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                sectionTitle(
                    icon: "sparkles",
                    title: "Claude (AI analysis)",
                    subtitle: "Model + reasoning effort the analysis pipeline runs with. Token usage rolls up here from each completed run."
                )

                modelPicker
                effortPicker
                Divider().background(Theme.Color.border)
                usageRow
            }
        }
    }

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MODEL")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)
            Picker("", selection: $claudeModel) {
                ForEach(Self.availableClaudeModels, id: \.id) { m in
                    Text(m.label).tag(m.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 320, alignment: .leading)

            Text(modelHint)
                .font(.system(size: 10))
                .foregroundStyle(Theme.Color.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var effortPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("REASONING EFFORT")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)
            HStack(spacing: 6) {
                ForEach(Self.effortLevels, id: \.id) { e in
                    Button {
                        claudeEffort = e.id
                    } label: {
                        Text(e.label)
                            .font(.system(size: 11, weight: claudeEffort == e.id ? .bold : .medium))
                            .foregroundStyle(claudeEffort == e.id ? .white : Theme.Color.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(claudeEffort == e.id
                                          ? AnyShapeStyle(Theme.accentGradient)
                                          : AnyShapeStyle(Theme.Color.surface))
                            )
                    }
                    .buttonStyle(.plain)
                    .help(e.tooltip)
                }
                Spacer()
            }
        }
    }

    private var usageRow: some View {
        let _ = rollUsageWindows()
        return VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("USAGE")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)
            HStack(spacing: Theme.Spacing.xl) {
                usageStat(label: "Today",       value: formatTokens(tokensToday))
                usageStat(label: "This week",   value: formatTokens(tokensWeek))
            }
            Text("Anthropic enforces 5-hour and weekly limits per plan. The values above are token totals from your local Helix runs — a useful proxy, not the canonical limit numbers.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.Color.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button {
                    if let url = URL(string: "https://console.anthropic.com/settings/usage") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Open Anthropic usage", systemImage: "arrow.up.right.square")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Color.accentStart)
                }
                .buttonStyle(.plain)
                Spacer()
                Button("Reset counters") {
                    tokensToday = 0
                    tokensWeek  = 0
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textMuted)
            }
        }
    }

    private func usageStat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(Theme.Color.textMuted)
            Text(value)
                .font(.system(size: 18, weight: .bold).monospacedDigit())
                .foregroundStyle(Theme.Color.textPrimary)
        }
    }

    private func rollUsageWindows() -> Bool {
        let cal = Calendar(identifier: .iso8601)
        let now = Date()
        let dayKey = Self.dayKeyFmt.string(from: now)
        if dayKey != tokensDayKey {
            tokensDayKey = dayKey
            tokensToday = 0
        }
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        let weekKey = "\(comps.yearForWeekOfYear ?? 0)-W\(comps.weekOfYear ?? 0)"
        if weekKey != tokensWeekKey {
            tokensWeekKey = weekKey
            tokensWeek = 0
        }
        return true
    }

    private static let dayKeyFmt: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    private var modelHint: String {
        switch claudeModel {
        case "claude-opus-4-7":            return "Most capable. Best for full TA, Confluence Trade Scanner, multi-timeframe. Higher cost per run."
        case "claude-opus-4-7[1m]":        return "Opus 4.7 with 1M-token context window — useful for very long histories or multi-pair runs."
        case "claude-sonnet-4-6":          return "Faster, lower cost. Good default for FVG / S&R / chat follow-ups."
        case "claude-haiku-4-5-20251001":  return "Fastest, lowest cost. Best for quick lookups or budget-sensitive runs."
        default:                           return ""
        }
    }

    private static let availableClaudeModels: [ClaudeModelOption] = [
        .init(id: "claude-opus-4-7",              label: "Opus 4.7"),
        .init(id: "claude-opus-4-7[1m]",          label: "Opus 4.7 · 1M context"),
        .init(id: "claude-sonnet-4-6",            label: "Sonnet 4.6"),
        .init(id: "claude-haiku-4-5-20251001",    label: "Haiku 4.5"),
    ]

    private struct ClaudeModelOption: Hashable { let id: String; let label: String }

    private static let effortLevels: [EffortOption] = [
        .init(id: "low",     label: "Low",     tooltip: "Quick, less reasoning."),
        .init(id: "medium",  label: "Medium",  tooltip: "Balanced default."),
        .init(id: "high",    label: "High",    tooltip: "Deepest reasoning."),
    ]

    private struct EffortOption: Hashable { let id: String; let label: String; let tooltip: String }

    // ── Network / proxy card ──────────────────────────────────────

    private var proxyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                sectionTitle(
                    icon: "network.badge.shield.half.filled",
                    title: "SOCKS5 Proxy",
                    subtitle: "Routes outbound HTTP through a SOCKS5 proxy. Useful when a data source is region-locked or when running behind a corporate proxy."
                )

                Toggle(isOn: proxyBinding(\.enabled)) {
                    Text("Enable proxy")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Color.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(Theme.Color.accentStart)

                HStack(spacing: Theme.Spacing.md) {
                    labelled("Host", text: proxyBinding(\.host), placeholder: "127.0.0.1")
                        .frame(maxWidth: .infinity)
                    labelled("Port", number: Binding(
                        get: { proxy.port },
                        set: { proxy.port = $0; proxyDirty = true }
                    ))
                    .frame(width: 110)
                }

                HStack {
                    if case .working = proxyTestState {
                        ProgressView().controlSize(.small)
                    }
                    if case .ok = proxyTestState {
                        Label("Reached Yahoo via proxy", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.Color.success)
                            .font(.system(size: 11, weight: .medium))
                    }
                    if case .failed(let msg) = proxyTestState {
                        Label(msg, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.Color.danger)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(2)
                    }
                    Spacer()
                    SecondaryButton(title: "Test") { testProxy() }
                    PrimaryButton(proxyDirty ? "Apply" : "Saved",
                                  systemImage: proxyDirty ? "checkmark" : nil) {
                        applyProxy()
                    }
                }
            }
        }
    }

    // ── Helpers ────────────────────────────────────────────────────

    private func sectionTitle(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.accentGradient)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            Spacer()
        }
    }

    private func labelled<V>(
        _ label: String,
        text: Binding<String>? = nil,
        number: Binding<Int>? = nil,
        placeholder: String = ""
    ) -> some View where V == Never {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)
            Group {
                if let text = text {
                    TextField(placeholder, text: text)
                } else if let number = number {
                    TextField("", value: number, format: .number)
                        .multilineTextAlignment(.trailing)
                }
            }
            .textFieldStyle(.plain)
            .padding(Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(Theme.Color.surface)
            )
            .foregroundStyle(Theme.Color.textPrimary)
            .font(.system(size: 12, design: .monospaced))
        }
    }

    private func proxyBinding<V>(_ keyPath: WritableKeyPath<ProxyConfig, V>) -> Binding<V> {
        Binding(
            get: { proxy[keyPath: keyPath] },
            set: { proxy[keyPath: keyPath] = $0; proxyDirty = true }
        )
    }

    private func applyProxy() {
        proxy.save()
        ProxyTransport.shared.configure(proxy)
        proxyDirty = false
    }

    private func testProxy() {
        proxyTestState = .working
        ProxyTransport.shared.configure(proxy)
        Task {
            do {
                let url = URL(string: "https://query2.finance.yahoo.com/v8/finance/chart/BTC-USD?interval=1d&range=1d")!
                let (_, resp) = try await ProxyTransport.shared.urlSession.data(from: url)
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    await MainActor.run { proxyTestState = .ok }
                } else {
                    await MainActor.run { proxyTestState = .failed("Unexpected status from Yahoo") }
                }
            } catch {
                await MainActor.run { proxyTestState = .failed(error.localizedDescription) }
            }
        }
    }
}

// ── SettingsCategory model ─────────────────────────────────────────────────

/// Settings left-rail categories. Lives at file scope so other
/// modules (AppState, the dashboard's deep-link gear button) can
/// reference it without nesting through `SettingsView`.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, data, ai, network, ctrader, autoTrader, about
    var id: String { rawValue }
    var label: String {
        switch self {
        case .general:    return "General"
        case .data:       return "Data sources"
        case .ai:         return "AI"
        case .network:    return "Network"
        case .ctrader:    return "cTrader Bridge"
        case .autoTrader: return "Auto-trader"
        case .about:      return "About"
        }
    }
    var symbol: String {
        switch self {
        case .general:    return "gearshape.fill"
        case .data:       return "antenna.radiowaves.left.and.right"
        case .ai:         return "sparkles"
        case .network:    return "network.badge.shield.half.filled"
        case .ctrader:    return "bolt.horizontal.circle.fill"
        case .autoTrader: return "wand.and.rays"
        case .about:      return "info.circle.fill"
        }
    }
    var blurb: String {
        switch self {
        case .general:    return "Markets visible in the sidebar + the first-run setup wizard."
        case .data:       return "Endpoints + API keys for the live data feeds and the AI binary."
        case .ai:         return "Claude model selection, reasoning effort, and token usage rollup."
        case .network:    return "SOCKS5 proxy for region-locked or corporate-network setups."
        case .ctrader:    return "Local TCP bridge that feeds XAU/USD ticks from a cTrader cBot."
        case .autoTrader: return "Per-pair auto-trading: lot size, trailing stops, safety gates. Paper by default; live requires explicit opt-in (XAU/USD only in this build)."
        case .about:      return "App version + links to release notes and the project page."
        }
    }
}
