import SwiftUI
import Charts

struct ChartViewiPad: View {
    let candles: [Candle]
    let chartType: ChartType
    let accent: Color

    @Binding var xDomain: ClosedRange<Double>?
    @Binding var yDomain: ClosedRange<Double>?

    let indicators: Set<IndicatorKind>
    let indicatorConfig: OscillatorConfig

    var srLevels: PromptBuilder.SRLevels = .init(support: [], resistance: [])
    var fvgZones: [PromptBuilder.FVGZone] = []
    var supplyDemandZones: [PromptBuilder.SupplyDemandZone] = []
    var taScenario: PromptBuilder.TAScenario? = nil
    var taAltScenario: PromptBuilder.TAScenario? = nil
    var drawings: [ChartDrawing] = []
    var activeTool: DrawingTool = .none
    var onCommitDrawing: ((ChartDrawing) -> Void)? = nil
    var onMoveDrawing: ((ChartDrawing) -> Void)? = nil
    var selectedDrawingID: UUID? = nil
    var onSelectDrawing: ((UUID?) -> Void)? = nil
    var trades: [Trade] = []
    var journalEntries: [JournalEntry] = []
    var livePrice: Double? = nil
    var replayActive: Bool = false

    @State private var hovered: HoverState?
    @StateObject private var derived = ChartDerivedCache()
    @State private var dragStartDomain: ClosedRange<Double>?
    @State private var dragStartYDomain: ClosedRange<Double>?
    @State private var panLockedY = false
    @State private var magnifyStartDomain: ClosedRange<Double>?
    @State private var magnifyStartYDomain: ClosedRange<Double>?
    @State private var yScaleStartDomain: ClosedRange<Double>?
    @State private var drawingStart: DrawingPoint?
    @State private var drawingEnd: DrawingPoint?
    @State private var movingDrawingOriginal: ChartDrawing?
    @State private var movingDeltaTime: TimeInterval = 0
    @State private var movingDeltaPrice: Double = 0
    @State private var editingDrawingID: UUID?
    @State private var editingHandle: ChartDrawing.Handle?
    @State private var editingCursor: DrawingPoint?
    @State private var dragHadMovement: Bool = false
    @State private var crosshairActive: Bool = false
    @State private var crosshairLocation: CGPoint = .zero

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
                .clipped()
                .overlay(alignment: .topLeading) { hoverTooltip }
        }
    }

    // MARK: - Chart body

    private var displayCandles: [Candle] {
        derived.displayCandles(
            candles: candles,
            heikinAshi: chartType == .heikinAshi,
            livePrice: livePrice
        )
    }

    private var utBotOutput: UTBot.Output? {
        guard indicators.contains(.utBot) else { return nil }
        return derived.utBot(
            candles: candles,
            keyValue: indicatorConfig.utKeyValue,
            atrPeriod: indicatorConfig.utATRPeriod,
            useHeikinAshi: indicatorConfig.utUseHeikinAshi
        )
    }

    private var orderBlockZones: [OrderBlocks.Zone] {
        guard indicators.contains(.orderBlock) else { return [] }
        let all = derived.orderBlocks(
            candles: candles,
            periods: indicatorConfig.obPeriods,
            threshold: indicatorConfig.obThreshold,
            useWicks: indicatorConfig.obUseWicks,
            detectSteroids: indicatorConfig.obDetectSteroids
        )
        let filtered = indicatorConfig.obShowExhausted ? all : all.filter { $0.status != .exhausted }
        return Array(filtered.suffix(6))
    }

    private var steroidOrderBlockZones: [SteroidOrderBlocks.Zone] {
        guard indicators.contains(.steroidOrderBlock) else { return [] }
        let all = derived.steroidOrderBlocks(
            candles: candles,
            periods: indicatorConfig.sobPeriods,
            threshold: indicatorConfig.sobThreshold,
            useWicks: indicatorConfig.sobUseWicks,
            volumeMultiplier: indicatorConfig.sobVolumeMultiplier,
            detectSteroids: indicatorConfig.sobDetectSteroids
        )
        let filtered = indicatorConfig.sobShowExhausted ? all : all.filter { $0.status != .exhausted }
        return Array(filtered.suffix(6))
    }

    private var indicatorFvgZones: [FairValueGap.Zone] {
        guard indicators.contains(.fairValueGap) else { return [] }
        let all = derived.fairValueGaps(
            candles: candles,
            threshold: indicatorConfig.fvgThreshold
        )
        return indicatorConfig.fvgShowMitigated ? all : all.filter { !$0.isMitigated }
    }

    private var fvgFirstOBZones: [FVGFirstOB.Zone] {
        guard indicators.contains(.fvgFirstOB) else { return [] }
        let all = derived.fvgFirstOB(
            candles: candles,
            fvgThreshold: indicatorConfig.fvobFVGThreshold,
            searchMin: indicatorConfig.fvobSearchMin,
            searchMax: indicatorConfig.fvobSearchMax,
            detectVolume: indicatorConfig.fvobDetectVolume,
            volumeMultiplier: indicatorConfig.fvobVolumeMultiplier
        )
        let filtered = indicatorConfig.fvobShowExhausted ? all : all.filter { $0.status != .exhausted }
        return Array(filtered.suffix(10))
    }

    private var sessionRuns: [TradingSessions.SessionRun] {
        guard indicators.contains(.tradingSession) else { return [] }
        var latest: [String: TradingSessions.SessionRun] = [:]
        for run in derived.tradingSessions(candles: candles) where indicatorConfig.showsSession(run.sessionID) {
            latest[run.sessionID] = run
        }
        return latest.values.sorted { $0.start < $1.start }
    }

    private var nySetupResults: [NYOpenSetup.Result] {
        guard indicators.contains(.nyOpenSetup) else { return [] }
        let all = derived.nyOpenSetup(
            candles: candles,
            atrMult: indicatorConfig.nyAtrMult,
            amOnly: indicatorConfig.nyAMOnly
        )
        guard !all.isEmpty,
              let b = ChartWindow.visibleBounds(domain: effectiveXDomain, count: candles.count)
        else { return [] }
        let lastIndex = candles.count - 1
        let margin = max(8, (b.hi - b.lo) / 4)
        let lo = b.lo - margin
        let hi = b.hi + margin
        return all.suffix(3).filter { r in
            let end = r.resolveIndex ?? lastIndex
            return end >= lo && r.orStartIndex <= hi
        }
    }

    private var volumeProfileSessions: [VolumeProfile.SessionVP] {
        guard indicators.contains(.volumeProfile), !indicatorConfig.vpUseZigzag else { return [] }
        return derived.volumeProfile(
            candles: candles,
            bucketCount: indicatorConfig.vpBucketCount,
            valueAreaPct: indicatorConfig.vpValueAreaPct
        )
    }

    private var zigzagTrendVP: VolumeProfile.TrendVP? {
        guard indicators.contains(.volumeProfile), indicatorConfig.vpUseZigzag else { return nil }
        return derived.zigzagVolumeProfile(
            candles: candles,
            bucketCount: indicatorConfig.vpBucketCount,
            valueAreaPct: indicatorConfig.vpValueAreaPct,
            zzDepth: indicatorConfig.vpZZDepth,
            zzMinChange: indicatorConfig.vpZZMinChange
        )
    }

    private var zigzagPivots: [ZigZag.Pivot] {
        guard indicators.contains(.volumeProfile),
              indicatorConfig.vpUseZigzag,
              indicatorConfig.vpShowZigzag else { return [] }
        return derived.zigzagPivots(
            candles: candles,
            depth: indicatorConfig.vpZZDepth,
            minChange: indicatorConfig.vpZZMinChange
        )
    }

    private var chart: some View {
        Group {
            let indices = renderIndices
            let indexSet = Set(indices)

            Chart {
                if let last = displayCandles.last {
                    RuleMark(y: .value("Last", last.close))
                        .foregroundStyle(accent.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                            Text(Self.priceExact(last.close))
                                .font(.system(size: 10, weight: .bold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(accent))
                        }
                }

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

                sessionMarks
                volumeProfileMarks
                zigzagLineMarks
                setupMarks
                srLevelMarks
                fvgMarks
                indicatorFvgMarks
                supplyDemandMarks
                orderBlockMarks
                steroidOrderBlockMarks
                fvgFirstOBMarks
                scenarioMarks
                tradeMarks
                journalMarks
                drawingMarks
                drawingPreviewMarks

                switch chartType {
                case .line:                  lineMarks(indices: indices)
                case .candle, .heikinAshi:   candleMarks(indices: indices)
                }

                indicatorMarks(visible: indexSet)
                utBotMarks(indices: indices, visible: indexSet)

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
                    PointMark(
                        x: .value("Hover", Double(h.index)),
                        y: .value("Hover", dc.close)
                    )
                    .foregroundStyle(accent)
                    .symbolSize(70)
                }
            }
            .chartYScale(domain: effectiveYDomain)
            .chartXScale(domain: effectiveXDomain)
            .chartXAxis(content: xAxis)
            .chartYAxis(content: yAxis)
            .chartPlotStyle { plot in
                plot.background(
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
                GeometryReader { geo in
                    let plotFrame = geo[proxy.plotAreaFrame]
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                let x = location.x - plotFrame.origin.x
                                let y = location.y - plotFrame.origin.y
                                guard plotFrame.size.width > 0,
                                      x >= 0, x <= plotFrame.size.width,
                                      y >= 0, y <= plotFrame.size.height,
                                      let xValue: Double = proxy.value(atX: x)
                                else { return }
                                let idx = max(0, min(candles.count - 1, Int(xValue.rounded())))
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
                        .simultaneousGesture(ipadDragGesture(
                            plotWidth: plotFrame.size.width,
                            plotHeight: plotFrame.size.height,
                            plotOrigin: plotFrame.origin,
                            proxy: proxy
                        ))
                        .simultaneousGesture(magnificationGesture())
                        .onTapGesture(count: 2) {
                            xDomain = nil
                            yDomain = nil
                        }
                }
            }
        }
    }

    // MARK: - iPad drag (pan + draw)

    private func ipadDragGesture(
        plotWidth: CGFloat,
        plotHeight: CGFloat,
        plotOrigin: CGPoint,
        proxy: ChartProxy
    ) -> some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                if dragStartDomain == nil {
                    dragStartDomain = effectiveXDomain
                    dragStartYDomain = effectiveYDomain
                    panLockedY = false
                    hovered = nil
                    dragHadMovement = false
                }
                let movedFar = abs(value.translation.width) > 3 || abs(value.translation.height) > 3
                if movedFar { dragHadMovement = true }
                guard dragHadMovement else { return }
                guard let start = dragStartDomain, plotWidth > 0 else { return }

                let span = start.upperBound - start.lowerBound
                let unitsPerPoint = span / Double(plotWidth)
                let deltaX = Double(value.translation.width) * unitsPerPoint

                // Batch xDomain + yDomain into one update to avoid double recompute
                let newXLower = start.lowerBound - deltaX
                let newXUpper = start.upperBound - deltaX
                xDomain = newXLower ... newXUpper

                if !panLockedY, abs(value.translation.height) > 2 { panLockedY = true }
                if panLockedY, let startY = dragStartYDomain, plotHeight > 0 {
                    let ySpan = startY.upperBound - startY.lowerBound
                    let pricePerPoint = ySpan / Double(plotHeight)
                    let shift = Double(value.translation.height) * pricePerPoint
                    yDomain = (startY.lowerBound + shift) ... (startY.upperBound + shift)
                }
            }
            .onEnded { _ in
                dragStartDomain = nil
                dragStartYDomain = nil
                panLockedY = false
            }
    }

    // MARK: - Pinch-to-zoom (throttled)

    private func magnificationGesture() -> some Gesture {
        MagnificationGesture(minimumScaleDelta: 0.02)
            .onChanged { value in
                if magnifyStartDomain == nil {
                    magnifyStartDomain = effectiveXDomain
                    magnifyStartYDomain = effectiveYDomain
                    hovered = nil
                }
                // X-axis zoom (horizontal pinch)
                if let start = magnifyStartDomain {
                    let center = (start.lowerBound + start.upperBound) / 2
                    let halfSpan = (start.upperBound - start.lowerBound) / 2
                    let scale = max(0.1, min(20, Double(value)))
                    let zoomedHalf = halfSpan / scale
                    xDomain = (center - zoomedHalf) ... (center + zoomedHalf)
                }
                // Y-axis zoom (vertical component of pinch)
                if let startY = magnifyStartYDomain {
                    let yCenter = (startY.lowerBound + startY.upperBound) / 2
                    let yHalfSpan = (startY.upperBound - startY.lowerBound) / 2
                    let yScale = max(0.1, min(20, Double(value)))
                    let yZoomedHalf = yHalfSpan / yScale
                    yDomain = (yCenter - yZoomedHalf) ... (yCenter + yZoomedHalf)
                }
            }
            .onEnded { _ in
                magnifyStartDomain = nil
                magnifyStartYDomain = nil
            }
    }

    // MARK: - Effective domains

    private var effectiveXDomain: ClosedRange<Double> {
        if let d = xDomain { return d }
        return ChartWindow.defaultDomain(count: candles.count)
    }

    private var renderIndices: [Int] {
        ChartWindow.renderIndices(domain: effectiveXDomain, count: candles.count)
    }

    // MARK: - Line marks

    @ChartContentBuilder
    private func lineMarks(indices: [Int]) -> some ChartContent {
        let cs = displayCandles
        ForEach(indices, id: \.self) { i in
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
        if cs.count == 1, let only = cs.first {
            PointMark(
                x: .value("Bar", 0.0),
                y: .value("Close", only.close)
            )
            .foregroundStyle(accent)
            .symbolSize(120)
        }
    }

    // MARK: - S/R levels

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

    // MARK: - FVG marks

    @ChartContentBuilder
    private var fvgMarks: some ChartContent {
        let lastIndex = candles.count - 1
        ForEach(fvgZones) { zone in
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

    // MARK: - Indicator FVG marks

    @ChartContentBuilder
    private var indicatorFvgMarks: some ChartContent {
        let lastIndex = candles.count - 1
        ForEach(indicatorFvgZones) { zone in
            let color: Color = zone.isBullish ? Theme.Color.success : Theme.Color.danger
            let xStart = Double(zone.index)
            let xEnd   = Double(lastIndex)
            RectangleMark(
                xStart: .value("FVG start", xStart),
                xEnd:   .value("FVG end",   xEnd),
                yStart: .value("FVG low",   zone.low),
                yEnd:   .value("FVG high",  zone.high)
            )
            .foregroundStyle(color.opacity(zone.isMitigated ? 0.08 : 0.16))

            RuleMark(
                xStart: .value("FVG hi start", xStart),
                xEnd:   .value("FVG hi end",   xEnd),
                y:      .value("FVG hi",        zone.high)
            )
            .foregroundStyle(color.opacity(zone.isMitigated ? 0.35 : 0.65))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: zone.isMitigated ? [4, 3] : []))

            RuleMark(
                xStart: .value("FVG lo start", xStart),
                xEnd:   .value("FVG lo end",   xEnd),
                y:      .value("FVG lo",        zone.low)
            )
            .foregroundStyle(color.opacity(zone.isMitigated ? 0.35 : 0.65))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: zone.isMitigated ? [4, 3] : []))

            RuleMark(
                xStart: .value("FVG mid start", xStart),
                xEnd:   .value("FVG mid end",   xEnd),
                y:      .value("FVG mid",        zone.mid)
            )
            .foregroundStyle(color.opacity(0.35))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))

            PointMark(
                x: .value("FVG label", xEnd),
                y: .value("FVG hi",    zone.high)
            )
            .symbolSize(0)
            .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                Text(zone.isBullish ? "FVG↑" : "FVG↓")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(color.opacity(zone.isMitigated ? 0.55 : 0.95)))
            }
        }
    }

    // MARK: - Supply & Demand marks

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

            PointMark(
                x: .value("Zone end label", xEnd),
                y: .value("Zone hi",        zone.high)
            )
            .symbolSize(0)
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

    // MARK: - Trading session marks

    @ChartContentBuilder
    private var sessionMarks: some ChartContent {
        let cfg = indicatorConfig
        let lineEnd = Double(max(candles.count - 1, 0))
        ForEach(sessionRuns) { run in
            let xStart = Double(run.start)
            let xEnd   = Double(run.end)

            RectangleMark(
                xStart: .value("Session start", xStart),
                xEnd:   .value("Session end",   xEnd),
                yStart: .value("Session low",   run.low),
                yEnd:   .value("Session high",  run.high)
            )
            .foregroundStyle(run.color.opacity(0.12))

            RuleMark(
                xStart: .value("Sess high start", xStart),
                xEnd:   .value("Sess high end",   lineEnd),
                y:      .value("Sess high",       run.high)
            )
            .foregroundStyle(run.color.opacity(0.7))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [1, 3]))
            RuleMark(
                xStart: .value("Sess low start", xStart),
                xEnd:   .value("Sess low end",   lineEnd),
                y:      .value("Sess low",        run.low)
            )
            .foregroundStyle(run.color.opacity(0.7))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [1, 3]))

            if cfg.sessShowOpenClose {
                RuleMark(
                    xStart: .value("Sess open start", xStart),
                    xEnd:   .value("Sess open end",   xEnd),
                    y:      .value("Sess open",       run.open)
                )
                .foregroundStyle(run.color.opacity(0.85))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                RuleMark(
                    xStart: .value("Sess close start", xStart),
                    xEnd:   .value("Sess close end",   xEnd),
                    y:      .value("Sess close",       run.close)
                )
                .foregroundStyle(run.color.opacity(0.85))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }

            if cfg.sessShowAverage {
                RuleMark(
                    xStart: .value("Sess avg start", xStart),
                    xEnd:   .value("Sess avg end",   lineEnd),
                    y:      .value("Sess avg",       run.average)
                )
                .foregroundStyle(run.color.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [1, 3]))
            }

            if let text = sessionLabelText(run) {
                PointMark(
                    x: .value("Sess label x", xStart),
                    y: .value("Sess label y", run.low)
                )
                .symbolSize(0)
                .annotation(position: .bottom, alignment: .leading, spacing: 1) {
                    Text(text)
                        .font(.system(size: 8, weight: .bold).monospacedDigit())
                        .foregroundStyle(run.color)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Theme.Color.surfaceMax.opacity(0.7))
                        )
                        .fixedSize()
                }
            }
        }
    }

    private func sessionLabelText(_ run: TradingSessions.SessionRun) -> String? {
        var lines: [String] = []
        if indicatorConfig.sessShowRange   { lines.append("Rng \(Self.priceShort(run.range))") }
        if indicatorConfig.sessShowAverage { lines.append("Avg \(Self.priceShort(run.average))") }
        if indicatorConfig.sessShowNames   { lines.append(run.name) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: - Volume Profile marks

    @ChartContentBuilder
    private var volumeProfileMarks: some ChartContent {
        if indicatorConfig.vpUseZigzag {
            zigzagVPMarks
        } else {
            sessionVPMarks
        }
    }

    @ChartContentBuilder
    private var zigzagVPMarks: some ChartContent {
        if let vp = zigzagTrendVP {
            let maxVol = vp.buckets.map(\.volume).max() ?? 1
            let lastBar = Double(candles.count - 1)
            let marginStart = lastBar + 1.0
            let marginWidth = 20.0
            let bucketSize = vp.buckets.count > 1
                ? (vp.buckets[1].priceLevel - vp.buckets[0].priceLevel)
                : vp.buckets[0].priceLevel * 0.001

            ForEach(Array(vp.buckets.enumerated()), id: \.offset) { _, bucket in
                let barWidth = marginWidth * (bucket.volume / maxVol)
                let isPOC = abs(bucket.priceLevel - vp.poc) < bucketSize * 0.01
                RectangleMark(
                    xStart: .value("ZVP x0", marginStart + marginWidth - barWidth),
                    xEnd:   .value("ZVP x1", marginStart + marginWidth),
                    yStart: .value("ZVP y0", bucket.priceLevel),
                    yEnd:   .value("ZVP y1", bucket.priceLevel + bucketSize * 0.92)
                )
                .foregroundStyle(
                    isPOC
                        ? Color(red: 0.96, green: 0.36, blue: 0.36).opacity(0.85)
                        : Theme.Color.info.opacity(0.45)
                )
            }

            RuleMark(y: .value("ZVP POC", vp.poc))
                .foregroundStyle(Color(red: 0.96, green: 0.36, blue: 0.36))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            RuleMark(y: .value("ZVP VAH", vp.vah))
                .foregroundStyle(Theme.Color.info.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            RuleMark(y: .value("ZVP VAL", vp.val))
                .foregroundStyle(Theme.Color.info.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }

    @ChartContentBuilder
    private var sessionVPMarks: some ChartContent {
        let sessions = volumeProfileSessions
        ForEach(sessions) { session in
            let maxVol = session.buckets.map(\.volume).max() ?? 1
            let sessionWidth = Double(session.endBar - session.startBar)
            let maxBarWidth = sessionWidth * 0.25
            let rightEdge = Double(session.endBar)
            let bucketSize = session.buckets.count > 1
                ? (session.buckets[1].priceLevel - session.buckets[0].priceLevel)
                : session.buckets[0].priceLevel * 0.001

            ForEach(Array(session.buckets.enumerated()), id: \.offset) { _, bucket in
                let barWidth = maxBarWidth * (bucket.volume / maxVol)
                let isPOC = abs(bucket.priceLevel - session.poc) < bucketSize * 0.01
                RectangleMark(
                    xStart: .value("VP x0", rightEdge - barWidth),
                    xEnd:   .value("VP x1", rightEdge),
                    yStart: .value("VP y0", bucket.priceLevel),
                    yEnd:   .value("VP y1", bucket.priceLevel + bucketSize * 0.92)
                )
                .foregroundStyle(
                    isPOC
                        ? Color(red: 0.96, green: 0.36, blue: 0.36).opacity(0.85)
                        : Theme.Color.info.opacity(0.45)
                )
            }

            RuleMark(y: .value("VP POC", session.poc))
                .foregroundStyle(Color(red: 0.96, green: 0.36, blue: 0.36))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            RuleMark(y: .value("VP VAH", session.vah))
                .foregroundStyle(Theme.Color.info.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            RuleMark(y: .value("VP VAL", session.val))
                .foregroundStyle(Theme.Color.info.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

            if session.startBar > 0 {
                RuleMark(x: .value("VP sep", Double(session.startBar) - 0.5))
                    .foregroundStyle(Theme.Color.textMuted.opacity(0.15))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
            }
        }
    }

    @ChartContentBuilder
    private var zigzagLineMarks: some ChartContent {
        let pivots = zigzagPivots
        if pivots.count >= 2 {
            ForEach(0..<(pivots.count - 1), id: \.self) { i in
                let p0 = pivots[i]
                let p1 = pivots[i + 1]
                let color = p1.isHigh
                    ? Color(red: 0.96, green: 0.36, blue: 0.36)
                    : Color(red: 0.30, green: 0.80, blue: 0.40)
                LineMark(
                    x: .value("ZZ x0", Double(p0.barIndex)),
                    y: .value("ZZ y0", p0.price),
                    series: .value("ZZ", i)
                )
                .foregroundStyle(color.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                LineMark(
                    x: .value("ZZ x1", Double(p1.barIndex)),
                    y: .value("ZZ y1", p1.price),
                    series: .value("ZZ", i)
                )
                .foregroundStyle(color.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            ForEach(pivots) { pivot in
                let color = pivot.isHigh
                    ? Color(red: 0.96, green: 0.36, blue: 0.36)
                    : Color(red: 0.30, green: 0.80, blue: 0.40)
                PointMark(
                    x: .value("ZZ dot x", Double(pivot.barIndex)),
                    y: .value("ZZ dot y", pivot.price)
                )
                .foregroundStyle(color)
                .symbolSize(18)
            }
        }
    }

    // MARK: - NY Open Setup marks

    @ChartContentBuilder
    private var setupMarks: some ChartContent {
        let lastIndex = candles.count - 1
        ForEach(nySetupResults) { r in
            let dirColor = setupDirectionColor(r.direction)
            let orStart = Double(r.orStartIndex)
            let orEnd   = Double(r.orEndIndex)
            let rayEnd  = Double(r.resolveIndex ?? lastIndex)

            RectangleMark(
                xStart: .value("OR start", orStart),
                xEnd:   .value("OR end",   orEnd),
                yStart: .value("OR low",   r.orLow),
                yEnd:   .value("OR high",  r.orHigh)
            )
            .foregroundStyle(dirColor.opacity(0.14))

            RuleMark(xStart: .value("ORH s", orStart), xEnd: .value("ORH e", rayEnd),
                     y: .value("OR high", r.orHigh))
            .foregroundStyle(dirColor.opacity(0.55))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            RuleMark(xStart: .value("ORL s", orStart), xEnd: .value("ORL e", rayEnd),
                     y: .value("OR low", r.orLow))
            .foregroundStyle(dirColor.opacity(0.55))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))

            PointMark(x: .value("NY High x", orStart), y: .value("NY High y", r.orHigh))
                .symbolSize(0)
                .annotation(position: .top, alignment: .leading, spacing: 1) {
                    setupTag("NY High", color: dirColor)
                }
            PointMark(x: .value("NY Low x", orStart), y: .value("NY Low y", r.orLow))
                .symbolSize(0)
                .annotation(position: .bottom, alignment: .leading, spacing: 1) {
                    setupTag("NY Low", color: dirColor)
                }

            if r.hasPlan,
               let fvgS = r.fvgStartIndex, let fvgE = r.fvgEndIndex,
               let fLo = r.fvgLow, let fHi = r.fvgHigh,
               let entry = r.entry, let sl = r.stopLoss, let tp = r.takeProfit {
                let planStart = Double(fvgE)
                let planEnd   = Double(r.resolveIndex ?? lastIndex)

                RectangleMark(
                    xStart: .value("FVG s", Double(fvgS)),
                    xEnd:   .value("FVG e", Double(fvgE)),
                    yStart: .value("FVG lo", fLo),
                    yEnd:   .value("FVG hi", fHi)
                )
                .foregroundStyle(dirColor.opacity(0.22))

                RuleMark(xStart: .value("E s", planStart), xEnd: .value("E e", planEnd),
                         y: .value("Entry", entry))
                .foregroundStyle(dirColor.opacity(0.9))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                RuleMark(xStart: .value("SL s", planStart), xEnd: .value("SL e", planEnd),
                         y: .value("SL", sl))
                .foregroundStyle(Theme.Color.danger.opacity(0.9))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                RuleMark(xStart: .value("TP s", planStart), xEnd: .value("TP e", planEnd),
                         y: .value("TP", tp))
                .foregroundStyle(Theme.Color.success.opacity(0.9))
                .lineStyle(StrokeStyle(lineWidth: 1.5))

                PointMark(x: .value("Entry lbl x", planEnd), y: .value("Entry lbl y", entry))
                    .symbolSize(0)
                    .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                        setupTag("Entry \(r.direction == .long ? "↑" : "↓")", color: dirColor)
                    }
                PointMark(x: .value("SL lbl x", planEnd), y: .value("SL lbl y", sl))
                    .symbolSize(0)
                    .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                        setupTag("SL", color: Theme.Color.danger)
                    }
                PointMark(x: .value("TP lbl x", planEnd), y: .value("TP lbl y", tp))
                    .symbolSize(0)
                    .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                        setupTag("TP", color: Theme.Color.success)
                    }

                if let rt = r.retestIndex {
                    PointMark(x: .value("retest x", Double(rt)), y: .value("retest y", entry))
                        .symbolSize(40)
                        .foregroundStyle(dirColor)
                }
            }
        }
    }

    private func setupDirectionColor(_ dir: NYOpenSetup.Direction?) -> Color {
        switch dir {
        case .long:  return Theme.Color.success
        case .short: return Theme.Color.danger
        case nil:    return Theme.Color.warn
        }
    }

    private func setupTag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.95)))
            .fixedSize()
    }

    // MARK: - Order block marks

    @ChartContentBuilder
    private var orderBlockMarks: some ChartContent {
        let lastIndex = candles.count - 1
        ForEach(orderBlockZones) { zone in
            orderOBMark(for: zone, lastIndex: lastIndex)
        }
    }

    @ChartContentBuilder
    private func orderOBMark(for zone: OrderBlocks.Zone, lastIndex: Int) -> some ChartContent {
        let baseColor: Color = zone.isBullish ? Theme.Color.success : Theme.Color.danger
        let xStart = Double(zone.index)
        let xEnd   = Double(lastIndex)

        let (fillOp, borderOp, borderDash, labelText): (Double, Double, [CGFloat], String) = {
            switch zone.status {
            case .fresh:
                return (0.14, 0.7, [], zone.isBullish ? "OB↑" : "OB↓")
            case .tested:
                return (0.07, 0.35, [2, 2], zone.isBullish ? "OB↑ · Tested" : "OB↓ · Tested")
            case .exhausted:
                return (0.03, 0.18, [2, 6], zone.isBullish ? "OB↑ · Exhausted" : "OB↓ · Exhausted")
            }
        }()

        RectangleMark(
            xStart: .value("OB start", xStart),
            xEnd:   .value("OB end",   xEnd),
            yStart: .value("OB low",   zone.low),
            yEnd:   .value("OB high",  zone.high)
        )
        .foregroundStyle(baseColor.opacity(fillOp))

        RuleMark(
            xStart: .value("OB start hi", xStart),
            xEnd:   .value("OB end hi",   xEnd),
            y:      .value("OB hi",       zone.high)
        )
        .foregroundStyle(baseColor.opacity(borderOp))
        .lineStyle(StrokeStyle(lineWidth: 1, dash: borderDash))
        RuleMark(
            xStart: .value("OB start lo", xStart),
            xEnd:   .value("OB end lo",   xEnd),
            y:      .value("OB lo",       zone.low)
        )
        .foregroundStyle(baseColor.opacity(borderOp))
        .lineStyle(StrokeStyle(lineWidth: 1, dash: borderDash))

        RuleMark(
            xStart: .value("OB start avg", xStart),
            xEnd:   .value("OB end avg",   xEnd),
            y:      .value("OB avg",       zone.avg)
        )
        .foregroundStyle(baseColor.opacity(borderOp * 0.7))
        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))

        PointMark(
            x: .value("OB label", xEnd),
            y: .value("OB hi",    zone.high)
        )
        .symbolSize(0)
        .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
            Text(labelText)
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(baseColor.opacity(zone.status == .fresh ? 0.95 : 0.6)))
        }
    }

    // MARK: - Steroid order block marks

    @ChartContentBuilder
    private var steroidOrderBlockMarks: some ChartContent {
        let lastIndex = candles.count - 1
        ForEach(steroidOrderBlockZones) { zone in
            let baseColor: Color = zone.isBullish ? Theme.Color.success : Theme.Color.danger
            let accentColor = IndicatorKind.steroidOrderBlock.color
            let xStart = Double(zone.index)
            let xEnd   = Double(lastIndex)

            let (fillOp, borderOp, borderDash, labelText): (Double, Double, [CGFloat], String) = {
                switch zone.status {
                case .fresh:
                    return (0.18, 0.85, [], zone.isBullish ? "⚡ SOB↑" : "⚡ SOB↓")
                case .tested:
                    return (0.09, 0.45, [3, 3], zone.isBullish ? "⚡ SOB↑ · Tested" : "⚡ SOB↓ · Tested")
                case .exhausted:
                    return (0.03, 0.18, [2, 6], zone.isBullish ? "⚡ SOB↑ · Exhausted" : "⚡ SOB↓ · Exhausted")
                }
            }()

            RectangleMark(
                xStart: .value("SOB start", xStart),
                xEnd:   .value("SOB end",   xEnd),
                yStart: .value("SOB low",   zone.low),
                yEnd:   .value("SOB high",  zone.high)
            )
            .foregroundStyle(baseColor.opacity(fillOp))

            RuleMark(xStart: .value("SOB start hi", xStart), xEnd: .value("SOB end hi", xEnd),
                     y: .value("SOB hi", zone.high))
            .foregroundStyle(baseColor.opacity(borderOp))
            .lineStyle(StrokeStyle(lineWidth: 1.2, dash: borderDash))
            RuleMark(xStart: .value("SOB start lo", xStart), xEnd: .value("SOB end lo", xEnd),
                     y: .value("SOB lo", zone.low))
            .foregroundStyle(baseColor.opacity(borderOp))
            .lineStyle(StrokeStyle(lineWidth: 1.2, dash: borderDash))

            RuleMark(xStart: .value("SOB start avg", xStart), xEnd: .value("SOB end avg", xEnd),
                     y: .value("SOB avg", zone.avg))
            .foregroundStyle(accentColor.opacity(0.8))
            .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 2]))

            PointMark(x: .value("SOB label", xEnd), y: .value("SOB hi", zone.high))
                .symbolSize(0)
                .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                    Text(labelText)
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(accentColor))
                }
        }
    }

    // MARK: - FVG→OB marks

    @ChartContentBuilder
    private var fvgFirstOBMarks: some ChartContent {
        let lastIndex = candles.count - 1
        ForEach(fvgFirstOBZones) { zone in
            fvgFirstOBMark(for: zone, lastIndex: lastIndex)
        }
    }

    @ChartContentBuilder
    private func fvgFirstOBMark(for zone: FVGFirstOB.Zone, lastIndex: Int) -> some ChartContent {
        let baseColor: Color = zone.isBullish ? Theme.Color.success : Theme.Color.danger
        let accentColor = IndicatorKind.fvgFirstOB.color
        let xStart = Double(zone.index)
        let xEnd   = Double(lastIndex)

        let (fillOp, borderOp, borderDash, midDash, labelText, tagColor): (Double, Double, [CGFloat], [CGFloat], String, Color) = {
            switch zone.status {
            case .fresh:
                return (0.14, 0.70, [], [3, 3],
                        zone.isBullish ? "FVOB↑" : "FVOB↓", accentColor)
            case .tested:
                return (0.07, 0.35, [2, 2], [2, 4],
                        zone.isBullish ? "FVOB↑ · T" : "FVOB↓ · T", accentColor.opacity(0.7))
            case .exhausted:
                return (0.03, 0.18, [2, 6], [1, 8],
                        zone.isBullish ? "FVOB↑ · X" : "FVOB↓ · X", Theme.Color.textMuted.opacity(0.8))
            }
        }()

        RectangleMark(
            xStart: .value("FVOB start", xStart), xEnd: .value("FVOB end", xEnd),
            yStart: .value("FVOB low", zone.low),  yEnd: .value("FVOB high", zone.high)
        )
        .foregroundStyle(baseColor.opacity(fillOp))

        RuleMark(xStart: .value("FVOB start hi", xStart), xEnd: .value("FVOB end hi", xEnd),
                 y: .value("FVOB hi", zone.high))
            .foregroundStyle(baseColor.opacity(borderOp))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: borderDash))
        RuleMark(xStart: .value("FVOB start lo", xStart), xEnd: .value("FVOB end lo", xEnd),
                 y: .value("FVOB lo", zone.low))
            .foregroundStyle(baseColor.opacity(borderOp))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: borderDash))

        RuleMark(xStart: .value("FVOB start avg", xStart), xEnd: .value("FVOB end avg", xEnd),
                 y: .value("FVOB avg", zone.avg))
            .foregroundStyle(accentColor.opacity(borderOp * 0.7))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: midDash))

        PointMark(x: .value("FVOB label", xEnd), y: .value("FVOB hi", zone.high))
            .symbolSize(0)
            .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                Text(labelText)
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(tagColor))
            }
    }

    // MARK: - Scenario marks

    @ChartContentBuilder
    private var scenarioMarks: some ChartContent {
        if let scenario = taScenario {
            scenarioOverlay(scenario, isAlt: false)
        }
        if let alt = taAltScenario {
            scenarioOverlay(alt, isAlt: true)
        }
    }

    @ChartContentBuilder
    private func scenarioOverlay(_ scenario: PromptBuilder.TAScenario, isAlt: Bool) -> some ChartContent {
        let tpOpacity: Double = isAlt ? 0.40 : 0.75
        let slOpacity: Double = isAlt ? 0.40 : 0.75
        let entryOpacity: Double = isAlt ? 0.55 : 0.85
        let lineWidth: CGFloat = isAlt ? 0.9 : 1.2
        let entryLineWidth: CGFloat = isAlt ? 1.0 : 1.4
        let dashPattern: [CGFloat] = isAlt ? [2, 5] : [4, 4]
        let entryDash: [CGFloat] = isAlt ? [1, 4] : [2, 3]
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
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.black.opacity(0.55)))
    }

    private func levelTag(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.85)))
    }

    // MARK: - Trade marks

    @ChartContentBuilder
    private var tradeMarks: some ChartContent {
        ForEach(trades) { trade in
            RuleMark(y: .value("Trade entry", trade.fillPrice ?? trade.entry))
                .foregroundStyle(tradeEntryColor(trade))
                .lineStyle(StrokeStyle(
                    lineWidth: trade.status == .active ? 1.6 : 1.3,
                    dash: trade.status == .pending ? [3, 3] : []
                ))
                .annotation(position: .overlay, alignment: .leading, spacing: 0) {
                    tradeEntryTag(trade)
                }

            RuleMark(y: .value("Trade TP", trade.takeProfit))
                .foregroundStyle(Theme.Color.success.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1.0, dash: trade.status == .pending ? [3, 3] : [4, 4]))
                .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                    levelTag(text: "TP \(Self.priceShort(trade.takeProfit))", color: Theme.Color.success)
                }

            RuleMark(y: .value("Trade SL", trade.stopLoss))
                .foregroundStyle(Theme.Color.danger.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1.0, dash: trade.status == .pending ? [3, 3] : [4, 4]))
                .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                    levelTag(text: "SL \(Self.priceShort(trade.stopLoss))", color: Theme.Color.danger)
                }
        }
    }

    private func tradeEntryColor(_ t: Trade) -> Color {
        switch t.status {
        case .pending: return Theme.Color.warn
        case .active:  return t.side == .short ? Theme.Color.danger : Theme.Color.success
        default:       return Theme.Color.textMuted
        }
    }

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
        .background(Capsule().fill(Color.black.opacity(0.6)))
    }

    // MARK: - Journal marks

    @ChartContentBuilder
    private var journalMarks: some ChartContent {
        ForEach(journalEntries) { je in
            let sideColor: Color = je.side == .short ? Theme.Color.danger : Theme.Color.success
            let closeIdx: Int? = barIndex(closestTo: je.date)
            let openIdx: Int? = {
                if let od = je.openDate { return barIndex(closestTo: od) }
                guard let ci = closeIdx, let ep = je.entry else { return nil }
                return barIndexForEntryPrice(ep, before: ci)
            }()
            let xOpen  = Double(openIdx  ?? 0)
            let xClose = Double(closeIdx ?? max(0, candles.count - 1))
            let hasSpan = openIdx != nil && closeIdx != nil && openIdx != closeIdx

            if let ep = je.entry, let tp = je.takeProfit, hasSpan {
                RectangleMark(
                    xStart: .value("Open", xOpen), xEnd: .value("Close", xClose),
                    yStart: .value("Entry", ep), yEnd: .value("TP", tp)
                )
                .foregroundStyle(Theme.Color.success.opacity(0.12))
                RuleMark(xStart: .value("Open", xOpen), xEnd: .value("Close", xClose),
                         y: .value("TP", tp))
                .foregroundStyle(Theme.Color.success.opacity(0.8))
                .lineStyle(StrokeStyle(lineWidth: 1.2))
                .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                    journalLevelTag(text: "TP  \(Self.priceShort(tp))", bg: Theme.Color.success)
                }
            } else if let tp = je.takeProfit {
                RuleMark(y: .value("TP", tp))
                    .foregroundStyle(Theme.Color.success.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1.0, dash: [4, 4]))
                    .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                        journalLevelTag(text: "TP  \(Self.priceShort(tp))", bg: Theme.Color.success)
                    }
            }

            if let ep = je.entry, let sl = je.stopLoss, hasSpan {
                RectangleMark(
                    xStart: .value("Open", xOpen), xEnd: .value("Close", xClose),
                    yStart: .value("Entry", ep), yEnd: .value("SL", sl)
                )
                .foregroundStyle(Theme.Color.danger.opacity(0.12))
                RuleMark(xStart: .value("Open", xOpen), xEnd: .value("Close", xClose),
                         y: .value("SL", sl))
                .foregroundStyle(Theme.Color.danger.opacity(0.8))
                .lineStyle(StrokeStyle(lineWidth: 1.2))
                .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                    journalLevelTag(text: "SL  \(Self.priceShort(sl))", bg: Theme.Color.danger)
                }
            } else if let sl = je.stopLoss {
                RuleMark(y: .value("SL", sl))
                    .foregroundStyle(Theme.Color.danger.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1.0, dash: [4, 4]))
                    .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                        journalLevelTag(text: "SL  \(Self.priceShort(sl))", bg: Theme.Color.danger)
                    }
            }

            if let ep = je.entry {
                if hasSpan {
                    RuleMark(xStart: .value("Open", xOpen), xEnd: .value("Close", xClose),
                             y: .value("Entry", ep))
                    .foregroundStyle(sideColor.opacity(0.95))
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                    .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                        journalLevelTag(text: "Entry  \(Self.priceShort(ep))", bg: sideColor)
                    }
                } else {
                    RuleMark(y: .value("Entry", ep))
                        .foregroundStyle(sideColor.opacity(0.85))
                        .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [3, 3]))
                        .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                            journalLevelTag(text: "Entry  \(Self.priceShort(ep))", bg: sideColor)
                        }
                }
            }
        }
    }

    private func journalLevelTag(text: String, bg: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(bg.opacity(0.85)))
    }

    // MARK: - Drawing marks

    private var renderableDrawings: [ChartDrawing] {
        let movingID = movingDrawingOriginal?.id
        let editingID = editingDrawingID
        var out = drawings.filter { d in
            d.visible && d.id != movingID && d.id != editingID
        }
        if let moving = movingDrawingOriginal, moving.visible {
            out.append(translated(moving))
        }
        if let id = editingID,
           let original = drawings.first(where: { $0.id == id }),
           original.visible,
           let cursor = editingCursor,
           let anchor = editingHandle {
            out.append(original.resized(anchor: anchor, to: cursor))
        }
        return out
    }

    @ChartContentBuilder
    private var drawingMarks: some ChartContent {
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
                   let xe = barIndex(forDate: end.date) {
                    LineMark(x: .value("Bar", xs), y: .value("Price", d.start.price),
                             series: .value("Drawing", d.id.uuidString))
                    .foregroundStyle(stroke)
                    .lineStyle(StrokeStyle(lineWidth: lw))
                    LineMark(x: .value("Bar", xe), y: .value("Price", end.price),
                             series: .value("Drawing", d.id.uuidString))
                    .foregroundStyle(stroke)
                    .lineStyle(StrokeStyle(lineWidth: lw))
                }
            case .rectangle:
                if let end = d.end,
                   let xs = barIndex(forDate: d.start.date),
                   let xe = barIndex(forDate: end.date) {
                    let x0 = min(xs, xe), x1 = max(xs, xe)
                    let y0 = min(d.start.price, end.price)
                    let y1 = max(d.start.price, end.price)
                    RectangleMark(
                        xStart: .value("X0", x0), xEnd: .value("X1", x1),
                        yStart: .value("Y0", y0), yEnd: .value("Y1", y1)
                    )
                    .foregroundStyle(stroke.opacity(d.color.alpha * 0.18))
                    let borderStyle = StrokeStyle(lineWidth: lw)
                    RuleMark(xStart: .value("T", x0), xEnd: .value("T", x1), y: .value("Top", y1))
                        .foregroundStyle(stroke).lineStyle(borderStyle)
                    RuleMark(xStart: .value("B", x0), xEnd: .value("B", x1), y: .value("Bot", y0))
                        .foregroundStyle(stroke).lineStyle(borderStyle)
                    RuleMark(x: .value("L", x0), yStart: .value("L0", y0), yEnd: .value("L1", y1))
                        .foregroundStyle(stroke).lineStyle(borderStyle)
                    RuleMark(x: .value("R", x1), yStart: .value("R0", y0), yEnd: .value("R1", y1))
                        .foregroundStyle(stroke).lineStyle(borderStyle)
                }
            case .volumeProfile:
                if let end = d.end,
                   let xs = barIndex(forDate: d.start.date),
                   let xe = barIndex(forDate: end.date) {
                    // Volume profile - simplified rectangle for iPad
                    RectangleMark(
                        xStart: .value("VP x0", min(xs, xe)),
                        xEnd:   .value("VP x1", max(xs, xe)),
                        yStart: .value("VP y0", min(d.start.price, end.price)),
                        yEnd:   .value("VP y1", max(d.start.price, end.price))
                    )
                    .foregroundStyle(stroke.opacity(0.15))
                }
            }
        }
    }

    @ChartContentBuilder
    private var drawingPreviewMarks: some ChartContent {
        if let s = drawingStart {
            switch activeTool {
            case .none:
                RuleMark(y: .value("noop", s.price)).opacity(0)
            case .horizontalLine:
                RuleMark(y: .value("Preview", s.price))
                    .foregroundStyle(DrawingPalette.preview)
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 4]))
            case .trendLine:
                if let e = drawingEnd,
                   let xs = barIndex(forDate: s.date),
                   let xe = barIndex(forDate: e.date) {
                    LineMark(x: .value("Bar", xs), y: .value("Price", s.price),
                             series: .value("Preview", "drawing-preview"))
                    .foregroundStyle(DrawingPalette.preview)
                    .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [3, 3]))
                    LineMark(x: .value("Bar", xe), y: .value("Price", e.price),
                             series: .value("Preview", "drawing-preview"))
                    .foregroundStyle(DrawingPalette.preview)
                    .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [3, 3]))
                }
            case .rectangle:
                if let e = drawingEnd,
                   let xs = barIndex(forDate: s.date),
                   let xe = barIndex(forDate: e.date) {
                    RectangleMark(
                        xStart: .value("Preview X start", min(xs, xe)),
                        xEnd:   .value("Preview X end",   max(xs, xe)),
                        yStart: .value("Preview Y start", min(s.price, e.price)),
                        yEnd:   .value("Preview Y end",   max(s.price, e.price))
                    )
                    .foregroundStyle(DrawingPalette.fill.opacity(0.6))
                }
            case .volumeProfile:
                if let e = drawingEnd,
                   let xs = barIndex(forDate: s.date),
                   let xe = barIndex(forDate: e.date) {
                    RectangleMark(
                        xStart: .value("VP Preview x0", min(xs, xe)),
                        xEnd:   .value("VP Preview x1", max(xs, xe)),
                        yStart: .value("VP Preview y0", min(s.price, e.price)),
                        yEnd:   .value("VP Preview y1", max(s.price, e.price))
                    )
                    .foregroundStyle(DrawingPalette.fill.opacity(0.25))
                }
            }
        }
    }

    // MARK: - Indicator marks

    @ChartContentBuilder
    private func indicatorMarks(visible: Set<Int>) -> some ChartContent {
        let computed = derived.indicators(instances: indicators.map { IndicatorInstance(kind: $0) }, candles: candles)
        ForEach(computed, id: \.instance.id) { entry in
            ForEach(entry.points.filter { visible.contains($0.index) }) { p in
                LineMark(
                    x: .value("Bar", Double(p.index)),
                    y: .value("Indicator", p.value),
                    series: .value("Series", "\(entry.instance.kind.rawValue)-\(p.band)")
                )
                .foregroundStyle(indicatorColor(for: entry.instance.kind, band: p.band))
                .lineStyle(StrokeStyle(
                    lineWidth: p.band == "bb_mid" ? 1 : 1.6,
                    dash: p.band == "bb_mid" ? [3, 3] : []
                ))
                .interpolationMethod(.monotone)
            }
        }
    }

    private func indicatorColor(for kind: IndicatorKind, band: String) -> Color {
        switch band {
        case "bb_upper", "bb_lower": return kind.color
        case "bb_mid":               return kind.color.opacity(0.55)
        default:                     return kind.color
        }
    }

    // MARK: - UT Bot marks

    @ChartContentBuilder
    private func utBotMarks(indices: [Int], visible: Set<Int>) -> some ChartContent {
        if let out = utBotOutput {
            if indicatorConfig.utShowTrailingStop {
                ForEach(indices, id: \.self) { i in
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
            let cs = displayCandles
            ForEach(out.signals.filter { visible.contains($0.index) }) { sig in
                let c = cs[sig.index]
                PointMark(
                    x: .value("Bar", Double(sig.index)),
                    y: .value("Signal", sig.isBuy ? c.low : c.high)
                )
                .symbol(.circle)
                .symbolSize(0)
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

    // MARK: - Candle marks

    @ChartContentBuilder
    private func candleMarks(indices: [Int]) -> some ChartContent {
        let cs = displayCandles
        ForEach(indices, id: \.self) { i in
            let c = cs[i]
            RuleMark(
                x: .value("Bar", Double(i)),
                yStart: .value("Low", c.low),
                yEnd: .value("High", c.high)
            )
            .foregroundStyle(c.close >= c.open ? Theme.Color.success : Theme.Color.danger)
            .lineStyle(StrokeStyle(lineWidth: 1))

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
        AxisMarks(preset: .aligned, values: xAxisLabelValues) { value in
            AxisGridLine().foregroundStyle(Color.white.opacity(0.04))
            AxisTick().foregroundStyle(Color.white.opacity(0.08))
            AxisValueLabel {
                if let idx = value.as(Double.self),
                   let label = labelForIndex(idx) {
                    Text(label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.Color.textMuted)
                }
            }
        }
    }

    private var xAxisLabelValues: [Double] {
        let domain = effectiveXDomain
        let span = domain.upperBound - domain.lowerBound
        guard span > 0 else { return [] }
        let count = 6
        return (0...count).map { i in
            domain.lowerBound + (span * Double(i) / Double(count))
        }
    }

    private func labelForIndex(_ idx: Double) -> String? {
        let rounded = Int(idx.rounded())
        guard candles.indices.contains(rounded) else { return nil }
        return Self.axisFormatter.string(from: candles[rounded].bucketStart)
    }

    static let axisFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm"
        return f
    }()

    private func yAxis() -> some AxisContent {
        AxisMarks(position: .trailing, values: .automatic(desiredCount: 6)) { value in
            AxisGridLine().foregroundStyle(Color.white.opacity(0.04))
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
            .transition(.opacity.animation(.easeOut(duration: 0.1)))
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
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 40))
                .foregroundStyle(Theme.Color.textMuted)
            Text("No data for this timeframe")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Color.textSecondary)
            Text("Wait for the next fetch cycle.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Y domain

    private var effectiveYDomain: ClosedRange<Double> {
        yDomain ?? autoYDomain
    }

    private var autoYDomain: ClosedRange<Double> {
        // Bind the (memoized) display candles once — this runs every
        // horizontal-pan frame, and each `displayCandles` access re-enters
        // the cache lookup.
        let cs = displayCandles
        let bounds = ChartWindow.visibleBounds(domain: effectiveXDomain, count: cs.count)
        let visibleCandles: ArraySlice<Candle>
        if let b = bounds {
            visibleCandles = cs[b.lo ... b.hi]
        } else {
            visibleCandles = cs[...]
        }
        // Single pass for the low/high extremes instead of two throwaway
        // `.map` arrays per frame.
        var lo = Double.greatestFiniteMagnitude
        var hi = -Double.greatestFiniteMagnitude
        for c in visibleCandles {
            if c.low  < lo { lo = c.low }
            if c.high > hi { hi = c.high }
        }
        if visibleCandles.isEmpty { lo = 0; hi = 1 }

        if !indicators.isEmpty, let b = bounds {
            for entry in derived.indicators(instances: indicators.map { IndicatorInstance(kind: $0) }, candles: candles) {
                for p in entry.points where p.index >= b.lo && p.index <= b.hi {
                    if p.value < lo { lo = p.value }
                    if p.value > hi { hi = p.value }
                }
            }
        }

        if indicatorConfig.utShowTrailingStop,
           indicators.contains(.utBot),
           let b = bounds,
           let stops = utBotOutput?.trailingStop {
            for i in b.lo ... b.hi where i < stops.count {
                guard let v = stops[i] else { continue }
                if v < lo { lo = v }
                if v > hi { hi = v }
            }
        }

        // Overlay Y extremes — computed inline to avoid 11+ temporary
        // heap-array allocations per pan/zoom frame. The overlay data
        // (S/R levels, FVG zones, order blocks, drawings, trades, etc.)
        // doesn't change during a gesture — only the visible xDomain
        // does — so this scan is O(overlay points) per frame, typically
        // a few hundred comparisons, which is cheaper than the old
        // approach of .map-ing each source into a temporary array,
        // concatenating them, and passing to a cached resolve that
        // would short-circuit anyway.

        for level in srLevels.support {
            if level < lo { lo = level }
            if level > hi { hi = level }
        }
        for level in srLevels.resistance {
            if level < lo { lo = level }
            if level > hi { hi = level }
        }
        for zone in fvgZones {
            if zone.low < lo { lo = zone.low }
            if zone.high > hi { hi = zone.high }
        }
        for zone in supplyDemandZones {
            if zone.low < lo { lo = zone.low }
            if zone.high > hi { hi = zone.high }
        }
        for zone in indicatorFvgZones {
            if zone.low < lo { lo = zone.low }
            if zone.high > hi { hi = zone.high }
        }
        for zone in orderBlockZones {
            if zone.low < lo { lo = zone.low }
            if zone.high > hi { hi = zone.high }
        }
        for zone in steroidOrderBlockZones {
            if zone.low < lo { lo = zone.low }
            if zone.high > hi { hi = zone.high }
        }
        for zone in fvgFirstOBZones {
            if zone.low < lo { lo = zone.low }
            if zone.high > hi { hi = zone.high }
        }
        for run in sessionRuns {
            if run.low < lo { lo = run.low }
            if run.high > hi { hi = run.high }
        }
        for r in nySetupResults {
            if r.orLow < lo { lo = r.orLow }
            if r.orHigh > hi { hi = r.orHigh }
        }
        for session in volumeProfileSessions {
            for bucket in session.buckets {
                if bucket.priceLevel < lo { lo = bucket.priceLevel }
                if bucket.priceLevel > hi { hi = bucket.priceLevel }
            }
        }
        if let vp = zigzagTrendVP {
            for bucket in vp.buckets {
                if bucket.priceLevel < lo { lo = bucket.priceLevel }
                if bucket.priceLevel > hi { hi = bucket.priceLevel }
            }
        }
        for pivot in zigzagPivots {
            if pivot.price < lo { lo = pivot.price }
            if pivot.price > hi { hi = pivot.price }
        }
        if let scenario = taScenario {
            for v in [scenario.takeProfit, scenario.stopLoss] + [scenario.entry].compactMap({ $0 }) {
                if v < lo { lo = v }
                if v > hi { hi = v }
            }
        }
        if let alt = taAltScenario {
            for v in [alt.takeProfit, alt.stopLoss] + [alt.entry].compactMap({ $0 }) {
                if v < lo { lo = v }
                if v > hi { hi = v }
            }
        }
        for d in drawings where d.visible {
            if d.start.price < lo { lo = d.start.price }
            if d.start.price > hi { hi = d.start.price }
            if let e = d.end {
                if e.price < lo { lo = e.price }
                if e.price > hi { hi = e.price }
            }
        }
        for t in trades {
            for v in [t.entry, t.takeProfit, t.stopLoss, t.fillPrice ?? t.entry] {
                if v < lo { lo = v }
                if v > hi { hi = v }
            }
        }
        for je in journalEntries {
            for v in [je.entry, je.takeProfit, je.stopLoss].compactMap({ $0 }) {
                if v < lo { lo = v }
                if v > hi { hi = v }
            }
        }

        guard visibleCandles.isEmpty == false else { return 0...1 }
        let span = hi - lo
        if span <= 0 || visibleCandles.count == 1 {
            let pad = max(hi * 0.005, 1)
            return (lo - pad)...(hi + pad)
        }
        let pad = span * 0.05
        return (lo - pad)...(hi + pad)
    }

    // MARK: - Candle body width

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

    // MARK: - Drawing helpers

    private func barIndex(forDate date: Date) -> Double? {
        guard !candles.isEmpty else { return nil }
        let ts = date.timeIntervalSince1970
        var lo = 0
        var hi = candles.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if candles[mid].bucketStart.timeIntervalSince1970 < ts {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        if lo > 0 {
            let dLo = abs(candles[lo].bucketStart.timeIntervalSince(date))
            let dPrev = abs(candles[lo - 1].bucketStart.timeIntervalSince(date))
            if dPrev < dLo { return Double(lo - 1) }
        }
        return Double(lo)
    }

    private func barIndex(closestTo date: Date) -> Int? {
        guard !candles.isEmpty else { return nil }
        let ts = date.timeIntervalSince1970
        var lo = 0
        var hi = candles.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if candles[mid].bucketStart.timeIntervalSince1970 < ts {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        if lo > 0 {
            let dLo = abs(candles[lo].bucketStart.timeIntervalSince(date))
            let dPrev = abs(candles[lo - 1].bucketStart.timeIntervalSince(date))
            if dPrev < dLo { return lo - 1 }
        }
        return lo
    }

    private func barIndexForEntryPrice(_ price: Double, before fromIndex: Int) -> Int? {
        guard fromIndex >= 0, fromIndex < candles.count else { return nil }
        for i in stride(from: fromIndex, through: 0, by: -1) {
            let c = candles[i]
            if price >= c.low && price <= c.high { return i }
        }
        return nil
    }

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

    // MARK: - Formatting

    static func priceShort(_ v: Double) -> String {
        let abs = Swift.abs(v)
        if abs >= 1_000_000_000 { return String(format: "%.2fB", v / 1_000_000_000) }
        if abs >= 1_000_000     { return String(format: "%.2fM", v / 1_000_000) }
        if abs >= 10_000        { return String(format: "%.0fK", v / 1_000) }
        if abs >= 100           { return v.formatted(.number.precision(.fractionLength(0))) }
        if abs >= 1             { return v.formatted(.number.precision(.fractionLength(2))) }
        return String(format: "%.4f", v)
    }

    static func priceExact(_ v: Double) -> String {
        let abs = Swift.abs(v)
        let digits: Int
        if abs >= 1_000_000 { digits = 0 }
        else if abs >= 100  { digits = 2 }
        else if abs >= 1    { digits = 4 }
        else                { digits = 5 }
        return v.formatted(.number.precision(.fractionLength(digits)))
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d · HH:mm"
        return f
    }()
}
