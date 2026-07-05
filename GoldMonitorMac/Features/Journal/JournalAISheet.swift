import SwiftUI

/// AI post-mortem sheet for a journal entry. Two panels:
///   • Config  — engine / model / effort selection + trade snapshot
///   • Result  — price-level ruler, trade metrics, and parsed insight cards
struct JournalAISheet: View {
    let entry: JournalEntry
    @EnvironmentObject private var journal: JournalStore
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    // ── Candle data for the price ruler ──────────────────────────
    @State private var tradingCandles: [OHLCBar] = []

    // ── Engine / model / effort ───────────────────────────────────
    @State private var engineKind: AIEngineKind = {
        let raw = UserDefaults.standard.string(forKey: "ai.journal.engine") ?? "claude"
        return AIEngineKind(rawValue: raw) ?? .claude
    }()
    @State private var claudeModelID  = UserDefaults.standard.string(forKey: "ai.claude.model")  ?? ClaudeModelCatalog.defaultModelID
    @State private var claudeEffortID = UserDefaults.standard.string(forKey: "ai.claude.effort") ?? ClaudeModelCatalog.defaultEffortID
    @State private var codexModelID    = UserDefaults.standard.string(forKey: "ai.codex.model")    ?? CodexModelCatalog.defaultModelID
    @State private var codexEffortID   = UserDefaults.standard.string(forKey: "ai.codex.effort")   ?? CodexModelCatalog.defaultEffortID
    @State private var opencodeModelID = UserDefaults.standard.string(forKey: "ai.opencode.model") ?? OpenCodeModelCatalog.defaultModelID

    // ── Stream state ──────────────────────────────────────────────
    @State private var thinking   = ""
    @State private var output     = ""
    @State private var isRunning  = false
    @State private var error: String? = nil
    @State private var streamTask: Task<Void, Never>? = nil
    @State private var showThinking = false
    @State private var savedToJournal = false

    // ── Layout ────────────────────────────────────────────────────
    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider().background(Theme.Color.border)
            if output.isEmpty && !isRunning && error == nil {
                configPanel
            } else {
                resultPanel
            }
        }
        .frame(width: 740, height: 660)
        .background(Theme.Color.canvas)
        .onDisappear { streamTask?.cancel() }
        .task { await loadTradingCandles() }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: – Header
    // ═══════════════════════════════════════════════════════════════

    private var sheetHeader: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(entry.result.color.opacity(0.15))
                    .frame(width: 38, height: 38)
                Image(systemName: entry.result.icon)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(entry.result.color)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("AI Trade Review")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(entry.title.isEmpty ? entry.pairName : entry.title)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textMuted)
                    .lineLimit(1)
            }
            Spacer()
            if entry.profitLoss != 0 {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(String(format: "%+.2f", entry.profitLoss))
                        .font(.system(size: 16, weight: .bold).monospacedDigit())
                        .foregroundStyle(entry.profitLoss >= 0 ? Theme.Color.success : Theme.Color.danger)
                    Text("P / L")
                        .font(.system(size: 8, weight: .bold)).tracking(0.5)
                        .foregroundStyle(Theme.Color.textMuted)
                }
            }
            resultBadge(entry.result)
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.Color.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: – Config panel
    // ═══════════════════════════════════════════════════════════════

    private var configPanel: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            // Price ruler always visible in config
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                priceLevelRuler
                    .frame(maxWidth: .infinity)
                tradeMetricsCard
                    .frame(width: 180)
            }
            .frame(height: 160)

            Divider().background(Theme.Color.border)

            sectionLabel("ENGINE")
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(AIEngineKind.allCases) { kind in
                    engineChip(kind: kind, engine: AIEngineFactory.make(kind))
                }
                Spacer()
            }
            if engineKind == .claude {
                modelEffortPicker(models: ClaudeModelCatalog.models,
                                  efforts: ClaudeModelCatalog.efforts,
                                  selectedModel: $claudeModelID,
                                  selectedEffort: $claudeEffortID)
            } else if engineKind == .codex {
                modelEffortPicker(models: CodexModelCatalog.models,
                                  efforts: CodexModelCatalog.efforts,
                                  selectedModel: $codexModelID,
                                  selectedEffort: $codexEffortID)
            } else {
                opencodeModelPicker
            }
            Spacer()
            HStack {
                Spacer()
                let engine = AIEngineFactory.make(engineKind)
                Button { startAnalysis() } label: {
                    Label("Analyze Trade", systemImage: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 9).fill(
                            engine.availability.canRun
                            ? AnyShapeStyle(Theme.accentGradient)
                            : AnyShapeStyle(Color.gray.opacity(0.3))))
                }
                .buttonStyle(.plain)
                .disabled(!engine.availability.canRun)
            }
        }
        .padding(Theme.Spacing.lg)
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: – Result panel
    // ═══════════════════════════════════════════════════════════════

    private var resultPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                // Trade snapshot row
                HStack(alignment: .top, spacing: Theme.Spacing.md) {
                    priceLevelRuler.frame(maxWidth: .infinity)
                    tradeMetricsCard.frame(width: 180)
                }
                .frame(height: 160)

                Divider().background(Theme.Color.border)

                if !thinking.isEmpty { thinkingDisclosure }

                if isRunning && output.isEmpty {
                    analyzingSpinner
                } else {
                    parsedSections
                }

                if let err = error {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Color.danger)
                }

                actionRow
            }
            .padding(Theme.Spacing.lg)
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: – Price Level Ruler (custom SwiftUI, no Apple Charts)
    // ═══════════════════════════════════════════════════════════════

    // Represents one named price level to draw on the ruler.
    private struct PriceLevel {
        let label: String
        let price: Double
        let color: Color
        let lineWidth: CGFloat
        let dashed: Bool
    }

    private var priceLevels: [PriceLevel] {
        var levels: [PriceLevel] = []
        if let tp = entry.takeProfit {
            levels.append(.init(label: "TP",    price: tp, color: Theme.Color.success,     lineWidth: 1.5, dashed: false))
        }
        if let e = entry.entry {
            levels.append(.init(label: "ENTRY", price: e,  color: Theme.Color.textSecondary, lineWidth: 1.5, dashed: true))
        }
        if let cp = entry.closePrice {
            levels.append(.init(label: "CLOSE", price: cp, color: Theme.Color.accentStart,  lineWidth: 2,   dashed: false))
        }
        if let sl = entry.stopLoss {
            levels.append(.init(label: "SL",    price: sl, color: Theme.Color.danger,       lineWidth: 1.5, dashed: false))
        }
        return levels
    }

    private var rulerRange: (lo: Double, hi: Double) {
        var prices = priceLevels.map(\.price)
        // Include candle extremes so bars don't overflow the ruler
        if !tradingCandles.isEmpty {
            prices += tradingCandles.map(\.low) + tradingCandles.map(\.high)
        }
        let lo = prices.min() ?? 0
        let hi = prices.max() ?? 1
        // Always guarantee a visible spread of at least 1 pip (for single-level or collapsed entries)
        let span = max(hi - lo, max(lo * 0.001, 1.0))
        let pad  = span * 0.12
        return (lo - pad, hi + pad)
    }

    private func yFraction(_ price: Double) -> Double {
        let r = rulerRange
        guard r.hi > r.lo else { return 0.5 }
        // Y=0 → top (hi), Y=1 → bottom (lo): invert so higher price = higher on screen
        return 1.0 - (price - r.lo) / (r.hi - r.lo)
    }

    private var priceLevelRuler: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PRICE LEVELS")
                .font(.system(size: 9, weight: .bold)).tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)

            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let r = rulerRange

                ZStack(alignment: .topLeading) {
                    // Background card
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(Theme.Color.surfaceHi)

                    // Mini candlestick chart behind the level lines
                    if !tradingCandles.isEmpty {
                        let chartLeft: CGFloat = 48
                        let chartRight: CGFloat = w - 88
                        let chartW = max(chartRight - chartLeft, 1)
                        let candleCount = CGFloat(tradingCandles.count)
                        let barW = max(1, chartW / candleCount)
                        let wickW: CGFloat = max(0.5, barW * 0.15)

                        ForEach(Array(tradingCandles.enumerated()), id: \.offset) { i, bar in
                            let x = chartLeft + (CGFloat(i) + 0.5) * (chartW / candleCount)
                            let bullish = bar.close >= bar.open
                            let color = bullish
                                ? Color(red: 0.25, green: 0.72, blue: 0.47).opacity(0.75)
                                : Color(red: 0.90, green: 0.35, blue: 0.35).opacity(0.75)
                            let bodyTop    = CGFloat(yFraction(max(bar.open, bar.close))) * h
                            let bodyBottom = CGFloat(yFraction(min(bar.open, bar.close))) * h
                            let bodyH      = max(1, bodyBottom - bodyTop)
                            let wickTop    = CGFloat(yFraction(bar.high)) * h
                            let wickBottom = CGFloat(yFraction(bar.low))  * h

                            // Wick
                            Path { p in
                                p.move(to:    CGPoint(x: x, y: wickTop))
                                p.addLine(to: CGPoint(x: x, y: wickBottom))
                            }
                            .stroke(color, lineWidth: wickW)

                            // Body
                            Rectangle()
                                .fill(color)
                                .frame(width: max(1, barW - 1), height: bodyH)
                                .position(x: x, y: bodyTop + bodyH / 2)
                        }
                    }

                    // Profit zone fill (between entry and TP / close, whichever is higher for long)
                    if let e = entry.entry {
                        let exitPrice = entry.closePrice ?? entry.takeProfit
                        if let ex = exitPrice {
                            let profitTop    = CGFloat(yFraction(max(e, ex))) * h
                            let profitBottom = CGFloat(yFraction(min(e, ex))) * h
                            let profitHeight = max(2, profitBottom - profitTop)
                            let won = (entry.side == .long && ex >= e) || (entry.side == .short && ex <= e)
                            Rectangle()
                                .fill((won ? Theme.Color.success : Theme.Color.danger).opacity(0.09))
                                .frame(width: w, height: profitHeight)
                                .offset(y: profitTop)
                        }
                    }

                    // Y-axis grid labels (4 ticks)
                    let gridCount = 4
                    ForEach(0...gridCount, id: \.self) { i in
                        let frac = Double(i) / Double(gridCount)
                        let price = r.hi - frac * (r.hi - r.lo)
                        let yPos  = CGFloat(frac) * h
                        // Grid line
                        Path { p in
                            p.move(to:    CGPoint(x: 44, y: yPos))
                            p.addLine(to: CGPoint(x: w - 90, y: yPos))
                        }
                        .stroke(Theme.Color.border, lineWidth: 0.5)
                        // Price label on the left
                        Text(compactPrice(price))
                            .font(.system(size: 8).monospacedDigit())
                            .foregroundStyle(Theme.Color.textMuted)
                            .frame(width: 42, alignment: .trailing)
                            .position(x: 21, y: yPos)
                    }

                    // Level lines + capsule labels
                    ForEach(Array(priceLevels.enumerated()), id: \.offset) { _, level in
                        let yPos = CGFloat(yFraction(level.price)) * h

                        // Horizontal rule
                        Path { p in
                            p.move(to:    CGPoint(x: 48, y: yPos))
                            p.addLine(to: CGPoint(x: w - 88, y: yPos))
                        }
                        .stroke(
                            level.color,
                            style: StrokeStyle(lineWidth: level.lineWidth,
                                               dash: level.dashed ? [5, 3] : [])
                        )

                        // Tick mark on the right side
                        Path { p in
                            p.move(to:    CGPoint(x: w - 88, y: yPos))
                            p.addLine(to: CGPoint(x: w - 84, y: yPos))
                        }
                        .stroke(level.color, lineWidth: level.lineWidth)

                        // Right-edge capsule: "LABEL  price"
                        HStack(spacing: 3) {
                            Text(level.label)
                                .font(.system(size: 7, weight: .heavy))
                            Text(compactPrice(level.price))
                                .font(.system(size: 8, weight: .semibold).monospacedDigit())
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(level.color.opacity(0.90)))
                        .position(x: w - 44, y: yPos)
                    }
                }
            }
        }
        .padding(Theme.Spacing.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.Color.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md)
            .strokeBorder(Theme.Color.border, lineWidth: 1))
    }

    private func compactPrice(_ v: Double) -> String {
        // Show 2 decimals for large prices (gold ≈ 3000+), 5 for forex
        if abs(v) >= 100 { return String(format: "%.2f", v) }
        if abs(v) >= 1   { return String(format: "%.4f", v) }
        return String(format: "%.5f", v)
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: – Trade Metrics Card
    // ═══════════════════════════════════════════════════════════════

    private var tradeMetricsCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("TRADE METRICS")
                .font(.system(size: 9, weight: .bold)).tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)

            if let e = entry.entry, let tp = entry.takeProfit, let sl = entry.stopLoss {
                let risk   = abs(e - sl)
                let reward = abs(tp - e)
                let rr     = risk > 0 ? reward / risk : 0
                rrBar(rr: rr, risk: risk, reward: reward)
            }

            Divider().background(Theme.Color.border)

            if let e = entry.entry, let cp = entry.closePrice {
                let move = cp - e
                let win  = (entry.side == .long && move >= 0) || (entry.side == .short && move <= 0)
                metricRow("Move",      String(format: "%+.3f", move),
                          win ? Theme.Color.success : Theme.Color.danger)
            }
            if let lots = entry.lots {
                metricRow("Size", String(format: "%.2f L", lots), Theme.Color.textSecondary)
            }
            if let open = entry.openDate {
                metricRow("Duration", durationStr(entry.date.timeIntervalSince(open)), Theme.Color.info)
            }
            metricRow("Direction", entry.side.label, entry.side.color)
            metricRow("Outcome",   entry.result.label, entry.result.color)
        }
        .padding(Theme.Spacing.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.Color.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md)
            .strokeBorder(Theme.Color.border, lineWidth: 1))
    }

    private func rrBar(rr: Double, risk: Double, reward: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("R : R").font(.system(size: 9, weight: .bold)).tracking(0.5)
                    .foregroundStyle(Theme.Color.textMuted)
                Spacer()
                Text(String(format: "1 : %.1f", rr))
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundStyle(rr >= 1.5 ? Theme.Color.success
                                   : rr >= 1.0 ? Theme.Color.warn
                                   : Theme.Color.danger)
            }
            GeometryReader { geo in
                let total = risk + reward
                let riskW = total > 0 ? geo.size.width * CGFloat(risk / total) : geo.size.width / 2
                HStack(spacing: 1) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.Color.danger.opacity(0.75))
                        .frame(width: riskW, height: 8)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.Color.success.opacity(0.75))
                        .frame(maxWidth: .infinity, minHeight: 8, maxHeight: 8)
                }
            }
            .frame(height: 8)
        }
    }

    private func metricRow(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.Color.textMuted)
            Spacer()
            Text(value).font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: – Parsed Section Cards
    // ═══════════════════════════════════════════════════════════════

    private struct AISection: Identifiable {
        let id: String
        let icon: String
        let title: String
        let body: String
        let accentColor: Color
    }

    private var sectionMeta: [(icon: String, color: Color)] {[
        ("waveform.path.ecg",           Theme.Color.warn),       // Why
        ("checkmark.seal.fill",         Theme.Color.success),    // What Went Right
        ("arrow.triangle.2.circlepath", Theme.Color.info),       // What Could Have Been Better
        ("lightbulb.fill",              Theme.Color.accentStart),// What You Should Have Done
        ("sparkles",                    Theme.Color.textSecondary), // Key Takeaway
    ]}

    private func parseOutput(_ raw: String) -> [AISection] {
        let lines = raw.components(separatedBy: "\n")
        var buckets: [(header: String, lines: [String])] = []
        var current: (header: String, lines: [String])?

        for line in lines {
            if line.hasPrefix("## ") {
                if let c = current { buckets.append(c) }
                current = (String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), [])
            } else if current != nil {
                current!.lines.append(line)
            }
        }
        if let c = current { buckets.append(c) }
        guard !buckets.isEmpty else { return [] }

        return buckets.enumerated().map { i, bucket in
            let body = bucket.lines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let meta = sectionMeta[min(i, sectionMeta.count - 1)]
            return AISection(id: "\(i)", icon: meta.icon, title: bucket.header,
                             body: body, accentColor: meta.color)
        }
    }

    private var parsedSections: some View {
        let sections = parseOutput(output)
        return Group {
            if sections.isEmpty {
                Text(output)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Color.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    ForEach(sections) { sectionCard($0) }
                }
            }
        }
    }

    private func sectionCard(_ section: AISection) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(section.accentColor.opacity(0.14))
                    .frame(width: 32, height: 32)
                Image(systemName: section.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(section.accentColor)
            }
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                Text(section.title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.Color.textPrimary)

                let bodyLines = section.body.components(separatedBy: "\n")
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(bodyLines.enumerated()), id: \.offset) { _, line in
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("• ") {
                            HStack(alignment: .top, spacing: 6) {
                                Circle()
                                    .fill(section.accentColor.opacity(0.75))
                                    .frame(width: 4, height: 4)
                                    .padding(.top, 5)
                                // Strip inline **bold** markers for display
                                Text(stripBold(trimmed.hasPrefix("- ")
                                     ? String(trimmed.dropFirst(2))
                                     : String(trimmed.dropFirst(2))))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.Color.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else if trimmed == "---" || trimmed.isEmpty {
                            EmptyView()
                        } else {
                            Text(stripBold(trimmed))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.Color.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Spacing.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.Color.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md)
            .strokeBorder(section.accentColor.opacity(0.22), lineWidth: 1))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(section.accentColor.opacity(0.85))
                .frame(width: 3)
                .padding(.vertical, 8)
        }
    }

    /// Remove **text** markers so they don't appear verbatim in the card body.
    private func stripBold(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "")
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: – Supporting result-panel views
    // ═══════════════════════════════════════════════════════════════

    private var thinkingDisclosure: some View {
        DisclosureGroup(isExpanded: $showThinking) {
            Text(thinking)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.Color.textMuted)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.sm)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "brain").font(.system(size: 10, weight: .semibold))
                Text("Thinking trace").font(.system(size: 10, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(Theme.Color.info.opacity(0.8))
        }
        .padding(Theme.Spacing.sm)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(Theme.Color.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm)
            .strokeBorder(Theme.Color.info.opacity(0.2), lineWidth: 1))
    }

    private var analyzingSpinner: some View {
        HStack(spacing: Theme.Spacing.md) {
            ProgressView().controlSize(.small).tint(Theme.Color.accentStart)
            VStack(alignment: .leading, spacing: 2) {
                Text("Analyzing your trade…")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text("Reviewing your entry, risk placement, and outcome.")
                    .font(.system(size: 11)).foregroundStyle(Theme.Color.textMuted)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.Color.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md)
            .strokeBorder(Theme.Color.border, lineWidth: 1))
    }

    private var actionRow: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if isRunning {
                Button { streamTask?.cancel(); isRunning = false } label: {
                    Label("Stop", systemImage: "stop.circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Color.danger)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.Color.surface))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Theme.Color.danger.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)
            } else {
                Button { thinking = ""; output = ""; error = nil; savedToJournal = false } label: {
                    Label("Re-run", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.Color.surface))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Theme.Color.border, lineWidth: 1))
                }
                .buttonStyle(.plain)

                if !output.isEmpty {
                    // Copy
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(output, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.Color.textSecondary)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.Color.surface))
                            .overlay(RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(Theme.Color.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                    // Save to journal
                    Button { saveReportToJournal() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: savedToJournal ? "checkmark.circle.fill" : "arrow.down.doc")
                                .font(.system(size: 10, weight: .semibold))
                            Text(savedToJournal ? "Saved" : "Save to Journal")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(savedToJournal ? Theme.Color.success : Theme.Color.accentStart)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill(savedToJournal
                                  ? Theme.Color.success.opacity(0.12)
                                  : Theme.Color.accentStart.opacity(0.12)))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(savedToJournal
                                          ? Theme.Color.success.opacity(0.35)
                                          : Theme.Color.accentStart.opacity(0.35), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(savedToJournal)
                }
            }
            Spacer()
            Button { dismiss() } label: {
                Text("Close")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Color.textMuted)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.Color.surface))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Theme.Color.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: – Engine / Model / Effort pickers
    // ═══════════════════════════════════════════════════════════════

    @ViewBuilder
    private func engineChip(kind: AIEngineKind, engine: AIEngine) -> some View {
        let selected  = engineKind == kind
        let available = engine.availability.canRun
        Button { if available { engineKind = kind } } label: {
            HStack(spacing: 5) {
                EngineGlyph(kind: kind, size: 12)
                Text(kind.label)
                    .font(.system(size: 12, weight: selected ? .bold : .medium))
                if !available {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 9))
                }
            }
            .foregroundStyle(selected ? .white : (available ? Theme.Color.textSecondary : Theme.Color.textMuted))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(selected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.Color.surface)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Color.clear : Theme.Color.border, lineWidth: 1))
        }
        .buttonStyle(.plain).disabled(!available)
    }

    @ViewBuilder
    private func modelEffortPicker(
        models: [ClaudeModelCatalog.Model],
        efforts: [ClaudeModelCatalog.Effort],
        selectedModel: Binding<String>,
        selectedEffort: Binding<String>
    ) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xl) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                sectionLabel("MODEL")
                Picker("Model", selection: selectedModel) {
                    ForEach(models) { Text($0.label).tag($0.id) }
                }
                .pickerStyle(.menu).labelsHidden()
                .frame(maxWidth: 280, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                sectionLabel("REASONING")
                HStack(spacing: 6) {
                    ForEach(efforts) { e in
                        let sel = selectedEffort.wrappedValue == e.id
                        Button { selectedEffort.wrappedValue = e.id } label: {
                            Text(e.label)
                                .font(.system(size: 11, weight: sel ? .bold : .medium))
                                .foregroundStyle(sel ? .white : Theme.Color.textSecondary)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 6).fill(
                                    sel ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.Color.surface)))
                                .overlay(RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(sel ? Color.clear : Theme.Color.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain).help(e.tooltip)
                    }
                }
            }
        }
    }

    private var opencodeModelPicker: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xl) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                sectionLabel("MODEL")
                Picker("Model", selection: $opencodeModelID) {
                    ForEach(OpenCodeModelCatalog.allModelsByProvider, id: \.provider) { group in
                        Section(group.provider) {
                            ForEach(group.models) { Text($0.label).tag($0.id) }
                        }
                    }
                }
                .pickerStyle(.menu).labelsHidden()
                .frame(maxWidth: 280, alignment: .leading)
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: – AI run + prompt
    // ═══════════════════════════════════════════════════════════════

    private func startAnalysis() {
        UserDefaults.standard.set(engineKind.rawValue, forKey: "ai.journal.engine")
        switch engineKind {
        case .claude:
            UserDefaults.standard.set(claudeModelID,  forKey: "ai.claude.model")
            UserDefaults.standard.set(claudeEffortID, forKey: "ai.claude.effort")
        case .codex:
            UserDefaults.standard.set(codexModelID,  forKey: "ai.codex.model")
            UserDefaults.standard.set(codexEffortID, forKey: "ai.codex.effort")
        case .opencode:
            UserDefaults.standard.set(opencodeModelID, forKey: "ai.opencode.model")
        }
        isRunning = true; error = nil; output = ""; thinking = ""; savedToJournal = false
        let engine = AIEngineFactory.make(engineKind)
        let (sys, usr) = buildPrompt()
        streamTask = Task { @MainActor in
            do {
                for try await event in engine.run(system: sys, user: usr) {
                    switch event {
                    case .text(let c):     output   += c
                    case .thinking(let c): thinking += c
                    }
                }
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
            isRunning = false
        }
    }

    private func buildPrompt() -> (system: String, user: String) {
        let resultLabel = entry.result.label.lowercased()
        let system = """
        You are an experienced trading coach specializing in gold (XAUUSD) and forex. \
        Perform a detailed post-mortem on this trade. \
        Structure your response with exactly these five Markdown sections \
        (use ## for the headers, keep them verbatim):

        ## Why This Trade \(entry.result.label)
        Primary driver(s) of the outcome. Be specific: cite price action, market structure, session timing.

        ## What Went Right
        Even losing trades have positives. Identify what the trader executed well \
        (discipline, sizing, recognizing the setup).

        ## What Could Have Been Better
        Concrete, actionable observations on entry timing, level selection, SL placement, trade management.

        ## What You Should Have Done
        A step-by-step alternative playbook: what confirmation to wait for, where to enter, \
        where to place the SL, where to target, and how to manage the trade differently \
        to improve the outcome. Be specific to this trade's levels and context.

        ## Key Takeaway
        One crisp sentence the trader should carry into their next similar setup.

        Use bullet points inside each section. No markdown tables. Be direct and educational.
        """

        var details: [String] = [
            "Pair: \(entry.pairName)",
            "Direction: \(entry.side.label)",
            "Outcome: \(entry.result.label)",
        ]
        if entry.profitLoss != 0 { details.append("Net P/L: \(String(format: "%+.2f", entry.profitLoss))") }
        if let e  = entry.entry      { details.append("Entry price: \(compactPrice(e))") }
        if let tp = entry.takeProfit { details.append("Take profit: \(compactPrice(tp))") }
        if let sl = entry.stopLoss   { details.append("Stop loss: \(compactPrice(sl))") }
        if let cp = entry.closePrice { details.append("Close price: \(compactPrice(cp))") }
        if let lo = entry.lots       { details.append("Lots: \(String(format: "%.2f", lo))") }
        if let e = entry.entry, let sl = entry.stopLoss, let tp = entry.takeProfit {
            let risk = abs(e - sl); let reward = abs(tp - e)
            if risk > 0 { details.append(String(format: "R:R ratio: 1:%.1f", reward / risk)) }
        }
        if let open = entry.openDate {
            details.append("Opened: \(Self.dateFmt.string(from: open))")
            details.append("Duration: \(durationStr(entry.date.timeIntervalSince(open)))")
        }
        details.append("Closed: \(Self.dateFmt.string(from: entry.date))")
        if !entry.title.isEmpty { details.append("Trade title: \(entry.title)") }
        if !entry.notes.isEmpty { details.append("\nTrader's notes:\n\(entry.notes)") }
        if let ex = entry.aiReportExcerpt, !ex.isEmpty {
            details.append("\nOriginal AI analysis (first 500 chars):\n\(String(ex.prefix(500)))")
        }

        let user = "Post-mortem this \(resultLabel) trade:\n\n\(details.joined(separator: "\n"))"
        return (system, user)
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: – Save to journal
    // ═══════════════════════════════════════════════════════════════

    private func saveReportToJournal() {
        guard !output.isEmpty else { return }
        var updated = entry
        // Append the AI report to the entry's notes (with a divider if notes already exist)
        let stamp = "AI Post-Mortem · \(Self.dateFmt.string(from: Date()))"
        let separator = entry.notes.isEmpty ? "" : "\n\n---\n\n"
        updated.notes = entry.notes + separator + "**\(stamp)**\n\n" + output
        // Also stash as the excerpt so future runs can reference it
        updated.aiReportExcerpt = String(output.prefix(600))
        journal.upsert(updated)
        savedToJournal = true
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: – Candle loading
    // ═══════════════════════════════════════════════════════════════

    private func loadTradingCandles() async {
        guard let db = app.database else { return }
        let openDate  = entry.openDate ?? entry.date.addingTimeInterval(-3600)
        let closeDate = entry.date
        let duration  = closeDate.timeIntervalSince(openDate)
        // Pick a timeframe that gives ~40–80 candles over the trade span
        let tf: String
        switch duration {
        case ..<600:      tf = "1m"
        case ..<7200:     tf = "5m"
        case ..<86400:    tf = "1h"
        default:          tf = "4h"
        }
        // Load candles from 2 candle-widths before entry to 2 after close
        let padding  = max(duration * 0.5, 3600)
        let since    = openDate.addingTimeInterval(-padding)
        let until    = closeDate.addingTimeInterval(padding)
        do {
            let bars = try await db.ohlcRepo.read(pairID: entry.pairID,
                                                  timeframe: tf,
                                                  since: since, until: until)
            await MainActor.run { tradingCandles = bars }
        } catch {
            // Silently fall back — price ruler still works without candles
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: – Helpers
    // ═══════════════════════════════════════════════════════════════

    private func resultBadge(_ result: JournalEntry.Result) -> some View {
        Text(result.label.uppercased())
            .font(.system(size: 9, weight: .heavy)).tracking(0.5)
            .foregroundStyle(result.color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(result.color.opacity(0.18)))
    }

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold)).tracking(0.8)
            .foregroundStyle(Theme.Color.textMuted)
    }

    private func durationStr(_ secs: TimeInterval) -> String {
        let s = Int(secs)
        if s < 60    { return "\(s)s" }
        if s < 3600  { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        return "\(s / 86400)d \((s % 86400) / 3600)h"
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d, yyyy HH:mm"; return f
    }()
}

// ── JournalEntry.Result convenience ──────────────────────────────────────
private extension JournalEntry.Result {
    var icon: String {
        switch self {
        case .win:       return "trophy.fill"
        case .loss:      return "arrow.down.circle.fill"
        case .breakeven: return "equal.circle.fill"
        case .open:      return "clock.fill"
        }
    }
}
