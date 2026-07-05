import SwiftUI

/// Comprehensive AI review for all trades on a single trading day.
/// Analyses the full session: what worked, what didn't, order-block quality,
/// discipline score, and actionable takeaways.
struct JournalDayAISheet: View {
    let entries: [JournalEntry]
    let day: Date
    /// Override the header date label — use for week / month reviews.
    var periodTitle: String? = nil

    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var dayReviewStore: DayReviewStore
    @Environment(\.dismiss) private var dismiss

    // ── Engine / model / effort ───────────────────────────────────
    @State private var engineKind: AIEngineKind = {
        let raw = UserDefaults.standard.string(forKey: "ai.journal.engine") ?? "claude"
        return AIEngineKind(rawValue: raw) ?? .claude
    }()
    @State private var claudeModelID   = UserDefaults.standard.string(forKey: "ai.claude.model")   ?? ClaudeModelCatalog.defaultModelID
    @State private var claudeEffortID  = UserDefaults.standard.string(forKey: "ai.claude.effort")  ?? ClaudeModelCatalog.defaultEffortID
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
    @State private var savedReview = false

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
        .frame(width: 780, height: 700)
        .background(Theme.Color.canvas)
        .onDisappear { streamTask?.cancel() }
    }

    // ── Summary computed props ────────────────────────────────────
    private var wins:   [JournalEntry] { entries.filter { $0.result == .win } }
    private var losses: [JournalEntry] { entries.filter { $0.result == .loss } }
    private var netPL:  Double { entries.reduce(0) { $0 + $1.profitLoss } }
    private var winRate: Double {
        let graded = wins.count + losses.count
        return graded == 0 ? 0 : Double(wins.count) / Double(graded)
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: – Header
    // ═══════════════════════════════════════════════════════════════

    private var sheetHeader: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Theme.Color.accentStart.opacity(0.15))
                    .frame(width: 38, height: 38)
                Image(systemName: "calendar.badge.sparkles")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.Color.accentStart)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("AI Day Review")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(periodTitle ?? Self.dayFmt.string(from: day))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textMuted)
            }
            Spacer()
            // Mini stats
            HStack(spacing: Theme.Spacing.md) {
                miniStat(label: "TRADES", value: "\(entries.count)")
                miniStat(label: "WIN RATE",
                         value: String(format: "%.0f%%", winRate * 100),
                         tint: winRate >= 0.5 ? Theme.Color.success : Theme.Color.danger)
                miniStat(label: "NET P/L",
                         value: String(format: "%+.2f", netPL),
                         tint: netPL >= 0 ? Theme.Color.success : Theme.Color.danger)
            }
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

    private func miniStat(label: String, value: String, tint: Color = Theme.Color.textPrimary) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value)
                .font(.system(size: 13, weight: .bold).monospacedDigit())
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 8, weight: .bold)).tracking(0.4)
                .foregroundStyle(Theme.Color.textMuted)
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: – Config panel
    // ═══════════════════════════════════════════════════════════════

    private var configPanel: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            tradesSummaryCard
                .frame(maxHeight: 220)
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
                    Label("Analyse \(entries.count) Trades", systemImage: "sparkles")
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

    private var tradesSummaryCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("TRADES THIS DAY")
                .font(.system(size: 9, weight: .bold)).tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(entries) { e in
                        HStack(spacing: Theme.Spacing.sm) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(e.result.color)
                                .frame(width: 3, height: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.title.isEmpty ? e.pairName : e.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.Color.textPrimary)
                                HStack(spacing: 6) {
                                    Text(Self.timeFmt.string(from: e.date))
                                        .font(.system(size: 9))
                                        .foregroundStyle(Theme.Color.textMuted)
                                    sideChip(e.side)
                                    if let entry = e.entry {
                                        Text("@ \(compactPrice(entry))")
                                            .font(.system(size: 9))
                                            .foregroundStyle(Theme.Color.textMuted)
                                    }
                                }
                            }
                            Spacer()
                            resultChip(e.result)
                            if e.profitLoss != 0 || e.result.isGraded {
                                Text(String(format: "%+.2f", e.profitLoss))
                                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                                    .foregroundStyle(e.profitLoss >= 0 ? Theme.Color.success : Theme.Color.danger)
                                    .frame(width: 70, alignment: .trailing)
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.Color.surfaceHi))
                    }
                }
            }
        }
        .padding(Theme.Spacing.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.Color.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.Color.border, lineWidth: 1))
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: – Result panel
    // ═══════════════════════════════════════════════════════════════

    private var resultPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
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

    // ── Section parsing ───────────────────────────────────────────

    private struct AISection: Identifiable {
        let id: String
        let icon: String
        let title: String
        let body: String
        let accentColor: Color
    }

    private var sectionMeta: [(icon: String, color: Color)] {[
        ("chart.bar.xaxis",               Theme.Color.info),
        ("checkmark.seal.fill",           Theme.Color.success),
        ("exclamationmark.triangle.fill", Theme.Color.danger),
        ("square.3.layers.3d.top.filled", Theme.Color.warn),
        ("arrow.up.right.circle.fill",    Theme.Color.accentStart),
        ("lightbulb.fill",                Theme.Color.textSecondary),
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

    private func stripBold(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "")
    }

    // ── Supporting result-panel views ─────────────────────────────

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
                Text("Analysing your trading day…")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text("Reviewing all \(entries.count) trades, order block quality, and session patterns.")
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
                Button { thinking = ""; output = ""; error = nil; savedReview = false } label: {
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

                    Button { saveReview() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: savedReview ? "checkmark.circle.fill" : "arrow.down.doc")
                                .font(.system(size: 10, weight: .semibold))
                            Text(savedReview ? "Saved" : "Save Review")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(savedReview ? Theme.Color.success : Theme.Color.accentStart)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill(savedReview
                                  ? Theme.Color.success.opacity(0.12)
                                  : Theme.Color.accentStart.opacity(0.12)))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(savedReview
                                          ? Theme.Color.success.opacity(0.35)
                                          : Theme.Color.accentStart.opacity(0.35), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(savedReview)
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
                    Section("FREE") {
                        ForEach(OpenCodeModelCatalog.freeModels) { Text($0.label).tag($0.id) }
                    }
                    ForEach(OpenCodeModelCatalog.providerOrder, id: \.self) { provider in
                        if let group = OpenCodeModelCatalog.paidModelsByProvider.first(where: { $0.provider == provider }) {
                            Section(provider) {
                                ForEach(group.models) { Text($0.label).tag($0.id) }
                            }
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
        isRunning = true; error = nil; output = ""; thinking = ""; savedReview = false
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
        let system = """
        You are an expert trading coach and market analyst specialising in gold (XAUUSD) and forex \
        with deep knowledge of Smart Money Concepts (SMC) and order block (OB) trading. \
        The trader you are reviewing primarily uses order blocks as their core setup — always factor \
        this into your feedback.

        Analyse the trader's full session for the day provided. Your response must use exactly \
        these six Markdown sections (## headers, keep titles verbatim):

        ## Session Overview
        Summarise the day: total trades, win rate, net P/L, dominant direction (long/short bias), \
        session context (Asia/London/NY overlap), and whether the day was overall disciplined.

        ## What Made You Profitable (or What Cost You)
        If net positive: identify the specific behaviours, setups, and order block confluences \
        that drove profitability — what to repeat. \
        If net negative or mixed: pinpoint the root causes of losses — overtrading, weak OB selection, \
        bad SL placement, chasing, poor session timing, etc.

        ## Order Block Quality Assessment
        Rate each order block entry individually (if price data given). \
        Comment on: mitigation quality, confluence with structure, entry timing, \
        whether the OB was respected or swept before continuation. \
        Highlight the best and worst OB trade of the session.

        ## Patterns & Discipline
        Identify behavioural patterns across the session: \
        Did the trader revenge-trade after a loss? Did they take low-quality setups late in the session? \
        Did they cut winners early? Did they move SL to breakeven too soon? \
        Reward good habits explicitly.

        ## What You Should Have Done Differently
        Concrete, trade-by-trade suggestions where applicable: \
        better entry, tighter SL, different target, skipping a trade entirely. \
        Be specific to the price levels and outcomes recorded.

        ## Key Rules to Carry Forward
        3–5 crisp, actionable rules this trader should apply starting from their very next session, \
        written as if they are personal trading rules ("Only enter OBs that are…", "Skip setups where…").

        Use bullet points within each section. No tables. Be direct and educational. \
        Reference specific trades by their title or time when relevant.
        """

        let dateStr = periodTitle ?? Self.dayFmt.string(from: day)
        var tradeLines: [String] = []
        let sorted = entries.sorted { $0.date < $1.date }
        for (i, e) in sorted.enumerated() {
            var parts: [String] = ["Trade \(i + 1): \(e.title.isEmpty ? e.pairName : e.title)"]
            parts.append("  Direction: \(e.side.label)")
            parts.append("  Result: \(e.result.label)")
            if e.profitLoss != 0 { parts.append("  Net P/L: \(String(format: "%+.2f", e.profitLoss))") }
            if let entry = e.entry  { parts.append("  Entry: \(compactPrice(entry))") }
            if let tp = e.takeProfit { parts.append("  Take Profit: \(compactPrice(tp))") }
            if let sl = e.stopLoss   { parts.append("  Stop Loss: \(compactPrice(sl))") }
            if let cp = e.closePrice { parts.append("  Close: \(compactPrice(cp))") }
            if let lo = e.lots       { parts.append("  Lots: \(String(format: "%.2f", lo))") }
            if let ent = e.entry, let sl = e.stopLoss, let tp = e.takeProfit {
                let risk = abs(ent - sl); let reward = abs(tp - ent)
                if risk > 0 { parts.append(String(format: "  R:R: 1:%.1f", reward / risk)) }
            }
            if let open = e.openDate {
                let dur = e.date.timeIntervalSince(open)
                parts.append("  Opened: \(Self.timeFmt.string(from: open))")
                parts.append("  Duration: \(durationStr(dur))")
            }
            parts.append("  Closed: \(Self.timeFmt.string(from: e.date))")
            if !e.notes.isEmpty { parts.append("  Trader notes: \(e.notes)") }
            tradeLines.append(parts.joined(separator: "\n"))
        }

        let gradedCount = wins.count + losses.count
        let wrStr = gradedCount > 0 ? String(format: "%.0f%%", winRate * 100) : "N/A"
        let user = """
        Please analyse my full trading session for \(dateStr).

        Day summary:
        - Total trades: \(entries.count)
        - Wins: \(wins.count), Losses: \(losses.count), Open: \(entries.filter { $0.result == .open }.count)
        - Win rate: \(wrStr)
        - Net P/L: \(String(format: "%+.2f", netPL))

        Individual trades:
        \(tradeLines.joined(separator: "\n\n"))
        """
        return (system, user)
    }

    /// Persist the finished report into `DayReviewStore` so it shows
    /// up in the AI review history instead of being lost the moment
    /// the sheet is dismissed.
    private func saveReview() {
        guard !output.isEmpty else { return }
        let modelLabel: String
        switch engineKind {
        case .claude:   modelLabel = ClaudeModelCatalog.label(forModelID: claudeModelID)
        case .codex:    modelLabel = CodexModelCatalog.label(forModelID: codexModelID)
        case .opencode: modelLabel = OpenCodeModelCatalog.label(forModelID: opencodeModelID)
        }
        let review = DayReviewEntry(
            periodStart: entries.map(\.date).min() ?? day,
            periodTitle: periodTitle ?? Self.dayFmt.string(from: day),
            tradeCount: entries.count,
            winRate: winRate,
            netPL: netPL,
            engineLabel: engineKind.label,
            modelLabel: modelLabel,
            report: output,
            thinking: thinking.isEmpty ? nil : thinking
        )
        dayReviewStore.add(review)
        savedReview = true
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: – Helpers / formatters
    // ═══════════════════════════════════════════════════════════════

    private func compactPrice(_ v: Double) -> String {
        if abs(v) >= 100 { return String(format: "%.2f", v) }
        if abs(v) >= 1   { return String(format: "%.4f", v) }
        return String(format: "%.5f", v)
    }

    private func durationStr(_ secs: TimeInterval) -> String {
        let s = Int(secs)
        if s < 60    { return "\(s)s" }
        if s < 3600  { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        return "\(s / 86400)d \((s % 86400) / 3600)h"
    }

    private func sideChip(_ side: JournalEntry.Side) -> some View {
        Text(side.label.uppercased())
            .font(.system(size: 8, weight: .heavy)).tracking(0.4)
            .foregroundStyle(side.color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(side.color.opacity(0.16)))
    }

    private func resultChip(_ result: JournalEntry.Result) -> some View {
        Text(result.label.uppercased())
            .font(.system(size: 9, weight: .heavy)).tracking(0.5)
            .foregroundStyle(result.color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(result.color.opacity(0.18)))
    }

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold)).tracking(0.8)
            .foregroundStyle(Theme.Color.textMuted)
    }

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMM d, yyyy"; return f
    }()

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
}
