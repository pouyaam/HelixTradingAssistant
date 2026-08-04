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

    /// Which engine's model/effort dropdown popover is currently open
    /// (nil = none). Driven by clicking an engine icon in the header.
    @State private var engineMenuOpen: AIEngineKind? = nil

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

    /// Claude model + reasoning effort the analysis pipeline runs with.
    /// Edited from the engine dropdown in this page's header (moved out
    /// of the Settings window). Same UserDefaults keys `ClaudeEngine`
    /// reads when it spawns the CLI.
    @AppStorage("ai.claude.model")  private var claudeModel: String = ClaudeModelCatalog.defaultModelID
    @AppStorage("ai.claude.effort") private var claudeEffort: String = ClaudeModelCatalog.defaultEffortID
    @AppStorage("ai.codex.model")   private var codexModel: String = CodexModelCatalog.defaultModelID
    @AppStorage("ai.codex.effort")  private var codexEffort: String = CodexModelCatalog.defaultEffortID
    @AppStorage("ai.opencode.model") private var opencodeModel: String = OpenCodeModelCatalog.defaultModelID

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

    /// Per-tab cache of every parsed structured payload (SR levels,
    /// FVG zones, S&D zones, scored scenarios, TA scenario + alt),
    /// keyed by tab id. Refreshed in `refreshParsedPayloads()` — the
    /// per-property accessors below read the *current tab's* slot
    /// instead of re-parsing on every render. Six brace-walking
    /// parsers running 3× each per body invocation was the dominant
    /// cause of the page lag.
    ///
    /// Keying by tab id (rather than a single slot) is what makes
    /// tab switching cheap: revisiting a previously-parsed tab is an
    /// instant dictionary lookup — no re-parse of its (potentially
    /// long) report. (Tab-switch Fix.)
    @State private var parsedPayloadsByTab: [UUID: ParsedPayloads] = [:]

    /// Signature of the last successful parse per tab. Lets a tab
    /// switch short-circuit the parse entirely when nothing the
    /// parsers care about has changed since we last visited that
    /// tab — collapsing the 4× `onChange` storm (tab id / kind /
    /// report / phase all flip on a switch) down to at most one
    /// real parse, and skipping it outright on revisit. (Tab-switch Fix.)
    @State private var parseSignatureByTab: [UUID: ParseSignature] = [:]

    private struct ParseSignature: Equatable {
        let kind: AnalysisKind
        let reportCount: Int
        let phase: AnalysisStore.Phase
    }

    /// The current tab's parsed payloads, or an empty set before
    /// its first parse completes.
    private var parsedPayloads: ParsedPayloads {
        parsedPayloadsByTab[currentTab.id] ?? ParsedPayloads()
    }

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

    /// Parsed CLARIFY_JSON per tab (the model asking the user to
    /// narrow scope). Refreshed alongside the other payloads; absent
    /// for normal runs. Per-tab so switching tabs restores the right
    /// clarify card without a re-parse.
    @State private var parsedClarifyByTab: [UUID: PromptBuilder.ClarifyRequest] = [:]

    /// The current tab's clarify request, if any.
    private var parsedClarify: PromptBuilder.ClarifyRequest? {
        parsedClarifyByTab[currentTab.id]
    }

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

    /// Cached upcoming high-impact event so we don't re-scan
    /// `news.events` on every body invocation. Refreshed on
    /// appear, on the 30 s countdown tick, and when the news
    /// feed itself changes. (Performance Fix 4.)
    @State private var cachedUpcomingEvent: ForexFactoryEvent? = nil

    /// Timestamp of the most recent successful `refreshParsedPayloads`
    /// call. Used to throttle parser work during streaming — six
    /// brace-walking JSON parsers running at 10 Hz was a measurable
    /// slice of the page's CPU budget. (Performance Fix 3.)
    @State private var lastParseAt: Date = .distantPast

    private var session: AnalysisStore.Session {
        store.session(kind: currentTab.kind, pairID: pair.id, tabID: currentTab.id)
    }

    var body: some View {
        // Cache the current tab and session once per body evaluation
        // to avoid repeated dictionary lookups. These are accessed
        // dozens of times across header, bodyContent, action dock,
        // and onChange modifiers. (UI Performance Fix.)
        let cachedTab = currentTab
        let cachedSession = session
        let cachedKind = cachedTab.kind
        let cachedTabID = cachedTab.id

        return VStack(spacing: 0) {
            header(kind: cachedKind, isRunning: cachedSession.phase == .running)
            Divider().background(Theme.Color.border)
            if let event = cachedUpcomingEvent {
                eventWarningBanner(event)
            }
            if showHistory {
                AnalysisHistoryView(
                    pair: pair,
                    kind: cachedKind,
                    onOpen: { entry in
                        store.loadFromHistory(entry, tabID: cachedTabID)
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
                bodyContent(kind: cachedKind, session: cachedSession, tabID: cachedTabID)
                if confluenceExpandPromptVisible {
                    confluenceExpandPrompt
                }
                if cachedSession.phase != .idle {
                    AnalysisActionDock(
                        phase: cachedSession.phase,
                        engineReady: engineReady,
                        srLevels: parsedSRLevels.isEmpty ? nil : parsedSRLevels,
                        fvgZones: parsedFVGZones.isEmpty ? nil : parsedFVGZones,
                        onAddSRLevels: { apply { onApplySRLevels?(parsedSRLevels) } },
                        onAddFVGZones: { apply { onApplyFVGZones?(parsedFVGZones) } },
                        onAddToJournal: { addToJournal(scenario: parsedTAScenario) },
                        onStop:     { store.stop(kind: cachedKind, pairID: pair.id, tabID: cachedTabID) },
                        onClear:    { store.clear(kind: cachedKind, pairID: pair.id, tabID: cachedTabID) },
                        // Combined "Run again" returns to the
                        // checklist card so the user can re-pick
                        // aspects; other kinds re-fire directly.
                        onRunAgain: {
                            if cachedKind == .combined {
                                store.clear(kind: .combined, pairID: pair.id, tabID: cachedTabID)
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
            refreshUpcomingEvent()
            // Tick the countdown every 30s while the page is on
            // screen. Long-lived loop with cancellation tied to
            // the View task scope.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                countdownTick = Date()
                refreshUpcomingEvent()
            }
        }
        .onAppear {
            refreshParsedPayloads(
                tabID: cachedTabID,
                kind: cachedKind,
                report: cachedSession.report,
                phase: cachedSession.phase
            )
        }
        .onChange(of: cachedSession.report) { _ in
            refreshParsedPayloads(
                tabID: cachedTabID,
                kind: cachedKind,
                report: cachedSession.report,
                phase: cachedSession.phase
            )
        }
        .onChange(of: cachedSession.phase)  { _ in
            // Phase transitions (esp. → .done) are exactly when we
            // want a guaranteed final parse, regardless of throttle.
            lastParseAt = .distantPast
            refreshParsedPayloads(
                tabID: cachedTabID,
                kind: cachedKind,
                report: cachedSession.report,
                phase: cachedSession.phase
            )
        }
        .onChange(of: cachedKind)  { _ in
            refreshParsedPayloads(
                tabID: cachedTabID,
                kind: cachedKind,
                report: cachedSession.report,
                phase: cachedSession.phase
            )
        }
        .onChange(of: currentAnalysisTabID) { _ in refreshParsedPayloads() }
        .onChange(of: news.events.count) { _ in refreshUpcomingEvent() }
    }

    /// Recompute the cached upcoming high-impact event. Called from
    /// the 30 s countdown loop, on appear, and when the news feed
    /// changes — never per body render. (Performance Fix 4.)
    private func refreshUpcomingEvent() {
        let now = Date()
        let window: TimeInterval = 30 * 60
        let pastWindow: TimeInterval = 15 * 60
        let next = news.events.first { event in
            guard event.impactLevel == .high,
                  event.currency.uppercased() == "USD",
                  let at = event.eventAt
            else { return false }
            let delta = at.timeIntervalSince(now)
            return delta <= window && delta >= -pastWindow
        }
        if cachedUpcomingEvent?.id != next?.id {
            cachedUpcomingEvent = next
        }
    }

    /// Re-read of the current-tab id so `.onChange` fires when the
    /// user switches tabs (the parsed payloads belong to the new
    /// tab's session).
    private var currentAnalysisTabID: UUID { currentTab.id }

    // ── Economic-event warning banner ──────────────────────────────

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
    private func bodyContent(
        kind: AnalysisKind,
        session: AnalysisStore.Session,
        tabID: UUID
    ) -> some View {
        if kind == .multiTimeframe {
            AnalysisReportColumn(
                session: session,
                idleHint: idleHint,
                unavailableHint: unavailableHint,
                engineReady: engineReady,
                onAnalyze: { runAnalysis() },
                onAskFollowUp: { question in
                    store.askFollowUp(
                        kind: kind,
                        pairID: pair.id,
                        engineKind: selectedEngine,
                        question: question,
                        tabID: tabID
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
                            kind: kind,
                            pairID: pair.id,
                            engineKind: selectedEngine,
                            question: question,
                            tabID: tabID
                        )
                    },
                    onSubmitInitial: combinedInitialSubmit,
                    inputChips: (kind == .custom || kind == .combined) ? customChips : [],
                    inputPlaceholder: (kind == .custom || kind == .combined)
                        ? "Ask anything about \(pair.name) at \(timeframe.label)…"
                        : "Ask a follow-up about this analysis…",
                    idleAccessory: kind == .combined
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
                    kind: kind,
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
    private func header(kind: AnalysisKind, isRunning: Bool) -> some View {
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
                // Engine icons on the left — click one to pick its model
                // + reasoning effort.
                enginePicker(isRunning: isRunning)
                // Legacy chip picker only when viewing an old
                // non-combined history entry (so its report still
                // makes sense). New analysis uses the checklist card.
                if kind != .combined {
                    Text(kind.label)
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

    /// Engine selector — brand glyph icons only (no names), exactly as
    /// before. Clicking an available engine selects it AND opens a
    /// dropdown popover to pick its model + reasoning effort. The
    /// selected engine gets a brand-tinted fill + ring; a "coming soon"
    /// engine shows a small badge and is disabled.
    private func enginePicker(isRunning: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(AIEngineKind.allCases) { kind in
                let engine = AIEngineFactory.make(kind)
                let isComingSoon: Bool = {
                    if case .comingSoon = engine.availability { return true }
                    return false
                }()
                let selected = selectedEngine == kind && !isComingSoon
                Button {
                    // Coming-soon engines can't be made the active engine
                    // yet, but the icon still opens its model dropdown so
                    // the user can preview / pre-pick a model.
                    if !isComingSoon { selectedEngine = kind }
                    engineMenuOpen = kind
                } label: {
                    engineGlyph(kind: kind, selected: selected, isComingSoon: isComingSoon)
                        .opacity(isComingSoon ? 0.5 : 1)
                }
                .buttonStyle(.plain)
                .disabled(isRunning)
                .help(engineHelp(kind: kind, isComingSoon: isComingSoon))
                .popover(
                    isPresented: Binding(
                        get: { engineMenuOpen == kind },
                        set: { if !$0 { engineMenuOpen = nil } }
                    ),
                    arrowEdge: .bottom
                ) {
                    enginePopover(for: kind)
                }
            }
        }
    }

    /// Tooltip for an engine icon — the active model + effort, or a
    /// "coming soon" note.
    private func engineHelp(kind: AIEngineKind, isComingSoon: Bool) -> String {
        switch kind {
        case .claude:
            return "Claude · \(ClaudeModelCatalog.label(forModelID: claudeModel)) · \(claudeEffort) effort"
        case .codex:
            let base = "Codex · \(CodexModelCatalog.label(forModelID: codexModel)) · \(codexEffort) effort"
            return isComingSoon ? "\(base) — coming soon" : base
        case .opencode:
            return "OpenCode · \(OpenCodeModelCatalog.label(forModelID: opencodeModel))"
        }
    }

    /// The glyph chip for one engine — identical look to the original
    /// (plain glyph + selected fill/ring + coming-soon badge).
    private func engineGlyph(kind: AIEngineKind, selected: Bool, isComingSoon: Bool) -> some View {
        EngineGlyph(kind: kind, size: 17)
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

    /// Dropdown content shown when an engine icon is clicked: pick its
    /// model + reasoning effort. Each engine routes to the same renderer
    /// with its own catalog + persisted bindings.
    @ViewBuilder
    private func enginePopover(for kind: AIEngineKind) -> some View {
        switch kind {
        case .claude:
            modelEffortPopover(
                title: "Claude",
                models: ClaudeModelCatalog.models,
                efforts: ClaudeModelCatalog.efforts,
                model: $claudeModel,
                effort: $claudeEffort
            )
        case .codex:
            modelEffortPopover(
                title: "Codex",
                models: CodexModelCatalog.models,
                efforts: CodexModelCatalog.efforts,
                model: $codexModel,
                effort: $codexEffort
            )
        case .opencode:
            opencodeModelPopover
        }
    }

    /// Shared model + reasoning-effort picker body, parameterised by an
    /// engine's catalog and its persisted selection bindings.
    private func modelEffortPopover(
        title: String,
        models: [ClaudeModelCatalog.Model],
        efforts: [ClaudeModelCatalog.Effort],
        model: Binding<String>,
        effort: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("\(title.uppercased()) · MODEL")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)
            VStack(spacing: 2) {
                ForEach(models) { m in
                    Button {
                        model.wrappedValue = m.id
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: model.wrappedValue == m.id ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 12))
                                .foregroundStyle(model.wrappedValue == m.id ? Theme.Color.accentStart : Theme.Color.textMuted)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.label)
                                    .font(.system(size: 12, weight: model.wrappedValue == m.id ? .semibold : .regular))
                                    .foregroundStyle(Theme.Color.textPrimary)
                                Text(m.hint)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.Color.textMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(model.wrappedValue == m.id ? Theme.Color.surface : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider().background(Theme.Color.border)

            Text("REASONING EFFORT")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)
            HStack(spacing: 6) {
                ForEach(efforts) { e in
                    Button {
                        effort.wrappedValue = e.id
                    } label: {
                        Text(e.label)
                            .font(.system(size: 11, weight: effort.wrappedValue == e.id ? .bold : .medium))
                            .foregroundStyle(effort.wrappedValue == e.id ? .white : Theme.Color.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(effort.wrappedValue == e.id
                                          ? AnyShapeStyle(Theme.accentGradient)
                                          : AnyShapeStyle(Theme.Color.surface))
                            )
                    }
                    .buttonStyle(.plain)
                    .help(e.tooltip)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 340)
    }

    /// OpenCode model picker popover — grouped by provider with
    /// collapsible DisclosureGroups inside a ScrollView so it stays
    /// manageable at any size.
    private var opencodeModelPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("OPENCODE · MODEL")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.top, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.sm)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    ForEach(OpenCodeModelCatalog.allModelsByProvider, id: \.provider) { group in
                        DisclosureGroup {
                            VStack(spacing: 2) {
                                ForEach(group.models) { m in
                                    opencodeModelRow(m)
                                }
                            }
                        } label: {
                            opencodeSectionLabel(group.provider, count: group.models.count)
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.lg)
            }
        }
        .frame(width: 340, height: 420)
    }

    private func opencodeSectionLabel(_ title: String, count: Int) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.Color.textSecondary)
            Text("(\(count))")
                .font(.system(size: 10))
                .foregroundStyle(Theme.Color.textMuted)
        }
    }

    private func opencodeModelRow(_ m: OpenCodeModelCatalog.Model) -> some View {
        Button {
            opencodeModel = m.id
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: opencodeModel == m.id ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(opencodeModel == m.id ? Theme.Color.accentStart : Theme.Color.textMuted)
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.label)
                        .font(.system(size: 12, weight: opencodeModel == m.id ? .semibold : .regular))
                        .foregroundStyle(Theme.Color.textPrimary)
                    Text(m.hint)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Color.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(opencodeModel == m.id ? Theme.Color.surface : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        case .smcDesk:
            runSMCDeskAnalysis()
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
            .init(id: "setup",    label: "Setup?",       body: "What's the cleanest trade setup on this pair right now? Give me entry, TP, SL."),
            .init(id: "levels",   label: "Key levels",   body: "List the 3-5 most important support and resistance levels and emit a LEVELS_JSON block."),
            .init(id: "fvgs",     label: "Find FVGs",    body: "Identify any unmitigated fair-value gaps in the visible bars and emit an FVG_JSON block."),
            .init(id: "long",     label: "Long bias",    body: "I want to go long. Where would you enter, where's TP, where's the invalidation? Emit SCENARIO_JSON."),
            .init(id: "short",    label: "Short bias",   body: "I want to go short. Where would you enter, where's TP, where's the invalidation? Emit SCENARIO_JSON."),
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

    /// Smart Money Desk — entry timeframe plus the one above it for
    /// bias. Unlike `runSingleTFAnalysis` this hands the raw HTF
    /// candles down rather than a `MarketSnapshot`: the SMC evidence
    /// pack has to run the structure engines on that series itself, so
    /// a summarised snapshot would be useless to it.
    private func runSMCDeskAnalysis() {
        let tabID = currentTab.id
        let htfTimeframe = higherTimeframe(above: timeframe)
        guard let htfTimeframe, let loader = loadCandles else {
            // No timeframe above (daily) or no loader — run entry-TF
            // only. The evidence pack degrades cleanly: the sentinel
            // falls back to its LTF read and says so.
            store.runSMCDesk(
                engineKind: selectedEngine,
                pair: pair, timeframe: timeframe, candles: candles,
                htfTimeframe: nil, htfCandles: [], tabID: tabID
            )
            return
        }
        Task {
            let htfCandles = await loader(htfTimeframe)
            await MainActor.run {
                store.runSMCDesk(
                    engineKind: selectedEngine,
                    pair: pair, timeframe: timeframe, candles: candles,
                    htfTimeframe: htfCandles.isEmpty ? nil : htfTimeframe,
                    htfCandles: htfCandles,
                    tabID: tabID
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
        parsedClarifyByTab[tab.id] = nil
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
        parsedClarifyByTab[currentTab.id] = nil
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
            journalID: journal.lastUsedJournalID,
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
            return "Write your own prompt in the editor and run it against **\(pair.name)** at \(timeframe.label)."
        case .smcDesk:
            let htf = higherTimeframe(above: timeframe)?.label
            return "Run **\(selectedEngine.label)** for **Smart Money Desk** on \(pair.name) at \(timeframe.label)\(htf.map { " with \($0) bias" } ?? "") — Ranked OB grades, ALGOSMART structure, and previous-day PDH/PDL/POC, pre-computed."
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
    ///
    /// **Throttling while streaming** *(Performance Fix 3)*:
    /// during `.running`, six brace-walking parsers per flush were
    /// the dominant CPU cost. JSON blocks almost always arrive in a
    /// single late chunk, so we:
    ///   1. Short-circuit when no `_JSON` marker is in the report yet
    ///      (~70% of mid-stream calls); and
    ///   2. Throttle remaining calls to once per 500 ms.
    /// `lastParseAt` is reset to `.distantPast` on phase transitions
    /// (`.done` / `.error`) so the final guaranteed parse always
    /// fires regardless of throttle state.
    private func refreshParsedPayloads() {
        let tab = currentTab
        let sess = session
        refreshParsedPayloads(tabID: tab.id, kind: tab.kind, report: sess.report, phase: sess.phase)
    }

    private func refreshParsedPayloads(
        tabID: UUID,
        kind: AnalysisKind,
        report: String,
        phase: AnalysisStore.Phase
    ) {
        let signature = ParseSignature(
            kind: kind,
            reportCount: report.count,
            phase: phase
        )

        if phase == .running {
            guard report.contains("_JSON") else { return }
            let now = Date()
            guard now.timeIntervalSince(lastParseAt) >= 0.5 else { return }
            lastParseAt = now
        } else {
            // Not streaming: nothing the parsers read has changed
            // since we last parsed this tab ⇒ skip. This is what
            // makes a tab switch cheap — the 4× `onChange` storm
            // (tab id / kind / report / phase) collapses to one
            // parse, and revisiting an already-parsed tab does zero
            // work (its payloads are already cached).
            guard parseSignatureByTab[tabID] != signature else { return }
            lastParseAt = Date()
        }
        parseSignatureByTab[tabID] = signature

        // `.custom`, `.combined`, `.topDownSniper` are permissive
        // (they can emit any of the structured blocks).
        let permissive = (kind == .custom || kind == .combined || kind == .topDownSniper || kind == .smcDesk)
        var p = ParsedPayloads()
        if kind == .supportResistance || kind == .full || permissive {
            p.srLevels = PromptBuilder.parseSRLevels(report)
        }
        if kind == .fvg || permissive {
            p.fvgZones = PromptBuilder.parseFVGZones(report)
        }
        if kind == .confluenceScanner || permissive {
            p.supplyDemand = PromptBuilder.parseSupplyDemandZones(report)
        }
        if kind == .confluenceScanner {
            p.scored = PromptBuilder.parseScoredScenarios(report)
        }
        if kind == .full || kind == .confluenceScanner || permissive {
            p.taScenario    = PromptBuilder.parseTAScenario(report)
            p.taAltScenario = PromptBuilder.parseTAAltScenario(report)
        }
        if parsedPayloadsByTab[tabID] != p { parsedPayloadsByTab[tabID] = p }

        // Clarify is combined-only and lives outside the cached
        // payloads struct (it's an ephemeral question, not chart data).
        let clarify = kind == .combined
            ? PromptBuilder.parseClarify(report)
            : nil
        if parsedClarifyByTab[tabID] != clarify { parsedClarifyByTab[tabID] = clarify }
    }
}
