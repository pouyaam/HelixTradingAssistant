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
    @State private var xDomain: ClosedRange<Double>? = nil
    @State private var yDomain: ClosedRange<Double>? = nil
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

    // Phase 3: Multi-chart grid
    @StateObject private var multiChart = MultiChartLayoutStore()

    // Phase 2: Activate trade
    @State private var pendingActivation: PendingActivation?

    private struct PendingActivation: Identifiable, Equatable {
        let scenario: PromptBuilder.TAScenario
        let sourceHistoryEntryID: UUID?
        var id: String { scenario.id }
    }

    private var enabledIndicators: Set<IndicatorKind> {
        Set(indicatorsRaw.split(separator: ",")
            .compactMap { IndicatorKind(rawValue: String($0)) })
    }
    private var enabledOscillators: Set<OscillatorKind> {
        Set(oscillatorsRaw.split(separator: ",")
            .compactMap { OscillatorKind(rawValue: String($0)) })
    }
    private var hiddenIndicators: Set<IndicatorKind> {
        Set(hiddenIndicatorsRaw.split(separator: ",")
            .compactMap { IndicatorKind(rawValue: String($0)) })
    }
    private var hiddenOscillators: Set<OscillatorKind> {
        Set(hiddenOscillatorsRaw.split(separator: ",")
            .compactMap { OscillatorKind(rawValue: String($0)) })
    }
    private var visibleIndicators: Set<IndicatorKind> {
        enabledIndicators.subtracting(hiddenIndicators)
    }
    private var visibleOscillators: Set<OscillatorKind> {
        enabledOscillators.subtracting(hiddenOscillators)
    }

    private func setIndicator(_ kind: IndicatorKind, enabled: Bool) {
        var s = enabledIndicators
        if enabled { s.insert(kind) } else { s.remove(kind) }
        indicatorsRaw = s.map(\.rawValue).sorted().joined(separator: ",")
    }
    private func setOscillator(_ kind: OscillatorKind, enabled: Bool) {
        var s = enabledOscillators
        if enabled { s.insert(kind) } else { s.remove(kind) }
        oscillatorsRaw = s.map(\.rawValue).sorted().joined(separator: ",")
    }
    private func setIndicatorHidden(_ kind: IndicatorKind, hidden: Bool) {
        var s = hiddenIndicators
        if hidden { s.insert(kind) } else { s.remove(kind) }
        hiddenIndicatorsRaw = s.map(\.rawValue).sorted().joined(separator: ",")
    }
    private func setOscillatorHidden(_ kind: OscillatorKind, hidden: Bool) {
        var s = hiddenOscillators
        if hidden { s.insert(kind) } else { s.remove(kind) }
        hiddenOscillatorsRaw = s.map(\.rawValue).sorted().joined(separator: ",")
    }

    // ── Grid fullscreen pane sync ─────────────────────────────────
    // Same helpers as DashboardView — see the comment there.
    @discardableResult
    private func syncToFullscreenPane<T: Equatable>(
        _ keyPath: WritableKeyPath<ChartPane, T>,
        _ value: T
    ) -> Bool {
        guard let fsID = multiChart.fullscreenPaneID,
              let pane = multiChart.panes.first(where: { $0.id == fsID }),
              pane[keyPath: keyPath] != value
        else { return false }
        var p = pane
        p[keyPath: keyPath] = value
        multiChart.updatePane(p)
        return true
    }

    private func syncIndicatorsToFullscreenPane() {
        guard let fsID = multiChart.fullscreenPaneID,
              let pane = multiChart.panes.first(where: { $0.id == fsID }),
              pane.indicators != enabledIndicators
        else { return }
        var p = pane
        p.indicators = enabledIndicators
        multiChart.updatePane(p)
    }

    private func syncOscillatorsToFullscreenPane() {
        guard let fsID = multiChart.fullscreenPaneID,
              let pane = multiChart.panes.first(where: { $0.id == fsID }),
              pane.oscillators != enabledOscillators
        else { return }
        var p = pane
        p.oscillators = enabledOscillators
        multiChart.updatePane(p)
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

                    let showsGrid = multiChart.layout != .single && !app.isChartFullscreen
                    let isFull = app.isChartFullscreen
                    ZStack {
                        chartCard(pair)
                            .frame(maxWidth: showsGrid ? 0 : .infinity,
                                   maxHeight: showsGrid ? 0 : .infinity)
                            .opacity(showsGrid ? 0 : 1)
                            .allowsHitTesting(!showsGrid)
                        ChartGridView(
                            layoutStore: multiChart,
                            indicatorConfig: oscillatorConfig,
                            drawingStore: drawingStore,
                            activeDrawingTool: $activeDrawingTool
                        ) { gridFullscreenToolbar }
                        .environmentObject(app)
                        .environmentObject(yahoo)
                        .frame(maxWidth: showsGrid ? .infinity : 0,
                               maxHeight: showsGrid ? .infinity : 0)
                        .opacity(showsGrid ? 1 : 0)
                        .allowsHitTesting(showsGrid)
                    }
                    .clipped()

                    if !showsGrid && !isFull {
                        statsRow(pair)
                    }
                } else {
                    emptyState
                }
            }
            .padding(app.isChartFullscreen ? 0 : 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // Phase 2: Analysis overlay
            if let pair = pair {
                let showAP = showAnalysis
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
                .frame(maxWidth: showAP ? .infinity : 0,
                       maxHeight: showAP ? .infinity : 0)
                .opacity(showAP ? 1 : 0)
                .allowsHitTesting(showAP)
            }
        }
        .background(Theme.Color.canvas)
        .task(id: app.selectedPairID) {
            await MainActor.run {
                xDomain = nil
                yDomain = nil
                srLevels = .init(support: [], resistance: [])
                fvgZones = []
                supplyDemandZones = []
                taScenario = nil
                taAltScenario = nil
                selectedDrawingID = nil
                alertStore.timeframeLabel = timeframe.rawValue
            }
            await reloadCandles()
        }
        .onChange(of: timeframe) { _ in
            if syncToFullscreenPane(\.timeframe, timeframe) { return }
            Task { @MainActor in
                xDomain = nil
                yDomain = nil
                alertStore.timeframeLabel = timeframe.rawValue
                await reloadCandles()
            }
        }
        .onChange(of: userChartType) { newValue in
            _ = syncToFullscreenPane(\.chartType, newValue)
        }
        .onChange(of: indicatorsRaw) { _ in
            syncIndicatorsToFullscreenPane()
        }
        .onChange(of: oscillatorsRaw) { _ in
            syncOscillatorsToFullscreenPane()
        }
        .onChange(of: showVolume) { newValue in
            _ = syncToFullscreenPane(\.showVolume, newValue)
        }
        .onChange(of: multiChart.fullscreenPaneID) { fsID in
            guard let fsID,
                  let pane = multiChart.panes.first(where: { $0.id == fsID })
            else { return }
            timeframe = pane.timeframe
            userChartType = pane.chartType
            indicatorsRaw = pane.indicators.map(\.rawValue).sorted().joined(separator: ",")
            oscillatorsRaw = pane.oscillators.map(\.rawValue).sorted().joined(separator: ",")
            showVolume = pane.showVolume
        }
        .onReceive(
            yahoo.$lastUpdateAt
                .compactMap { $0 }
                .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
        ) { _ in
            if let cur = app.pairs.first(where: { $0.id == app.selectedPairID }),
               cur.usesLiveStream {
                Task { await reloadCandles() }
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

            // Grid layout toggle
            Menu {
                ForEach(ChartLayoutKind.allCases) { layout in
                    Button {
                        if let pairID = app.selectedPairID {
                            multiChart.setLayout(layout, defaultPairID: pairID)
                        }
                    } label: {
                        Label(layout.label, systemImage: layout.icon)
                    }
                }
            } label: {
                Image(systemName: multiChart.layout.icon)
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
                        Button {
                            setIndicator(kind, enabled: !enabledIndicators.contains(kind))
                        } label: {
                            Label(kind.label,
                                  systemImage: enabledIndicators.contains(kind) ? "checkmark.circle.fill" : "circle")
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

            // Chart body — Phase 2: wired with drawing store
            ChartViewiPad(
                candles: candles,
                chartType: userChartType,
                accent: pair.color,
                xDomain: $xDomain,
                yDomain: $yDomain,
                indicators: visibleIndicators,
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
                replayActive: replay.isActive
            )
            .frame(maxHeight: .infinity)
            .clipped()

            // Oscillator panels
            if !visibleOscillators.isEmpty {
                Divider().background(Theme.Color.border)
                ForEach(Array(visibleOscillators)) { kind in
                    OscillatorPanel(
                        kind: kind,
                        candles: candles,
                        config: oscillatorConfig,
                        xDomain: xDomain
                    )
                    .padding(.horizontal, Theme.Spacing.lg)
                }
            }

            // Volume bars
            if showVolume {
                let volView = VolumeBarsView(candles: candles, accent: pair.color, xDomain: xDomain)
                if volView.hasVolume {
                    Divider().background(Theme.Color.border)
                    volView
                        .frame(height: 50)
                        .padding(.horizontal, Theme.Spacing.lg)
                }
            }
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

    // MARK: - Grid fullscreen toolbar

    private var gridFullscreenToolbar: some View {
        HStack(spacing: Theme.Spacing.md) {
            if let pairID = app.selectedPairID,
               let pair = app.pairs.first(where: { $0.id == pairID }) {
                Text(pair.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(timeframe.label)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.Color.textMuted)
                Divider().frame(height: 20).background(Theme.Color.border)
            }
            HStack(spacing: 6) {
                // AI Analyze
                Button { showAnalysis = true } label: {
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

                // Replay
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
                }

                // Alerts
                Button { showAlertSheet = true } label: {
                    Image(systemName: "bell")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .frame(width: 32, height: 32)
                }

                Divider().frame(height: 20).background(Theme.Color.border)

                // Indicators
                Menu {
                    ForEach(IndicatorKind.allCases) { kind in
                        Button {
                            setIndicator(kind, enabled: !enabledIndicators.contains(kind))
                        } label: {
                            Label(kind.label,
                                  systemImage: enabledIndicators.contains(kind) ? "checkmark.circle.fill" : "circle")
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
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .frame(width: 32, height: 32)
                }

                // Layers
                Menu {
                    layersMenuContent
                } label: {
                    Image(systemName: "square.3.layers.3d")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .frame(width: 32, height: 32)
                }

                // Drawing tools
                drawingToolbar

                Divider().frame(height: 20).background(Theme.Color.border)

                ChartTypeToggle(selected: $userChartType, isDisabled: false)
                TimeframeSelector(selected: $timeframe)

                Divider().frame(height: 20).background(Theme.Color.border)

                // Debug
                Button {
                    showDebugLogSheet = true
                } label: {
                    Image(systemName: "ladybug.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(NetworkLog.shared.isEnabled
                                         ? Theme.Color.warn
                                         : Theme.Color.textSecondary)
                        .frame(width: 32, height: 32)
                }

                // Fullscreen
                Button {
                    app.isChartFullscreen = false
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .frame(width: 32, height: 32)
                }
                .help("Exit fullscreen")
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
