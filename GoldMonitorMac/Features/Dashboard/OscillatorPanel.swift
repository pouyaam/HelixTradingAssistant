import SwiftUI
import Charts

/// One oscillator rendered as a thin sub-chart underneath the price
/// chart. Each kind has its own Y scale (0-100 for RSI/Stoch, auto for
/// MACD) and per-kind reference lines (overbought / oversold for RSI &
/// Stochastic; zero baseline for MACD).
///
/// X axis is hidden — the main chart's X axis labels the time for the
/// whole stack via shared `xDomain`.
struct OscillatorPanel: View {
    let instance: OscillatorInstance
    let candles: [Candle]
    /// Same bar-index domain the price chart uses; lets pan/zoom on the
    /// price chart move this panel in lock-step.
    @Binding var xDomain: ClosedRange<Double>?
    @Binding var hoverCrosshairX: Double?

    /// Memoizes this panel's oscillator computation so a pan/zoom (which
    /// only changes `xDomain`) doesn't re-run RSI/MACD/Stoch over the
    /// full history every frame, and runs the recompute on a background
    /// `Task` so it never blocks the UI. `@StateObject` so a background
    /// task's `objectWillChange` actually triggers a redraw. See
    /// `ChartDerivedCache`.
    @StateObject private var derived = ChartDerivedCache()

    @State private var manualYDomain: ClosedRange<Double>? = nil
    @State private var yScaleStartDomain: ClosedRange<Double>? = nil
    @State private var customHeight: CGFloat? = nil
    @State private var startHeight: CGFloat? = nil

    private var defaultHeight: CGFloat {
        instance.kind == .helixOBCombo ? 150 : 90
    }

    private var currentHeight: CGFloat {
        customHeight ?? defaultHeight
    }

    var body: some View {
        let pts = visiblePoints
        let domain = effectiveDomain
        let yDom = effectiveYDomain(pts: pts)

        VStack(alignment: .leading, spacing: 2) {
            resizeDividerBar

            HStack(spacing: 6) {
                Text(instance.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Color.textSecondary)
                Spacer()
                latestReadout
            }
            .padding(.top, 2)

            Chart {
                ForEach(
                    ChartWindow.dayBoundaryPositions(candles: candles, domain: domain),
                    id: \.self
                ) { x in
                    RuleMark(x: .value("Day boundary", x))
                        .foregroundStyle(Theme.Color.textMuted.opacity(0.20))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }

                marks(pts: pts)
                referenceLines

                if let hx = hoverCrosshairX {
                    RuleMark(x: .value("Hover X", hx))
                        .foregroundStyle(Color.white.opacity(0.20))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartXScale(domain: domain)
            .chartYScale(domain: yDom)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: yAxisValues(for: yDom)) { value in
                    AxisGridLine().foregroundStyle(Theme.Color.border.opacity(0.5))
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(yLabel(v))
                                .font(.system(size: 8, weight: .medium).monospacedDigit())
                                .foregroundStyle(Theme.Color.textMuted)
                                .frame(width: 50, alignment: .trailing)
                        }
                    }
                }
            }
            .overlay(alignment: .trailing) {
                yAxisScaleStrip(plotHeight: currentHeight)
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                let plotFrame = geo[proxy.plotAreaFrame]
                                let origin = plotFrame.origin
                                let x = location.x - origin.x
                                if let xValue: Double = proxy.value(atX: x) {
                                    let idx = max(0, min(candles.count - 1, Int(xValue.rounded())))
                                    if hoverCrosshairX != Double(idx) {
                                        hoverCrosshairX = Double(idx)
                                    }
                                }
                            case .ended:
                                hoverCrosshairX = nil
                            }
                        }
                }
            }
            #if os(macOS)
            .scrollZoom(xDomain: $xDomain, totalCandles: candles.count)
            #endif
            .frame(height: currentHeight)
            .clipped()
        }
    }

    // MARK: - Panel Height Resize Splitter Bar

    private var resizeDividerBar: some View {
        ZStack {
            Rectangle()
                .fill(Theme.Color.border.opacity(0.35))
                .frame(height: 1)
            Rectangle()
                .fill(Color.clear)
                .frame(height: 8)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if startHeight == nil {
                                startHeight = currentHeight
                            }
                            guard let start = startHeight else { return }
                            let newH = start - value.translation.height
                            customHeight = min(max(newH, 60), 450)
                        }
                        .onEnded { _ in startHeight = nil }
                )
                .onTapGesture(count: 2) { customHeight = nil }
                #if os(macOS)
                .onHover { inside in
                    if inside { NSCursor.resizeUpDown.push() }
                    else      { NSCursor.pop() }
                }
                #endif
        }
    }

    // MARK: - Y-Axis Scale Strip & Gesture

    private func yAxisScaleStrip(plotHeight: CGFloat) -> some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .gesture(priceScaleDrag(plotHeight: plotHeight))
                .onTapGesture(count: 2) { manualYDomain = nil }
                #if os(macOS)
                .onHover { inside in
                    if inside { NSCursor.resizeUpDown.push() }
                    else      { NSCursor.pop() }
                }
                #endif
        }
        .frame(width: 50)
    }

    private func priceScaleDrag(plotHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if yScaleStartDomain == nil {
                    let pts = visiblePoints
                    yScaleStartDomain = effectiveYDomain(pts: pts)
                }
                guard let start = yScaleStartDomain, plotHeight > 0 else { return }
                let center = (start.lowerBound + start.upperBound) / 2
                let halfSpan = (start.upperBound - start.lowerBound) / 2
                guard halfSpan > 0 else { return }
                let raw = exp(Double(value.translation.height) / Double(plotHeight) * 1.6)
                let factor = min(max(raw, 0.1), 10)
                let newHalf = halfSpan * factor
                manualYDomain = (center - newHalf) ... (center + newHalf)
            }
            .onEnded { _ in yScaleStartDomain = nil }
    }

    private func effectiveYDomain(pts: [IndicatorPoint]) -> ClosedRange<Double> {
        if let manual = manualYDomain { return manual }
        return yDomainForPoints(pts)
    }

    // MARK: - Marks dispatch

    @ChartContentBuilder
    private func marks(pts: [IndicatorPoint]) -> some ChartContent {
        switch instance.kind {
        case .rsi:
            ForEach(pts) { p in
                LineMark(
                    x: .value("Bar", Double(p.index)),
                    y: .value("RSI", p.value),
                    series: .value("Series", "rsi")
                )
                .foregroundStyle(rsiColor)
                .lineStyle(StrokeStyle(lineWidth: 1.4))
                .interpolationMethod(.monotone)
            }
        case .macd:
            ForEach(pts) { p in
                if p.band == "histogram" {
                    BarMark(
                        x: .value("Bar", Double(p.index)),
                        y: .value("Hist", p.value)
                    )
                    .foregroundStyle((p.value >= 0
                                       ? Theme.Color.success
                                       : Theme.Color.danger).opacity(0.6))
                } else {
                    LineMark(
                        x: .value("Bar", Double(p.index)),
                        y: .value("MACD", p.value),
                        series: .value("Series", p.band)
                    )
                    .foregroundStyle(p.band == "macd" ? macdLineColor : signalColor)
                    .lineStyle(StrokeStyle(lineWidth: p.band == "macd" ? 1.4 : 1.2))
                    .interpolationMethod(.monotone)
                }
            }
        case .stochastic:
            ForEach(pts) { p in
                LineMark(
                    x: .value("Bar", Double(p.index)),
                    y: .value("%", p.value),
                    series: .value("Series", p.band)
                )
                .foregroundStyle(p.band == "k" ? stochKColor : stochDColor)
                .lineStyle(StrokeStyle(lineWidth: p.band == "k" ? 1.4 : 1.2))
                .interpolationMethod(.monotone)
            }
        case .helixOBCombo:
            let out = derived.helixOBCombo(candles: candles, params: instance.params)
            let isHA = instance.params["heikenAshi"]?.boolValue ?? false
            let subCandles = isHA ? HeikinAshi.transform(candles) : candles
            let lastIndex = max(0, subCandles.count - 1)
            let visibleIndices = ChartWindow.renderIndices(domain: effectiveDomain, count: subCandles.count)

            // A) Sub-panel Candlesticks (Normal or Heikin Ashi)
            ForEach(visibleIndices, id: \.self) { i in
                if i >= 0 && i < subCandles.count {
                    let c = subCandles[i]
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
                        width: .fixed(3)
                    )
                    .foregroundStyle(c.close >= c.open ? Theme.Color.success : Theme.Color.danger)
                    .cornerRadius(1)
                }
            }

            // B) Volumetric Order Blocks
            ForEach(out.bullishOBs + out.bearishOBs) { ob in
                let baseColor: Color = ob.isBullish ? Theme.Color.success : Theme.Color.danger
                let xStart = Double(ob.barStart)
                let xEnd = Double(lastIndex)

                RectangleMark(
                    xStart: .value("HelixOB x0", xStart), xEnd: .value("HelixOB x1", xEnd),
                    yStart: .value("HelixOB y0", ob.btm), yEnd: .value("HelixOB y1", ob.top)
                )
                .foregroundStyle(baseColor.opacity(0.18))

                RuleMark(xStart: .value("HelixOB t0", xStart), xEnd: .value("HelixOB t1", xEnd), y: .value("HelixOB top", ob.top))
                    .foregroundStyle(baseColor.opacity(0.70))
                RuleMark(xStart: .value("HelixOB b0", xStart), xEnd: .value("HelixOB b1", xEnd), y: .value("HelixOB bot", ob.btm))
                    .foregroundStyle(baseColor.opacity(0.70))

                RuleMark(xStart: .value("HelixOB m0", xStart), xEnd: .value("HelixOB m1", xEnd), y: .value("HelixOB mid", ob.mid))
                    .foregroundStyle(Color.gray.opacity(0.50))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))

                let totalStr = ob.bullishStr + ob.bearishStr
                if totalStr > 0 {
                    let span = max(1.0, xEnd - xStart)
                    let maxW = min(span * 0.5, 12.0)
                    let bullW = maxW * (ob.bullishStr / totalStr)
                    let bearW = maxW * (ob.bearishStr / totalStr)

                    RectangleMark(
                        xStart: .value("HelixOB uv0", xStart), xEnd: .value("HelixOB uv1", xStart + bullW),
                        yStart: .value("HelixOB uvy0", ob.mid), yEnd: .value("HelixOB uvy1", ob.top)
                    )
                    .foregroundStyle(Theme.Color.success.opacity(0.45))

                    RectangleMark(
                        xStart: .value("HelixOB dv0", xStart), xEnd: .value("HelixOB dv1", xStart + bearW),
                        yStart: .value("HelixOB dvy0", ob.btm), yEnd: .value("HelixOB dvy1", ob.mid)
                    )
                    .foregroundStyle(Theme.Color.danger.opacity(0.45))

                    let sepX = xStart + max(bullW, bearW)
                    RuleMark(
                        x: .value("HelixOB sepX", sepX),
                        yStart: .value("HelixOB sepY0", ob.btm),
                        yEnd: .value("HelixOB sepY1", ob.top)
                    )
                    .foregroundStyle(Color.gray.opacity(0.60))
                }
            }

            // C) MSB / BOS Structure Lines
            ForEach(out.structures) { s in
                let color: Color = s.isBullish ? Theme.Color.success : Theme.Color.danger
                RuleMark(
                    xStart: .value("HelixMSB x0", Double(s.x1)),
                    xEnd: .value("HelixMSB x1", Double(s.x2)),
                    y: .value("HelixMSB y", s.y1)
                )
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1))

                PointMark(x: .value("HelixMSB midX", Double(s.x1 + s.x2) / 2.0), y: .value("HelixMSB midY", s.y1))
                    .symbolSize(0)
                    .annotation(position: s.isBullish ? .bottom : .top, alignment: .center, spacing: 2) {
                        Text(s.label)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(color)
                    }
            }

            let visibleSet = Set(visibleIndices)
            let visiblePoints = out.points.filter { visibleSet.contains($0.index) }
            let visibleEMAPoints = out.emaPoints.filter { visibleSet.contains($0.index) }
            let visibleSignals = out.signals.filter { visibleSet.contains($0.index) }

            // D) Long / Short ATR Stop lines
            let plotStops = instance.params["plotLongShortStop"]?.boolValue ?? false
            if plotStops {
                ForEach(visiblePoints) { pt in
                    if let ls = pt.longStop {
                        LineMark(
                            x: .value("Bar", Double(pt.index)),
                            y: .value("Helix Long Stop", ls),
                            series: .value("Series", "helix-longstop")
                        )
                        .foregroundStyle(Theme.Color.success)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.stepStart)
                    }
                    if let ss = pt.shortStop {
                        LineMark(
                            x: .value("Bar", Double(pt.index)),
                            y: .value("Helix Short Stop", ss),
                            series: .value("Series", "helix-shortstop")
                        )
                        .foregroundStyle(Theme.Color.danger)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.stepStart)
                    }
                }
            }

            // E) EMA Filter Line
            ForEach(visibleEMAPoints) { p in
                LineMark(
                    x: .value("Bar", Double(p.index)),
                    y: .value("Helix EMA", p.value),
                    series: .value("Series", "helix-ema")
                )
                .foregroundStyle(Color.orange.opacity(0.85))
                .lineStyle(StrokeStyle(lineWidth: 1.2))
            }

            // F) Buy / Sell / MACD Signals
            ForEach(visibleSignals) { sig in
                if sig.index >= 0 && sig.index < subCandles.count {
                    let c = subCandles[sig.index]
                    PointMark(
                        x: .value("Bar", Double(sig.index)),
                        y: .value("Helix Signal", sig.isBuy ? c.low : c.high)
                    )
                    .symbol(.circle)
                    .symbolSize(sig.isMACD ? 20 : 0)
                    .foregroundStyle(sig.isBuy ? Theme.Color.success : Theme.Color.danger)
                    .annotation(
                        position: sig.isBuy ? .bottom : .top,
                        alignment: .center,
                        spacing: 2
                    ) {
                        if !sig.isMACD {
                            Text(sig.isBuy ? "Buy" : "Sell")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(sig.isBuy ? Theme.Color.success : Theme.Color.danger))
                        }
                    }
                }
            }
        }
    }

    /// Horizontal reference lines specific to each oscillator.
    @ChartContentBuilder
    private var referenceLines: some ChartContent {
        switch instance.kind {
        case .rsi:
            RuleMark(y: .value("Overbought", 70))
                .foregroundStyle(Theme.Color.danger.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
            RuleMark(y: .value("Oversold", 30))
                .foregroundStyle(Theme.Color.success.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
        case .stochastic:
            RuleMark(y: .value("Overbought", 80))
                .foregroundStyle(Theme.Color.danger.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
            RuleMark(y: .value("Oversold", 20))
                .foregroundStyle(Theme.Color.success.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
        case .macd:
            RuleMark(y: .value("Zero", 0))
                .foregroundStyle(Theme.Color.border.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 0.6))
        case .helixOBCombo:
            // No static percentage reference lines for price sub-panel
            RuleMark(y: .value("Zero", 0)).foregroundStyle(Color.clear)
        }
    }

    // MARK: - Latest readout (top-right label)

    @ViewBuilder
    private var latestReadout: some View {
        let pts = computedPoints
        switch instance.kind {
        case .rsi:
            if let last = pts.last {
                Text(String(format: "%.1f", last.value))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(rsiColor)
            }
        case .macd:
            if let macd = pts.last(where: { $0.band == "macd" }),
               let sig  = pts.last(where: { $0.band == "signal" }) {
                HStack(spacing: 8) {
                    label("MACD", String(format: "%.2f", macd.value), color: macdLineColor)
                    label("SIG",  String(format: "%.2f", sig.value),  color: signalColor)
                }
            }
        case .stochastic:
            if let k = pts.last(where: { $0.band == "k" }),
               let d = pts.last(where: { $0.band == "d" }) {
                HStack(spacing: 8) {
                    label("%K", String(format: "%.1f", k.value), color: stochKColor)
                    label("%D", String(format: "%.1f", d.value), color: stochDColor)
                }
            }
        case .helixOBCombo:
            let isHA = instance.params["heikenAshi"]?.boolValue ?? false
            let subCandles = isHA ? HeikinAshi.transform(candles) : candles
            if let last = subCandles.last {
                HStack(spacing: 6) {
                    Text(isHA ? "HA" : "Normal")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.Color.info)
                    Text(ChartView.priceExact(last.close))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(last.close >= last.open ? Theme.Color.success : Theme.Color.danger)
                }
            }
        }
    }

    private func label(_ key: String, _ value: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.Color.textMuted)
            Text(value)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
        }
    }

    // MARK: - Compute

    /// Memoized oscillator series. Cached against the candle data +
    /// config so repeated reads within a frame (marks, yDomain, readout)
    /// and across pan/zoom frames reuse one computation instead of
    /// re-running it over the full history each time.
    private var computedPoints: [IndicatorPoint] {
        if instance.kind == .helixOBCombo { return [] }
        return derived.oscillatorPoints(kind: instance.kind, candles: candles, config: oscillatorConfigFromParams(instance.params))
    }

    /// Build an OscillatorConfig from per-instance params for the cache
    /// to use (the shared cache slot already keys on the individual
    /// int fields, so the extra config fields are harmless).
    private func oscillatorConfigFromParams(_ params: [String: ParamValue]) -> OscillatorConfig {
        var c = OscillatorConfig()
        if let v = params["period"] { c.rsiPeriod = Int(v.doubleValue); c.stochK = Int(v.doubleValue) }
        if let v = params["fast"]   { c.macdFast = Int(v.doubleValue) }
        if let v = params["slow"]   { c.macdSlow = Int(v.doubleValue) }
        if let v = params["signal"] { c.macdSignal = Int(v.doubleValue) }
        if let v = params["k"]      { c.stochK = Int(v.doubleValue) }
        if let v = params["d"]      { c.stochD = Int(v.doubleValue) }
        return c
    }

    // ── Visible-points memoization ───────────────────────────────────
    //
    // `visiblePoints` filters `computedPoints` to the visible bar
    // window. Previously it rebuilt a `Set<Int>` from
    // `renderIndices` + filtered the full array on every body eval.
    // In grid mode with 4 panes × 2 oscillators = 8 calls per tick,
    // that's 8 Set allocations + 8 full-array filters per frame.
    //
    // Cache keyed on (domain bounds, candle count, computed count).
    // During pan/zoom only the domain changes — the Set rebuild is
    // still O(visible bars), but the filter is skipped when the
    // domain is unchanged (e.g. on a tick where no new bar arrived).

    private struct VisiblePointsCache {
        let domainLo: Double
        let domainHi: Double
        let candleCount: Int
        let computedCount: Int
        let points: [IndicatorPoint]
    }
    /// Class box to avoid "Modifying state during view update" —
    /// `visiblePoints` is a computed property called from `body`.
    private final class VisiblePointsCacheBox {
        var cached: VisiblePointsCache?
    }
    private let _vpCacheBox = VisiblePointsCacheBox()

    /// computedPoints restricted to the bar indices actually rendered
    /// this frame — keeps mark count bounded on deep history, matching
    /// the price chart's windowing. Latest-value readouts still read the
    /// full series so they never go stale when zoomed in.
    private var visiblePoints: [IndicatorPoint] {
        let domain = effectiveDomain
        let computed = computedPoints
        let cacheKey = VisiblePointsCache(
            domainLo: domain.lowerBound,
            domainHi: domain.upperBound,
            candleCount: candles.count,
            computedCount: computed.count,
            points: []
        )
        if let cached = _vpCacheBox.cached,
           cached.domainLo == cacheKey.domainLo,
           cached.domainHi == cacheKey.domainHi,
           cached.candleCount == cacheKey.candleCount,
           cached.computedCount == cacheKey.computedCount {
            return cached.points
        }
        let set = Set(ChartWindow.renderIndices(domain: domain, count: candles.count))
        let result = computed.filter { set.contains($0.index) }
        _vpCacheBox.cached = VisiblePointsCache(
            domainLo: cacheKey.domainLo,
            domainHi: cacheKey.domainHi,
            candleCount: cacheKey.candleCount,
            computedCount: cacheKey.computedCount,
            points: result
        )
        return result
    }

    // MARK: - Scales

    private var effectiveDomain: ClosedRange<Double> {
        if let d = xDomain { return d }
        return ChartWindow.defaultDomain(count: candles.count)
    }

    private func yDomainForPoints(_ pts: [IndicatorPoint]) -> ClosedRange<Double> {
        switch instance.kind {
        case .rsi, .stochastic:
            return 0 ... 100
        case .macd:
            let values = pts.map(\.value)
            let lo = values.min() ?? -1
            let hi = values.max() ?? 1
            let span = max(hi - lo, 0.001)
            let pad = span * 0.1
            return (lo - pad) ... (hi + pad)
        case .helixOBCombo:
            let out = derived.helixOBCombo(candles: candles, params: instance.params)
            let isHA = instance.params["heikenAshi"]?.boolValue ?? false
            let subCandles = isHA ? HeikinAshi.transform(candles) : candles
            let visibleIndices = Set(ChartWindow.renderIndices(domain: effectiveDomain, count: subCandles.count))

            var lo = Double.greatestFiniteMagnitude
            var hi = -Double.greatestFiniteMagnitude

            for i in visibleIndices {
                if i >= 0 && i < subCandles.count {
                    let c = subCandles[i]
                    if c.low < lo { lo = c.low }
                    if c.high > hi { hi = c.high }
                }
            }
            for ob in out.bullishOBs + out.bearishOBs {
                if ob.btm < lo { lo = ob.btm }
                if ob.top > hi { hi = ob.top }
            }
            for pt in out.points {
                if visibleIndices.contains(pt.index) {
                    if let ls = pt.longStop { if ls < lo { lo = ls }; if ls > hi { hi = ls } }
                    if let ss = pt.shortStop { if ss < lo { lo = ss }; if ss > hi { hi = ss } }
                }
            }
            if lo >= hi { lo = 0; hi = 1 }
            let span = max(hi - lo, 0.01)
            let pad = span * 0.05
            return (lo - pad) ... (hi + pad)
        }
    }

    private func yAxisValues(for yDom: ClosedRange<Double>) -> [Double] {
        switch instance.kind {
        case .rsi:        return [30, 50, 70]
        case .stochastic: return [20, 50, 80]
        case .macd:       return [yDom.lowerBound, 0, yDom.upperBound]
        case .helixOBCombo:
            let mid = (yDom.lowerBound + yDom.upperBound) / 2
            return [yDom.lowerBound, mid, yDom.upperBound]
        }
    }

    private func yLabel(_ v: Double) -> String {
        switch instance.kind {
        case .rsi, .stochastic:
            return String(format: "%.0f", v)
        case .macd:
            return String(format: "%.2f", v)
        case .helixOBCombo:
            return ChartView.priceShort(v)
        }
    }

    // MARK: - Colors

    private var rsiColor:    Color { Color(red: 1.00, green: 0.78, blue: 0.20) }
    private var macdLineColor: Color { Color(red: 0.38, green: 0.65, blue: 1.00) }
    private var signalColor:   Color { Color(red: 1.00, green: 0.45, blue: 0.65) }
    private var stochKColor:   Color { Color(red: 0.38, green: 0.65, blue: 1.00) }
    private var stochDColor:   Color { Color(red: 1.00, green: 0.45, blue: 0.65) }
}

/// See `ChartView`'s `Equatable` note — same rationale, scoped to one
/// oscillator sub-chart. In grid mode each pane can stack several of
/// these, so gating their re-layout on actual input changes (not on every
/// live tick that ripples through the pane) is a big part of the
/// split-screen win. The oscillator math itself is already memoized by
/// this view's own `ChartDerivedCache`; this stops the Charts *layout*
/// pass from running needlessly on top of that.
extension OscillatorPanel: Equatable {
    static func == (l: OscillatorPanel, r: OscillatorPanel) -> Bool {
        l.instance == r.instance
            && Candle.seriesEqual(l.candles, r.candles)
            && l.xDomain == r.xDomain
            && l.hoverCrosshairX == r.hoverCrosshairX
    }
}
