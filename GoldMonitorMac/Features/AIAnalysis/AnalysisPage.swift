import SwiftUI

/// Full-window AI analysis surface. Replaces the old modal sheet so the
/// streamed report has room to breathe AND the user can see a chart
/// preview of the trade plan they're about to add. Rendered as a ZStack
/// overlay inside DashboardView so the dashboard's @State (xDomain,
/// selected drawing, drawing tool, …) survives the transition.
/// Toggled by `AppState.showAnalysisFullPage`.
///
/// Layout:
///   ┌──────────────────────────────────────────────────────────┐
///   │ ← Back   AI Analysis · Pair · TF             [History]   │
///   │ [Technical][S&R][FVG][MTF]   ENGINE [Claude] [Codex CS]  │
///   ├──────────────────────────────────────────────────────────┤
///   │                            │                              │
///   │  Cleaned markdown report   │   Chart preview              │
///   │  (no JSON walls)           │   ─────────────              │
///   │                            │   PlanCard MAIN              │
///   │                            │   PlanCard ALT (if any)      │
///   │                            │   LevelsCard (if any)        │
///   ├──────────────────────────────────────────────────────────┤
///   │  [Add S/R (N)] [Add FVG (N)]        [Run again] [Clear]  │
///   └──────────────────────────────────────────────────────────┘
struct AnalysisPage: View {
    let pair: TradingPair
    let timeframe: Timeframe
    let candles: [Candle]
    let livePrice: Double?
    /// Loads candles for an arbitrary timeframe — same shape as the
    /// old AnalysisPanel callback, used by the multi-TF run path so
    /// the user can pick a different analysis TF than the chart.
    var loadCandles: ((Timeframe) async -> [Candle])?

    /// Explicit "Add to chart" / "Activate" callbacks. The page calls
    /// these once and then flips `app.showAnalysisFullPage = false`
    /// itself so the user lands on the chart they just configured —
    /// callers only need to apply the payload to their overlay slot.
    var onApplySRLevels: ((PromptBuilder.SRLevels) -> Void)?
    var onApplyFVGZones: (([PromptBuilder.FVGZone]) -> Void)?
    var onApplySupplyDemand: (([PromptBuilder.SupplyDemandZone]) -> Void)?
    var onApplyTAScenario: ((PromptBuilder.TAScenario) -> Void)?
    var onApplyTAAltScenario: ((PromptBuilder.TAScenario) -> Void)?
    /// Receives the scenario AND the source history entry ID (when
    /// available — nil while the run is still streaming and hasn't
    /// produced a HistoryEntry yet). The dashboard threads the ID
    /// onto the resulting Trade so its terminal status stamps back
    /// onto the entry.
    var onActivateTradeFromScenario: ((PromptBuilder.TAScenario, UUID?) -> Void)?

    /// Silent restore callbacks — used by the History "Open" button so
    /// the page stays up while we re-apply the overlays to the chart
    /// behind it. Same target setters as the apply callbacks, but the
    /// page does NOT dismiss after firing them.
    var onRestoreSRLevels: ((PromptBuilder.SRLevels) -> Void)?
    var onRestoreFVGZones: (([PromptBuilder.FVGZone]) -> Void)?
    var onRestoreSupplyDemand: (([PromptBuilder.SupplyDemandZone]) -> Void)?
    var onRestoreTAScenario: ((PromptBuilder.TAScenario) -> Void)?
    var onRestoreTAAltScenario: ((PromptBuilder.TAScenario) -> Void)?

    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var store: AnalysisStore
    /// Optional — News may not have loaded yet (the user might
    /// never have opened the News tab). The event banner just
    /// skips gracefully when there's nothing to show.
    @EnvironmentObject private var news: NewsStore
    /// Read so the Confluence Trade Scanner run path uses the
    /// per-pair `strategyProfile`'s timeframes + horizon hint
    /// (instead of a hardcoded swing trio).
    @EnvironmentObject private var autoTraderConfig: AutoTraderConfigStore
    /// Trade journal — "Add to journal" captures the current analysis
    /// (+ its position) as a journal draft for the user to fill in.
    @EnvironmentObject private var journal: JournalStore

    @State private var showHistory: Bool = false

    // ── Add-to-journal ─────────────────────────────────────────────
    /// Draft journal entry awaiting the editor sheet. Set by the
    /// "Add to journal" buttons; `.sheet(item:)` presents the form.
    @State private var journalDraft: JournalEntry? = nil

    // ── Tab rename ─────────────────────────────────────────────────
    /// The tab whose name is being edited inline (double-click), plus
    /// the working text + focus binding for the rename field.
    @State private var renamingTabID: UUID? = nil
    @State private var renameText: String = ""
    @FocusState private var renameFocused: Bool

    /// Default aspect set seeded into freshly-created tabs (sticky
    /// across tabs via @AppStorage). Per-tab overrides live on the
    /// tab itself.
    @AppStorage("analysis.aspects.v1") private var defaultAspectsCSV: String = "technical,levels,scenarios"

    // ── Per-tab state proxies ──────────────────────────────────────
    // The source of truth is the current `AnalysisTab` in AppState,
    // so switching tabs restores exactly what that tab was doing and
    // each tab runs an independent session.

    private var currentTab: AnalysisTab { app.currentAnalysisTab(for: pair.id) }

    /// Current tab's analysis kind. Defaults to `.combined`; flips to
    /// `.confluenceScanner` on scanner launch or a legacy kind when
    /// opening old history.
    private var selectedKind: AnalysisKind {
        get { currentTab.kind }
        nonmutating set {
            var t = currentTab; t.kind = newValue
            app.updateAnalysisTab(t, for: pair.id)
        }
    }

    /// Current tab's AI engine. Per-tab so each tab's chip can show
    /// which model runs it and the user can mix Claude + Codex across
    /// tabs. Writing flips the tab's engine in AppState.
    private var selectedEngine: AIEngineKind {
        get { currentTab.engine }
        nonmutating set {
            var t = currentTab; t.engine = newValue
            app.updateAnalysisTab(t, for: pair.id)
        }
    }

    /// Read-only profile accessor (writes go through `scenarioProfileBinding`).
    private var scenarioProfile: StrategyProfile { currentTab.profile }

    private var scenarioProfileBinding: Binding<StrategyProfile> {
        Binding(
            get: { currentTab.profile },
            set: { newValue in
                var t = currentTab; t.profile = newValue
                app.updateAnalysisTab(t, for: pair.id)
            }
        )
    }
    /// Tab IDs whose Confluence Scanner "Expand to market structure?"
    /// prompt the user has dismissed. Keyed by tab so dismissing in
    /// one tab doesn't hide it in another.
    @State private var confluenceExpandDismissedFor: Set<UUID> = []

    /// Single source of truth for every parsed structured
    /// payload (SR levels, FVG zones, S&D zones, scored
    /// scenarios, TA scenario + alt). Refreshed once per
    /// `session.report` change in `refreshParsedPayloads()` — the
    /// per-property accessors below read this cache instead of
    /// re-parsing on every render. Six brace-walking parsers
    /// running 3× each per body invocation was the dominant
    /// cause of the page lag.
    @State private var parsedPayloads = ParsedPayloads()

    private struct ParsedPayloads: Equatable {
        var srLevels: PromptBuilder.SRLevels = .init(support: [], resistance: [])
        var fvgZones: [PromptBuilder.FVGZone] = []
        var supplyDemand: [PromptBuilder.SupplyDemandZone] = []
        var scored: [PromptBuilder.ScoredScenario] = []
        var taScenario: PromptBuilder.TAScenario? = nil
        var taAltScenario: PromptBuilder.TAScenario? = nil
    }
    /// Visibility flag for the strategy-profile picker sheet.
    /// Fires from the Analyze + Run Again paths when the current
    /// kind is `.confluenceScanner` — Full TA / S&R / FVG / MTF
    /// stay on a fast no-popup path.
    @State private var profilePickerVisible: Bool = false

    /// Parsed CLARIFY_JSON from the combined run (the model asking
    /// the user to narrow scope). Refreshed alongside the other
    /// payloads; nil for normal runs.
    @State private var parsedClarify: PromptBuilder.ClarifyRequest? = nil

    /// Binding bridge between the current tab's aspect CSV and the
    /// card's `Set<AnalysisAspect>`. Also updates the @AppStorage
    /// default so the next new tab inherits the latest pick.
    private var selectedAspects: Binding<Set<AnalysisAspect>> {
        Binding(
            get: { Set(csv: currentTab.aspectsCSV) },
            set: { newValue in
                var t = currentTab; t.aspectsCSV = newValue.csv
                app.updateAnalysisTab(t, for: pair.id)
                defaultAspectsCSV = newValue.csv
            }
        )
    }

    /// Triggers a re-render every 30 seconds while the page is
    /// open so the event countdown stays fresh ("starts in 12 min"
    /// → "starts in 11 min"). Cheap — no network, just a tick.
    @State private var countdownTick: Date = Date()

    private var session: AnalysisStore.Session {
        store.session(kind: currentTab.kind, pairID: pair.id, tabID: currentTab.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.Color.border)
            if let event = upcomingHighImpactEvent {
                eventWarningBanner(event)
            }
            if showHistory {
                AnalysisHistoryView(
                    pair: pair,
                    kind: selectedKind,
                    onOpen: { entry in
                        store.loadFromHistory(entry, tabID: currentTab.id)
                        selectedKind = entry.kind
                        showHistory = false
                        // Re-apply each captured overlay via the silent
                        // restore callbacks — these don't dismiss the
                        // page, so the user can read the loaded report
                        // alongside the chart they just restored.
                        if let sr = entry.srLevels, !sr.isEmpty {
                            onRestoreSRLevels?(sr)
                        }
                        if let fvg = entry.fvgZones, !fvg.isEmpty {
                            onRestoreFVGZones?(fvg)
                        }
                        if let sd = entry.supplyDemandZones, !sd.isEmpty {
                            onRestoreSupplyDemand?(sd)
                        }
                        if let scenario = entry.taScenario {
                            onRestoreTAScenario?(scenario)
                        }
                        if let alt = entry.taAltScenario {
                            onRestoreTAAltScenario?(alt)
                        }
                    },
                    onDismiss: { showHistory = false }
                )
            } else {
                bodyContent
                if confluenceExpandPromptVisible {
                    confluenceExpandPrompt
                }
                if session.phase != .idle {
                    AnalysisActionDock(
                        phase: session.phase,
                        engineReady: engineReady,
                        srLevels: parsedSRLevels.isEmpty ? nil : parsedSRLevels,
                        fvgZones: parsedFVGZones.isEmpty ? nil : parsedFVGZones,
                        onAddSRLevels: { apply { onApplySRLevels?(parsedSRLevels) } },
                        onAddFVGZones: { apply { onApplyFVGZones?(parsedFVGZones) } },
                        onAddToJournal: { addToJournal(scenario: parsedTAScenario) },
                        onStop:     { store.stop(kind: selectedKind, pairID: pair.id, tabID: currentTab.id) },
                        onClear:    { store.clear(kind: selectedKind, pairID: pair.id, tabID: currentTab.id) },
                        // Combined "Run again" returns to the
                        // checklist card so the user can re-pick
                        // aspects; other kinds re-fire directly.
                        onRunAgain: {
                            if selectedKind == .combined {
                                store.clear(kind: .combined, pairID: pair.id, tabID: currentTab.id)
                            } else {
                                runAnalysis()
                            }
                        }
                    )
                }
            }
        }
        .background(Theme.Color.canvas)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $profilePickerVisible) {
            confluenceProfileSheet
        }
        .sheet(item: $journalDraft) { draft in
            JournalEntrySheet(
                entry: draft,
                onSave: { journal.add($0) }
            )
            .environmentObject(app)
        }
        .task {
            // Make sure the news feed is loaded so the warning
            // banner has something to work with. NewsStore
            // coalesces in-flight requests, so calling refresh()
            // when it's already loading is a no-op.
            news.refresh()
            // Tick the countdown every 30s while the page is on
            // screen. Long-lived loop with cancellation tied to
            // the View task scope.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                countdownTick = Date()
            }
        }
        .onAppear { refreshParsedPayloads() }
        .onChange(of: session.report) { _ in refreshParsedPayloads() }
        .onChange(of: selectedKind)  { _ in refreshParsedPayloads() }
        .onChange(of: currentAnalysisTabID) { _ in refreshParsedPayloads() }
    }

    /// Re-read of the current-tab id so `.onChange` fires when the
    /// user switches tabs (the parsed payloads belong to the new
    /// tab's session).
    private var currentAnalysisTabID: UUID { currentTab.id }

    // ── Economic-event warning banner ──────────────────────────────

    /// First high-impact USD event in the next 30 minutes (or
    /// currently happening, within ±15min of its start). Gold is
    /// event-driven, so a FOMC / CPI / NFP release minutes away
    /// makes any technical analysis dangerous — surface it loudly
    /// at the top of the page so the user thinks twice before
    /// committing.
    private var upcomingHighImpactEvent: ForexFactoryEvent? {
        _ = countdownTick   // re-read so the @State tick reruns this
        let now = Date()
        let window: TimeInterval = 30 * 60
        let pastWindow: TimeInterval = 15 * 60
        return news.events.first { event in
            guard event.impactLevel == .high,
                  event.currency.uppercased() == "USD",
                  let at = event.eventAt
            else { return false }
            let delta = at.timeIntervalSince(now)
            return delta <= window && delta >= -pastWindow
        }
    }

    private func eventWarningBanner(_ event: ForexFactoryEvent) -> some View {
        let delta = event.eventAt?.timeIntervalSince(Date()) ?? 0
        let countdown: String = {
            let mins = Int(abs(delta) / 60)
            if delta > 60   { return "in \(mins) min" }
            if delta < -60  { return "started \(mins) min ago" }
            return "now"
        }()
        return HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.Color.warn)
            VStack(alignment: .leading, spacing: 2) {
                Text("High-impact USD event \(countdown)")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(Theme.Color.warn)
                Text(event.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                if !event.forecast.isEmpty || !event.previous.isEmpty {
                    Text("Forecast: \(event.forecast.isEmpty ? "—" : event.forecast) · Previous: \(event.previous.isEmpty ? "—" : event.previous)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(Theme.Color.textMuted)
                }
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Theme.Color.warn.opacity(0.12))
        .overlay(
            Rectangle()
                .fill(Theme.Color.warn.opacity(0.6))
                .frame(height: 2),
            alignment: .bottom
        )
    }

    // ── Body content (two columns) ─────────────────────────────────
    @ViewBuilder
    private var bodyContent: some View {
        if selectedKind == .multiTimeframe {
            AnalysisReportColumn(
                session: session,
                idleHint: idleHint,
                unavailableHint: unavailableHint,
                engineReady: engineReady,
                onAnalyze: { runAnalysis() },
                onAskFollowUp: { question in
                    store.askFollowUp(
                        kind: selectedKind,
                        pairID: pair.id,
                        engineKind: selectedEngine,
                        question: question,
                        tabID: currentTab.id
                    )
                }
            )
        } else {
            HStack(spacing: 0) {
                AnalysisReportColumn(
                    session: session,
                    idleHint: idleHint,
                    unavailableHint: unavailableHint,
                    engineReady: engineReady,
                    onAnalyze: { runAnalysis() },
                    onAskFollowUp: { question in
                        store.askFollowUp(
                            kind: selectedKind,
                            pairID: pair.id,
                            engineKind: selectedEngine,
                            question: question
                        )
                    },
                    onSubmitInitial: combinedInitialSubmit,
                    inputChips: (selectedKind == .custom || selectedKind == .combined) ? customChips : [],
                    inputPlaceholder: (selectedKind == .custom || selectedKind == .combined)
                        ? "Ask anything about \(pair.name) at \(timeframe.label)…"
                        : "Ask a follow-up about this analysis…",
                    idleAccessory: selectedKind == .combined
                        ? AnyView(
                            AnalysisAspectCard(
                                selected: selectedAspects,
                                profile: scenarioProfileBinding,
                                engineReady: engineReady,
                                onRun: { runCombinedAction() },
                                onRunConfluenceScanner: { launchConfluenceScanner() },
                                onRunTopDownSniperSwing: { launchTopDownSniper([.h4, .h1, .m15]) },
                                onRunTopDownSniperIntraday: { launchTopDownSniper([.h1, .m15, .m1]) }
                            )
                          )
                        : nil,
                    clarify: parsedClarify,
                    onClarifyPick: { id in onClarifyPick(id) }
                )
                .frame(maxWidth: .infinity)

                Divider().background(Theme.Color.border)

                AnalysisPlansColumn(
                    kind: selectedKind,
                    pair: pair,
                    candles: candles,
                    livePrice: livePrice,
                    srLevels: parsedSRLevels,
                    fvgZones: parsedFVGZones,
                    supplyDemandZones: parsedSupplyDemandZones,
                    scoredScenarios: parsedScoredScenarios,
                    taScenario: parsedTAScenario,
                    taAltScenario: parsedTAAltScenario,
                    onAddSRLevels:      { apply { onApplySRLevels?(parsedSRLevels) } },
                    onAddFVGZones:      { apply { onApplyFVGZones?(parsedFVGZones) } },
                    onAddSupplyDemand:  { apply { onApplySupplyDemand?(parsedSupplyDemandZones) } },
                    onApplyMainPlan:    { if let s = parsedTAScenario    { apply { onApplyTAScenario?(s) } } },
                    onApplyAltPlan:     { if let a = parsedTAAltScenario { apply { onApplyTAAltScenario?(a) } } },
                    onActivateMainPlan: { if let s = parsedTAScenario    { apply { onActivateTradeFromScenario?(s, sourceHistoryEntryID(for: s)) } } },
                    onActivateScored:   { s in apply { onActivateTradeFromScenario?(s.scenario, sourceHistoryEntryID(for: s.scenario)) } },
                    onJournalMainPlan:  { addToJournal(scenario: parsedTAScenario) },
                    onJournalAltPlan:   { addToJournal(scenario: parsedTAAltScenario) },
                    onJournalScored:    { s in addToJournal(scenario: s.scenario) }
                )
                .frame(maxWidth: .infinity)
            }
        }
    }

    // ── Tab bar (browser-style) ────────────────────────────────────
    private var tabBar: some View {
        let tabs = app.analysisTabs(for: pair.id)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(tabs) { tab in
                    tabChip(tab, canClose: tabs.count > 1)
                }
                Button {
                    app.addAnalysisTab(
                        for: pair.id,
                        aspectsCSV: defaultAspectsCSV,
                        profile: scenarioProfile,
                        engine: selectedEngine
                    )
                    showHistory = false
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .frame(width: 26, height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surface))
                }
                .buttonStyle(.plain)
                .help("New analysis tab")
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.top, 6)
        }
    }

    private func tabChip(_ tab: AnalysisTab, canClose: Bool) -> some View {
        let isCurrent = tab.id == currentTab.id
        let running = store.session(kind: tab.kind, pairID: pair.id, tabID: tab.id).phase == .running
        let isRenaming = renamingTabID == tab.id
        return HStack(spacing: 6) {
            if running {
                Circle()
                    .fill(isCurrent ? Color.white : Theme.Color.accentStart)
                    .frame(width: 6, height: 6)
            }
            // Which engine runs this tab — shown as the brand glyph so
            // every tab carries its model at a glance.
            EngineGlyph(kind: tab.engine, size: 12)
                .help(tab.engine.label)
            if isRenaming {
                TextField("Name", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(isCurrent ? .white : Theme.Color.textPrimary)
                    .frame(width: 84)
                    .focused($renameFocused)
                    .onSubmit { commitRename(tab) }
                    .onChange(of: renameFocused) { focused in
                        if !focused { commitRename(tab) }
                    }
            } else {
                Text(tab.displayName)
                    .font(.system(size: 11, weight: isCurrent ? .bold : .medium))
                    .foregroundStyle(isCurrent ? .white : Theme.Color.textSecondary)
                    .lineLimit(1)
            }
            if canClose {
                Button {
                    // Stop any in-flight run for the tab before
                    // closing so we don't leak a streaming task.
                    store.stop(kind: tab.kind, pairID: pair.id, tabID: tab.id)
                    app.closeAnalysisTab(tab.id, for: pair.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(isCurrent ? .white.opacity(0.8) : Theme.Color.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isCurrent ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.Color.surface))
        )
        .contentShape(Rectangle())
        // Double-click renames; single click selects. Order matters —
        // the higher-count gesture is declared first so SwiftUI gives
        // it priority.
        .onTapGesture(count: 2) { startRename(tab) }
        .onTapGesture {
            app.selectAnalysisTab(tab.id, for: pair.id)
            showHistory = false
        }
        .help("Double-click to rename")
    }

    private func startRename(_ tab: AnalysisTab) {
        app.selectAnalysisTab(tab.id, for: pair.id)
        renameText = tab.displayName
        renamingTabID = tab.id
        renameFocused = true
    }

    private func commitRename(_ tab: AnalysisTab) {
        guard renamingTabID == tab.id else { return }
        var t = tab
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Blank ⇒ clear the custom title so it falls back to the
        // kind-derived name rather than showing an empty chip.
        t.customTitle = trimmed.isEmpty ? nil : trimmed
        app.updateAnalysisTab(t, for: pair.id)
        renamingTabID = nil
    }

    // ── Header ─────────────────────────────────────────────────────
    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            tabBar
            HStack(spacing: Theme.Spacing.md) {
                backButton
                Label("AI Analysis", systemImage: "sparkles")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text("·")
                    .foregroundStyle(Theme.Color.textMuted)
                Text(pair.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Color.textSecondary)
                Text("·")
                    .foregroundStyle(Theme.Color.textMuted)
                Text(timeframe.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Color.textSecondary)
                Spacer()
                historyButton
            }
            HStack(spacing: Theme.Spacing.md) {
                // Legacy chip picker only when viewing an old
                // non-combined history entry (so its report still
                // makes sense). New analysis uses the checklist card.
                if selectedKind != .combined {
                    Text(selectedKind.label)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accentGradient))
                    Button("New analysis") {
                        selectedKind = .combined
                        showHistory = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Color.accentStart)
                }
                Spacer()
                enginePicker
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
        .padding(.top, 4)
    }

    private var backButton: some View {
        Button {
            app.showAnalysisFullPage = false
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 11, weight: .semibold))
                Text("Back to chart")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Theme.Color.textSecondary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surface)
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
    }

    private var historyButton: some View {
        Button {
            showHistory.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: showHistory ? "arrow.left" : "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                Text(showHistory
                     ? "Back to live"
                     : (historyForKind.isEmpty ? "History" : "History (\(historyForKind.count))"))
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Theme.Color.textSecondary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surface)
            )
        }
        .buttonStyle(.plain)
    }

    /// Engine selector — brand glyphs only (no names). The selected
    /// engine gets a brand-tinted fill + ring; a "coming soon" engine
    /// shows a small badge and is disabled. The model name lives in the
    /// tooltip for anyone who needs it spelled out.
    private var enginePicker: some View {
        HStack(spacing: 6) {
            Text("ENGINE")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)
            ForEach(AIEngineKind.allCases) { kind in
                let engine = AIEngineFactory.make(kind)
                let isComingSoon: Bool = {
                    if case .comingSoon = engine.availability { return true }
                    return false
                }()
                let selected = selectedEngine == kind && !isComingSoon
                Button {
                    if !isComingSoon { selectedEngine = kind }
                } label: {
                    EngineGlyph(kind: kind, size: 17)
                        .opacity(isComingSoon ? 0.4 : 1)
                        .frame(width: 36, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(selected ? kind.brandColor.opacity(0.18) : Theme.Color.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(selected ? kind.brandColor : Color.clear, lineWidth: 1.5)
                        )
                        .overlay(alignment: .topTrailing) {
                            if isComingSoon {
                                Circle()
                                    .fill(Theme.Color.warn)
                                    .frame(width: 5, height: 5)
                                    .offset(x: 2, y: -2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .disabled(session.phase == .running || isComingSoon)
                .help(isComingSoon ? "\(kind.label) — coming soon" : kind.label)
            }
        }
    }

    private var historyForKind: [AnalysisStore.HistoryEntry] {
        store.history.filter { $0.kind == selectedKind && $0.pairID == pair.id }
    }

    // ── Run / apply ────────────────────────────────────────────────
    private func runAnalysis() {
        switch selectedKind {
        case .combined:
            runCombinedAction()
        case .topDownSniper:
            runTopDownSniperAnalysis()
        case .multiTimeframe:
            runMultiTimeframeAnalysis()
        case .confluenceScanner:
            // CTS runs always go through the strategy-profile
            // picker — the user explicitly chooses Position /
            // Swing / Scalp before each analyze so the
            // timeframes + prompt-horizon match their intent.
            profilePickerVisible = true
        case .full, .supportResistance, .fvg:
            runSingleTFAnalysis()
        case .custom:
            // Custom is chat-driven from the input bar (see
            // `runCustomChat`), not from a top-level Analyze
            // button. A code path that lands here without a
            // message has nothing to send, so we no-op rather
            // than firing a hardcoded "please analyze" request.
            return
        }
    }

    /// Chat-style entry for the `.custom` kind. The user's typed
    /// message becomes the task line in the user prompt; the
    /// system message is the canned conversational analyst from
    /// `systemCustomDefault`. Reuses the same HTF-context fetch
    /// the other single-TF kinds use so the model sees the bigger
    /// picture before answering. Once the first message returns,
    /// subsequent messages flow through the standard follow-up
    /// path (`store.askFollowUp`) so the conversation continues
    /// without re-fetching context.
    private func runCustomChat(message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let htfTimeframe = higherTimeframe(above: timeframe),
              let loader = loadCandles
        else {
            store.run(
                kind: .custom, engineKind: selectedEngine,
                pair: pair, timeframe: timeframe, candles: candles,
                customTask: trimmed, tabID: currentTab.id
            )
            return
        }
        Task {
            let htfCandles = await loader(htfTimeframe)
            let htf: PromptBuilder.HTFContext? = htfCandles.isEmpty
                ? nil
                : PromptBuilder.HTFContext(
                    timeframe: htfTimeframe,
                    snapshot: MarketSnapshot.compute(htfCandles)
                )
            await MainActor.run {
                store.run(
                    kind: .custom, engineKind: selectedEngine,
                    pair: pair, timeframe: timeframe, candles: candles,
                    htf: htf, customTask: trimmed, tabID: currentTab.id
                )
            }
        }
    }

    /// Quick-fill chips for the chat input. Tap populates the
    /// input box (doesn't auto-send) so the user can edit before
    /// submitting. Kept short and action-oriented — these are
    /// starter questions, not analysis recipes.
    private var customChips: [AnalysisReportColumn.InputChip] {
        [
            .init(label: "Setup?",       body: "What's the cleanest trade setup on this pair right now? Give me entry, TP, SL."),
            .init(label: "Key levels",   body: "List the 3-5 most important support and resistance levels and emit a LEVELS_JSON block."),
            .init(label: "Find FVGs",    body: "Identify any unmitigated fair-value gaps in the visible bars and emit an FVG_JSON block."),
            .init(label: "Long bias",    body: "I want to go long. Where would you enter, where's TP, where's the invalidation? Emit SCENARIO_JSON."),
            .init(label: "Short bias",   body: "I want to go short. Where would you enter, where's TP, where's the invalidation? Emit SCENARIO_JSON."),
        ]
    }

    /// Single-TF run with optional higher-TF context. We fetch the
    /// higher TF asynchronously (when there is one — daily charts
    /// have no HTF above them) and pass its precomputed snapshot to
    /// the store. Falls back to a context-free run if the loader
    /// isn't wired or the higher-TF fetch returns empty.
    private func runSingleTFAnalysis() {
        guard let htfTimeframe = higherTimeframe(above: timeframe),
              let loader = loadCandles
        else {
            store.run(
                kind: selectedKind, engineKind: selectedEngine,
                pair: pair, timeframe: timeframe, candles: candles,
                tabID: currentTab.id
            )
            return
        }
        Task {
            let htfCandles = await loader(htfTimeframe)
            let htf: PromptBuilder.HTFContext? = htfCandles.isEmpty
                ? nil
                : PromptBuilder.HTFContext(
                    timeframe: htfTimeframe,
                    snapshot: MarketSnapshot.compute(htfCandles)
                )
            await MainActor.run {
                store.run(
                    kind: selectedKind, engineKind: selectedEngine,
                    pair: pair, timeframe: timeframe, candles: candles,
                    htf: htf, tabID: currentTab.id
                )
            }
        }
    }

    /// Pick the next higher timeframe for the HTF context block. The
    /// jump factor mirrors how traders actually layer TFs (4× rule:
    /// 15m → 1h, 1h → 4h, 4h → 1d). Returns nil for `.d1` since
    /// we don't carry weekly bars.
    private func higherTimeframe(above tf: Timeframe) -> Timeframe? {
        switch tf {
        case .m1:  return .m15
        case .m5:  return .m30
        case .m15: return .h1
        case .m30: return .h4
        case .h1:  return .h4
        case .h4:  return .d1
        case .d1:  return nil
        }
    }

    private func runMultiTimeframeAnalysis() {
        let tabID = currentTab.id
        runMultiTFBundle { byTF in
            store.runMultiTimeframe(
                engineKind: selectedEngine,
                pair: pair,
                candlesByTF: byTF,
                tabID: tabID
            )
        }
    }

    // ── Combined (checklist) run ───────────────────────────────────

    /// Free-text submit handler for the report column's chat bar.
    /// Combined + Custom both accept a first typed message; other
    /// kinds disable the idle input (nil).
    private var combinedInitialSubmit: ((String) -> Void)? {
        switch selectedKind {
        case .custom:   return { runCustomChat(message: $0) }
        case .combined: return { text in runCombinedAction(freeText: text) }
        default:        return nil
        }
    }

    /// Fire the combined analysis from the ticked aspects (+ optional
    /// free text). Bundles the timeframe trio when any aspect needs
    /// multi-TF context; otherwise just the chart's focus TF.
    private func runCombinedAction(freeText: String? = nil) {
        let tab = currentTab
        let aspects = Set<AnalysisAspect>(csv: tab.aspectsCSV)
        // Nothing to do if neither aspects nor free text are present.
        let trimmedText = (freeText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !aspects.isEmpty || !trimmedText.isEmpty else { return }
        parsedClarify = nil
        let needsMTF = aspects.contains { $0.needsMultiTF }
        let tfs: [Timeframe] = needsMTF
            ? (aspects.contains(.scenarios) ? tab.profile.meta.timeframes : [.m15, .h1, .h4])
            : [timeframe]
        let horizon = aspects.contains(.scenarios) ? tab.profile.meta.horizonText : nil
        runMultiTFBundle(timeframes: tfs) { byTF in
            store.runCombined(
                engineKind: selectedEngine,
                pair: pair,
                focusTimeframe: timeframe,
                candlesByTF: byTF,
                aspects: aspects,
                horizonHint: horizon,
                freeText: trimmedText.isEmpty ? nil : trimmedText,
                tabID: tab.id
            )
        }
    }

    /// Launch the Top-Down Sniper from the checklist card on a given
    /// HTF→MTF→LTF trio. No profile — the timeframe roles are baked
    /// into the model. Swing = 4H/1H/15m, Intraday = 1H/15m/1m.
    private func launchTopDownSniper(_ trio: [Timeframe]) {
        selectedKind = .topDownSniper
        runTopDownSniperAnalysis(trio)
    }

    private func runTopDownSniperAnalysis(_ trio: [Timeframe] = [.h4, .h1, .m15]) {
        let tabID = currentTab.id
        runMultiTFBundle(timeframes: trio) { byTF in
            store.runTopDownSniper(
                engineKind: selectedEngine,
                pair: pair,
                candlesByTF: byTF,
                tabID: tabID
            )
        }
    }

    /// Launch the dedicated Confluence Trade Scanner from the
    /// checklist card. Applies the card's chosen profile to the
    /// pair config (the scanner reads it), switches the page to the
    /// `.confluenceScanner` kind, and fires the existing scored-
    /// scenario flow (including its opt-in Expand step).
    private func launchConfluenceScanner() {
        var c = autoTraderConfig.config(for: pair.id)
        c.applyProfile(scenarioProfile)
        autoTraderConfig.update(c, for: pair.id)
        selectedKind = .confluenceScanner
        runConfluenceScannerAnalysis()
    }

    /// Handle a tap on a clarify option. "all" re-runs the full set
    /// with a do-not-ask nudge; a specific aspect id narrows to just
    /// that one and re-runs.
    private func onClarifyPick(_ id: String) {
        parsedClarify = nil
        if id == "all" {
            runCombinedAction(freeText: "Produce all requested aspects in full now — do not ask to narrow.")
            return
        }
        if let one = AnalysisAspect(rawValue: id) {
            selectedAspects.wrappedValue = Set([one])
            runCombinedAction()
        }
    }

    /// Picker shown every time the user triggers a CTS run from
    /// the analysis page. Snaps the per-pair config to the
    /// chosen profile and fires the analysis on confirm.
    private var confluenceProfileSheet: some View {
        let cfg = autoTraderConfig.config(for: pair.id)
        return StrategyProfileSheet(
            title: "Confluence Scanner — pick profile",
            subtitle: "Determines the timeframes the scanner bundles and the horizon the model uses for stops + targets.",
            currentProfile: cfg.strategyProfile,
            confirmLabel: "Start Analysis",
            onPick: { profile in
                var c = cfg
                c.applyProfile(profile)
                autoTraderConfig.update(c, for: pair.id)
                profilePickerVisible = false
                runConfluenceScannerAnalysis()
            },
            onCancel: { profilePickerVisible = false }
        )
    }

    private func runConfluenceScannerAnalysis() {
        // A fresh Confluence Trade Scanner run wipes the per-tab dismissal so
        // the expand prompt re-offers itself after the new
        // stage 1 settles.
        let tabID = currentTab.id
        confluenceExpandDismissedFor.remove(tabID)
        let profile = autoTraderConfig.config(for: pair.id).strategyProfile
        runMultiTFBundle(timeframes: profile.meta.timeframes) { byTF in
            store.runConfluenceScanner(
                engineKind: selectedEngine,
                pair: pair,
                candlesByTF: byTF,
                horizonHint: profile.meta.horizonText,
                tabID: tabID
            )
        }
    }

    private func runConfluenceScannerExpandAction() {
        let tabID = currentTab.id
        let profile = autoTraderConfig.config(for: pair.id).strategyProfile
        runMultiTFBundle(timeframes: profile.meta.timeframes) { byTF in
            store.runConfluenceScannerExpand(
                engineKind: selectedEngine,
                pair: pair,
                candlesByTF: byTF,
                tabID: tabID
            )
        }
    }

    // ── Confluence Trade Scanner Expand prompt ─────────────────────────────────────

    /// Shown once Stage 1 (S&D) finishes and the user hasn't yet
    /// run Stage 2 or dismissed the prompt for this pair. Gated
    /// on the absence of a `SCENARIOS_JSON` block so it
    /// disappears the moment Stage 2 begins streaming.
    private var confluenceExpandPromptVisible: Bool {
        guard selectedKind == .confluenceScanner,
              session.phase == .done,
              !session.report.contains("SCENARIOS_JSON"),
              session.report.contains("SCENARIO_JSON"),
              !confluenceExpandDismissedFor.contains(currentTab.id)
        else { return false }
        return true
    }

    private var confluenceExpandPrompt: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.Color.accentStart)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Next step — scan market structure?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text("Adds breakout / range / liquidity-grab / trend-continuation patterns to the S&D analysis above and produces a scored scenario queue for the auto-trader. Skip to keep the analysis as-is.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            HStack(spacing: 8) {
                Button("Skip") {
                    confluenceExpandDismissedFor.insert(currentTab.id)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Color.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.Color.surface)
                )

                Button("Continue") {
                    runConfluenceScannerExpandAction()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.accentGradient)
                )
                .disabled(!engineReady)
                .opacity(engineReady ? 1 : 0.5)
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
        .background(
            Rectangle()
                .fill(Theme.Color.accentStart.opacity(0.08))
                .overlay(
                    Rectangle()
                        .frame(height: 1)
                        .foregroundStyle(Theme.Color.border),
                    alignment: .top
                )
        )
    }

    /// Shared multi-TF candle loader. Pulls the requested
    /// timeframes via the dashboard's loader (falls back to the
    /// current candles for each slot if no loader was wired) and
    /// hands the bundle to `start` on the main actor. Defaults to
    /// 15m/1h/4h (swing) so non-CTS callers stay unchanged; CTS
    /// callers pass the per-pair profile's timeframes.
    private func runMultiTFBundle(
        timeframes: [Timeframe] = [.m15, .h1, .h4],
        start: @escaping ([(Timeframe, [Candle])]) -> Void
    ) {
        Task {
            var byTF: [(Timeframe, [Candle])] = []
            if let loader = loadCandles {
                for tf in timeframes {
                    let cs = await loader(tf)
                    byTF.append((tf, cs))
                }
            } else {
                byTF = timeframes.map { ($0, candles) }
            }
            await MainActor.run { start(byTF) }
        }
    }

    /// Single funnel for every "Add to chart" / "Activate" click in
    /// the page: fire the apply closure (which sets the dashboard's
    /// overlay slot or opens the activation sheet), then dismiss the
    /// page so the user lands back on the chart.
    private func apply(_ action: () -> Void) {
        action()
        app.showAnalysisFullPage = false
    }

    /// Build a journal draft from the current analysis (+ an optional
    /// scenario for the position) and present the editor. The draft
    /// captures the engine, kind, timeframe(s), a cleaned report
    /// excerpt, and the source history-entry id when known — so the
    /// journal keeps the reasoning next to the eventual result. Unlike
    /// the chart/activate flows this does NOT dismiss the page; the
    /// sheet floats over it.
    private func addToJournal(scenario: PromptBuilder.TAScenario?) {
        let engineLabel = AIEngineFactory.make(selectedEngine).label
        let tfLabel = session.timeframeLabel.isEmpty ? timeframe.label : session.timeframeLabel
        let reportExcerpt: String? = {
            let trimmed = session.report.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let clean = PromptBuilder.stripStructuredBlocks(trimmed)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? nil : String(clean.prefix(4000))
        }()
        let side: JournalEntry.Side = {
            switch scenario?.bias {
            case .long:    return .long
            case .short:   return .short
            case .neutral: return .neutral
            case .none:    return .long
            }
        }()
        journalDraft = JournalEntry(
            pairID: pair.id,
            pairName: pair.name,
            side: side,
            entry: scenario?.entry,
            takeProfit: scenario?.takeProfit,
            stopLoss: scenario?.stopLoss,
            sourceHistoryEntryID: scenario.flatMap { sourceHistoryEntryID(for: $0) },
            aiEngineLabel: engineLabel,
            aiKindLabel: selectedKind.label,
            aiTimeframeLabel: tfLabel,
            aiReportExcerpt: reportExcerpt
        )
    }

    /// Find the most recent history entry that matches the running
    /// scenario for this (pair, kind) so the activation flow can
    /// thread its ID onto the resulting Trade. Returns nil while
    /// the session is still streaming (no entry recorded yet) — the
    /// trade just won't contribute to the win-rate stat.
    private func sourceHistoryEntryID(for scenario: PromptBuilder.TAScenario) -> UUID? {
        store.history.first { entry in
            entry.pairID == pair.id
            && entry.kind == selectedKind
            && entry.taScenario?.id == scenario.id
        }?.id
    }

    // ── Engine / idle hints ────────────────────────────────────────
    private var engineReady: Bool {
        AIEngineFactory.make(selectedEngine).availability.canRun
    }

    private var unavailableHint: String? {
        switch AIEngineFactory.make(selectedEngine).availability {
        case .ready:           return nil
        case .comingSoon:      return "\(selectedEngine.label) is coming soon — pick another engine."
        case .notReady(let h): return h
        }
    }

    private var idleHint: String {
        switch selectedKind {
        case .combined:
            return "Pick what to analyze on \(pair.name) at \(timeframe.label)."
        case .topDownSniper:
            return "Run **\(selectedEngine.label)** for **Top-Down Sniper** on \(pair.name) — 4H bias, 1H setup, 15m entry."
        case .multiTimeframe:
            return "Run **\(selectedEngine.label)** for **Multi-Timeframe Analysis** on \(pair.name) across 15m, 1h, and 4h."
        case .confluenceScanner:
            return "Run **\(selectedEngine.label)** for **Confluence Trade Scanner** on \(pair.name) across 15m, 1h, and 4h — scans for impulsive breakouts that left an FVG, then frames an entry against the last opposite-direction candle."
        case .custom:
            // The custom path uses CustomPromptEditor instead of
            // the idle hint, but keep the string defined for
            // exhaustiveness — and as a fallback if some other
            // code path surfaces it (e.g. follow-up chat re-using
            // the kind label).
            return "Write your own prompt in the editor and run it against **\(pair.name)** at \(timeframe.label)."
        case .full, .supportResistance, .fvg:
            return "Run **\(selectedEngine.label)** for **\(selectedKind.label)** on \(pair.name) at \(timeframe.label)."
        }
    }

    // ── Parsed payloads ────────────────────────────────────────────
    //
    // `.custom` is permissive on every block — the user's prompt
    // can ask for any combination, so we try them all and let the
    // right column render whatever actually parsed. The other
    // kinds keep their tight whitelists so e.g. a Confluence Trade Scanner run
    // doesn't accidentally show a half-parsed FVG block from
    // unrelated narrative text.

    private var parsedSRLevels: PromptBuilder.SRLevels { parsedPayloads.srLevels }
    private var parsedFVGZones: [PromptBuilder.FVGZone] { parsedPayloads.fvgZones }
    private var parsedSupplyDemandZones: [PromptBuilder.SupplyDemandZone] { parsedPayloads.supplyDemand }
    private var parsedScoredScenarios: [PromptBuilder.ScoredScenario] { parsedPayloads.scored }
    private var parsedTAScenario: PromptBuilder.TAScenario? { parsedPayloads.taScenario }
    private var parsedTAAltScenario: PromptBuilder.TAScenario? { parsedPayloads.taAltScenario }

    /// Re-parse every structured payload from the current
    /// session report. Called once per `session.report` change
    /// (or kind switch / page appear), not per render — the
    /// computed properties above just read this cache.
    private func refreshParsedPayloads() {
        let report = session.report
        // `.custom`, `.combined`, `.topDownSniper` are permissive
        // (they can emit any of the structured blocks).
        let permissive = (selectedKind == .custom || selectedKind == .combined || selectedKind == .topDownSniper)
        var p = ParsedPayloads()
        if selectedKind == .supportResistance || selectedKind == .full || permissive {
            p.srLevels = PromptBuilder.parseSRLevels(report)
        }
        if selectedKind == .fvg || permissive {
            p.fvgZones = PromptBuilder.parseFVGZones(report)
        }
        if selectedKind == .confluenceScanner || permissive {
            p.supplyDemand = PromptBuilder.parseSupplyDemandZones(report)
        }
        if selectedKind == .confluenceScanner {
            p.scored = PromptBuilder.parseScoredScenarios(report)
        }
        if selectedKind == .full || selectedKind == .confluenceScanner || permissive {
            p.taScenario    = PromptBuilder.parseTAScenario(report)
            p.taAltScenario = PromptBuilder.parseTAAltScenario(report)
        }
        if p != parsedPayloads { parsedPayloads = p }

        // Clarify is combined-only and lives outside the cached
        // payloads struct (it's an ephemeral question, not chart data).
        parsedClarify = selectedKind == .combined
            ? PromptBuilder.parseClarify(report)
            : nil
    }
}
