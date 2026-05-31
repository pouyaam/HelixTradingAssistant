import SwiftUI
import Charts

/// Trading-style chart built on Apple's Charts framework.
///
/// What it shows:
///   • OHLC candles or a smoothed line of closes (caller's choice).
///   • A dashed horizontal rule pinned to the most recent close, with a
///     floating accent-coloured price tag at the right edge — same visual
///     idiom as TradingView / lightweight-charts. Lets you eyeball the
///     current price without scanning the whole Y axis.
///   • A live crosshair on hover: vertical + horizontal dashed lines and
///     a pulse dot at the data point under the cursor.
///   • A floating OHLC + Δ tooltip at the top-left whenever the user is
///     hovering, so they can read precise values without a separate pane.
///   • Auto-fit Y axis with 5% padding — never the dreaded "0 → ∞" scale
///     that drowns million-toman prices into a single pixel.
///   • Compact "K/M/B" Y-axis labels so 19,634,000 → "19.6M", not "1.9E7".
struct ChartView: View {
    let candles: [Candle]
    let chartType: ChartType
    let accent: Color

    /// Visible X-axis window expressed in *bar indices* (Double for
    /// fractional pan/zoom precision). nil ⇒ auto-fit to the full series.
    /// We use index-based axes rather than continuous time so calendar
    /// gaps (weekends for COMEX, intraday silences for any source) don't
    /// open holes in the chart — consecutive candles are always adjacent.
    @Binding var xDomain: ClosedRange<Double>?

    /// Technical indicators the user has toggled on. Re-computed on every
    /// candle change; ChartView is stateless about them — DashboardView
    /// owns the user's selection.
    let indicators: Set<IndicatorKind>

    /// User-tunable indicator parameters (RSI period, UT Bot key value
    /// etc.). Threaded down so UT Bot can compute its trailing stop +
    /// signals from the same config the settings sheet edits.
    let indicatorConfig: OscillatorConfig

    /// Support / resistance levels the user added from an AI analysis.
    /// Empty by default; populated when the user clicks "Add to chart"
    /// on a Support & Resistance Claude run. Drawn as horizontal rules
    /// with a small "S" / "R" tag.
    var srLevels: PromptBuilder.SRLevels = .init(support: [], resistance: [])

    /// FVG / iFVG zones from the AI analysis. Each renders as a
    /// translucent rectangle spanning the gap's bar range and price
    /// band. iFVGs (mitigated) get a dashed border to distinguish them
    /// from active FVGs.
    var fvgZones: [PromptBuilder.FVGZone] = []

    /// Supply & Demand zones from the Confluence Trade Scanner (or Custom) analysis.
    /// Each renders as a translucent rectangle: green for Demand,
    /// red for Supply, spanning the base candle's bar range + price
    /// band. Tested zones (`isFresh == false`) drop to a lower
    /// opacity + dashed border so the user can tell first-test
    /// setups apart from already-revisited ones at a glance.
    var supplyDemandZones: [PromptBuilder.SupplyDemandZone] = []

    /// Outlook from a full TA analysis. When present, two dashed rules
    /// (green target, red invalidation) plus a bias capsule at the
    /// right edge appear on the chart.
    var taScenario: PromptBuilder.TAScenario? = nil

    /// Optional alternative trade plan from the same TA run. Rendered
    /// in parallel with `taScenario` but with thinner / dimmer
    /// styling so the eye reads "this is the secondary plan, not a
    /// duplicate of the main one".
    var taAltScenario: PromptBuilder.TAScenario? = nil

    /// User-drawn shapes (horizontal lines, trend lines, rectangles).
    /// DashboardView owns the persistent store and feeds the visible
    /// subset here; ChartView is stateless about which pair these
    /// belong to.
    var drawings: [ChartDrawing] = []

    /// Tool currently armed by the dashboard's drawing toolbar. When
    /// `.none` the chart behaves normally (drag = pan). Anything else
    /// swaps drag → "draw a shape" — the pinch gesture and crosshair
    /// stay active so the user keeps spatial reference while drawing.
    var activeTool: DrawingTool = .none

    /// Called with the fully-formed `ChartDrawing` when the user
    /// finishes a draw gesture (mouse-up). DashboardView appends to
    /// its `DrawingStore`. Optional so existing call-sites that don't
    /// care about drawings can omit it.
    var onCommitDrawing: ((ChartDrawing) -> Void)? = nil

    /// Called with a modified `ChartDrawing` when the user finishes
    /// dragging an existing shape to a new position. Same `id` as the
    /// original — DashboardView's `DrawingStore.update` replaces in
    /// place. Optional for call-sites that don't allow editing.
    var onMoveDrawing: ((ChartDrawing) -> Void)? = nil

    /// Drawing that should render with selection handles, if any. The
    /// dashboard owns this state because it also drives the inspector
    /// popover; the chart just renders + lets the user grab a handle.
    var selectedDrawingID: UUID? = nil

    /// Called when the user clicks a drawing (selects it) or clicks
    /// empty space (deselects, value = nil). Lets the dashboard sync
    /// its `selectedDrawingID` state with what the chart is showing.
    var onSelectDrawing: ((UUID?) -> Void)? = nil

    /// Open paper trades to render. Closed trades are filtered out by
    /// the dashboard (`TradeStore.openVisibleTrades`); the chart only
    /// sees `.pending` or `.active`. Each contributes three RuleMarks
    /// (entry / TP / SL) plus a fill-time marker for actives.
    var trades: [Trade] = []

    /// Most recent live price for the pair this chart represents.
    /// Drives the live P/L capsule on active trades AND the VALID /
    /// INVALID badge on TA scenario entry tags (a scenario flips to
    /// invalid the moment price crosses its SL line). Optional —
    /// non-live-stream pairs may not have a fresh tick yet, in which
    /// case the validity badge falls back to "VALID" so we don't
    /// false-negative on cold start.
    var livePrice: Double? = nil

    /// Replay mode is active (the chart is showing history up to a
    /// cursor). Draws a marker at the last (cursor) bar so the user
    /// always knows where "now" sits in the replay.
    var replayActive: Bool = false

    /// The chart is waiting for the user to click a start bar for
    /// Replay. While true, a plain click (no drag) anchors the replay
    /// instead of deselecting drawings; panning still works.
    var isPickingReplayAnchor: Bool = false

    /// Called with the clicked bar's index (into `candles`) when the
    /// user picks a replay start bar. DashboardView maps it to that
    /// candle's date and sets the cursor.
    var onPickReplayAnchor: ((Int) -> Void)? = nil

    @State private var hovered: HoverState?
    /// Memoizes the data-derived arrays (HA candles, indicators, UT Bot)
    /// so pan/zoom — which only changes `xDomain` — doesn't recompute
    /// them over the full history every frame. @State so it survives the
    /// struct being re-created each render. See `ChartDerivedCache`.
    @State private var derived = ChartDerivedCache()
    @State private var dragStartDomain: ClosedRange<Double>?
    @State private var magnifyStartDomain: ClosedRange<Double>?

    /// In-progress drawing endpoints — captured on drag start, updated
    /// each frame, cleared on drag end. Lets the chart render a live
    /// preview of the shape the user is currently creating so they
    /// can see what they'll get before committing.
    @State private var drawingStart: DrawingPoint?
    @State private var drawingEnd: DrawingPoint?

    /// Drag-to-move state. When the user clicks on an existing drawing
    /// in cursor mode (`activeTool == .none`), `movingDrawingOriginal`
    /// captures its initial endpoints and `movingDelta` accumulates
    /// the offset (in date + price space) as the cursor moves. The
    /// chart filters the original out of `drawingMarks` and renders a
    /// translated preview based on these so the user sees where the
    /// shape will land before releasing the mouse.
    @State private var movingDrawingOriginal: ChartDrawing?
    @State private var movingDeltaTime: TimeInterval = 0
    @State private var movingDeltaPrice: Double = 0

    /// Drag-to-reshape state. When the user grabs an endpoint handle
    /// of the currently-selected drawing, this captures which handle
    /// (so we know which endpoint to mutate) plus the live cursor
    /// point each frame. `editingHandle == nil` ⇒ no handle drag in
    /// flight, fall back to move/pan logic.
    @State private var editingDrawingID: UUID?
    @State private var editingHandle: ChartDrawing.Handle?
    @State private var editingCursor: DrawingPoint?

    /// Tracks whether a gesture was a click vs a drag. We can't tell
    /// at `onChanged` time whether a click will turn into a drag, so
    /// we route the gesture optimistically and use this in `onEnded`
    /// to convert a zero-distance click on a drawing into a selection.
    @State private var dragHadMovement: Bool = false

    /// Captured on hover. Holds the candle the cursor is over plus the
    /// raw cursor location (kept for the tooltip's positional anchor —
    /// could be useful later for a sticky tooltip) and the cursor's
    /// free Y price, projected from screen Y via the chart proxy.
    /// `cursorPrice` is the value the horizontal crosshair line tracks
    /// (TradingView-style: line follows the cursor, not the snapped
    /// candle close), so the user can read off the price at any spot
    /// on the chart — not just rows that line up with a bar.
    private struct HoverState: Equatable {
        let candle: Candle
        let index: Int
        let cursor: CGPoint
        let cursorPrice: Double
    }

    var body: some View {
        if candles.isEmpty {
            emptyState
        } else {
            chart
                // Tight clip on every edge. The last-price capsule now
                // overlays the rule *inside* the plot area (see the
                // `RuleMark` above) so no trailing slack is needed.
                .clipped()
                .overlay(alignment: .topLeading) { hoverTooltip }
                .animation(.easeOut(duration: 0.15), value: hovered)
                .animation(.easeInOut(duration: 0.4), value: candles.count)
        }
    }

    // MARK: - Chart body

    /// Candles actually drawn on the chart. When the user selects the
    /// Heikin Ashi chart type, we transform OHLC values here so every
    /// price-anchored mark (candles, line, last-price rule, hover
    /// crosshair, UT Bot signal markers) uses the smoothed values.
    /// Indicators that derive their own values from `candles` (SMA, EMA,
    /// Bollinger, oscillators) still read the raw input — that matches
    /// TradingView's convention.
    private var displayCandles: [Candle] {
        // Delegates to the memoizing cache: HA transform + live-price
        // patch on the last bar. Cached against the candle data + live
        // price so a pan (xDomain-only change) reuses the prior result
        // instead of rebuilding the whole array every frame.
        derived.displayCandles(
            candles: candles,
            heikinAshi: chartType == .heikinAshi,
            livePrice: livePrice
        )
    }

    /// UT Bot output, lazily computed when the indicator is toggled on.
    /// Both the trailing-stop line and the buy/sell labels come from
    /// this single computation, so we don't re-run the (O(n)) loop in
    /// two different builders.
    private var utBotOutput: UTBot.Output? {
        guard indicators.contains(.utBot) else { return nil }
        return derived.utBot(
            candles: candles,
            keyValue: indicatorConfig.utKeyValue,
            atrPeriod: indicatorConfig.utATRPeriod,
            useHeikinAshi: indicatorConfig.utUseHeikinAshi
        )
    }

    private var chart: some View {
        Chart {
            // Last-price horizontal reference line. Drawn first so it sits
            // behind the data marks. The trailing annotation pins a price
            // tag to the right edge — TradingView-style.
            if let last = displayCandles.last {
                RuleMark(y: .value("Last", last.close))
                    .foregroundStyle(accent.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    // Tag overlays the rule at its trailing end and stays
                    // *inside* the plot area — previously the annotation
                    // used `.trailing` which made the capsule extend past
                    // the plot edge, so the chart had to be clipped with
                    // slack on the right (which let panned marks leak too).
                    .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                        Text(Self.priceExact(last.close))
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(accent)
                            )
                    }
            }

            // Replay cursor — a dashed vertical at the last revealed bar
            // marks where "now" sits while stepping through history.
            if replayActive, !displayCandles.isEmpty {
                RuleMark(x: .value("Replay", Double(displayCandles.count - 1)))
                    .foregroundStyle(Theme.Color.warn.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
                    .annotation(position: .top, alignment: .trailing, spacing: 0) {
                        Text("REPLAY")
                            .font(.system(size: 8, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.Color.warn))
                    }
            }

            // S/R levels — horizontal rules at the prices the AI
            // analysis identified. Drawn behind the candles (before the
            // switch below) so the price action stays the visual focus.
            srLevelMarks
            fvgMarks
            supplyDemandMarks
            scenarioMarks
            tradeMarks
            drawingMarks
            drawingPreviewMarks

            // Main marks. `.heikinAshi` goes through the same candle
            // builder as `.candle` — the OHLC transform happens in
            // `displayCandles`, so the renderer doesn't need to care
            // about the source.
            switch chartType {
            case .line:                  lineMarks
            case .candle, .heikinAshi:   candleMarks
            }

            // Indicator overlays — drawn on top of the price series so
            // SMA/EMA/Bollinger lines aren't obscured by candle bodies.
            indicatorMarks

            // UT Bot trailing-stop line + buy/sell labels. Rendered last
            // so the labels sit on top of every other mark.
            utBotMarks

            // Crosshair — drawn last so it overlays the data. Vertical
            // rule snaps to the bar column under the cursor (bars are
            // discrete, free X would land between candles). Horizontal
            // rule follows the cursor's free Y so the user can read
            // the price at any point on the chart — TradingView's
            // default Cross mode. Both rules carry pill labels at the
            // axes showing the exact price (Y) and timestamp (X).
            if let h = hovered, h.index < displayCandles.count {
                let dc = displayCandles[h.index]
                RuleMark(x: .value("Hover X", Double(h.index)))
                    .foregroundStyle(Color.white.opacity(0.18))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .bottom, alignment: .center, spacing: 2) {
                        Text(Self.dateFormatter.string(from: h.candle.bucketStart))
                            .font(.system(size: 9, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Theme.Color.surfaceMax)
                            )
                    }
                RuleMark(y: .value("Hover Y", h.cursorPrice))
                    .foregroundStyle(Color.white.opacity(0.18))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                        Text(Self.priceExact(h.cursorPrice))
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(Theme.Color.surfaceMax)
                            )
                    }
                // Marker on the snapped candle close so the user still
                // sees which bar the crosshair is reading. Doesn't
                // anchor the horizontal line any more — that follows
                // the cursor.
                PointMark(
                    x: .value("Hover", Double(h.index)),
                    y: .value("Hover", dc.close)
                )
                .foregroundStyle(accent)
                .symbolSize(70)
            }
        }
        .chartYScale(domain: yDomain)
        .chartXScale(domain: effectiveXDomain)
        .chartXAxis(content: xAxis)
        .chartYAxis(content: yAxis)
        .chartPlotStyle { plot in
            plot
                .background(
                    LinearGradient(
                        colors: [
                            Theme.Color.surface.opacity(0.0),
                            Theme.Color.surface.opacity(0.6),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
        }
        .chartOverlay { proxy in
            // Transparent gesture catcher sized to the plot area. Maps the
            // cursor's X position back into the data domain (Date), then
            // snaps to the nearest candle. Set to nil on hover-end so the
            // crosshair disappears cleanly. Also hosts the drag-to-pan
            // and pinch-to-zoom gestures — both operate on `xDomain` and
            // need the plot frame size to translate point-distance into
            // time-distance, which lives on the chart proxy.
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            // Translate to the chart's plot frame coords,
                            // ask the proxy for the X-axis value (a bar
                            // index as Double), round to the nearest
                            // whole bar, and clamp into the array.
                            let origin = geo[proxy.plotAreaFrame].origin
                            let x = location.x - origin.x
                            let y = location.y - origin.y
                            guard let xValue: Double = proxy.value(atX: x) else { return }
                            let idx = max(0, min(candles.count - 1, Int(xValue.rounded())))
                            // Project the cursor's Y back into price
                            // space. nil ⇒ cursor is outside the plot
                            // area's Y range; fall back to the candle
                            // close so the crosshair always has a
                            // sensible reading.
                            let yPrice: Double = proxy.value(atY: y) ?? candles[idx].close
                            hovered = HoverState(
                                candle: candles[idx],
                                index: idx,
                                cursor: location,
                                cursorPrice: yPrice
                            )
                        case .ended:
                            hovered = nil
                        }
                    }
                    .gesture(dragGesture(
                        plotWidth: geo[proxy.plotAreaFrame].size.width,
                        plotOrigin: geo[proxy.plotAreaFrame].origin,
                        proxy: proxy
                    ))
                    .simultaneousGesture(magnificationGesture())
            }
        }
    }

    // MARK: - Pan / draw

    /// Single drag-handler that dispatches to one of three modes:
    ///   • cursor + drag started on a drawing → MOVE that drawing
    ///   • cursor + drag started anywhere else → PAN the chart
    ///   • a drawing tool armed → DRAW a new shape
    /// We use `minimumDistance: 0` so a simple click commits a
    /// horizontal line — the pan branch tolerates zero-distance drags
    /// fine (translation = 0 ⇒ no-op).
    private func dragGesture(
        plotWidth: CGFloat,
        plotOrigin: CGPoint,
        proxy: ChartProxy
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let movedFar = pow(value.translation.width, 2) + pow(value.translation.height, 2) >= 9
                if movedFar { dragHadMovement = true }

                if activeTool != .none {
                    handleDrawChange(value, plotOrigin: plotOrigin, proxy: proxy)
                    return
                }
                // Cursor mode — decide on the very first frame whether
                // the user grabbed a handle, the body of a drawing,
                // or wants to pan. The decision sticks for the rest of
                // the gesture.
                let alreadyChose =
                    editingDrawingID != nil ||
                    movingDrawingOriginal != nil ||
                    dragStartDomain != nil
                if !alreadyChose {
                    // 1) Handle first — handles are small, so only the
                    //    currently-selected drawing presents them and
                    //    the threshold is tight.
                    if let sel = selectionTargetDrawing,
                       let anchor = hitTestHandle(
                            of: sel,
                            at: value.startLocation,
                            plotOrigin: plotOrigin,
                            proxy: proxy
                       )
                    {
                        editingDrawingID = sel.id
                        editingHandle = anchor
                        editingCursor = drawingPoint(at: value.startLocation, plotOrigin: plotOrigin, proxy: proxy)
                        hovered = nil
                    }
                    // 2) Otherwise hit-test the body of any visible drawing.
                    else if let hit = hitTestDrawing(
                        at: value.startLocation,
                        plotOrigin: plotOrigin,
                        proxy: proxy
                    ) {
                        movingDrawingOriginal = hit
                        movingDeltaTime = 0
                        movingDeltaPrice = 0
                        hovered = nil
                    }
                }

                if editingDrawingID != nil {
                    editingCursor = drawingPoint(at: value.location, plotOrigin: plotOrigin, proxy: proxy)
                } else if movingDrawingOriginal != nil {
                    handleMoveChange(value, plotOrigin: plotOrigin, proxy: proxy)
                } else {
                    handlePanChange(value, plotWidth: plotWidth)
                }
            }
            .onEnded { value in
                let hadMovement = dragHadMovement
                dragHadMovement = false

                // Replay anchor pick takes priority: a click (no drag)
                // while picking sets the start bar. A drag is still a
                // pan — leave the panned domain in place and bail.
                if isPickingReplayAnchor {
                    if !hadMovement {
                        let xInPlot = value.location.x - plotOrigin.x
                        if let xVal: Double = proxy.value(atX: xInPlot) {
                            let idx = max(0, min(candles.count - 1, Int(xVal.rounded())))
                            onPickReplayAnchor?(idx)
                        }
                    }
                    dragStartDomain = nil
                    return
                }

                if activeTool != .none {
                    handleDrawEnd(value, plotOrigin: plotOrigin, proxy: proxy)
                    return
                }
                if editingDrawingID != nil {
                    handleResizeEnd()
                    return
                }
                if let moving = movingDrawingOriginal {
                    if hadMovement {
                        handleMoveEnd()
                    } else {
                        // No drag ⇒ this was a click on a drawing — treat
                        // as "select me", not a move.
                        onSelectDrawing?(moving.id)
                        movingDrawingOriginal = nil
                        movingDeltaTime = 0
                        movingDeltaPrice = 0
                    }
                    return
                }
                // Click on empty space deselects.
                if !hadMovement && selectedDrawingID != nil {
                    onSelectDrawing?(nil)
                }
                dragStartDomain = nil
            }
    }

    /// Was the click within handle-grab distance of any of the
    /// selected drawing's handles? Returns the matching anchor or nil.
    /// Handle hit-radius is tighter than body hit-radius (handles are
    /// supposed to feel precise).
    private func hitTestHandle(
        of d: ChartDrawing,
        at location: CGPoint,
        plotOrigin: CGPoint,
        proxy: ChartProxy,
        threshold: CGFloat = 10
    ) -> ChartDrawing.Handle? {
        let p = CGPoint(x: location.x - plotOrigin.x, y: location.y - plotOrigin.y)
        let handles = handlePositions(for: d)
        let anchors = handleAnchors(for: d)
        for (hp, anchor) in zip(handles, anchors) {
            guard let hx: CGFloat = proxy.position(forX: hp.x),
                  let hy: CGFloat = proxy.position(forY: hp.y)
            else { continue }
            if hypot(p.x - hx, p.y - hy) <= threshold {
                return anchor
            }
        }
        return nil
    }

    /// Anchors that pair 1:1 with `handlePositions(for:)` — the
    /// rendering side just needs coordinates, but the gesture side
    /// needs to know which logical endpoint to mutate.
    private func handleAnchors(for d: ChartDrawing) -> [ChartDrawing.Handle] {
        switch d.kind {
        case .horizontalLine: return [.start]
        case .trendLine:      return [.start, .end]
        case .rectangle:      return [.topLeft, .topRight, .bottomLeft, .bottomRight]
        }
    }

    /// Commit the in-flight resize. The drawing handed back to the
    /// dashboard carries the same `id` so `DrawingStore.update`
    /// replaces in place — no duplicate, no churn in the Layers
    /// popover ordering.
    private func handleResizeEnd() {
        defer {
            editingDrawingID = nil
            editingHandle = nil
            editingCursor = nil
        }
        guard let id = editingDrawingID,
              let original = drawings.first(where: { $0.id == id }),
              let anchor = editingHandle,
              let cursor = editingCursor
        else { return }
        let resized = original.resized(anchor: anchor, to: cursor)
        if resized == original { return }
        onMoveDrawing?(resized)
    }

    private func handlePanChange(_ value: DragGesture.Value, plotWidth: CGFloat) {
        if dragStartDomain == nil {
            dragStartDomain = effectiveXDomain
            // Drop the crosshair while panning — it'd flicker against
            // the moving series otherwise.
            hovered = nil
        }
        guard let start = dragStartDomain, plotWidth > 0 else { return }
        let span = start.upperBound - start.lowerBound
        let unitsPerPoint = span / Double(plotWidth)
        let delta = Double(value.translation.width) * unitsPerPoint
        // Drag right ⇒ pan into the past (lower indices), so subtract.
        xDomain = (start.lowerBound - delta) ... (start.upperBound - delta)
    }

    private func handleDrawChange(
        _ value: DragGesture.Value,
        plotOrigin: CGPoint,
        proxy: ChartProxy
    ) {
        if drawingStart == nil {
            drawingStart = drawingPoint(at: value.startLocation, plotOrigin: plotOrigin, proxy: proxy)
            // Suppress the crosshair while a drawing is in flight so it
            // doesn't fight the preview marks for visual attention.
            hovered = nil
        }
        drawingEnd = drawingPoint(at: value.location, plotOrigin: plotOrigin, proxy: proxy)
    }

    private func handleDrawEnd(
        _ value: DragGesture.Value,
        plotOrigin: CGPoint,
        proxy: ChartProxy
    ) {
        // Resolve endpoints (falling back to the gesture's own start/end
        // locations if `onChanged` never captured them — happens on a
        // very fast click).
        let startPoint = drawingStart ?? drawingPoint(at: value.startLocation, plotOrigin: plotOrigin, proxy: proxy)
        let endPoint   = drawingEnd   ?? drawingPoint(at: value.location,      plotOrigin: plotOrigin, proxy: proxy)
        drawingStart = nil
        drawingEnd = nil

        guard let start = startPoint else { return }
        let end = endPoint ?? start

        // Anything that needs two distinct points requires a minimum
        // drag distance, otherwise an accidental click would commit a
        // zero-size shape. ~4pt screen-space threshold.
        let dragDistSq = pow(value.translation.width, 2) + pow(value.translation.height, 2)
        let hasDrag = dragDistSq >= 16

        switch activeTool {
        case .none:
            return
        case .horizontalLine:
            // A horizontal line only needs a Y position; click *or*
            // drag works.
            onCommitDrawing?(ChartDrawing(kind: .horizontalLine, start: start, end: nil))
        case .trendLine:
            guard hasDrag else { return }
            onCommitDrawing?(ChartDrawing(kind: .trendLine, start: start, end: end))
        case .rectangle:
            guard hasDrag else { return }
            onCommitDrawing?(ChartDrawing(kind: .rectangle, start: start, end: end))
        }
    }

    /// Drag-to-move: update the in-flight (time, price) delta. Both
    /// drawing endpoints will translate by this same delta when the
    /// chart re-renders. We compute delta in data space (rather than
    /// screen-space pixels) so the move follows the same scale as the
    /// chart's X/Y axes — important when the user has zoomed in.
    private func handleMoveChange(
        _ value: DragGesture.Value,
        plotOrigin: CGPoint,
        proxy: ChartProxy
    ) {
        guard let startPt = drawingPoint(at: value.startLocation, plotOrigin: plotOrigin, proxy: proxy),
              let nowPt   = drawingPoint(at: value.location,       plotOrigin: plotOrigin, proxy: proxy)
        else { return }
        movingDeltaTime  = nowPt.date.timeIntervalSince(startPt.date)
        movingDeltaPrice = nowPt.price - startPt.price
    }

    /// Drag-to-move: commit the translation. We rebuild the drawing
    /// (same `id`, kind, and `visible`; both endpoints offset by the
    /// accumulated delta) and hand it back to the dashboard, which
    /// calls `DrawingStore.update` to replace in place.
    private func handleMoveEnd() {
        defer {
            movingDrawingOriginal = nil
            movingDeltaTime = 0
            movingDeltaPrice = 0
        }
        guard let original = movingDrawingOriginal else { return }
        // No-op moves (a click on a drawing without dragging) shouldn't
        // round-trip through the store — saves a useless write.
        if movingDeltaTime == 0 && movingDeltaPrice == 0 { return }
        onMoveDrawing?(translated(original))
    }

    /// Apply the in-flight delta to a drawing. Used by both the live
    /// preview render and the final commit.
    private func translated(_ d: ChartDrawing) -> ChartDrawing {
        ChartDrawing(
            id: d.id,
            kind: d.kind,
            start: DrawingPoint(
                date: d.start.date.addingTimeInterval(movingDeltaTime),
                price: d.start.price + movingDeltaPrice
            ),
            end: d.end.map { e in
                DrawingPoint(
                    date: e.date.addingTimeInterval(movingDeltaTime),
                    price: e.price + movingDeltaPrice
                )
            },
            visible: d.visible
        )
    }

    /// Pick the topmost visible drawing within `threshold` screen
    /// points of `location`. Returns nil if nothing is close enough —
    /// lets the gesture dispatcher fall back to chart panning.
    private func hitTestDrawing(
        at location: CGPoint,
        plotOrigin: CGPoint,
        proxy: ChartProxy,
        threshold: CGFloat = 8
    ) -> ChartDrawing? {
        let p = CGPoint(x: location.x - plotOrigin.x, y: location.y - plotOrigin.y)
        // Iterate newest-last so the most-recently-drawn shape wins on
        // overlap — the user's "current" drawing is usually the one
        // they want to grab.
        var best: (ChartDrawing, CGFloat)?
        for d in drawings where d.visible {
            guard let dist = drawingDistance(d, at: p, proxy: proxy) else { continue }
            if dist <= threshold, best == nil || dist < best!.1 {
                best = (d, dist)
            }
        }
        return best?.0
    }

    /// Screen-space distance from `p` to a drawing's nearest pixel.
    /// Horizontal lines collapse to a y-distance; trend lines use
    /// point-to-segment; rectangles return 0 inside their bounds and
    /// distance-to-nearest-edge outside.
    private func drawingDistance(
        _ d: ChartDrawing,
        at p: CGPoint,
        proxy: ChartProxy
    ) -> CGFloat? {
        switch d.kind {
        case .horizontalLine:
            guard let lineY = proxy.position(forY: d.start.price) else { return nil }
            return abs(p.y - lineY)
        case .trendLine:
            guard let end = d.end,
                  let xs = barIndex(forDate: d.start.date),
                  let xe = barIndex(forDate: end.date),
                  let xsScreen: CGFloat = proxy.position(forX: xs),
                  let xeScreen: CGFloat = proxy.position(forX: xe),
                  let ysScreen = proxy.position(forY: d.start.price),
                  let yeScreen = proxy.position(forY: end.price)
            else { return nil }
            return Self.distanceToSegment(
                p,
                CGPoint(x: xsScreen, y: ysScreen),
                CGPoint(x: xeScreen, y: yeScreen)
            )
        case .rectangle:
            guard let end = d.end,
                  let xs = barIndex(forDate: d.start.date),
                  let xe = barIndex(forDate: end.date),
                  let xsScreen: CGFloat = proxy.position(forX: xs),
                  let xeScreen: CGFloat = proxy.position(forX: xe),
                  let ysScreen = proxy.position(forY: d.start.price),
                  let yeScreen = proxy.position(forY: end.price)
            else { return nil }
            let rect = CGRect(
                x: min(xsScreen, xeScreen),
                y: min(ysScreen, yeScreen),
                width:  abs(xeScreen - xsScreen),
                height: abs(yeScreen - ysScreen)
            )
            if rect.contains(p) { return 0 }
            let dx = max(rect.minX - p.x, 0, p.x - rect.maxX)
            let dy = max(rect.minY - p.y, 0, p.y - rect.maxY)
            return hypot(dx, dy)
        }
    }

    /// Closest distance from point `p` to the line segment a–b. Used
    /// for trend-line hit testing.
    private static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        let projX = a.x + t * dx
        let projY = a.y + t * dy
        return hypot(p.x - projX, p.y - projY)
    }

    /// Translate a cursor location (in the gesture catcher's coord
    /// space, which is the GeometryReader's frame) into a date-anchored
    /// DrawingPoint. The X axis is bar-indexed, so we resolve the bar
    /// index from the proxy, clamp to the candle array, then look up
    /// that candle's `bucketStart` as the persisted anchor date.
    private func drawingPoint(
        at location: CGPoint,
        plotOrigin: CGPoint,
        proxy: ChartProxy
    ) -> DrawingPoint? {
        guard !candles.isEmpty else { return nil }
        let xInPlot = location.x - plotOrigin.x
        let yInPlot = location.y - plotOrigin.y
        guard let barX: Double = proxy.value(atX: xInPlot),
              let priceY: Double = proxy.value(atY: yInPlot)
        else { return nil }
        let idx = max(0, min(candles.count - 1, Int(barX.rounded())))
        return DrawingPoint(date: candles[idx].bucketStart, price: priceY)
    }

    /// Resolve a persisted `Date` anchor back to its bar index on the
    /// current candle series. Returns the nearest-by-time index so a
    /// drawing made on 1h still renders sensibly when the user flips
    /// to 4h (it lands on whichever 4h bucket contains the same moment).
    /// Returns nil for empty series.
    private func barIndex(forDate date: Date) -> Double? {
        guard !candles.isEmpty else { return nil }
        var bestIdx = 0
        var bestDelta = abs(candles[0].bucketStart.timeIntervalSince(date))
        for (i, c) in candles.enumerated().dropFirst() {
            let d = abs(c.bucketStart.timeIntervalSince(date))
            if d < bestDelta {
                bestDelta = d
                bestIdx = i
            }
        }
        return Double(bestIdx)
    }

    /// Trackpad pinch-to-zoom. value > 1 ⇒ zoom in; < 1 ⇒ zoom out. We
    /// keep the centre of the current window fixed so the user's eye
    /// doesn't lose its reference point.
    private func magnificationGesture() -> some Gesture {
        MagnificationGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                if magnifyStartDomain == nil {
                    magnifyStartDomain = effectiveXDomain
                    hovered = nil
                }
                guard let start = magnifyStartDomain else { return }
                let center = (start.lowerBound + start.upperBound) / 2
                let halfSpan = (start.upperBound - start.lowerBound) / 2
                // Clamp scale so a frantic pinch can't collapse the chart
                // to a point or blow it up past the entire history.
                let scale = max(0.05, min(50, Double(value)))
                let zoomedHalf = halfSpan / scale
                xDomain = (center - zoomedHalf) ... (center + zoomedHalf)
            }
            .onEnded { _ in magnifyStartDomain = nil }
    }

    /// X-domain actually handed to Charts. Falls back to the full bar
    /// span when the caller hasn't pinned a window. Adds half-bar padding
    /// at each edge so the first/last candles aren't drawn flush against
    /// the plot's vertical borders.
    private var effectiveXDomain: ClosedRange<Double> {
        if let d = xDomain { return d }
        // No pinned window → open on the most recent N bars (trading-app
        // convention) rather than dumping the entire (possibly multi-year)
        // series on screen. Pan left for history.
        return ChartWindow.defaultDomain(count: candles.count)
    }

    /// Bar indices to actually emit marks for this frame. Swift Charts
    /// draws every mark you hand it and clips afterward, so without this
    /// a deep series pins the main thread on pan/zoom. We render only the
    /// visible window (+margin), stride-decimated when zoomed way out.
    /// Marks still plot at the *global* bar index, so overlays/hover/
    /// replay keep working unchanged.
    private var renderIndices: [Int] {
        // Use the raw `candles.count` (a stored property, O(1)) rather
        // than `displayCandles.count` — the Heikin-Ashi transform /
        // live-price patch preserve length, so the counts are identical
        // and we avoid triggering that whole O(n) rebuild just to size
        // the window.
        ChartWindow.renderIndices(domain: effectiveXDomain, count: candles.count)
    }

    private var renderIndexSet: Set<Int> {
        Set(renderIndices)
    }

    // MARK: - Mark variants

    @ChartContentBuilder
    private var lineMarks: some ChartContent {
        // Evaluate `displayCandles` ONCE here. It's a computed property
        // that rebuilds (HA transform + live-price array copy) on every
        // access, so indexing it inside the ForEach closure would re-run
        // that O(n) work per visible bar — quadratic on deep history.
        let cs = displayCandles
        ForEach(renderIndices, id: \.self) { i in
            let c = cs[i]
            AreaMark(
                x: .value("Bar", Double(i)),
                y: .value("Close", c.close)
            )
            .foregroundStyle(LinearGradient(
                colors: [accent.opacity(0.4), accent.opacity(0)],
                startPoint: .top, endPoint: .bottom
            ))
            .interpolationMethod(.monotone)

            LineMark(
                x: .value("Bar", Double(i)),
                y: .value("Close", c.close)
            )
            .foregroundStyle(accent)
            .lineStyle(StrokeStyle(lineWidth: 1.8, lineJoin: .round))
            .interpolationMethod(.monotone)
        }
        // Single-point series can't draw a line — drop a visible marker.
        if cs.count == 1, let only = cs.first {
            PointMark(
                x: .value("Bar", 0.0),
                y: .value("Close", only.close)
            )
            .foregroundStyle(accent)
            .symbolSize(120)
        }
    }

    /// Horizontal lines for support / resistance levels carried in
    /// `srLevels`. Support is green, resistance red; each gets a small
    /// "S" / "R" capsule at the right edge as a price tag.
    @ChartContentBuilder
    private var srLevelMarks: some ChartContent {
        ForEach(srLevels.support, id: \.self) { level in
            RuleMark(y: .value("Support", level))
                .foregroundStyle(Theme.Color.success.opacity(0.55))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [6, 4]))
                .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                    srTag(price: level, isSupport: true)
                }
        }
        ForEach(srLevels.resistance, id: \.self) { level in
            RuleMark(y: .value("Resistance", level))
                .foregroundStyle(Theme.Color.danger.opacity(0.55))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [6, 4]))
                .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                    srTag(price: level, isSupport: false)
                }
        }
    }

    /// FVG / iFVG zones rendered as translucent rectangles spanning the
    /// gap's three-candle bar range and its price band. Bullish gaps
    /// fill green; bearish fill red. iFVG (mitigated) zones overlay
    /// dashed top/bottom edges since `RectangleMark` has no native
    /// dashed stroke API.
    @ChartContentBuilder
    private var fvgMarks: some ChartContent {
        let lastIndex = candles.count - 1
        ForEach(fvgZones) { zone in
            // Translate negative bar offsets (-1 = latest bar) onto the
            // chart's index X axis.
            let xStart = Double(lastIndex + zone.barOffsetStart)
            let xEnd   = Double(lastIndex + zone.barOffsetEnd)
            RectangleMark(
                xStart: .value("FVG start", xStart),
                xEnd:   .value("FVG end",   xEnd),
                yStart: .value("Zone low",  zone.low),
                yEnd:   .value("Zone high", zone.high)
            )
            .foregroundStyle((zone.isBullish ? Theme.Color.success : Theme.Color.danger)
                              .opacity(zone.isMitigated ? 0.10 : 0.18))
            if zone.isMitigated {
                // Dashed boundary lines for iFVG candidates so the user
                // can tell them apart from active FVGs at a glance.
                RuleMark(
                    xStart: .value("iFVG start hi", xStart),
                    xEnd:   .value("iFVG end hi",   xEnd),
                    y:      .value("iFVG hi",       zone.high)
                )
                .foregroundStyle((zone.isBullish ? Theme.Color.success : Theme.Color.danger).opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                RuleMark(
                    xStart: .value("iFVG start lo", xStart),
                    xEnd:   .value("iFVG end lo",   xEnd),
                    y:      .value("iFVG lo",       zone.low)
                )
                .foregroundStyle((zone.isBullish ? Theme.Color.success : Theme.Color.danger).opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
    }

    /// Supply & Demand zones rendered as translucent rectangles + a
    /// small "D" / "S" capsule pinned to the zone's right edge so
    /// the user can read intent without the legend. Strong zones
    /// get a thicker rule on top/bottom for emphasis; tested
    /// (`!isFresh`) zones drop to half opacity + dashed boundary
    /// since a re-entry on a tested zone is statistically weaker
    /// than a first test.
    @ChartContentBuilder
    private var supplyDemandMarks: some ChartContent {
        let lastIndex = candles.count - 1
        ForEach(supplyDemandZones) { zone in
            let xStart = Double(lastIndex + zone.barOffsetStart)
            let xEnd   = Double(lastIndex + zone.barOffsetEnd)
            let baseColor: Color = zone.isDemand ? Theme.Color.success : Theme.Color.danger
            let fillOpacity: Double = {
                if !zone.isFresh { return 0.10 }
                switch zone.strength {
                case .weak:   return 0.14
                case .medium: return 0.20
                case .strong: return 0.28
                }
            }()
            RectangleMark(
                xStart: .value("Zone start", xStart),
                xEnd:   .value("Zone end",   xEnd),
                yStart: .value("Zone low",   zone.low),
                yEnd:   .value("Zone high",  zone.high)
            )
            .foregroundStyle(baseColor.opacity(fillOpacity))

            // Top + bottom boundary lines so the zone's edges
            // read clearly against the candles inside it. Solid
            // for fresh, dashed for tested. Line width scales
            // with strength.
            let lineWidth: CGFloat = {
                switch zone.strength {
                case .weak:   return 0.8
                case .medium: return 1.2
                case .strong: return 1.8
                }
            }()
            let dashStyle: [CGFloat] = zone.isFresh ? [] : [4, 3]
            RuleMark(
                xStart: .value("Zone start hi", xStart),
                xEnd:   .value("Zone end hi",   xEnd),
                y:      .value("Zone hi",       zone.high)
            )
            .foregroundStyle(baseColor.opacity(zone.isFresh ? 0.75 : 0.5))
            .lineStyle(StrokeStyle(lineWidth: lineWidth, dash: dashStyle))
            RuleMark(
                xStart: .value("Zone start lo", xStart),
                xEnd:   .value("Zone end lo",   xEnd),
                y:      .value("Zone lo",       zone.low)
            )
            .foregroundStyle(baseColor.opacity(zone.isFresh ? 0.75 : 0.5))
            .lineStyle(StrokeStyle(lineWidth: lineWidth, dash: dashStyle))

            // Tiny capsule at the right edge of the zone showing
            // direction + strength. "D⋅strong" / "S⋅medium" etc.
            // Sits on the high boundary so it doesn't crowd the
            // price action inside the zone.
            PointMark(
                x: .value("Zone end label", xEnd),
                y: .value("Zone hi",        zone.high)
            )
            .symbolSize(0)   // invisible anchor; we just want the annotation
            .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                Text("\(zone.isDemand ? "D" : "S")·\(zone.strength.rawValue.prefix(1).uppercased())")
                    .font(.system(size: 8, weight: .heavy).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(baseColor.opacity(zone.isFresh ? 0.95 : 0.6))
                    )
            }
        }
    }

    /// Scenario marks: TP + SL + (optional) entry lines plus a bias
    /// capsule pinned to the entry rule (or TP rule if entry is missing
    /// — older history entries don't carry an entry price). Positions
    /// all use `.overlay`/`.trailing` so capsules sit inside the plot
    /// area, matching the last-price tag's strategy.
    @ChartContentBuilder
    private var scenarioMarks: some ChartContent {
        if let scenario = taScenario {
            scenarioOverlay(scenario, isAlt: false)
        }
        if let alt = taAltScenario {
            scenarioOverlay(alt, isAlt: true)
        }
    }

    /// Renders one scenario's TP / SL / entry rules + capsules. `isAlt`
    /// shifts the styling down a notch (lower opacity, thinner lines,
    /// "ALT" tag on the bias capsule) so the alternative plan reads
    /// as the secondary one when both are on screen together.
    @ChartContentBuilder
    private func scenarioOverlay(
        _ scenario: PromptBuilder.TAScenario,
        isAlt: Bool
    ) -> some ChartContent {
        // Visual treatment per variant. Alt: dimmer, thinner, sparser
        // dash pattern so the eye picks the main lines first.
        let tpOpacity: Double = isAlt ? 0.40 : 0.75
        let slOpacity: Double = isAlt ? 0.40 : 0.75
        let entryOpacity: Double = isAlt ? 0.55 : 0.85
        let lineWidth: CGFloat = isAlt ? 0.9 : 1.2
        let entryLineWidth: CGFloat = isAlt ? 1.0 : 1.4
        let dashPattern: [CGFloat] = isAlt ? [2, 5] : [4, 4]
        let entryDash:   [CGFloat] = isAlt ? [1, 4] : [2, 3]
        let tpPrefix = isAlt ? "ALT TP" : "TP"
        let slPrefix = isAlt ? "ALT SL" : "SL"

        RuleMark(y: .value(tpPrefix, scenario.takeProfit))
            .foregroundStyle(Theme.Color.success.opacity(tpOpacity))
            .lineStyle(StrokeStyle(lineWidth: lineWidth, dash: dashPattern))
            .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                levelTag(text: "\(tpPrefix) \(Self.priceShort(scenario.takeProfit))",
                         color: Theme.Color.success.opacity(isAlt ? 0.7 : 1))
            }
        RuleMark(y: .value(slPrefix, scenario.stopLoss))
            .foregroundStyle(Theme.Color.danger.opacity(slOpacity))
            .lineStyle(StrokeStyle(lineWidth: lineWidth, dash: dashPattern))
            .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                levelTag(text: "\(slPrefix) \(Self.priceShort(scenario.stopLoss))",
                         color: Theme.Color.danger.opacity(isAlt ? 0.7 : 1))
            }
        if let entry = scenario.entry {
            RuleMark(y: .value(isAlt ? "Alt Entry" : "Entry", entry))
                .foregroundStyle(Theme.Color.warn.opacity(entryOpacity))
                .lineStyle(StrokeStyle(lineWidth: entryLineWidth, dash: entryDash))
                .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                    scenarioEntryTag(scenario: scenario, entry: entry, isAlt: isAlt)
                }
        }
    }

    /// Paper-trade overlay: one set of entry / TP / SL lines per open
    /// trade. Active trades render solid with live P/L on the entry
    /// capsule; pending trades render dashed-amber until price fills
    /// them. Closed trades aren't passed in (DashboardView filters
    /// them out via `TradeStore.openVisibleTrades`).
    @ChartContentBuilder
    private var tradeMarks: some ChartContent {
        ForEach(trades) { trade in
            // Entry — the most important line: shows the trade's
            // cost basis (active) or its trigger (pending). The
            // capsule on this line carries the side / status / live
            // P/L so it's the user's at-a-glance "how am I doing?"
            // readout.
            RuleMark(y: .value("Trade entry", trade.fillPrice ?? trade.entry))
                .foregroundStyle(tradeEntryColor(trade))
                .lineStyle(StrokeStyle(
                    lineWidth: trade.status == .active ? 1.6 : 1.3,
                    dash: trade.status == .pending ? [3, 3] : []
                ))
                .annotation(position: .overlay, alignment: .leading, spacing: 0) {
                    tradeEntryTag(trade)
                }

            // Take-profit
            RuleMark(y: .value("Trade TP", trade.takeProfit))
                .foregroundStyle(Theme.Color.success.opacity(0.6))
                .lineStyle(StrokeStyle(
                    lineWidth: 1.0,
                    dash: trade.status == .pending ? [3, 3] : [4, 4]
                ))
                .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                    levelTag(text: "TP \(Self.priceShort(trade.takeProfit))",
                             color: Theme.Color.success)
                }

            // Stop-loss
            RuleMark(y: .value("Trade SL", trade.stopLoss))
                .foregroundStyle(Theme.Color.danger.opacity(0.6))
                .lineStyle(StrokeStyle(
                    lineWidth: 1.0,
                    dash: trade.status == .pending ? [3, 3] : [4, 4]
                ))
                .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                    levelTag(text: "SL \(Self.priceShort(trade.stopLoss))",
                             color: Theme.Color.danger)
                }
        }
    }

    /// Entry-line colour keys to the trade's state: amber when
    /// pending, success/danger for active long/short.
    private func tradeEntryColor(_ t: Trade) -> Color {
        switch t.status {
        case .pending:        return Theme.Color.warn
        case .active:         return t.side == .short ? Theme.Color.danger : Theme.Color.success
        default:              return Theme.Color.textMuted
        }
    }

    /// Wide capsule pinned to the entry rule: bias chip, lot size,
    /// status, and live P/L for active trades.
    private func tradeEntryTag(_ t: Trade) -> some View {
        let pl: Double = livePrice.map { t.currentPL(at: $0) } ?? 0
        let plText: String? = {
            guard t.status == .active, livePrice != nil else { return nil }
            let sign = pl >= 0 ? "+" : "−"
            return "\(sign)$\(String(format: "%.2f", abs(pl)))"
        }()
        return HStack(spacing: 4) {
            Text(t.sideLabel)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(tradeEntryColor(t)))
            Text("\(String(format: "%.2f", t.lots)) · \(t.statusLabel.uppercased())")
                .font(.system(size: 9, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
            if let plText = plText {
                Text(plText)
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundStyle(pl >= 0 ? Theme.Color.success : Theme.Color.danger)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(Color.black.opacity(0.6))
        )
    }

    /// User-drawn shapes from the per-pair DrawingStore. Date-anchored
    /// points are resolved to bar indices at render time, so a trend
    /// line drawn on yesterday's bars stays glued to those bars when
    /// new candles arrive. Skips shapes whose endpoints can't be
    /// resolved (e.g. when the series is empty or the timeframe was
    /// flipped to a window that doesn't contain the anchor date).
    /// Drawings to draw on the chart this frame: every visible
    /// committed drawing, with the in-flight moving one swapped for
    /// its translated preview. Keeps the IDs identical so ForEach
    /// diffs stably and the move feels like in-place movement rather
    /// than a delete-and-redraw.
    private var renderableDrawings: [ChartDrawing] {
        let movingID = movingDrawingOriginal?.id
        let editingID = editingDrawingID
        var out = drawings.filter { d in
            d.visible && d.id != movingID && d.id != editingID
        }
        if let moving = movingDrawingOriginal, moving.visible {
            out.append(translated(moving))
        }
        // For the drawing whose handle is being dragged, render the
        // resized preview rather than the original geometry — same
        // pattern as the move case so exactly one instance is on the
        // chart at any time.
        if let id = editingID,
           let original = drawings.first(where: { $0.id == id }),
           original.visible,
           let cursor = editingCursor,
           let anchor = editingHandle
        {
            out.append(original.resized(anchor: anchor, to: cursor))
        }
        return out
    }

    @ChartContentBuilder
    private var drawingMarks: some ChartContent {
        // While the user is dragging an existing drawing, swap the
        // original for a translated copy so exactly one instance of
        // the shape sits on the chart — the live one under the cursor.
        // Keeping the IDs identical lets ForEach diff stably.
        ForEach(renderableDrawings) { d in
            let stroke = d.color.color
            let lw = CGFloat(d.lineWidth)
            switch d.kind {
            case .horizontalLine:
                RuleMark(y: .value("Drawing", d.start.price))
                    .foregroundStyle(stroke)
                    .lineStyle(StrokeStyle(lineWidth: lw, dash: [6, 3]))
            case .trendLine:
                if let end = d.end,
                   let xs = barIndex(forDate: d.start.date),
                   let xe = barIndex(forDate: end.date)
                {
                    LineMark(
                        x: .value("Bar", xs),
                        y: .value("Price", d.start.price),
                        series: .value("Drawing", d.id.uuidString)
                    )
                    .foregroundStyle(stroke)
                    .lineStyle(StrokeStyle(lineWidth: lw))
                    LineMark(
                        x: .value("Bar", xe),
                        y: .value("Price", end.price),
                        series: .value("Drawing", d.id.uuidString)
                    )
                    .foregroundStyle(stroke)
                    .lineStyle(StrokeStyle(lineWidth: lw))
                }
            case .rectangle:
                if let end = d.end,
                   let xs = barIndex(forDate: d.start.date),
                   let xe = barIndex(forDate: end.date)
                {
                    // Translucent fill derived from the stroke colour
                    // so a single colour pick drives the whole shape.
                    // We keep the relative scale of the original
                    // palette (stroke alpha → ~0.16× fill alpha).
                    RectangleMark(
                        xStart: .value("X start", min(xs, xe)),
                        xEnd:   .value("X end",   max(xs, xe)),
                        yStart: .value("Y start", min(d.start.price, end.price)),
                        yEnd:   .value("Y end",   max(d.start.price, end.price))
                    )
                    .foregroundStyle(stroke.opacity(d.color.alpha * 0.18))
                }
            }
        }

        // Selection handles — rendered last so they sit on top of every
        // committed mark. Only the selected drawing gets handles; click
        // anywhere else to deselect.
        selectionHandleMarks
    }

    /// Small square handles drawn at the selected drawing's endpoints
    /// or corners. These are the grab targets for the reshape gesture.
    /// While a handle is being dragged we render an additional handle
    /// at the *live* cursor position via `editingPreviewMarks` so the
    /// user sees where they're moving the endpoint to.
    @ChartContentBuilder
    private var selectionHandleMarks: some ChartContent {
        if let sel = selectionTargetDrawing {
            ForEach(handlePositions(for: sel), id: \.self) { hp in
                PointMark(
                    x: .value("Handle X", hp.x),
                    y: .value("Handle Y", hp.y)
                )
                .symbol(.square)
                .symbolSize(70)
                .foregroundStyle(Color.white)
            }
        }
        // Live-preview handle for the endpoint the user is currently
        // dragging — sits on top of the others so the active endpoint
        // visually leads the gesture.
        if let cursor = editingCursor,
           let id = editingDrawingID,
           let _ = drawings.first(where: { $0.id == id }),
           let xs = barIndex(forDate: cursor.date)
        {
            PointMark(
                x: .value("Edit X", xs),
                y: .value("Edit Y", cursor.price)
            )
            .symbol(.circle)
            .symbolSize(90)
            .foregroundStyle(Color.white)
        }
    }

    /// The drawing whose handles should be shown — the selected one,
    /// or the in-flight edit target so the handle being dragged stays
    /// rendered even if `selectedDrawingID` was cleared elsewhere.
    private var selectionTargetDrawing: ChartDrawing? {
        if let id = editingDrawingID,
           let d = drawings.first(where: { $0.id == id })
        {
            return resizedPreview(of: d) ?? d
        }
        if let id = selectedDrawingID,
           let d = drawings.first(where: { $0.id == id }),
           d.visible
        {
            return d
        }
        return nil
    }

    /// Bar-index + price coordinates for each handle of a drawing.
    /// Returns the empty list when the drawing's endpoints can't be
    /// resolved (e.g. the anchor date is far outside the current
    /// candle window).
    private func handlePositions(for d: ChartDrawing) -> [HandlePoint] {
        switch d.kind {
        case .horizontalLine:
            // Single handle pinned to the right edge of the visible
            // window so the user always has something to grab.
            return [HandlePoint(x: effectiveXDomain.upperBound - 0.5, y: d.start.price)]
        case .trendLine:
            guard let end = d.end,
                  let xs = barIndex(forDate: d.start.date),
                  let xe = barIndex(forDate: end.date)
            else { return [] }
            return [
                HandlePoint(x: xs, y: d.start.price),
                HandlePoint(x: xe, y: end.price)
            ]
        case .rectangle:
            guard let end = d.end,
                  let xs = barIndex(forDate: d.start.date),
                  let xe = barIndex(forDate: end.date)
            else { return [] }
            return [
                HandlePoint(x: xs, y: d.start.price),
                HandlePoint(x: xe, y: d.start.price),
                HandlePoint(x: xs, y: end.price),
                HandlePoint(x: xe, y: end.price)
            ]
        }
    }

    /// Coordinate pair for a selection handle, plottable on the chart.
    /// Hashable so `ForEach(id: \.self)` can identify it without an
    /// explicit Identifiable wrapper — there are at most four handles
    /// in flight at once, so naive hashing is fine.
    struct HandlePoint: Hashable {
        let x: Double
        let y: Double
    }

    /// Apply the in-flight handle drag (if any) to produce a preview
    /// of the drawing in its new shape. Returns nil when no edit is
    /// active or the cursor hasn't resolved to a valid point yet.
    private func resizedPreview(of d: ChartDrawing) -> ChartDrawing? {
        guard editingDrawingID == d.id,
              let anchor = editingHandle,
              let cursor = editingCursor
        else { return nil }
        return d.resized(anchor: anchor, to: cursor)
    }

    /// Translucent live preview of the shape being drawn right now.
    /// Falls back to nothing if the user hasn't started a draw — the
    /// `drawingStart` state is the canonical "is the user actively
    /// drawing" flag.
    @ChartContentBuilder
    private var drawingPreviewMarks: some ChartContent {
        if let s = drawingStart {
            switch activeTool {
            case .none:
                // Unreachable in practice — handleDrawChange only sets
                // drawingStart when a tool is armed.
                RuleMark(y: .value("noop", s.price))
                    .opacity(0)
            case .horizontalLine:
                RuleMark(y: .value("Preview", s.price))
                    .foregroundStyle(DrawingPalette.preview)
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 4]))
            case .trendLine:
                if let e = drawingEnd,
                   let xs = barIndex(forDate: s.date),
                   let xe = barIndex(forDate: e.date)
                {
                    LineMark(
                        x: .value("Bar", xs),
                        y: .value("Price", s.price),
                        series: .value("Preview", "drawing-preview")
                    )
                    .foregroundStyle(DrawingPalette.preview)
                    .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [3, 3]))
                    LineMark(
                        x: .value("Bar", xe),
                        y: .value("Price", e.price),
                        series: .value("Preview", "drawing-preview")
                    )
                    .foregroundStyle(DrawingPalette.preview)
                    .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [3, 3]))
                }
            case .rectangle:
                if let e = drawingEnd,
                   let xs = barIndex(forDate: s.date),
                   let xe = barIndex(forDate: e.date)
                {
                    RectangleMark(
                        xStart: .value("Preview X start", min(xs, xe)),
                        xEnd:   .value("Preview X end",   max(xs, xe)),
                        yStart: .value("Preview Y start", min(s.price, e.price)),
                        yEnd:   .value("Preview Y end",   max(s.price, e.price))
                    )
                    .foregroundStyle(DrawingPalette.fill.opacity(0.6))
                }
            }
        }
    }

    /// Bias + entry capsule. Sits on the entry line. Renders the bias
    /// chip ("LONG"/"SHORT"/"NEUTRAL") next to "ENTRY <price>" plus a
    /// validity badge so the user can see at a glance whether the
    /// plan is still in play (green ✓ VALID) or has been invalidated
    /// by current price (red ✗ INVALID, with entry text struck
    /// through). `isAlt` slips an "ALT" prefix before the bias so
    /// stacked main+alt capsules read cleanly.
    private func scenarioEntryTag(
        scenario: PromptBuilder.TAScenario,
        entry: Double,
        isAlt: Bool
    ) -> some View {
        let biasLabel: String
        let biasColor: Color
        switch scenario.bias {
        case .long:    biasLabel = "LONG";    biasColor = Theme.Color.success
        case .short:   biasLabel = "SHORT";   biasColor = Theme.Color.danger
        case .neutral: biasLabel = "NEUTRAL"; biasColor = Theme.Color.textSecondary
        }
        let prefix = isAlt ? "ALT · " : ""
        // Validity verdict. Without a live price we lean toward
        // "still valid" so the badge doesn't false-positive on cold
        // start; the moment a price arrives the badge becomes
        // authoritative.
        let valid: Bool = livePrice.map { scenario.isValid(at: $0) } ?? true
        return HStack(spacing: 4) {
            Text(prefix + biasLabel)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(biasColor.opacity(isAlt ? 0.7 : 1)))
            Text("ENTRY \(Self.priceShort(entry))")
                .font(.system(size: 9, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .strikethrough(!valid, color: Theme.Color.danger)
            validityBadge(valid: valid)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(Color.black.opacity(0.55))
        )
    }

    /// Tiny VALID / INVALID pill stacked next to the entry text on
    /// each scenario tag. Green when the plan's SL hasn't been
    /// touched, red when it has.
    private func validityBadge(valid: Bool) -> some View {
        Text(valid ? "✓ VALID" : "✗ INVALID")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(valid
                               ? Theme.Color.success.opacity(0.85)
                               : Theme.Color.danger.opacity(0.85))
            )
    }

    /// Compact level capsule used for TP / SL labels. Single colour,
    /// single line of text so the three scenario tags read consistently
    /// when stacked at the right edge.
    private func levelTag(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(color.opacity(0.85))
            )
    }

    /// Small price-tag capsule. Mirrors the last-price tag's overlay
    /// position so it sits inline on the rule rather than escaping past
    /// the plot edge (where the chart's `.clipped()` would chop it).
    private func srTag(price: Double, isSupport: Bool) -> some View {
        HStack(spacing: 3) {
            Text(isSupport ? "S" : "R")
                .font(.system(size: 8, weight: .bold))
            Text(Self.priceShort(price))
                .font(.system(size: 9, weight: .bold).monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(isSupport ? Theme.Color.success : Theme.Color.danger)
        )
    }

    /// UT Bot trailing-stop line + buy/sell signal labels. Returns no
    /// content when the indicator is toggled off.
    @ChartContentBuilder
    private var utBotMarks: some ChartContent {
        if let out = utBotOutput {
            let visible = renderIndexSet
            // Trailing stop: amber stepped line across all bars where
            // the stop is defined. Toggled by the user via the UT Bot
            // settings — when off, only the buy/sell labels remain.
            if indicatorConfig.utShowTrailingStop {
                ForEach(renderIndices, id: \.self) { i in
                    if i < out.trailingStop.count, let v = out.trailingStop[i] {
                        LineMark(
                            x: .value("Bar", Double(i)),
                            y: .value("UT Stop", v),
                            series: .value("Series", "utbot-trail")
                        )
                        .foregroundStyle(IndicatorKind.utBot.color)
                        .lineStyle(StrokeStyle(lineWidth: 1.4, lineJoin: .miter))
                        .interpolationMethod(.stepStart)
                    }
                }
            }
            // Buy/Sell labels — positioned just below (buy) or above
            // (sell) the candle's actual extreme so the marker doesn't
            // sit on top of the wick.
            let cs = displayCandles
            ForEach(out.signals.filter { visible.contains($0.index) }) { sig in
                let c = cs[sig.index]
                PointMark(
                    x: .value("Bar", Double(sig.index)),
                    y: .value("Signal", sig.isBuy ? c.low : c.high)
                )
                .symbol(.circle)
                .symbolSize(0)   // hide the point itself; we just want the annotation
                .annotation(
                    position: sig.isBuy ? .bottom : .top,
                    alignment: .center,
                    spacing: 2
                ) {
                    Text(sig.isBuy ? "BUY" : "SELL")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(sig.isBuy
                                           ? Theme.Color.success
                                           : Theme.Color.danger)
                        )
                }
            }
        }
    }

    /// Indicator overlays. Each enabled indicator becomes one or more
    /// `LineMark` series keyed by `series:` so Apple Charts treats the
    /// points as a single connected line (rather than a per-point disjoint
    /// segment).
    @ChartContentBuilder
    private var indicatorMarks: some ChartContent {
        let computed = derived.indicators(enabled: indicators, candles: candles)
        let visible = renderIndexSet
        ForEach(computed, id: \.kind) { entry in
            ForEach(entry.points.filter { visible.contains($0.index) }) { p in
                LineMark(
                    x: .value("Bar", Double(p.index)),
                    y: .value("Indicator", p.value),
                    series: .value("Series", "\(entry.kind.rawValue)-\(p.band)")
                )
                .foregroundStyle(indicatorColor(for: entry.kind, band: p.band))
                .lineStyle(StrokeStyle(
                    lineWidth: indicatorLineWidth(for: p.band),
                    dash: p.band == "bb_mid" ? [3, 3] : []
                ))
                .interpolationMethod(.monotone)
            }
        }
    }

    /// Bollinger upper/lower share the indicator's accent; middle uses a
    /// muted version so the band is visually clearly the "envelope".
    private func indicatorColor(for kind: IndicatorKind, band: String) -> Color {
        switch band {
        case "bb_upper", "bb_lower": return kind.color
        case "bb_mid":               return kind.color.opacity(0.55)
        default:                     return kind.color
        }
    }

    /// Slightly thinner middle Bollinger line; everything else 1.6pt.
    private func indicatorLineWidth(for band: String) -> CGFloat {
        band == "bb_mid" ? 1 : 1.6
    }

    @ChartContentBuilder
    private var candleMarks: some ChartContent {
        // See `lineMarks`: bind `displayCandles` once to avoid the
        // quadratic per-bar rebuild on deep history.
        let cs = displayCandles
        ForEach(renderIndices, id: \.self) { i in
            let c = cs[i]
            // Wick — full high-to-low range.
            RuleMark(
                x: .value("Bar", Double(i)),
                yStart: .value("Low", c.low),
                yEnd: .value("High", c.high)
            )
            .foregroundStyle(c.close >= c.open ? Theme.Color.success : Theme.Color.danger)
            .lineStyle(StrokeStyle(lineWidth: 1))

            // Body — open to close. Width scales inversely with bar
            // count so dense charts don't smear together and sparse
            // ones don't look like toothpicks.
            RectangleMark(
                x: .value("Bar", Double(i)),
                yStart: .value("Body lo", min(c.open, c.close)),
                yEnd: .value("Body hi", max(c.open, c.close)),
                width: .fixed(candleBodyWidth)
            )
            .foregroundStyle(c.close >= c.open ? Theme.Color.success : Theme.Color.danger)
            .cornerRadius(1)
        }
    }

    // MARK: - Axes

    private func xAxis() -> some AxisContent {
        // Custom evenly-spaced label values based on bar indices. Apple
        // Charts can't auto-derive date labels for an index axis, so we
        // hand it the exact indices we want labels at, then look up each
        // candle's real date for the formatted text.
        AxisMarks(preset: .aligned, values: xAxisLabelValues) { value in
            AxisGridLine()
                .foregroundStyle(Color.white.opacity(0.04))
            AxisTick()
                .foregroundStyle(Color.white.opacity(0.08))
            AxisValueLabel {
                if let idx = value.as(Double.self),
                   let label = labelForIndex(idx)
                {
                    Text(label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.Color.textMuted)
                }
            }
        }
    }

    /// Pick ~6 evenly-spaced indices across the *visible* domain (so
    /// labels redistribute as you pan/zoom). Returns Doubles so they
    /// align exactly with the chart's X plottable type.
    private var xAxisLabelValues: [Double] {
        let domain = effectiveXDomain
        let span = domain.upperBound - domain.lowerBound
        guard span > 0 else { return [] }
        let count = 6
        return (0...count).map { i in
            domain.lowerBound + (span * Double(i) / Double(count))
        }
    }

    /// Format the date of the candle nearest `idx`. Out-of-range indices
    /// (e.g. pan past data) return nil so no label is drawn.
    private func labelForIndex(_ idx: Double) -> String? {
        let rounded = Int(idx.rounded())
        guard candles.indices.contains(rounded) else { return nil }
        return Self.axisFormatter.string(from: candles[rounded].bucketStart)
    }

    /// Compact axis label format: "10:30" / "Mon 10:30" — picked by
    /// looking at the visible time span elsewhere if we ever want to
    /// adapt it. For now, time-of-day is fine because charts default to
    /// recent windows.
    static let axisFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm"
        return f
    }()

    private func yAxis() -> some AxisContent {
        AxisMarks(position: .trailing, values: .automatic(desiredCount: 6)) { value in
            AxisGridLine()
                .foregroundStyle(Color.white.opacity(0.04))
            AxisValueLabel {
                if let d = value.as(Double.self) {
                    Text(Self.priceShort(d))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.Color.textMuted)
                }
            }
        }
    }

    // MARK: - Hover tooltip

    @ViewBuilder
    private var hoverTooltip: some View {
        if let h = hovered {
            let c = h.candle
            let delta = c.close - c.open
            let pct = c.open > 0 ? (delta / c.open) * 100 : 0
            let isUp = c.close >= c.open

            VStack(alignment: .leading, spacing: 4) {
                Text(Self.dateFormatter.string(from: c.bucketStart))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Color.textMuted)
                HStack(spacing: 12) {
                    ohlcCell("O", c.open)
                    ohlcCell("H", c.high)
                    ohlcCell("L", c.low)
                    ohlcCell("C", c.close)
                }
                HStack(spacing: 4) {
                    Image(systemName: isUp ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 9, weight: .bold))
                    Text("\(isUp ? "+" : "")\(Self.priceShort(delta)) (\(String(format: "%+.2f", pct))%)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(isUp ? Theme.Color.success : Theme.Color.danger)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.Color.surfaceMax.opacity(0.96))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Theme.Color.border, lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
            .padding(12)
        }
    }

    private func ohlcCell(_ label: String, _ v: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.Color.textMuted)
            Text(Self.priceExact(v))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.Color.textPrimary)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        // During replay an empty chart almost always means the cursor
        // predates the stored history for this timeframe (1m only goes
        // back ~8 days, 5m ~1 month). Point the user at the fix instead
        // of the generic "wait for the next fetch" message.
        let replaying = replayActive
        return VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: replaying ? "clock.badge.exclamationmark" : "chart.xyaxis.line")
                .font(.system(size: 40))
                .foregroundStyle(replaying ? Theme.Color.warn.opacity(0.8) : Theme.Color.textMuted)
            Text(replaying ? "No stored bars this far back" : "No data for this timeframe")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Color.textSecondary)
            Text(replaying
                 ? "This timeframe's history doesn't reach the replay point. Switch to a higher timeframe (5m+) or pick a more recent start."
                 : "Wait for the next fetch cycle, or import older history.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Derived

    /// Y-axis domain that hugs the actual data range with ~5% padding.
    /// Without this, Apple Charts sometimes pins the lower bound at 0,
    /// which compresses million-toman prices into a single pixel. Also
    /// folds in indicator extremes so e.g. the upper Bollinger band
    /// doesn't get clipped off the top.
    private var yDomain: ClosedRange<Double> {
        // Fit Y to only the *visible* bar window — otherwise the axis
        // hugs the entire (possibly multi-year) range and the recent
        // price action gets squashed into a few pixels. HA values can
        // exceed raw OHLC at the edges, so fit to displayCandles.
        let bounds = ChartWindow.visibleBounds(
            domain: effectiveXDomain, count: displayCandles.count
        )
        let visibleCandles: ArraySlice<Candle>
        if let b = bounds {
            visibleCandles = displayCandles[b.lo ... b.hi]
        } else {
            visibleCandles = displayCandles[...]
        }
        var lo = visibleCandles.map(\.low).min()  ?? 0
        var hi = visibleCandles.map(\.high).max() ?? 1
        // Pull in any indicator values that exceed the candle range so
        // SMA/EMA/Bollinger lines never get clipped off-screen. Restrict
        // to the visible index window to match the rendered marks.
        if let b = bounds {
            for entry in derived.indicators(enabled: indicators, candles: candles) {
                for p in entry.points where p.index >= b.lo && p.index <= b.hi {
                    if p.value < lo { lo = p.value }
                    if p.value > hi { hi = p.value }
                }
            }
        }
        // UT Bot trailing stop can sit well outside the candle range,
        // especially right after a flip. Only fold it into the domain
        // when the user has the visual stop line enabled — otherwise
        // we'd be reserving Y space for an invisible mark.
        if indicatorConfig.utShowTrailingStop,
           let b = bounds,
           let stops = utBotOutput?.trailingStop
        {
            for i in b.lo ... b.hi where i < stops.count {
                guard let v = stops[i] else { continue }
                if v < lo { lo = v }
                if v > hi { hi = v }
            }
        }
        // S/R levels from the AI: keep them on-screen even when the
        // identified level sits beyond the visible candles.
        for v in srLevels.support + srLevels.resistance {
            if v < lo { lo = v }
            if v > hi { hi = v }
        }
        // FVG zones — fold both edges so a gap above/below the visible
        // range still shows up at the chart border.
        for zone in fvgZones {
            if zone.low  < lo { lo = zone.low }
            if zone.high > hi { hi = zone.high }
        }
        // Supply / Demand zones — same treatment so a zone above or
        // below the visible candles still draws against the chart
        // edge (typical with strong moves that left a big base
        // behind).
        for zone in supplyDemandZones {
            if zone.low  < lo { lo = zone.low }
            if zone.high > hi { hi = zone.high }
        }
        // Scenario entry / TP / SL — same treatment. Entry can be nil
        // for legacy history entries; skip it then. Alt scenario folds
        // in the same way so its lines stay on-screen too.
        for scenario in [taScenario, taAltScenario].compactMap({ $0 }) {
            var values = [scenario.takeProfit, scenario.stopLoss]
            if let entry = scenario.entry { values.append(entry) }
            for v in values {
                if v < lo { lo = v }
                if v > hi { hi = v }
            }
        }
        // User drawings — a horizontal line above the highest candle
        // would clip off-screen without this, defeating its purpose.
        for d in drawings where d.visible {
            if d.start.price < lo { lo = d.start.price }
            if d.start.price > hi { hi = d.start.price }
            if let e = d.end {
                if e.price < lo { lo = e.price }
                if e.price > hi { hi = e.price }
            }
        }
        // Paper trades — fold in entry / TP / SL / fillPrice so an
        // out-of-range trade line still renders inside the visible
        // plot. fillPrice diverges from entry only on market orders.
        for t in trades {
            for v in [t.takeProfit, t.stopLoss, t.entry, t.fillPrice ?? t.entry] {
                if v < lo { lo = v }
                if v > hi { hi = v }
            }
        }
        guard visibleCandles.isEmpty == false else { return 0...1 }
        let span = hi - lo
        if span <= 0 || visibleCandles.count == 1 {
            // Single bar → expand ±0.5% so it has visible vertical
            // extent rather than collapsing to a 1px line.
            let pad = max(hi * 0.005, 1)
            return (lo - pad)...(hi + pad)
        }
        let pad = span * 0.05
        return (lo - pad)...(hi + pad)
    }

    /// Body width tuned to the *visible* bar count so candles get fatter
    /// as the user zooms in (via pinch, scroll, or the +/- buttons) and
    /// thinner as they zoom out — instead of being permanently pegged to
    /// whatever the full series happens to contain.
    private var candleBodyWidth: CGFloat {
        let span = effectiveXDomain.upperBound - effectiveXDomain.lowerBound
        let visible = max(1, Int(span.rounded()))
        switch visible {
        case 0...3:    return 28
        case 4...10:   return 18
        case 11...30:  return 11
        case 31...80:  return 7
        case 81...200: return 4
        default:       return 2
        }
    }

    // MARK: - Formatting

    /// Compact price label: 19,634,000 → "19.6M"; 4,675 → "4,675";
    /// 0.0234 → "0.0234". K/M/B suffixes once values exceed 4 digits so
    /// the Y-axis labels stay narrow. Used for tick labels where a long
    /// number would crowd the axis; the last-price tag and crosshair
    /// labels use `priceExact` instead so the user can read the actual
    /// figure.
    static func priceShort(_ v: Double) -> String {
        let abs = Swift.abs(v)
        if abs >= 1_000_000_000 { return String(format: "%.2fB", v / 1_000_000_000) }
        if abs >= 1_000_000     { return String(format: "%.2fM", v / 1_000_000) }
        if abs >= 10_000        { return String(format: "%.0fK", v / 1_000) }
        if abs >= 100           { return v.formatted(.number.precision(.fractionLength(0))) }
        if abs >= 1             { return v.formatted(.number.precision(.fractionLength(2))) }
        return String(format: "%.4f", v)
    }

    /// Exact price with thousands separators and up to 4 decimals.
    /// Used wherever the user is trying to read the actual figure off
    /// the chart — the live-price tag, the hover tooltip's OHLC cells,
    /// and the crosshair Y-axis label. Decimal width scales with
    /// magnitude so we don't render meaningless ".00" suffixes on
    /// millions-of-toman quotes, but we always show enough precision
    /// to distinguish two consecutive ticks on small-priced pairs.
    static func priceExact(_ v: Double) -> String {
        let abs = Swift.abs(v)
        let digits: Int
        if abs >= 1_000_000 { digits = 0 }
        else if abs >= 100  { digits = 2 }
        else if abs >= 1    { digits = 4 }
        else                { digits = 5 }
        return v.formatted(.number.precision(.fractionLength(digits)))
    }

    /// Compact human-readable timestamp for the hover tooltip.
    /// Local time, no year — finance UIs almost never need it.
    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d · HH:mm"
        return f
    }()
}

