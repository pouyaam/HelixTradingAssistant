import SwiftUI
import Combine

struct DashboardViewiPad: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var yahoo: YahooScheduler
    @EnvironmentObject private var notificationInbox: NotificationInbox
    @EnvironmentObject private var analysisStore: AnalysisStore
    @EnvironmentObject private var tradeStore: TradeStore
    @EnvironmentObject private var journal: JournalStore
    @EnvironmentObject private var autoTraderConfig: AutoTraderConfigStore
    @EnvironmentObject private var autoTrader: AutoTraderEngine
    @EnvironmentObject private var paperBalance: PaperBalance

    @AppStorage("dashboard.timeframe")  private var timeframe: Timeframe = .h1
    @AppStorage("dashboard.chartType")  private var userChartType: ChartType = .candle
    @AppStorage("dashboard.showVolume") private var showVolume: Bool = true
    @AppStorage("dashboard.indicators")  private var indicatorsRaw: String = ""
    @AppStorage("dashboard.oscillators") private var oscillatorsRaw: String = ""
    @AppStorage("dashboard.hiddenIndicators")  private var hiddenIndicatorsRaw: String = ""
    @AppStorage("dashboard.hiddenOscillators") private var hiddenOscillatorsRaw: String = ""

    @State private var candles: [Candle] = []
    @State private var isLoading: Bool = false
    // NOTE: the chart's zoom window (xDomain/yDomain) deliberately does NOT
    // live here. It's local @State inside `ChartPlotiPad` so a pan/zoom —
    // which rewrites the domain on every gesture frame — re-renders only the
    // chart subtree, not this whole 900-line dashboard body (pair header,
    // multi-chart grid, hidden analysis overlay, stats, toolbar). Hoisting it
    // up here is what made the iPad chart lag vs the Mac app. Reset-on-switch
    // is handled by the `.id(pair|timeframe)` on that view instead.
    @State private var oscillatorConfig: OscillatorConfig = .load()
    @State private var srLevels: PromptBuilder.SRLevels = .init(support: [], resistance: [])
    @State private var fvgZones: [PromptBuilder.FVGZone] = []
    @State private var supplyDemandZones: [PromptBuilder.SupplyDemandZone] = []
    @State private var taScenario: PromptBuilder.TAScenario? = nil
    @State private var taAltScenario: PromptBuilder.TAScenario? = nil
    @State private var srVisible: Bool = true
    @State private var fvgVisible: Bool = true
    @State private var supplyDemandVisible: Bool = true
    @State private var scenarioVisible: Bool = true
    @State private var altScenarioVisible: Bool = true
    @State private var showAnalysis: Bool = false
    @State private var showDebugLogSheet: Bool = false

    // Phase 2: Drawing tools
    @StateObject private var drawingStore = DrawingStore()
    @State private var activeDrawingTool: DrawingTool = .none
    @State private var selectedDrawingID: UUID? = nil

    // Phase 2: Sheets
    @State private var showLayersPopover: Bool = false
    @State private var showIndicatorSettings: Bool = false
    @State private var settingsFocusSection: String? = nil
    @State private var showAlertSheet: Bool = false

    // Phase 2: Alert store
    @StateObject private var alertStore = AlertStore()

    // Phase 3: Replay controller
    @StateObject private var replay = ReplayController()

    // Phase 2: Activate trade
    @State private var pendingActivation: PendingActivation?

    private struct PendingActivation: Identifiable, Equatable {
        let scenario: PromptBuilder.TAScenario
        let sourceHistoryEntryID: UUID?
        var id: String { scenario.id }
    }

    // Cached parsed sets — avoids re-parsing @AppStorage strings on
    // every body evaluation. Updated via .onChange below.
    @State private var _enabledIndicators: Set<IndicatorKind> = Self.parseIndicators(UserDefaults.standard.string(forKey: "dashboard.indicators") ?? "")
    @State private var _enabledOscillators: Set<OscillatorKind> = Self.parseOscillators(UserDefaults.standard.string(forKey: "dashboard.oscillators") ?? "")
    @State private var _hiddenIndicators: Set<IndicatorKind> = Self.parseIndicators(UserDefaults.standard.string(forKey: "dashboard.hiddenIndicators") ?? "")
    @State private var _hiddenOscillators: Set<OscillatorKind> = Self.parseOscillators(UserDefaults.standard.string(forKey: "dashboard.hiddenOscillators") ?? "")

    private var enabledIndicators: Set<IndicatorKind> { _enabledIndicators }
    private var enabledOscillators: Set<OscillatorKind> { _enabledOscillators }
    private var hiddenIndicators: Set<IndicatorKind> { _hiddenIndicators }
    private var hiddenOscillators: Set<OscillatorKind> { _hiddenOscillators }
    private var visibleIndicators: Set<IndicatorKind> {
        _enabledIndicators.subtracting(_hiddenIndicators)
    }
    private var visibleOscillators: Set<OscillatorKind> {
        _enabledOscillators.subtracting(_hiddenOscillators)
    }

    private func setIndicator(_ kind: IndicatorKind, enabled: Bool) {
        var s = _enabledIndicators
        if enabled { s.insert(kind) } else { s.remove(kind) }
        indicatorsRaw = s.map(\.rawValue).sorted().joined(separator: ",")
    }
    private func setOscillator(_ kind: OscillatorKind, enabled: Bool) {
        var s = _enabledOscillators
        if enabled { s.insert(kind) } else { s.remove(kind) }
        oscillatorsRaw = s.map(\.rawValue).sorted().joined(separator: ",")
    }
    private func setIndicatorHidden(_ kind: IndicatorKind, hidden: Bool) {
        var s = _hiddenIndicators
        if hidden { s.insert(kind) } else { s.remove(kind) }
        hiddenIndicatorsRaw = s.map(\.rawValue).sorted().joined(separator: ",")
    }
    private func setOscillatorHidden(_ kind: OscillatorKind, hidden: Bool) {
        var s = _hiddenOscillators
        if hidden { s.insert(kind) } else { s.remove(kind) }
        hiddenOscillatorsRaw = s.map(\.rawValue).sorted().joined(separator: ",")
    }

    private static func parseIndicators(_ raw: String) -> Set<IndicatorKind> {
        Set(raw.split(separator: ",").compactMap { IndicatorKind(rawValue: String($0)) })
    }
    private static func parseOscillators(_ raw: String) -> Set<OscillatorKind> {
        Set(raw.split(separator: ",").compactMap { OscillatorKind(rawValue: String($0)) })
    }

    var body: some View {
        let pair = app.pairs.first(where: { $0.id == app.selectedPairID })

        ZStack {
            VStack(spacing: 8) {
                if let pair = pair {
                    if !app.isChartFullscreen {
                        pairHeader(pair)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    let isFull = app.isChartFullscreen
                    chartCard(pair)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()

                    if !isFull {
                        statsRow(pair)
                    }
                } else {
                    emptyState
                }
            }
            .padding(app.isChartFullscreen ? 0 : 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // Phase 2: Analysis overlay. Built ONLY while shown — previously
            // it was always mounted (collapsed to frame 0), so its body — which
            // renders the AI report markdown — re-evaluated on every dashboard
            // re-render (each 1 Hz candle tick, each fullscreen toggle) even
            // while hidden. Gating it behind `showAnalysis` keeps it off the
            // hot path; the one-time build cost lands only when the user opens it.
            if let pair = pair, showAnalysis {
                AnalysisPageiPad(
                    pair: pair,
                    timeframe: timeframe,
                    candles: candles,
                    livePrice: yahoo.latestPrices[pair.id],
                    loadCandles: { tf in
                        await MainActor.run { candles(for: tf) }
                    },
                    onApplySRLevels:      { srLevels = $0 },
                    onApplyFVGZones:      { fvgZones = $0 },
                    onApplySupplyDemand:  { supplyDemandZones = $0 },
                    onApplyTAScenario:    { taScenario = $0 },
                    onApplyTAAltScenario: { taAltScenario = $0 },
                    onActivateTradeFromScenario: { scenario, entryID in
                        pendingActivation = PendingActivation(
                            scenario: scenario,
                            sourceHistoryEntryID: entryID
                        )
                    }
                )
                .environmentObject(analysisStore)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.Color.canvas)
        .task(id: app.selectedPairID) {
            await MainActor.run {
                // Domain reset happens via ChartPlotiPad's `.id` changing.
                srLevels = .init(support: [], resistance: [])
                fvgZones = []
                supplyDemandZones = []
                taScenario = nil
                taAltScenario = nil
                selectedDrawingID = nil
                alertStore.timeframeLabel = timeframe.rawValue
            }
            await reloadCandles()
            warmHistory()
        }
        .onChange(of: timeframe) { _ in
            // Domain reset happens via ChartPlotiPad's `.id` changing.
            alertStore.timeframeLabel = timeframe.rawValue
            warmHistory()
        }
        .onChange(of: userChartType) { _ in }
        .onChange(of: indicatorsRaw) { newValue in
            _enabledIndicators = Self.parseIndicators(newValue)
        }
        .onChange(of: oscillatorsRaw) { newValue in
            _enabledOscillators = Self.parseOscillators(newValue)
        }
        .onChange(of: showVolume) { _ in }
        .onReceive(
            yahoo.$lastUpdateAt
                .compactMap { $0 }
                .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
        ) { _ in
            if let cur = app.pairs.first(where: { $0.id == app.selectedPairID }),
               cur.usesLiveStream {
                Task { await refreshTrailingCandles() }
            }
        }
        .sheet(isPresented: $showIndicatorSettings) {
            oscillatorConfig.save()
            settingsFocusSection = nil
        } content: {
            IndicatorSettingsSheet(config: $oscillatorConfig, focusSection: settingsFocusSection)
        }
        .sheet(isPresented: $showAlertSheet) {
            if let cur = pair {
                AlertSheet(
                    pairID: cur.id,
                    pairName: cur.name,
                    livePrice: yahoo.latestPrices[cur.id],
                    onCreate: { alert in alertStore.add(alert) }
                )
                .environmentObject(alertStore)
            }
        }
        .sheet(isPresented: $showDebugLogSheet) {
            DebugLogSheetiPad()
        }
        .sheet(item: $pendingActivation) { mode in
            ActivateTradeSheet(
                scenario: mode.scenario,
                pairID: pair?.id ?? "",
                livePrice: pair.flatMap { yahoo.latestPrices[$0.id] },
                sourceHistoryEntryID: mode.sourceHistoryEntryID
            ) { trade in
                tradeStore.add(trade, for: pair?.id ?? "")
                pendingActivation = nil
            }
            .environmentObject(tradeStore)
        }
    }

    // MARK: - Pair header (Phase 2: + fetch timer)

    private func pairHeader(_ pair: TradingPair) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            // Pair selector dropdown
            Menu {
                ForEach(app.pairs) { p in
                    Button {
                        app.selectedPairID = p.id
                    } label: {
                        Label(p.name, systemImage: p.id == app.selectedPairID ? "checkmark.circle.fill" : "circle")
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(pair.color)
                        .frame(width: 12, height: 12)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pair.name)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Theme.Color.textPrimary)
                        Text(pair.symbol)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Color.textMuted)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Color.textMuted)
                }
            }
            Spacer()

            // Phase 2: Fetch timer
            FetchTimerView(
                lastFetchAt: yahoo.lastUpdateAt,
                intervalSeconds: 60,
                isFetching: yahoo.isFetching
            )

            let price = yahoo.latestPrices[pair.id] ?? pair.price
            if price > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(formatPrice(price))
                        .font(.system(size: 22, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.Color.textPrimary)
                    let pct = pair.changePercent
                    Text(String(format: "%+.2f%%", pct))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(pct >= 0 ? Theme.Color.success : Theme.Color.danger)
                }
            }
            Button {
                Task { await reloadCandles() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Theme.Color.surface))
            }
        }
    }

    // MARK: - Chart card (Phase 2: + drawing toolbar + layers + alerts)

    private func chartCard(_ pair: TradingPair) -> some View {
        VStack(spacing: 0) {
            // Chart header
            HStack(spacing: Theme.Spacing.sm) {
                TimeframeSelector(selected: $timeframe)
                ChartTypeToggle(selected: $userChartType, isDisabled: false)

                Spacer()

                // Phase 2: Drawing tools toolbar
                drawingToolbar

                Divider().frame(height: 20).background(Theme.Color.border)

                // Phase 3: Replay controls
                if replay.isActive {
                    HStack(spacing: 4) {
                        Button { replay.exit() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.Color.danger)
                        }
                        Text("REPLAY")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(Theme.Color.warn)
                    }
                } else {
                    Button { replay.arm() } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.Color.textSecondary)
                            .frame(width: 32, height: 32)
                    }
                    .help("Replay mode")
                }

                Divider().frame(height: 20).background(Theme.Color.border)

                // Indicators menu
                Menu {
                    ForEach(IndicatorKind.allCases) { kind in
                        let isOn = enabledIndicators.contains(kind)
                        let isHidden = isOn && hiddenIndicators.contains(kind)
                        Button {
                            if isOn {
                                setIndicatorHidden(kind, hidden: !isHidden)
                            } else {
                                setIndicator(kind, enabled: true)
                            }
                        } label: {
                            Label {
                                HStack(spacing: 6) {
                                    Text(kind.label)
                                    if isOn {
                                        Image(systemName: isHidden ? "eye.slash" : "eye")
                                            .font(.system(size: 10))
                                            .foregroundStyle(isHidden ? Theme.Color.textMuted.opacity(0.4) : kind.color)
                                    }
                                }
                            } icon: {
                                Image(systemName: isOn
                                      ? (isHidden ? "eye.slash" : "checkmark.circle.fill")
                                      : "circle")
                            }
                        }
                    }
                    Divider()
                    ForEach(OscillatorKind.allCases) { kind in
                        Button {
                            setOscillator(kind, enabled: !enabledOscillators.contains(kind))
                        } label: {
                            Label(kind.label,
                                  systemImage: enabledOscillators.contains(kind) ? "checkmark.circle.fill" : "circle")
                        }
                    }
                    Divider()
                    Button { showIndicatorSettings = true } label: {
                        Label("Indicator Settings...", systemImage: "slider.horizontal.3")
                    }
                } label: {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .frame(width: 32, height: 32)
                }

                // Phase 2: Layers popover
                Menu {
                    layersMenuContent
                } label: {
                    Image(systemName: "square.3.layers.3d")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .frame(width: 32, height: 32)
                }

                // Phase 2: Alerts button
                Button { showAlertSheet = true } label: {
                    Image(systemName: "bell")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .frame(width: 32, height: 32)
                }

                // AI Analyze button
                Button {
                    showAnalysis = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12, weight: .bold))
                        Text("Analyze")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Theme.accentGradient))
                }

                // Network debug button
                Button {
                    showDebugLogSheet = true
                } label: {
                    Image(systemName: "ladybug.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(NetworkLog.shared.isEnabled
                                         ? Theme.Color.warn
                                         : Theme.Color.textSecondary)
                        .frame(width: 32, height: 32)
                }
                .help(NetworkLog.shared.isEnabled
                      ? "Network debug · capturing"
                      : "Network debug")

                // Fullscreen toggle
                Button {
                    app.isChartFullscreen.toggle()
                } label: {
                    Image(systemName: app.isChartFullscreen
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .frame(width: 32, height: 32)
                }
                .help(app.isChartFullscreen ? "Exit fullscreen" : "Fullscreen")
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, 8)

            Divider().background(Theme.Color.border)

            // Chart body + oscillators + volume, isolated in ChartPlotiPad.
            // That view owns xDomain/yDomain, so pan/zoom re-renders only its
            // subtree — never this dashboard body, the multi-chart grid, or
            // the analysis overlay. The `.id` gives each pair/timeframe a
            // fresh (auto-fit) zoom window, replacing the old explicit resets.
            ChartPlotiPad(
                candles: candles,
                chartType: userChartType,
                accent: pair.color,
                indicators: visibleIndicators,
                oscillators: visibleOscillators,
                indicatorConfig: oscillatorConfig,
                srLevels: srVisible ? srLevels : .init(support: [], resistance: []),
                fvgZones: fvgVisible ? fvgZones : [],
                supplyDemandZones: supplyDemandVisible ? supplyDemandZones : [],
                taScenario: scenarioVisible ? taScenario : nil,
                taAltScenario: altScenarioVisible ? taAltScenario : nil,
                drawings: app.selectedPairID.map { drawingStore.drawings(for: $0) } ?? [],
                activeTool: activeDrawingTool,
                onCommitDrawing: { drawing in
                    guard let pairID = app.selectedPairID else { return }
                    drawingStore.add(drawing, for: pairID)
                    activeDrawingTool = .none
                },
                onMoveDrawing: { drawing in
                    guard let pairID = app.selectedPairID else { return }
                    drawingStore.update(drawing, for: pairID)
                },
                selectedDrawingID: selectedDrawingID,
                onSelectDrawing: { id in selectedDrawingID = id },
                trades: app.selectedPairID.flatMap { tradeStore.openVisibleTrades(for: $0) } ?? [],
                journalEntries: app.selectedPairID == app.journalChartEntry?.pairID
                    ? (app.journalChartEntry.map { [$0] } ?? []) : [],
                livePrice: yahoo.latestPrices[pair.id],
                replayActive: replay.isActive,
                showVolume: showVolume
            )
            .id("\(pair.id)|\(timeframe.rawValue)")
        }
        .background(
            RoundedRectangle(cornerRadius: app.isChartFullscreen ? 0 : Theme.Radius.lg, style: .continuous)
                .fill(app.isChartFullscreen ? Color.clear : Theme.Color.surfaceHi)
                .overlay(
                    app.isChartFullscreen ? nil :
                    RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                        .strokeBorder(Theme.Color.border, lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: app.isChartFullscreen ? 0 : Theme.Radius.lg, style: .continuous))
        .frame(maxHeight: .infinity)
    }

    // MARK: - Phase 2: Drawing toolbar

    private var drawingToolbar: some View {
        HStack(spacing: 4) {
            ForEach(DrawingTool.allCases.filter { $0 != .none }) { tool in
                Button {
                    activeDrawingTool = activeDrawingTool == tool ? .none : tool
                } label: {
                    Image(systemName: tool.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(activeDrawingTool == tool ? Theme.Color.accentStart : Theme.Color.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(activeDrawingTool == tool ? Theme.Color.surfaceMax : Color.clear)
                        )
                }
                .help(tool.label)
            }
            if selectedDrawingID != nil {
                Button {
                    if let id = selectedDrawingID, let pairID = app.selectedPairID {
                        drawingStore.remove(id: id, for: pairID)
                        selectedDrawingID = nil
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Color.danger)
                        .frame(width: 32, height: 32)
                }
                .help("Delete selected drawing")
            }
        }
    }

    // MARK: - Phase 2: Layers menu

    @ViewBuilder
    private var layersMenuContent: some View {
        // Indicators
        Section("Indicators") {
            ForEach(IndicatorKind.allCases) { kind in
                let isEnabled = enabledIndicators.contains(kind)
                let isHidden = hiddenIndicators.contains(kind)
                if isEnabled {
                    Button {
                        setIndicatorHidden(kind, hidden: !isHidden)
                    } label: {
                        Label(kind.label,
                              systemImage: isHidden ? "eye.slash" : "eye")
                    }
                }
            }
        }
        // Oscillators
        Section("Oscillators") {
            ForEach(OscillatorKind.allCases) { kind in
                let isEnabled = enabledOscillators.contains(kind)
                let isHidden = hiddenOscillators.contains(kind)
                if isEnabled {
                    Button {
                        setOscillatorHidden(kind, hidden: !isHidden)
                    } label: {
                        Label(kind.label,
                              systemImage: isHidden ? "eye.slash" : "eye")
                    }
                }
            }
        }
        // AI Overlays
        Section("AI Overlays") {
            if !srLevels.isEmpty {
                Button { srVisible.toggle() } label: {
                    Label("S/R Levels", systemImage: srVisible ? "eye" : "eye.slash")
                }
            }
            if !fvgZones.isEmpty {
                Button { fvgVisible.toggle() } label: {
                    Label("FVG Zones", systemImage: fvgVisible ? "eye" : "eye.slash")
                }
            }
            if !supplyDemandZones.isEmpty {
                Button { supplyDemandVisible.toggle() } label: {
                    Label("Supply & Demand", systemImage: supplyDemandVisible ? "eye" : "eye.slash")
                }
            }
            if taScenario != nil {
                Button { scenarioVisible.toggle() } label: {
                    Label("Trade Plan", systemImage: scenarioVisible ? "eye" : "eye.slash")
                }
            }
            if taAltScenario != nil {
                Button { altScenarioVisible.toggle() } label: {
                    Label("Alt Plan", systemImage: altScenarioVisible ? "eye" : "eye.slash")
                }
            }
        }
        // Drawings
        let drawings = app.selectedPairID.map { drawingStore.drawings(for: $0) } ?? []
        if !drawings.isEmpty {
            Section("Drawings") {
                ForEach(drawings) { d in
                    Button {
                        if let pairID = app.selectedPairID {
                            drawingStore.setVisible(!d.visible, id: d.id, for: pairID)
                        }
                    } label: {
                        Label(d.kind.rawValue, systemImage: d.visible ? "eye" : "eye.slash")
                    }
                }
                Divider()
                Button(role: .destructive) {
                    if let pairID = app.selectedPairID {
                        drawingStore.clear(for: pairID)
                        selectedDrawingID = nil
                    }
                } label: {
                    Label("Clear All Drawings", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Stats row

    private func statsRow(_ pair: TradingPair) -> some View {
        HStack(spacing: Theme.Spacing.lg) {
            statItem("24H High", value: pair.high24h > 0 ? formatPrice(pair.high24h) : "—")
            statItem("24H Low", value: pair.low24h > 0 ? formatPrice(pair.low24h) : "—")
            statItem("24H Change", value: String(format: "%+.2f%%", pair.changePercent),
                     color: pair.changePercent >= 0 ? Theme.Color.success : Theme.Color.danger)
        }
    }

    private func statItem(_ label: String, value: String, color: Color? = nil) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Color.textMuted)
            Text(value)
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(color ?? Theme.Color.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(Theme.Color.surface)
        )
    }

    // MARK: - Helpers

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Spacer()
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 48))
                .foregroundStyle(Theme.Color.textMuted)
            Text("Select a pair")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.Color.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func formatPrice(_ v: Double) -> String {
        if v >= 10_000 { return String(format: "%.0f", v) }
        if v >= 100 { return String(format: "%.2f", v) }
        if v >= 1 { return String(format: "%.4f", v) }
        return String(format: "%.5f", v)
    }

    @MainActor
    private func reloadCandles() async {
        guard let pairID = app.selectedPairID else { return }
        candles = candles(for: pairID, tf: timeframe)
    }

    private func warmHistory() {
        guard let pairID = app.selectedPairID else { return }
        let currentSrc = OHLCCandleLoader.sourceTimeframeTag(for: timeframe)
        Task {
            await yahoo.ensureDeepHistory(pairID: pairID, sourceTF: currentSrc)
            await reloadCandles()
            await yahoo.backfillAll(pairID: pairID)
            await reloadCandles()
        }
    }

    /// Cheap live-tick path: reads only a short trailing window, folds it,
    /// and splices onto the tail of in-memory `candles`. Avoids the full
    /// DB read + fold that `reloadCandles()` does.
    @MainActor
    private func refreshTrailingCandles() async {
        guard let db = app.database, let pairID = app.selectedPairID else { return }
        let pair = app.pairs.first(where: { $0.id == pairID })
        let respectsWeekend = pair?.category != .crypto
        let until = Date()
        let margin = Double(max(timeframe.seconds * 3, 6 * 3600))
        let since = until.addingTimeInterval(-margin)
        let recent = OHLCCandleLoader.load(
            repo: db.ohlcRepo, pairID: pairID, tf: timeframe,
            since: since, until: until, dropClosedDays: respectsWeekend
        )
        guard let cutoff = recent.first?.bucketStart else { return }
        var merged = candles
        while let last = merged.last, last.bucketStart >= cutoff { merged.removeLast() }
        merged.append(contentsOf: recent)
        candles = merged
    }

    @MainActor
    private func candles(for pairID: String, tf: Timeframe, ignoreReplay: Bool = false) -> [Candle] {
        guard let db = app.database else { return [] }
        let pair = app.pairs.first(where: { $0.id == pairID })
        let respectsWeekend = pair?.category != .crypto
        return OHLCCandleLoader.load(
            repo: db.ohlcRepo,
            pairID: pairID,
            tf: tf,
            since: Date.distantPast,
            until: Date(),
            dropClosedDays: respectsWeekend
        )
    }

    @MainActor
    private func candles(for tf: Timeframe) -> [Candle] {
        guard let pairID = app.selectedPairID else { return [] }
        return candles(for: pairID, tf: tf)
    }
}

// MARK: - Isolated chart plot

/// The price chart plus its oscillator panels and volume bars, all sharing
/// one `xDomain`/`yDomain` zoom window.
///
/// Why this is its own view: the domain lives here as local `@State`, not on
/// `DashboardViewiPad`. A pan/zoom rewrites the domain on *every* gesture
/// frame; keeping it local means SwiftUI re-evaluates only this subtree per
/// frame, instead of the entire dashboard body (pair header, multi-chart
/// grid, hidden analysis overlay, stats row, toolbar menus). Re-rendering
/// that whole tree ~60–120×/sec during a drag is what made the iPad chart
/// lag compared to the Mac app, whose domain state is likewise scoped to an
/// isolated chart pane (`ChartPaneView`).
///
/// Reset-on-switch is driven from the parent by changing this view's `.id`
/// (pair | timeframe): a new id re-creates the view with nil domains, so
/// each pair/timeframe opens on its default auto-fit window.
private struct ChartPlotiPad: View {
    let candles: [Candle]
    let chartType: ChartType
    let accent: Color
    let indicators: Set<IndicatorKind>
    let oscillators: Set<OscillatorKind>
    let indicatorConfig: OscillatorConfig
    let srLevels: PromptBuilder.SRLevels
    let fvgZones: [PromptBuilder.FVGZone]
    let supplyDemandZones: [PromptBuilder.SupplyDemandZone]
    let taScenario: PromptBuilder.TAScenario?
    let taAltScenario: PromptBuilder.TAScenario?
    let drawings: [ChartDrawing]
    let activeTool: DrawingTool
    let onCommitDrawing: (ChartDrawing) -> Void
    let onMoveDrawing: (ChartDrawing) -> Void
    let selectedDrawingID: UUID?
    let onSelectDrawing: (UUID?) -> Void
    let trades: [Trade]
    let journalEntries: [JournalEntry]
    let livePrice: Double?
    let replayActive: Bool
    let showVolume: Bool

    @State private var xDomain: ClosedRange<Double>? = nil
    @State private var yDomain: ClosedRange<Double>? = nil

    var body: some View {
        VStack(spacing: 0) {
            ChartViewiPad(
                candles: candles,
                chartType: chartType,
                accent: accent,
                xDomain: $xDomain,
                yDomain: $yDomain,
                indicators: indicators,
                indicatorConfig: indicatorConfig,
                srLevels: srLevels,
                fvgZones: fvgZones,
                supplyDemandZones: supplyDemandZones,
                taScenario: taScenario,
                taAltScenario: taAltScenario,
                drawings: drawings,
                activeTool: activeTool,
                onCommitDrawing: onCommitDrawing,
                onMoveDrawing: onMoveDrawing,
                selectedDrawingID: selectedDrawingID,
                onSelectDrawing: onSelectDrawing,
                trades: trades,
                journalEntries: journalEntries,
                livePrice: livePrice,
                replayActive: replayActive
            )
            .frame(maxHeight: .infinity)
            .clipped()
            // Tap-and-hold to rescale — mirrors the double-tap reset, but
            // discoverable. Drops the pinned window so the chart re-fits to
            // the latest bars and auto-scales the price axis.
            .contextMenu {
                Button {
                    xDomain = nil
                    yDomain = nil
                } label: {
                    Label("Reset Zoom", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
                }
            }

            // Oscillator panels — follow the same xDomain so they scroll in
            // lockstep with the price chart.
            if !oscillators.isEmpty {
                Divider().background(Theme.Color.border)
                ForEach(Array(oscillators)) { kind in
                    OscillatorPanel(
                        instance: OscillatorInstance(kind: kind),
                        candles: candles,
                        xDomain: xDomain
                    )
                    .padding(.horizontal, Theme.Spacing.lg)
                }
            }

            // Volume bars
            if showVolume {
                let volView = VolumeBarsView(candles: candles, accent: accent, xDomain: xDomain)
                if volView.hasVolume {
                    Divider().background(Theme.Color.border)
                    volView
                        .frame(height: 50)
                        .padding(.horizontal, Theme.Spacing.lg)
                }
            }
        }
    }
}
