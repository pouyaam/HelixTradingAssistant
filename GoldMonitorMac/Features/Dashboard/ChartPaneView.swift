import SwiftUI
import Combine

/// One independent chart in the multi-chart split-screen grid: its own
/// pair, timeframe, chart type, and indicator/oscillator selection.
/// Deliberately lighter than the primary dashboard chart — no AI
/// overlays, trade markers, replay, or journal pins; those stay on the
/// single-chart view (`DashboardView.chartCard`). Drawings ARE
/// supported (tools live in the right-click menu) since they're a
/// property of the pair, shared with the primary chart via the same
/// `DrawingStore`. Candle loading mirrors `DashboardView.reloadCandles`
/// / `refreshTrailingCandles` but scoped to this pane's own pair +
/// timeframe via the shared `OHLCCandleLoader`.
struct ChartPaneView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var yahoo: YahooScheduler

    let pane: ChartPane
    /// Indicator-parameter config (RSI period, UT Bot key value, etc.)
    /// is a global app setting, not per-pane — every pane reads the
    /// same `OscillatorConfig` the primary chart's settings sheet
    /// edits, so tuning a period there updates every open pane too.
    let indicatorConfig: OscillatorConfig
    /// Same store the primary chart uses, keyed by `pane.pairID` — a
    /// line drawn here shows up on the primary chart for that pair too.
    @ObservedObject var drawingStore: DrawingStore
    /// True while this pane is the one expanded to fill the whole grid
    /// area (every sibling pane, the sidebar, and the pair header hide
    /// — see `ChartGridView`). Toggled by the header's fullscreen
    /// button or the right-click menu's "Fullscreen" item.
    @Binding var isFullscreen: Bool
    /// True when the grid stacks two full rows of panes (`.twoRow` /
    /// `.grid2x2`) — those layouts need roughly double the vertical
    /// budget of a single-row layout, so this trims chart/volume/
    /// oscillator minimums and padding to help both rows actually fit
    /// the window instead of overflowing it.
    var isCompact: Bool = false
    /// False while a *sibling* pane is fullscreen, collapsing this one
    /// to zero size (see `ChartGridView.paneSlot`'s `isHidden`). The
    /// view stays mounted either way — only the tick-driven candle
    /// refresh pauses (see `body`'s `onReceive`). Skipping that refresh
    /// while invisible avoids rebuilding this pane's `ChartView` (candle
    /// marks, Order Block / Steroid OB scans, oscillators — the
    /// expensive part) on every live price tick for a chart nobody can
    /// see; a plain grid with N mounted panes was paying that cost N×
    /// even with only one pane on screen.
    var isVisible: Bool = true
    /// External drawing tool binding from the parent (ChartGridView /
    /// DashboardView). When the pane is fullscreen, this binding is
    /// used instead of the internal @State so the fullscreen toolbar's
    /// drawing picker and the pane's gesture handler share the same
    /// state. (Grid fullscreen drawing fix.)
    @Binding var fullscreenDrawingTool: DrawingTool
    let onUpdate: (ChartPane) -> Void

    @State private var candles: [Candle] = []
    @State private var xDomain: ClosedRange<Double>?
    @State private var yDomain: ClosedRange<Double>?
    /// Armed drawing tool for this pane's next drag gesture on the
    /// chart. `.none` = normal pan/zoom cursor. Mirrors
    /// `DashboardView.activeDrawingTool`, just scoped per pane instead
    /// of to the whole dashboard.
    @State private var activeDrawingTool: DrawingTool = .none
    @State private var selectedDrawingID: UUID?

    /// The active drawing tool — reads from the external binding when
    /// fullscreen (so the fullscreen toolbar works), falls back to the
    /// internal @State when not fullscreen.
    private var effectiveDrawingTool: DrawingTool {
        isFullscreen ? fullscreenDrawingTool : activeDrawingTool
    }

    /// Set the drawing tool on both internal state and external binding.
    private func setDrawingTool(_ tool: DrawingTool) {
        activeDrawingTool = tool
        fullscreenDrawingTool = tool
    }

    private var pair: TradingPair? { app.pairs.first(where: { $0.id == pane.pairID }) }

    var body: some View {
        content
            .task(id: "\(pane.pairID)|\(pane.timeframe.rawValue)") {
                await load()
            }
            .onReceive(
                // Same 1 Hz throttle as `DashboardView`'s trailing refresh —
                // see the comment there for why 5 Hz raw ticks would pin
                // the main thread across N panes.
                yahoo.$lastUpdateAt
                    .compactMap { $0 }
                    .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            ) { _ in
                guard isVisible else { return }
                Task { await refreshTrailing() }
            }
            .onChange(of: yahoo.dataResetToken) { _ in
                Task { await load() }
            }
            // Catch up on whatever ticks were skipped while a sibling
            // pane was fullscreen — refreshTrailing's lookback window
            // (`margin`) covers ordinary durations, so a cheap trailing
            // refresh is enough rather than a full `load()`.
            .onChange(of: isVisible) { visible in
                if visible { Task { await refreshTrailing() } }
            }
    }

    private var content: some View {
        // Fullscreen drops the Card chrome (rounded corners, padding,
        // surface fill) the same way the primary chart's own
        // `isChartFull` does — the chart's edges meet the window edges
        // so it truly fills the space with nothing else visible. A
        // single, unconditional `Card` call (chrome + padding vary by
        // value) instead of `if isFullscreen { chartStack } else {
        // Card { chartStack } }` — that `if/else` would tear down and
        // rebuild `chartStack`'s `ChartView` (and its indicator cache)
        // on every fullscreen toggle. See `Card.chromeless`.
        Card(padding: isFullscreen ? 0 : (isCompact ? Theme.Spacing.md : Theme.Spacing.xl), chromeless: isFullscreen) {
            chartStack.padding(isFullscreen ? 0 : Theme.Spacing.md)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chartStack: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            header
            if let pair {
                let chartContent = Group {
                    #if os(iOS)
                    ChartViewiPad(
                        candles: candles,
                        chartType: pane.chartType,
                        accent: pair.color,
                        xDomain: $xDomain,
                        yDomain: $yDomain,
                        indicators: pane.indicators,
                        indicatorConfig: indicatorConfig,
                        drawings: drawingStore.drawings(for: pane.pairID),
                        activeTool: effectiveDrawingTool,
                        onCommitDrawing: { drawing in
                            drawingStore.add(drawing, for: pane.pairID)
                            setDrawingTool(.none)
                            selectedDrawingID = drawing.id
                        },
                        onMoveDrawing: { drawing in
                            drawingStore.update(drawing, for: pane.pairID)
                        },
                        selectedDrawingID: selectedDrawingID,
                        onSelectDrawing: { id in
                            selectedDrawingID = id
                        },
                        livePrice: yahoo.latestPrices[pane.pairID]
                    )
                    #else
                    ChartView(
                        candles: candles,
                        chartType: pane.chartType,
                        accent: pair.color,
                        xDomain: $xDomain,
                        yDomain: $yDomain,
                        indicators: pane.indicators,
                        indicatorConfig: indicatorConfig,
                        drawings: drawingStore.drawings(for: pane.pairID),
                        activeTool: effectiveDrawingTool,
                        onCommitDrawing: { drawing in
                            drawingStore.add(drawing, for: pane.pairID)
                            setDrawingTool(.none)
                            selectedDrawingID = drawing.id
                        },
                        onMoveDrawing: { drawing in
                            drawingStore.update(drawing, for: pane.pairID)
                        },
                        selectedDrawingID: selectedDrawingID,
                        onSelectDrawing: { id in
                            selectedDrawingID = id
                        },
                        livePrice: yahoo.latestPrices[pane.pairID]
                    )
                    #endif
                }
                chartContent
                    .frame(minHeight: isCompact ? 130 : 200, maxHeight: .infinity)
                    .clipped()
                #if !os(iOS)
                .drawingDeleteKey(selectedDrawingID: $selectedDrawingID, drawingStore: drawingStore, pairID: pane.pairID)
                #endif
                .contextMenu { optionsMenu }
                // Scroll-to-latest puck — same as the single chart's.
                .overlay(alignment: .bottomLeading) {
                    if !isViewingLatest {
                        Button { scrollToLatest() } label: {
                            Image(systemName: "forward.end.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(Theme.accentGradient))
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                                .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                        }
                        .buttonStyle(.plain)
                        .help("Scroll to latest")
                        .padding(.leading, Theme.Spacing.sm)
                        .padding(.bottom, Theme.Spacing.sm)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.15), value: isViewingLatest)

                if pane.showVolume {
                    VolumeBarsView(candles: candles, accent: pair.color, xDomain: xDomain)
                        .frame(height: isCompact ? 28 : 36)
                }
                ForEach(pane.oscillators.sorted(by: { $0.rawValue < $1.rawValue })) { osc in
                    OscillatorPanel(kind: osc, candles: candles, config: indicatorConfig, xDomain: xDomain)
                        .frame(height: isCompact ? 56 : 80)
                }
            } else {
                Text("Pair unavailable")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Color.textMuted)
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // ── Header ────────────────────────────────────────────────────
    //
    // Deliberately minimal — read-only pair/price/timeframe info plus
    // the one control that needs a discoverable, always-visible button
    // (fullscreen). Every other option (pair, timeframe, chart type,
    // indicators, oscillators, volume) now lives in `optionsMenu`,
    // reached by right-clicking the chart.

    private var header: some View {
        HStack(spacing: 6) {
            Circle().fill(pair?.color ?? Theme.Color.textMuted).frame(width: 8, height: 8)
            Text(pair?.symbol ?? "—")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Color.textPrimary)
            if let pair {
                Text(displayedPrice(pair))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.Color.textMuted)
            }

            Spacer()

            if effectiveDrawingTool != .none {
                armedToolBadge
            }

            // Timeframe + chart type selectors — same controls as the
            // single chart's toolbar, bound to this pane's state.
            TimeframeSelector(selected: timeframeBinding)
            ChartTypeToggle(selected: chartTypeBinding, isDisabled: false)

            fullscreenButton
        }
    }

    /// Binding for TimeframeSelector — reads from pane, writes via onUpdate.
    private var timeframeBinding: Binding<Timeframe> {
        Binding(
            get: { pane.timeframe },
            set: { newTF in
                var updated = pane
                updated.timeframe = newTF
                onUpdate(updated)
            }
        )
    }

    /// Binding for ChartTypeToggle — reads from pane, writes via onUpdate.
    private var chartTypeBinding: Binding<ChartType> {
        Binding(
            get: { pane.chartType },
            set: { newCT in
                var updated = pane
                updated.chartType = newCT
                onUpdate(updated)
            }
        )
    }

    /// Shown only while a drawing tool is armed — there's no persistent
    /// toolbar row anymore (options moved to right-click), so this is
    /// the only visual cue that the next drag on the chart draws a
    /// shape instead of panning. Tapping it disarms back to the cursor.
    private var armedToolBadge: some View {
        Button {
            setDrawingTool(.none)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: effectiveDrawingTool.systemImage)
                Text(effectiveDrawingTool.label)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Theme.accentGradient))
        }
        .buttonStyle(.plain)
        .help("Drawing \(activeDrawingTool.label) — click to cancel")
    }

    private var fullscreenButton: some View {
        Button {
            isFullscreen.toggle()
        } label: {
            Image(systemName: isFullscreen
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Color.textSecondary)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(isFullscreen ? "Exit fullscreen" : "Fullscreen")
    }

    /// Right-click menu with every chart option that used to live in
    /// the always-visible header row: pair, timeframe, chart type,
    /// indicators/oscillators, volume, and fullscreen. Parameter
    /// tuning (RSI period, UT Bot key value, etc.) stays global, edited
    /// from the primary chart's settings sheet.
    @ViewBuilder
    private var optionsMenu: some View {
        Menu("Pair") {
            ForEach(app.pairs) { p in
                Button {
                    var updated = pane
                    updated.pairID = p.id
                    onUpdate(updated)
                } label: {
                    Label(p.name, systemImage: p.id == pane.pairID ? "checkmark.circle.fill" : "circle")
                }
            }
        }
        Menu("Timeframe") {
            ForEach(Timeframe.allCases) { tf in
                Button {
                    var updated = pane
                    updated.timeframe = tf
                    onUpdate(updated)
                } label: {
                    Label(tf.label, systemImage: tf == pane.timeframe ? "checkmark.circle.fill" : "circle")
                }
            }
        }
        Menu("Chart type") {
            ForEach(ChartType.allCases) { ct in
                Button {
                    var updated = pane
                    updated.chartType = ct
                    onUpdate(updated)
                } label: {
                    Label(ct.label, systemImage: ct == pane.chartType ? "checkmark.circle.fill" : "circle")
                }
            }
        }
        Menu("Indicators") {
            ForEach(IndicatorKind.allCases) { kind in
                Button {
                    var updated = pane
                    if updated.indicators.contains(kind) { updated.indicators.remove(kind) }
                    else { updated.indicators.insert(kind) }
                    onUpdate(updated)
                } label: {
                    Label(kind.label, systemImage: pane.indicators.contains(kind) ? "checkmark.circle.fill" : "circle")
                }
            }
        }
        Menu("Oscillators") {
            ForEach(OscillatorKind.allCases) { kind in
                Button {
                    var updated = pane
                    if updated.oscillators.contains(kind) { updated.oscillators.remove(kind) }
                    else { updated.oscillators.insert(kind) }
                    onUpdate(updated)
                } label: {
                    Label(kind.label, systemImage: pane.oscillators.contains(kind) ? "checkmark.circle.fill" : "circle")
                }
            }
        }
        Button {
            var updated = pane
            updated.showVolume.toggle()
            onUpdate(updated)
        } label: {
            Label("Volume", systemImage: pane.showVolume ? "checkmark.circle.fill" : "circle")
        }
        Divider()
        Menu("Drawing Tool") {
            ForEach(DrawingTool.allCases) { tool in
                Button {
                    setDrawingTool(tool)
                } label: {
                    Label(tool.label, systemImage: effectiveDrawingTool == tool
                          ? "checkmark.circle.fill" : tool.systemImage)
                }
            }
        }
        if selectedDrawingID != nil {
            Button(role: .destructive) {
                if let id = selectedDrawingID {
                    drawingStore.remove(id: id, for: pane.pairID)
                    selectedDrawingID = nil
                }
            } label: {
                Label("Delete Selected Drawing", systemImage: "trash")
            }
        }
        if !drawingStore.drawings(for: pane.pairID).isEmpty {
            Button(role: .destructive) {
                drawingStore.clear(for: pane.pairID)
                selectedDrawingID = nil
            } label: {
                Label("Clear Drawings", systemImage: "trash.slash")
            }
        }
        Divider()
        Button {
            isFullscreen.toggle()
        } label: {
            Label(isFullscreen ? "Exit Fullscreen" : "Fullscreen",
                  systemImage: isFullscreen
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
        }
    }

    private func displayedPrice(_ pair: TradingPair) -> String {
        if let p = yahoo.latestPrices[pair.id] {
            return p.formatted(.number.precision(.fractionLength(2)))
        }
        return "—"
    }

    // ── Candle loading ────────────────────────────────────────────
    //
    // Mirrors `DashboardView.reloadCandles` / `refreshTrailingCandles`
    // exactly, just scoped to this pane's own pair + timeframe instead
    // of the dashboard's single `@AppStorage` selection.

    private func load() async {
        guard let db = app.database else { candles = []; return }
        let pairID = pane.pairID
        let tf = pane.timeframe
        let respectsWeekend = app.pairs.first(where: { $0.id == pairID })?.category != .crypto
        let result = await OHLCCandleLoader.loadAsync(
            repo: db.ohlcRepo, pairID: pairID, tf: tf,
            since: .distantPast, until: Date(), dropClosedDays: respectsWeekend
        )
        self.candles = result
        self.xDomain = nil
        self.yDomain = nil
        self.setDrawingTool(.none)
        self.selectedDrawingID = nil
    }

    /// Cheap trailing-window refresh on the same live-tick cadence the
    /// primary chart uses, so panes stay current without re-reading
    /// years of history every tick.
    private func refreshTrailing() async {
        guard let db = app.database, !candles.isEmpty else { return }
        let pairID = pane.pairID
        let tf = pane.timeframe
        let respectsWeekend = app.pairs.first(where: { $0.id == pairID })?.category != .crypto
        let until = Date()
        let margin = Double(max(tf.seconds * 3, 6 * 3600))
        let since = until.addingTimeInterval(-margin)
        let recent = await OHLCCandleLoader.loadAsync(
            repo: db.ohlcRepo, pairID: pairID, tf: tf,
            since: since, until: until, dropClosedDays: respectsWeekend
        )
        guard let cutoff = recent.first?.bucketStart else { return }
        var merged = candles
        while let last = merged.last, last.bucketStart >= cutoff { merged.removeLast() }
        merged.append(contentsOf: recent)
        candles = merged
    }

    // ── Scroll to latest ──────────────────────────────────────────

    /// True when the visible window's right edge is at or past the
    /// newest candle. Drives the scroll-to-latest puck's visibility.
    private var isViewingLatest: Bool {
        guard candles.count > 0, let d = xDomain else { return true }
        return d.upperBound >= Double(candles.count - 1)
    }

    /// Slide the window so its right edge lands on the newest candle,
    /// preserving the current zoom width. Matches DashboardView's
    /// `scrollToLatest()`.
    private func scrollToLatest() {
        guard candles.count > 0 else { return }
        let domain = xDomain ?? ChartWindow.defaultDomain(count: candles.count)
        let span = domain.upperBound - domain.lowerBound
        let upper = Double(candles.count - 1) + 0.5
        let lower = max(-0.5, upper - span)
        withAnimation(.easeInOut(duration: 0.25)) {
            xDomain = lower ... upper
        }
    }
}
