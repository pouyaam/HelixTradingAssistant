import SwiftUI

/// Comprehensive AI review for all trades on a single trading day.
/// Analyses the full session: what worked, what didn't, order-block quality,
/// discipline score, and actionable takeaways.
struct JournalDayAISheet: View {
    let entries: [JournalEntry]
    let day: Date
    /// Override the header date label — use for week / month / all-time reviews.
    var periodTitle: String? = nil
    /// Coarse period classification so the system prompt can frame the
    /// scope correctly ("today's session" vs "the full week" vs "all-time")
    /// instead of always speaking of "this trading day". Defaults to
    /// `.day` because the day-group analyse button still passes a single day.
    var periodScope: PeriodScope = .day
    /// Heuristic behavioral flags already computed by the caller
    /// (`JournalDetailView.computeBehavioralWarnings(for:)`) — revenge
    /// trades, overtrading windows, loss streaks, late-session fade. Feeding
    /// them into the prompt as "preliminary flags detected by your rules
    /// engine — corroborate or refute each" makes the AI's review build on
    /// the deterministic checks instead of silently redoing them blind, and
    /// surfaces disagreement (model thinks it *wasn't* revenge, the rules
    /// engine thought it was) as a discussion rather than a hidden bug.
    var behavioralHints: [String] = []
    /// Journal these trades belong to. Derived from `entries.first` if nil
    /// so legacy callers don't need to thread an explicit ID through. Used
    /// for per-journal engine/model persistence and to scope the saved
    /// review into `DayReviewEntry.journalID` for the inline history.
    var journalID: UUID? = nil

    /// Coarse scope classification for the period being reviewed.
    enum PeriodScope: String {
        case day, yesterday, week, month, custom, all

        /// User-facing noun ("this session", "this week", "this month",
        /// "your entire trading history").
        var nounPhrase: String {
            switch self {
            case .day:        return "this trading day"
            case .yesterday:  return "yesterday's session"
            case .week:       return "this week's sessions"
            case .month:      return "this month's sessions"
            case .custom:     return "this custom period"
            case .all:        return "your entire trading history"
            }
        }
        /// Short label appended to the AI button on the journal detail
        /// screen ("AI Today", "AI This Week", "AI All-Time").
        var buttonLabel: String {
            switch self {
            case .day:        return "Today"
            case .yesterday:  return "Yesterday"
            case .week:       return "This Week"
            case .month:      return "This Month"
            case .custom:     return "Custom"
            case .all:        return "All-Time"
            }
        }
    }

    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var dayReviewStore: DayReviewStore
    @Environment(\.dismiss) private var dismiss

    /// The journal under analysis — either the explicit `journalID` or the
    /// journal every entry was filed under. Used for per-journal prefs and
    /// to scope the saved `DayReviewEntry.journalID`.
    private var scopedJournalID: UUID { journalID ?? entries.first?.journalID ?? JournalEntry.defaultJournalID }

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
    /// Flips to true once the model emits its first `## ` header — used to
    /// decide when to switch from the live raw-text streaming view over to
    /// the parsed section cards.
    @State private var firstHeaderArrived = false
    /// Toggle for the "vs Previous review" disclosure — set to false on
    /// each new run, true once the user expands the prior report.
    @State private var showPrevious = false
    /// Most-recent saved review for this journal + period, looked up at
    /// run-time so the user can compare what changed against last week's
    /// verdict on the same scope.
    @State private var previousReview: DayReviewEntry? = nil

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
        .task { applyPerJournalDefaults(); refreshPreviousReview() }
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
                if let prev = previousReview { previousReviewDisclosure(prev) }
                if !thinking.isEmpty { thinkingDisclosure }
                if isRunning && output.isEmpty {
                    analyzingSpinner
                } else if isRunning && !firstHeaderArrived {
                    liveRawText
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

    /// Collapsible view of the most recent saved review matching this
    /// (journal, period) — gives the user a side-by-side mental diff so a
    /// weekly run can be compared against the previous week's verdict
    /// without diving into the global review history sheet. Rendered as a
    /// plain-text disclosure (no line-level diff — the model's wording
    /// churns too much to make a character diff useful; a "compare against
    /// last week's bottom line" still surfaces consistency / drift).
    @ViewBuilder
    private func previousReviewDisclosure(_ review: DayReviewEntry) -> some View {
        DisclosureGroup(isExpanded: $showPrevious) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(String(format: "%+.2f", review.netPL))
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(review.netPL >= 0 ? Theme.Color.success : Theme.Color.danger)
                    Text("\(review.tradeCount) trades")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Color.textMuted)
                    Text("· \(review.engineLabel) · \(review.modelLabel)")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Color.textMuted)
                    Spacer()
                }
                Text(review.report)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Color.info.opacity(0.85))
                Text("Previous review — \(Self.dateFmt.string(from: review.createdAt))")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Color.info.opacity(0.85))
                Spacer()
            }
        }
        .padding(Theme.Spacing.sm)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(Theme.Color.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm)
            .strokeBorder(Theme.Color.info.opacity(0.2), lineWidth: 1))
    }

    /// Mid-stream raw text shown until the model emits its first `## `
    /// header, mirroring `JournalAISheet.liveRawText` — keeps the sheet
    /// visibly responsive between "Analyse…" → first section header.
    private var liveRawText: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).tint(Theme.Color.accentStart)
                Text("Receiving…")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Color.textMuted)
                Spacer()
            }
            ScrollView {
                Text(output.isEmpty ? "…" : output)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.Color.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md)
            .strokeBorder(Theme.Color.border, lineWidth: 1))
    }

    // ── Section parsing ───────────────────────────────────────────

    private struct AISection: Identifiable {
        let id: String
        let icon: String
        let title: String
        let body: String
        let accentColor: Color
    }

    /// Resolve a section header → (icon, color) **by name** rather than by
    /// array index. The original index-based mapping sent the wrong glyph
    /// when the model reordered sections or added an intro paragraph; this
    /// lookup tolerates reordering, paraphrasing, and an extra "Summary"
    /// the rules engine itself pre-stages.
    private func meta(forTitle title: String) -> (icon: String, color: Color) {
        let known = ["Session Overview",
                     "What Made You Profitable",
                     "What Cost You",
                     "Order Block Quality Assessment",
                     "Patterns & Discipline",
                     "What You Should Have Done Differently",
                     "Key Rules to Carry Forward",
                     "Summary"]
        let idx = AISectionParse.match(title, against: known)
        switch idx {
        case 0:  return ("chart.bar.xaxis",               Theme.Color.info)
        case 1:  return ("checkmark.seal.fill",           Theme.Color.success)
        case 2:  return ("exclamationmark.triangle.fill", Theme.Color.danger)
        case 3:  return ("square.3.layers.3d.top.filled", Theme.Color.warn)
        case 4:  return ("arrow.up.right.circle.fill",    Theme.Color.accentStart)
        case 5:  return ("lightbulb.fill",                Theme.Color.accentStart)
        case 6:  return ("checkmark.seal.fill",           Theme.Color.textSecondary)
        case 7:  return ("line.3.horizontal",             Theme.Color.textSecondary)
        default: return ("line.3.horizontal",             Theme.Color.textSecondary)
        }
    }

    private func parseOutput(_ raw: String) -> [AISection] {
        let buckets = AISectionParse.sections(from: raw)
        return buckets.enumerated().map { i, b in
            let m = meta(forTitle: b.title)
            return AISection(
                id: "\(i)",
                icon: m.icon,
                title: b.title.isEmpty ? "Summary" : b.title,
                body: b.body,
                accentColor: m.color
            )
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
                AIMarkdownLines(
                    bodyText: section.body,
                    accentColor: section.accentColor,
                    bodyColor: Theme.Color.textSecondary
                )
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
                Button { thinking = ""; output = ""; error = nil; savedReview = false; firstHeaderArrived = false } label: {
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
        // Persist global (legacy) + per-journal preferences.
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
        persistPerJournalSettings(.engine)
        persistPerJournalSettings(.model)
        persistPerJournalSettings(.effort)
        // Refresh the "previous review" so the user can compare against the
        // most recent verdict *before* this run, not after we save this one.
        refreshPreviousReview()
        isRunning = true; error = nil
        output = ""; thinking = ""; savedReview = false
        firstHeaderArrived = false
        showPrevious = false
        let engine = AIEngineFactory.make(engineKind)
        let (sys, usr) = buildPrompt()
        streamTask = Task { @MainActor in
            do {
                for try await event in engine.run(system: sys, user: usr) {
                    switch event {
                    case .text(let c):
                        output += c
                        if !firstHeaderArrived,
                           output.range(of: "(?m)^## ", options: .regularExpression) != nil {
                            firstHeaderArrived = true
                        }
                    case .thinking(let c):
                        thinking += c
                    }
                }
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
            isRunning = false
        }
    }

    private func buildPrompt() -> (system: String, user: String) {
        // Period-aware framing: the system prompt previously always spoke of
        // "this trading day" even when the analysis covered a week, month, or
        // the journal's entire history — which led the model to narrate a
        // Monday-Friday single session even on multi-week reviews. Branching
        // on `periodScope` keeps the wording aligned with what the user
        // actually asked for.
        let scopeNoun = periodScope.nounPhrase
        let isAllTime = periodScope == .all
        let isMultiDay = periodScope == .week || periodScope == .month || periodScope == .custom || periodScope == .all

        let system = """
        You are an expert trading coach and market analyst specialising in gold (XAUUSD) and forex \
        with deep knowledge of Smart Money Concepts (SMC) and order block (OB) trading. \
        The trader you are reviewing primarily uses order blocks as their core setup — always factor \
        this into your feedback.

        Analyse the trader's \(scopeNoun). \(isMultiDay
            ? "Because this spans multiple trading sessions, organise your commentary by day and don't treat this as a single session. Aggregate intra-day trends only after giving a per-day take."
            : "Treat this as one trading session and review intra-day sequencing explicitly.")

        Your response must use exactly these six Markdown sections (## headers, keep titles verbatim):

        ## Session Overview
        \(isMultiDay
            ? "Summarise the period: total trades, win rate, net P/L, dominant direction, sessions contributing most to net P/L (e.g. London vs NY), and whether the period overall was disciplined."
            : "Summarise the day: total trades, win rate, net P/L, dominant direction (long/short bias), session context (Asia/London/NY overlap), and whether the day was overall disciplined.")

        ## What Made You Profitable (or What Cost You)
        If net positive: identify the specific behaviours, setups, and order block confluences \
        that drove profitability — what to repeat. \
        If net negative or mixed: pinpoint the root causes of losses — overtrading, weak OB selection, \
        bad SL placement, chasing, poor session timing, etc.

        ## Order Block Quality Assessment
        Rate each order block entry individually (if price data given). \
        Comment on: mitigation quality, confluence with structure, entry timing, \
        whether the OB was respected or swept before continuation. \
        \(isMultiDay ? "Group by trading day if the period spans several." : "Highlight the best and worst OB trade of the session.")

        ## Patterns & Discipline
        Identify behavioural patterns across \(scopeNoun): \
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
        var userHeaders: [String] = [
            "Please analyse my trading for \(dateStr)."
        ]
        if isAllTime { userHeaders.append("This is the all-time review of this journal — treat it as a long-run retrospective, not a single session.") }

        var userDetails: [String] = [
            "Period summary:",
            "- Total trades: \(entries.count)",
            "- Wins: \(wins.count), Losses: \(losses.count), Open: \(entries.filter { $0.result == .open }.count)",
            "- Win rate: \(wrStr)",
            "- Net P/L: \(String(format: "%+.2f", netPL))"
        ]

        // Feed heuristic flags from the caller into the prompt as preliminary
        // findings — the AI is asked to *corroborate or refute* each, turning
        // the model's behavioural-pattern analysis into a dialogue with the
        // deterministic rules engine rather than a duplicate blind pass.
        if !behavioralHints.isEmpty {
            userDetails.append("")
            userDetails.append("Preliminary flags already detected by your rules engine — corroborate or explicitly refute each below in your Patterns & Discipline section:")
            for h in behavioralHints { userDetails.append("- \(h)") }
        }
        userDetails.append("")
        userDetails.append("Individual trades:")
        userDetails.append(tradeLines.joined(separator: "\n\n"))
        let user = (userHeaders + userDetails).joined(separator: "\n")
        return (system, user)
    }

    /// Persist the finished report into `DayReviewStore` so it shows
    /// up in the AI review history instead of being lost the moment
    /// the sheet is dismissed. The journal the trades belong to is
    /// stamped on `DayReviewEntry.journalID` so the journal detail screen
    /// can show this review inline in its "AI Review History — this
    /// journal" section without surfacing reviews from other journals.
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
            thinking: thinking.isEmpty ? nil : thinking,
            journalID: scopedJournalID
        )
        dayReviewStore.add(review)
        savedReview = true
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: – Per-journal engine / model persistence
    // ═══════════════════════════════════════════════════════════════

    private enum JournalPrefSlot: String { case engine, model, effort }

    private func journalPrefKey(_ slot: JournalPrefSlot) -> String {
        "ai.journal.\(scopedJournalID.uuidString).\(slot.rawValue)"
    }

    /// On appear, override seeded global defaults with this journal's
    /// last-used settings if any were ever persisted.
    private func applyPerJournalDefaults() {
        if let raw = UserDefaults.standard.string(forKey: journalPrefKey(.engine)),
           let kind = AIEngineKind(rawValue: raw) {
            engineKind = kind
        }
        switch engineKind {
        case .claude:
            if let m  = UserDefaults.standard.string(forKey: journalPrefKey(.model))  { claudeModelID  = m }
            if let ef = UserDefaults.standard.string(forKey: journalPrefKey(.effort)) { claudeEffortID = ef }
        case .codex:
            if let m  = UserDefaults.standard.string(forKey: journalPrefKey(.model))  { codexModelID   = m }
            if let ef = UserDefaults.standard.string(forKey: journalPrefKey(.effort)) { codexEffortID  = ef }
        case .opencode:
            if let m = UserDefaults.standard.string(forKey: journalPrefKey(.model)) { opencodeModelID = m }
        }
    }

    private func persistPerJournalSettings(_ slot: JournalPrefSlot) {
        let key = journalPrefKey(slot)
        switch (slot, engineKind) {
        case (.engine, _):                    UserDefaults.standard.set(engineKind.rawValue, forKey: key)
        case (.model, .claude):               UserDefaults.standard.set(claudeModelID, forKey: key)
        case (.effort, .claude):              UserDefaults.standard.set(claudeEffortID, forKey: key)
        case (.model, .codex):                UserDefaults.standard.set(codexModelID, forKey: key)
        case (.effort, .codex):               UserDefaults.standard.set(codexEffortID, forKey: key)
        case (.model, .opencode):             UserDefaults.standard.set(opencodeModelID, forKey: key)
        case (.effort, .opencode):            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Look up the most recent saved review for *this* journal and *this*
    /// period scope, excluding whatever the current run produced. Used to
    /// drive the "vs Previous" disclosure so the user can compare against
    /// the prior verdict on the same period.
    private func refreshPreviousReview() {
        previousReview = dayReviewStore.previousReview(journalID: scopedJournalID,
                                                        matchingPeriodTitle: periodTitle)
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

    /// Date+time formatter used by the "Previous review — …" disclosure.
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d, yyyy · HH:mm"; return f
    }()
}
