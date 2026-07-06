import SwiftUI
import UniformTypeIdentifiers

/// A single journal's trades (sidebar → Journal → tap a journal row).
/// A hand-written log of trades the user actually took: position,
/// profit/loss, free-form notes, and — for ideas that came from an AI
/// run — a reference back to that analysis. Complements the Portfolio
/// analytics (which grades *paper* trades) with a record of real
/// decisions and their outcomes.
///
/// Scoped to one `Journal` (`journalID`) — `JournalListView` is what the
/// user actually lands on first; this is pushed on top when they open a
/// specific journal, and `onBack` returns them to the list.
struct JournalDetailView: View {
    let journalID: UUID
    let onBack: () -> Void

    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var journal: JournalStore
    @EnvironmentObject private var dayReviewStore: DayReviewStore

    @State private var filter: JournalEntry.Result? = nil
    @State private var sheetEntry: JournalEntry? = nil
    @State private var groupByDay: Bool = false
    @State private var showAnalytics: Bool = true
    /// Tracks any import error message to surface in an alert.
    @State private var importError: String? = nil
    @State private var aiEntry: JournalEntry? = nil
    @State private var aiDayEntries: [JournalEntry]? = nil
    @State private var aiDayDate: Date? = nil
    @State private var aiPeriodTitle: String? = nil
    /// Scope of the period handed to `JournalDayAISheet`. Set alongside
    /// `aiDayEntries`; lets the day-AI prompt frame "today" vs "this week"
    /// vs "all-time" instead of speaking of "this trading day" for every
    /// run.
    #if !os(iOS)
    @State private var aiDayScope: JournalDayAISheet.PeriodScope = .day
    #else
    @State private var aiDayScope: String = "day"
    #endif
    /// Pre-computed heuristic behavioral flags passed into the AI prompt
    /// as "corroborate or refute each" so the model's behavioural
    /// analysis builds on the rules engine instead of redoing it blind.
    @State private var aiDayHints: [String] = []
    /// Selected journal entry for the side inspector (item 15). nil when
    /// no entry is selected — the inspector pane collapses.
    @State private var selectedEntryID: UUID? = nil
    @State private var showBehavioralWarnings: Bool = true
    @State private var showReviewHistory: Bool = false
    /// Inline "AI Review History — this journal" collapsible section,
    /// scoped to this journal's saved `DayReviewEntry`s (legacy nil-
    /// journal reviews included so an upgrade doesn't hide prior history).
    @State private var showInlineHistory: Bool = false
    /// Free-text search across title / notes / pair (case-insensitive).
    @State private var searchText: String = ""
    /// Row ordering for the flat (non-grouped) list.
    @State private var sortOrder: SortOrder = .newest
    enum SortOrder: String, CaseIterable, Identifiable {
        case newest = "Newest"
        case oldest = "Oldest"
        case bestPL = "Best P/L"
        case worstPL = "Worst P/L"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .newest:  return "arrow.down"
            case .oldest:  return "arrow.up"
            case .bestPL:  return "arrow.up.right"
            case .worstPL: return "arrow.down.right"
            }
        }
    }

    // ── Date range ────────────────────────────────────────────────
    enum DatePreset: String, CaseIterable, Identifiable {
        case all = "All"
        case today = "Today"
        case yesterday = "Yesterday"
        case week = "This Week"
        case month = "This Month"
        case custom = "Custom"
        var id: String { rawValue }
        /// Short label admired on the always-on "AI [period]" header
        /// button (item 4/5). "All" gets a friendlier "All-Time" so the
        /// button doesn't read "AI All".
        var buttonLabelForAI: String {
            switch self {
            case .all:       return "All-Time"
            case .today:     return "Today"
            case .yesterday: return "Yesterday"
            case .week:      return "This Week"
            case .month:     return "This Month"
            case .custom:    return "Custom"
            }
        }
    }
    @State private var datePreset: DatePreset = .all
    @State private var customStart: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customEnd: Date = Date()

    /// Display name of the journal this view is scoped to. Falls back
    /// to a generic label if the journal was deleted out from under this
    /// view (shouldn't happen — `JournalView` drops back to the list
    /// the moment that occurs — but avoids a crash if it briefly does).
    private var journalName: String {
        journal.journals.first(where: { $0.id == journalID })?.name ?? "Journal"
    }

    /// This journal's entries — every place the old single-journal view
    /// read `journal.entries` / `journal.sorted` now reads this instead.
    private var scopedEntries: [JournalEntry] { journal.entries(in: journalID) }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    header
                    if scopedEntries.isEmpty {
                        emptyState
                    } else {
                        summaryCards
                        metricsStrip
                        analyticsSection
                        behavioralWarningsSection
                        inlineAIHistorySection
                        filterRow
                        if groupByDay {
                            groupedList
                        } else {
                            entryList(filteredEntries)
                        }
                    }
                }
                .padding(Theme.Spacing.xl)
            }
            // Side inspector pane (item 15). Shows only when an entry is
            // selected; collapses with a slide transition otherwise.
            if let selected = selectedEntry {
                inspectorPane(for: selected)
                    .frame(width: 288)
                    .background(Theme.Color.surface)
                    .overlay(Rectangle().fill(Theme.Color.border).frame(width: 1), alignment: .leading)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: selectedEntryID)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Color.canvas)
        // Hidden keyboard-shortcut buttons (item 14) — invisible & non-
        // hit-testing, but present in the responder chain so their
        // shortcuts fire when the Journal detail screen is focused.
        // ⌘N opens a new entry; ⌘⇧A opens the AI period review.
        .background {
            Color.clear
                .overlay(alignment: .topLeading) {
                    Button { sheetEntry = blankDraft() } label: { EmptyView() }
                        .keyboardShortcut("n", modifiers: .command)
                        .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false)
                    Button { openPeriodAI() } label: { EmptyView() }
                        .keyboardShortcut("a", modifiers: [.command, .shift])
                        .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false)
                }
                .allowsHitTesting(false)
        }
        .sheet(item: $sheetEntry) { draft in
            let isExisting = journal.entries.contains { $0.id == draft.id }
            JournalEntrySheet(
                entry: draft,
                heading: isExisting ? "Edit journal entry" : "New journal entry",
                onSave: { journal.upsert($0) },
                onDelete: isExisting ? { journal.remove(draft.id) } : nil
            )
            .environmentObject(app)
        }
        #if !os(iOS)
        .sheet(item: $aiEntry) { entry in
            JournalAISheet(entry: entry)
                .environmentObject(journal)
                .environmentObject(app)
        }
        .sheet(isPresented: Binding(
            get: { aiDayEntries != nil },
            set: { if !$0 { aiDayEntries = nil; aiDayDate = nil; aiPeriodTitle = nil } }
        )) {
            if let entries = aiDayEntries, let day = aiDayDate {
                JournalDayAISheet(
                    entries: entries,
                    day: day,
                    periodTitle: aiPeriodTitle,
                    periodScope: aiDayScope,
                    behavioralHints: aiDayHints,
                    journalID: journalID
                )
                .environmentObject(app)
                .environmentObject(dayReviewStore)
            }
        }
        #endif
        .sheet(isPresented: $showReviewHistory) {
            DayReviewHistoryView()
                .environmentObject(dayReviewStore)
        }
        .alert("Import failed", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        // Entries added from outside this screen (e.g. "Add to journal"
        // on an AI analysis run) have no journal context of their own —
        // they land in whichever journal the user had open most
        // recently. Mark this one as soon as its screen appears.
        .task { journal.markLastUsed(journalID) }
    }

    // ── Header ────────────────────────────────────────────────────
    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.Color.surface))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.Color.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Back to all journals")
            Label(journalName, systemImage: "book.closed.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.Color.textPrimary)
            Spacer()
            // Group by day toggle
            Button {
                groupByDay.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Group by day")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(groupByDay ? .white : Theme.Color.textSecondary)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(groupByDay ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.Color.surface))
                )
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(groupByDay ? Color.clear : Theme.Color.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            // Import / Export — folded into one overflow menu to keep
            // the header uncluttered on narrow windows.
            Menu {
                Button {
                    importCTraderCSV()
                } label: {
                    Label("Import cTrader CSV…", systemImage: "square.and.arrow.down")
                }
                if !scopedEntries.isEmpty {
                    Button {
                        exportCSV()
                    } label: {
                        Label("Export journal CSV…", systemImage: "square.and.arrow.up")
                    }
                }
                if !dayReviewStore.reviews.isEmpty {
                    Button {
                        showReviewHistory = true
                    } label: {
                        Label("AI Review History…", systemImage: "clock.arrow.circlepath")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(width: 30, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.Color.surface))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.Color.border, lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Import / export journal data")
            // AI period analysis button — always visible when this scope has
            // any entries (previously hidden for .all, which was the one
            // period you most wanted a single review for). The label
            // adapts to the chosen scope ("AI Today" / "AI This Week" /
            // "AI All-Time" / "AI Custom"). For all-time we review every
            // entry in this journal, not just rangeEntries (which the
            // filter sliders narrow); that matches the user's mental
            // model of an all-time retrospective.
            if !aiScopeHasEntries {
                EmptyView()
            } else {
                Button {
                    openPeriodAI()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                        Text("AI \(currentPeriodButtonLabel)")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accentGradient))
                }
                .buttonStyle(.plain)
                .help("Comprehensive AI review of all trades in this period (⌘⇧A)")
            }
            // New entry
            Button {
                sheetEntry = blankDraft()
            } label: {
                Label("New entry", systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accentGradient))
            }
            .buttonStyle(.plain)
        }
    }

    #if !os(iOS)
    private func openPeriodAI() {
        let entries = aiScopeEntries
        guard !entries.isEmpty else { return }
        let (scope, title): (JournalDayAISheet.PeriodScope, String)
        switch datePreset {
        case .today:
            scope = .day; title = "Today — \(Self.dayFmt.string(from: Date()))"
        case .yesterday:
            let y = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
            scope = .yesterday; title = "Yesterday — \(Self.dayFmt.string(from: y))"
        case .week:
            scope = .week; title = "This Week"
        case .month:
            let f = DateFormatter(); f.dateFormat = "MMMM yyyy"
            scope = .month; title = f.string(from: Date())
        case .custom:
            scope = .custom
            title = "\(Self.dayFmt.string(from: customStart)) → \(Self.dayFmt.string(from: customEnd))"
        case .all:
            scope = .all; title = "\(journalName) — All Time"
        }
        aiDayEntries = entries
        aiDayDate = entries.first?.date ?? Date()
        aiPeriodTitle = title
        aiDayScope = scope
        aiDayHints = Self.hintLines(for: Self.computeWarnings(entries))
    }
    #else
    private func openPeriodAI() {
        // AI period reviews not available on iPad (requires Claude/Codex)
    }
    #endif

    /// Entries the AI period review would actually cover — `rangeEntries`
    /// for any non-All preset, every scoped entry for All-Time. Pre-computed
    /// here so both the header button's visibility (item 4/5) and
    /// `openPeriodAI()` agree on what's in scope without recomputing.
    private var aiScopeEntries: [JournalEntry] {
        datePreset == .all ? journal.sorted(in: journalID) : rangeEntries
    }
    private var aiScopeHasEntries: Bool { !aiScopeEntries.isEmpty }
    /// Short label shown on the header's AI button — mirrors the
    /// day-AI sheet's `PeriodScope.buttonLabel` so the button and the
    /// eventual sheet title use the same vocabulary.
    private var currentPeriodButtonLabel: String {
        datePreset.buttonLabelForAI
    }

    private func blankDraft() -> JournalEntry {
        let pairID = app.selectedPairID ?? app.pairs.first?.id ?? ""
        let pairName = app.pairs.first { $0.id == pairID }?.name ?? ""
        return JournalEntry(journalID: journalID, pairID: pairID, pairName: pairName)
    }

    /// Draft pre-set to noon on a specific calendar day. Used by the
    /// day-header "+" button so the new entry lands in that day's group.
    private func draftFor(day: Date) -> JournalEntry {
        let pairID = app.selectedPairID ?? app.pairs.first?.id ?? ""
        let pairName = app.pairs.first { $0.id == pairID }?.name ?? ""
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
        return JournalEntry(date: noon, journalID: journalID, pairID: pairID, pairName: pairName)
    }

    /// Helper invoked by the group-by-day "Analyse Day" button — sets the
    /// AI sheet's period title from the day-group's calendar day.
    private func aiDayPeriodTitleForGroup(_ group: DayGroup) {
        aiPeriodTitle = Self.dayFmt.string(from: group.day)
    }

    // ── Analytics section ─────────────────────────────────────────

    private var analyticsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            // Collapsible header row
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showAnalytics.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showAnalytics ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.Color.textMuted)
                    Text("CHARTS")
                        .font(.system(size: 9, weight: .heavy))
                        .tracking(0.8)
                        .foregroundStyle(Theme.Color.textMuted)
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if showAnalytics {
                JournalAnalyticsView(entries: rangeEntries)
                    .transition(AnyTransition.opacity.combined(with: AnyTransition.move(edge: .top)))
            }
        }
    }

    // ── Behavioral warnings ───────────────────────────────────────

    fileprivate struct BehaviorWarning: Identifiable {
        let id: String
        let icon: String
        let color: Color
        let title: String
        let detail: String
    }

    private var behavioralWarnings: [BehaviorWarning] {
        Self.computeWarnings(rangeEntries)
    }

    /// Same heuristic the rules engine shows in the
    /// "BEHAVIORAL PATTERNS" section — lifted into a static helper so
    /// the AI prompt builder can run it on a *different* slice than
    /// the one currently in view (e.g. the all-time period vs the
    /// today-filtered list).
    @MainActor fileprivate static func computeWarnings(_ entries: [JournalEntry]) -> [BehaviorWarning] {
        let sorted = entries.sorted { $0.date < $1.date }
        guard sorted.count >= 2 else { return [] }
        var warnings: [BehaviorWarning] = []

        // 1. Revenge trades: loss followed by another trade within 15 min
        var revengeDates: [String] = []
        for i in 1..<sorted.count {
            let prev = sorted[i - 1]
            let curr = sorted[i]
            if prev.result == .loss {
                let gap = curr.date.timeIntervalSince(prev.date)
                if gap >= 0 && gap <= 900 { // 15 min
                    revengeDates.append(Self.timeFmt.string(from: curr.date))
                }
            }
        }
        if !revengeDates.isEmpty {
            warnings.append(.init(
                id: "revenge",
                icon: "flame.fill",
                color: Theme.Color.danger,
                title: "Possible revenge trading (\(revengeDates.count)x)",
                detail: "Trade(s) opened within 15 min of a loss: \(revengeDates.joined(separator: ", "))"
            ))
        }

        // 2. Overtrading: 4+ trades within any 60-minute window
        var overtradingWindows: [String] = []
        for i in 0..<sorted.count {
            let windowStart = sorted[i].date
            let windowEnd   = windowStart.addingTimeInterval(3600)
            let inWindow = sorted.filter { $0.date >= windowStart && $0.date <= windowEnd }
            if inWindow.count >= 4 {
                let label = Self.timeFmt.string(from: windowStart)
                if !overtradingWindows.contains(label) {
                    overtradingWindows.append(label)
                }
            }
        }
        if !overtradingWindows.isEmpty {
            warnings.append(.init(
                id: "overtrade",
                icon: "exclamationmark.triangle.fill",
                color: Theme.Color.warn,
                title: "Overtrading detected",
                detail: "4+ trades in a 60-min window starting at: \(overtradingWindows.joined(separator: ", "))"
            ))
        }

        // 3. Consecutive losses ≥ 3 in a row
        var maxStreak = 0, streak = 0
        for e in sorted {
            if e.result == .loss { streak += 1; maxStreak = max(maxStreak, streak) }
            else if e.result == .win { streak = 0 }
        }
        if maxStreak >= 3 {
            warnings.append(.init(
                id: "streak",
                icon: "arrow.down.circle.fill",
                color: Theme.Color.danger,
                title: "Loss streak of \(maxStreak) in a row",
                detail: "Consider pausing after 2 consecutive losses — the third is often an emotional trade."
            ))
        }

        // 4. Late-session drift: losses clustered in trades taken after profitable early session
        let early = sorted.filter { Calendar.current.component(.hour, from: $0.date) < 12 }
        let late  = sorted.filter { Calendar.current.component(.hour, from: $0.date) >= 14 }
        if early.count >= 2 && late.count >= 2 {
            let earlyNet = early.reduce(0.0) { $0 + $1.profitLoss }
            let lateNet  = late.reduce(0.0)  { $0 + $1.profitLoss }
            if earlyNet > 0 && lateNet < 0 && abs(lateNet) > earlyNet * 0.5 {
                warnings.append(.init(
                    id: "latefade",
                    icon: "moon.fill",
                    color: Theme.Color.info,
                    title: "Late-session gave back gains",
                    detail: String(format: "Morning: %+.2f → Afternoon: %+.2f. Consider stopping after morning session.", earlyNet, lateNet)
                ))
            }
        }

        return warnings
    }

    /// One short line per warning, the form the model expects in its
    /// "preliminary flags already detected by your rules engine" prompt
    /// block. The model is asked to corroborate or refute each.
    @MainActor fileprivate static func hintLines(for warnings: [BehaviorWarning]) -> [String] {
        warnings.map { "\($0.title). \($0.detail)" }
    }

    /// Public-facing hook used by `JournalListView`'s all-time AI run:
    /// runs the rules engine over the supplied entries and returns the
    /// warning lines ready to feed into `JournalDayAISheet.behavioralHints`.
    /// Kept `internal` so callers in other files don't need to know about
    /// the private `BehaviorWarning` storage type.
    @MainActor static func behavioralHints(for entries: [JournalEntry]) -> [String] {
        hintLines(for: computeWarnings(entries))
    }

    @ViewBuilder
    private var behavioralWarningsSection: some View {
        let warnings = behavioralWarnings
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showBehavioralWarnings.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showBehavioralWarnings ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.Color.warn)
                        Text("BEHAVIORAL PATTERNS")
                            .font(.system(size: 9, weight: .heavy))
                            .tracking(0.8)
                            .foregroundStyle(Theme.Color.warn)
                        Text("\(warnings.count)")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Theme.Color.warn))
                        Spacer()
                    }
                }
                .buttonStyle(.plain)

                if showBehavioralWarnings {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(warnings) { w in
                            HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                                Image(systemName: w.icon)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(w.color)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(w.title)
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(w.color)
                                    Text(w.detail)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.Color.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(Theme.Spacing.sm)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(w.color.opacity(0.07)))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(w.color.opacity(0.25), lineWidth: 1))
                        }
                    }
                    .transition(AnyTransition.opacity.combined(with: AnyTransition.move(edge: .top)))
                }
            }
        }
    }

    // ── Summary ───────────────────────────────────────────────────
    private struct Summary {
        var count = 0
        var wins = 0
        var losses = 0
        var open = 0
        var net = 0.0
        var grossProfit = 0.0   // sum of positive P/L
        var grossLoss = 0.0     // sum of |negative P/L|
        var best = 0.0          // single biggest win
        var worst = 0.0         // single biggest loss (most negative)
        var graded: Int { wins + losses }
        var winRate: Double { graded == 0 ? 0 : Double(wins) / Double(graded) }
        /// Gross profit ÷ gross loss. nil when there are no losses yet.
        var profitFactor: Double? { grossLoss == 0 ? nil : grossProfit / grossLoss }
        var avgWin: Double { wins == 0 ? 0 : grossProfit / Double(wins) }
        var avgLoss: Double { losses == 0 ? 0 : grossLoss / Double(losses) }
        /// Average P/L per graded trade (expectancy).
        var expectancy: Double { graded == 0 ? 0 : (grossProfit - grossLoss) / Double(graded) }
    }

    private func makeSummary(_ entries: [JournalEntry]) -> Summary {
        var s = Summary()
        for e in entries {
            s.count += 1
            s.net += e.profitLoss
            s.best = max(s.best, e.profitLoss)
            s.worst = min(s.worst, e.profitLoss)
            if e.profitLoss > 0 { s.grossProfit += e.profitLoss }
            else if e.profitLoss < 0 { s.grossLoss += -e.profitLoss }
            switch e.result {
            case .win:       s.wins += 1
            case .loss:      s.losses += 1
            case .open:      s.open += 1
            case .breakeven: break
            }
        }
        return s
    }

    private var summaryCards: some View {
        let s = makeSummary(rangeEntries)
        return HStack(spacing: Theme.Spacing.md) {
            statCard(label: "ENTRIES", value: "\(s.count)",
                     subtitle: "\(s.open) open", tint: Theme.Color.textPrimary)
            statCard(label: "WIN RATE", value: String(format: "%.0f%%", s.winRate * 100),
                     subtitle: "\(s.wins)W / \(s.losses)L",
                     tint: s.winRate >= 0.5 ? Theme.Color.success : Theme.Color.danger)
            statCard(label: "NET P/L", value: String(format: "%+.2f", s.net),
                     subtitle: "all entries",
                     tint: s.net >= 0 ? Theme.Color.success : Theme.Color.danger)
        }
    }

    /// A compact secondary row of the metrics traders actually review:
    /// profit factor, average win/loss, expectancy, and the single
    /// best / worst trade in the period. Only graded trades feed these.
    @ViewBuilder
    private var metricsStrip: some View {
        let s = makeSummary(rangeEntries)
        if s.graded > 0 {
            HStack(spacing: Theme.Spacing.sm) {
                metricPill(
                    label: "PROFIT FACTOR",
                    value: s.profitFactor.map { String(format: "%.2f", $0) } ?? "∞",
                    tint: (s.profitFactor ?? .infinity) >= 1 ? Theme.Color.success : Theme.Color.danger)
                metricPill(label: "AVG WIN", value: String(format: "+%.2f", s.avgWin), tint: Theme.Color.success)
                metricPill(label: "AVG LOSS", value: String(format: "-%.2f", s.avgLoss), tint: Theme.Color.danger)
                metricPill(
                    label: "EXPECTANCY",
                    value: String(format: "%+.2f", s.expectancy),
                    tint: s.expectancy >= 0 ? Theme.Color.success : Theme.Color.danger)
                metricPill(label: "BEST", value: String(format: "+%.2f", s.best), tint: Theme.Color.success)
                metricPill(label: "WORST", value: String(format: "%.2f", s.worst), tint: Theme.Color.danger)
            }
        }
    }

    private func metricPill(label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .heavy))
                .tracking(0.5)
                .foregroundStyle(Theme.Color.textMuted)
            Text(value)
                .font(.system(size: 14, weight: .bold).monospacedDigit())
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(Theme.Color.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).strokeBorder(Theme.Color.border, lineWidth: 1))
    }

    private func statCard(label: String, value: String, subtitle: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(Theme.Color.textMuted)
            Text(value)
                .font(.system(size: 22, weight: .bold).monospacedDigit())
                .foregroundStyle(tint)
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(Theme.Color.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.Color.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.Color.border, lineWidth: 1))
    }

    // ── Inline AI review history (this journal) ─────────────────────

    /// Collapsible list of saved AI reviews scoped to this journal — the
    /// existing "AI Review History…" overflow menu surfaced *every*
    /// saved review (regardless of journal). With per-journal
    /// `DayReviewEntry.journalID`, we can scope this list down to "this
    /// journal only" so a backtesting journal's gap-year retrospective
    /// doesn't get mixed into the user's prop-firm reviews. Tapping a
    /// row opens the existing `DayReviewHistoryView`-style detail.
    @ViewBuilder
    private var inlineAIHistorySection: some View {
        let reviews = dayReviewStore.reviews(for: journalID)
        if !reviews.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showInlineHistory.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showInlineHistory ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.Color.accentStart)
                        Text("AI REVIEW HISTORY — THIS JOURNAL")
                            .font(.system(size: 9, weight: .heavy))
                            .tracking(0.8)
                            .foregroundStyle(Theme.Color.accentStart)
                        Text("\(reviews.count)")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Theme.Color.accentStart))
                        Spacer()
                    }
                }
                .buttonStyle(.plain)

                if showInlineHistory {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(reviews.prefix(8)) { review in
                            inlineHistoryRow(review)
                        }
                        if reviews.count > 8 {
                            Button { showReviewHistory = true } label: {
                                Text("See all \(reviews.count) reviews…")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Theme.Color.accentStart)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .transition(AnyTransition.opacity.combined(with: AnyTransition.move(edge: .top)))
                }
            }
        }
    }

    private func inlineHistoryRow(_ review: DayReviewEntry) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 1) {
                Text(review.periodTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                HStack(spacing: 6) {
                    Text("\(review.tradeCount) trades")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Color.textMuted)
                    Text("· \(review.engineLabel) · \(review.modelLabel)")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Color.textMuted)
                    Text("· \(Self.shortFmt.string(from: review.createdAt))")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Color.textMuted)
                }
            }
            Spacer()
            Text(String(format: "%+.2f", review.netPL))
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(review.netPL >= 0 ? Theme.Color.success : Theme.Color.danger)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.Color.textMuted)
        }
        .padding(.horizontal, Theme.Spacing.md).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.Color.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.Color.border, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { showReviewHistory = true }
    }

    // ── Side inspector (item 15) ───────────────────────────────────

    @ViewBuilder
    private func inspectorPane(for id: UUID) -> some View {
        if let entry = journal.entries.first(where: { $0.id == id }) {
            EntryInspector(
                entry: entry,
                isChartActive: app.journalChartEntry?.id == entry.id,
                onEdit: { sheetEntry = entry },
                onChart: {
                    if app.journalChartEntry?.id == entry.id { app.journalChartEntry = nil }
                    else {
                        app.selectedPairID = entry.pairID
                        app.journalChartEntry = entry
                        app.selectedSidebarItem = .dashboard
                    }
                },
                onAI: { aiEntry = entry },
                onClose: { selectedEntryID = nil }
            )
        } else {
            EmptyView()
        }
    }

    private var selectedEntry: UUID? {
        guard let id = selectedEntryID,
              journal.entries.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    // ── Filter ────────────────────────────────────────────────────
    private var filterRow: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            // Date range presets + custom picker
            HStack(spacing: 6) {
                Text("PERIOD")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Color.textMuted)
                ForEach(DatePreset.allCases) { preset in
                    presetChip(preset)
                }
                Spacer()
            }
            // Custom date pickers — visible only in custom mode
            if datePreset == .custom {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "calendar")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Color.textMuted)
                    DatePicker("From", selection: $customStart, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .font(.system(size: 11))
                    Text("→")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Color.textMuted)
                    DatePicker("To", selection: $customEnd, in: customStart..., displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .font(.system(size: 11))
                }
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.Color.surface))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.Color.border, lineWidth: 1))
            }
            // Result filter + search + sort
            HStack(spacing: 6) {
                Text("RESULT")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Color.textMuted)
                filterChip(label: "All", value: nil)
                ForEach(JournalEntry.Result.allCases) { r in
                    filterChip(label: r.label, value: r)
                }
                Spacer()
                searchField
                if !groupByDay { sortMenu }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.Color.textMuted)
            TextField("Search title, notes, pair…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textPrimary)
                .frame(width: 160)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Color.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surface))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(searchText.isEmpty ? Theme.Color.border : Theme.Color.accentStart.opacity(0.4), lineWidth: 1))
    }

    private var sortMenu: some View {
        Menu {
            ForEach(SortOrder.allCases) { order in
                Button {
                    sortOrder = order
                } label: {
                    Label(order.rawValue, systemImage: sortOrder == order ? "checkmark" : order.icon)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: sortOrder.icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(sortOrder.rawValue)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Theme.Color.textSecondary)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surface))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.Color.border, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func presetChip(_ preset: DatePreset) -> some View {
        let selected = datePreset == preset
        return Button {
            datePreset = preset
        } label: {
            Text(preset.rawValue)
                .font(.system(size: 11, weight: selected ? .bold : .medium))
                .foregroundStyle(selected ? .white : Theme.Color.textSecondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(
                    selected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.Color.surface)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selected ? Color.clear : Theme.Color.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func filterChip(label: String, value: JournalEntry.Result?) -> some View {
        let selected = filter == value
        return Button {
            filter = value
        } label: {
            Text(label)
                .font(.system(size: 11, weight: selected ? .bold : .medium))
                .foregroundStyle(selected ? .white : Theme.Color.textSecondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(
                    selected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.Color.surface)))
        }
        .buttonStyle(.plain)
    }

    // ── Date range filtering ──────────────────────────────────────

    private var dateRange: (start: Date, end: Date)? {
        let cal = Calendar.current
        let now = Date()
        switch datePreset {
        case .all:    return nil
        case .today:
            let s = cal.startOfDay(for: now)
            let e = cal.date(byAdding: .day, value: 1, to: s)!
            return (s, e)
        case .yesterday:
            let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
            let s = cal.startOfDay(for: yesterday)
            let e = cal.startOfDay(for: now)
            return (s, e)
        case .week:
            let s = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
            let e = cal.date(byAdding: .day, value: 7, to: s)!
            return (s, e)
        case .month:
            let comps = cal.dateComponents([.year, .month], from: now)
            let s = cal.date(from: comps)!
            let e = cal.date(byAdding: .month, value: 1, to: s)!
            return (s, e)
        case .custom:
            let s = cal.startOfDay(for: customStart)
            let e = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: customEnd))!
            return (s, e)
        }
    }

    /// Entries restricted to the current date range (ignores result filter).
    private var rangeEntries: [JournalEntry] {
        let all = journal.sorted(in: journalID)
        guard let r = dateRange else { return all }
        return all.filter { $0.date >= r.start && $0.date < r.end }
    }

    /// Case-insensitive match against title, notes, and pair name.
    private func matchesSearch(_ entry: JournalEntry) -> Bool {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return entry.title.lowercased().contains(q)
            || entry.notes.lowercased().contains(q)
            || entry.pairName.lowercased().contains(q)
    }

    // ── Flat list ─────────────────────────────────────────────────
    private var filteredEntries: [JournalEntry] {
        var result = rangeEntries.filter(matchesSearch)
        if let f = filter { result = result.filter { $0.result == f } }
        switch sortOrder {
        case .newest:  break // rangeEntries is already newest-first
        case .oldest:  result.reverse()
        case .bestPL:  result.sort { $0.profitLoss > $1.profitLoss }
        case .worstPL: result.sort { $0.profitLoss < $1.profitLoss }
        }
        return result
    }

    private func entryList(_ entries: [JournalEntry]) -> some View {
        LazyVStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ForEach(entries) { entry in
                entryRow(entry)
            }
            if entries.isEmpty {
                Text("No entries match this filter.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Color.textMuted)
                    .padding(.vertical, Theme.Spacing.lg)
            }
        }
    }

    private func entryRow(_ entry: JournalEntry) -> some View {
        JournalEntryRow(
            entry: entry,
            isChartActive: app.journalChartEntry?.id == entry.id,
            isSelected: selectedEntryID == entry.id,
            onSelect: { selectedEntryID = entry.id },
            onEdit: { sheetEntry = entry },
            onChart: {
                if app.journalChartEntry?.id == entry.id {
                    app.journalChartEntry = nil
                } else {
                    app.selectedPairID = entry.pairID
                    app.journalChartEntry = entry
                    app.selectedSidebarItem = .dashboard
                }
            },
            onAI: { aiEntry = entry }
        )
    }

    // ── Grouped by day ────────────────────────────────────────────

    private struct DayGroup: Identifiable {
        let day: Date       // midnight of that calendar day
        let entries: [JournalEntry]
        var id: Date { day }
    }

    private var groupedList: some View {
        let groups = makeDayGroups(filteredEntries)
        return LazyVStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            if groups.isEmpty {
                Text("No entries match this filter.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Color.textMuted)
                    .padding(.vertical, Theme.Spacing.lg)
            } else {
                ForEach(groups) { group in
                    daySection(group)
                }
            }
        }
    }

    private func daySection(_ group: DayGroup) -> some View {
        let s = makeSummary(group.entries)
        return VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            // Day header row
            HStack(spacing: Theme.Spacing.sm) {
                Text(Self.dayFmt.string(from: group.day))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Capsule()
                    .fill(Theme.Color.border)
                    .frame(height: 1)
                Text("\(group.entries.count) trade\(group.entries.count == 1 ? "" : "s")")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.Color.textMuted)
                if s.graded > 0 {
                    Text(String(format: "%.0f%% WR", s.winRate * 100))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(s.winRate >= 0.5 ? Theme.Color.success : Theme.Color.danger)
                }
                Text(String(format: "%+.2f", s.net))
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(s.net >= 0 ? Theme.Color.success : Theme.Color.danger)
                // AI analyse all trades for this day
                Button {
                    aiDayEntries = group.entries
                    aiDayDate = group.day
                    #if !os(iOS)
                    aiDayScope = .day
                    #endif
                    aiDayPeriodTitleForGroup(group)
                    aiDayHints = Self.hintLines(for: Self.computeWarnings(group.entries))
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9, weight: .bold))
                        Text("Analyse Day")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(Theme.Color.accentStart)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.Color.accentStart.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(Theme.Color.accentStart.opacity(0.35), lineWidth: 0.8))
                }
                .buttonStyle(.plain)
                .help("AI comprehensive review of all \(group.entries.count) trades this day")
                // Quick-add button for this day
                Button {
                    sheetEntry = draftFor(day: group.day)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Color.accentStart.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Add entry for \(Self.dayFmt.string(from: group.day))")
            }
            ForEach(group.entries) { entry in
                entryRow(entry)
            }
        }
    }

    private func makeDayGroups(_ entries: [JournalEntry]) -> [DayGroup] {
        let cal = Calendar.current
        var map: [Date: [JournalEntry]] = [:]
        for e in entries {
            let day = cal.startOfDay(for: e.date)
            map[day, default: []].append(e)
        }
        return map.keys
            .sorted(by: >)
            .map { DayGroup(day: $0, entries: map[$0]!.sorted { $0.date > $1.date }) }
    }

    // ── Row → see JournalEntryRow below ──────────────────────────

    // ── Empty state ───────────────────────────────────────────────
    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Spacer().frame(height: 80)
            Image(systemName: "book.closed")
                .font(.system(size: 36))
                .foregroundStyle(Theme.Color.textMuted)
            Text("Log your first trade.")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Color.textSecondary)
            Text("New entry, import a cTrader CSV, or hit \"Add to journal\" on an AI analysis.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack(spacing: Theme.Spacing.sm) {
                Button {
                    importCTraderCSV()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down")
                        Text("Import CSV")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.Color.surface))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.Color.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Button {
                    sheetEntry = blankDraft()
                } label: {
                    Label("New entry", systemImage: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accentGradient))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, Theme.Spacing.sm)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }


    // ── CSV export ────────────────────────────────────────────────

    private func exportCSV() {
        #if !os(iOS)
        let panel = NSSavePanel()
        panel.title = "Export Journal"
        panel.nameFieldStringValue = "journal_export.csv"
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let csv = buildExportCSV(journal.sorted(in: journalID))
        try? csv.write(to: url, atomically: true, encoding: .utf8)
        #endif
    }

    private func buildExportCSV(_ entries: [JournalEntry]) -> String {
        var lines = [
            "Date,Pair,Title,Side,Entry,Take Profit,Stop Loss,Lots,Result,P/L,Notes,AI Engine,AI Kind,AI Timeframe"
        ]
        let iso = ISO8601DateFormatter()
        for e in entries {
            func q(_ s: String) -> String { "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            func p(_ v: Double?) -> String { v.map { String(format: "%.5f", $0) } ?? "" }
            let row = [
                iso.string(from: e.date),
                q(e.pairName), q(e.title),
                e.side.rawValue,
                p(e.entry), p(e.takeProfit), p(e.stopLoss),
                e.lots.map { String(format: "%.2f", $0) } ?? "",
                e.result.rawValue,
                String(format: "%.2f", e.profitLoss),
                q(e.notes),
                q(e.aiEngineLabel ?? ""), q(e.aiKindLabel ?? ""), q(e.aiTimeframeLabel ?? ""),
            ].joined(separator: ",")
            lines.append(row)
        }
        return lines.joined(separator: "\n")
    }

    // ── cTrader CSV import ────────────────────────────────────────

    /// Opens an NSOpenPanel, parses the cTrader statement CSV, and adds
    /// each row as a JournalEntry — skipping any row that matches an
    /// entry already in the journal (idempotent — re-importing the
    /// same statement, or a fresh export that overlaps a previous
    /// one, only adds the genuinely new rows).
    private func importCTraderCSV() {
        #if !os(iOS)
        let panel = NSOpenPanel()
        panel.title = "Import cTrader Statement"
        panel.message = "Select a cTrader CSV statement file"
        panel.allowedContentTypes = [UTType.commaSeparatedText, UTType.plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let raw = try String(contentsOf: url, encoding: .utf8)
            let imported = try parseCTraderCSV(raw, knownPairs: app.pairs)
            var added = 0
            var skipped = 0
            for entry in imported {
                // Identify "the same trade" by pair + side + entry price +
                // close time (to the second) — matches regardless of which
                // file/export it came from, so re-importing a statement
                // that overlaps a previous one (e.g. exporting "today" more
                // than once) only adds the rows not already logged.
                // `scopedEntries` is re-read fresh on every iteration, so
                // a duplicate *within* the same file also gets caught
                // against rows added earlier in this same loop. Scoped to
                // this journal — importing the same statement into two
                // different journals is allowed, re-importing it into
                // the same one isn't.
                let isDuplicate = scopedEntries.contains {
                    $0.pairID == entry.pairID &&
                    $0.side == entry.side &&
                    $0.entry == entry.entry &&
                    abs($0.date.timeIntervalSince(entry.date)) < 1
                }
                if isDuplicate {
                    skipped += 1
                } else {
                    journal.add(entry)
                    added += 1
                }
            }
            if added == 0 && skipped > 0 {
                importError = "No new trades found — all \(skipped) row\(skipped == 1 ? "" : "s") were already in your journal."
            }
        } catch {
            importError = error.localizedDescription
        }
        #endif
    }

    /// Parses a cTrader statement CSV into JournalEntry values.
    ///
    /// Expected columns (quoted, comma-separated):
    ///   Symbol | Opening direction | Closing time (UTC+3:30) |
    ///   Entry price | Closing price | Closing Quantity | Net $ | Balance $
    private func parseCTraderCSV(
        _ raw: String,
        knownPairs: [TradingPair]
    ) throws -> [JournalEntry] {
        let lines = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard lines.count > 1 else {
            throw ImportError.empty
        }

        // Parse header to find column indices (tolerates extra/reordered columns)
        let headerCols = parseCSVRow(lines[0]).map { $0.lowercased() }
        func col(_ keyword: String) -> Int? {
            headerCols.firstIndex(where: { $0.contains(keyword) })
        }
        guard let iSymbol   = col("symbol"),
              let iDir      = col("direction"),
              let iTime     = col("closing time"),
              let iEntry    = col("entry price"),
              let iClose    = col("closing price"),
              let iQty      = col("closing quantity"),
              let iNet      = col("net")
        else {
            throw ImportError.missingColumns
        }
        let iOpenTime = col("opening time")

        var results: [JournalEntry] = []
        for line in lines.dropFirst() {
            let cols = parseCSVRow(line)
            guard cols.count > max(iSymbol, iDir, iTime, iEntry, iClose, iQty, iNet) else { continue }

            let symbol = cols[iSymbol]
            let direction = cols[iDir].lowercased()
            let timeStr = cols[iTime]
            let entryStr = cols[iEntry]
            let closeStr = cols[iClose]
            let qtyStr = cols[iQty]
            let netStr = cols[iNet]

            guard let closeDate = Self.cTraderDateFmt.date(from: timeStr) else { continue }
            guard let entryPrice = Double(entryStr) else { continue }
            let closePriceVal = Double(closeStr)
            let lots = Double(qtyStr.components(separatedBy: " ").first ?? "")
            let netCleaned = netStr.replacingOccurrences(of: " ", with: "")
            guard let netPL = Double(netCleaned) else { continue }

            // Parse opening time if the column exists
            let openDateVal: Date? = iOpenTime.flatMap { idx in
                idx < cols.count ? Self.cTraderDateFmt.date(from: cols[idx]) : nil
            }

            let side: JournalEntry.Side = direction.contains("buy") ? .long : .short
            let result: JournalEntry.Result = netPL > 0 ? .win : (netPL < 0 ? .loss : .breakeven)

            let pair = knownPairs.first { p in
                symbol.lowercased().hasPrefix(p.symbol.lowercased()) ||
                symbol.lowercased() == (p.symbol + "USD").lowercased() ||
                symbol.lowercased() == p.id.lowercased()
            }
            let pairID = pair?.id ?? symbol.lowercased()
            let pairName = pair?.name ?? symbol

            results.append(JournalEntry(
                date: closeDate,      // date = close time for cTrader imports
                journalID: journalID,
                pairID: pairID,
                pairName: pairName,
                title: "\(side == .long ? "Long" : "Short") \(symbol)",
                side: side,
                entry: entryPrice,
                lots: lots,
                openDate: openDateVal,
                closePrice: closePriceVal,
                result: result,
                profitLoss: netPL
            ))
        }
        if results.isEmpty { throw ImportError.noValidRows }
        return results
    }

    /// Splits one CSV row respecting double-quoted fields.
    private func parseCSVRow(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        for ch in line {
            if ch == "\"" {
                inQuotes.toggle()
            } else if ch == "," && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        fields.append(current)
        return fields
    }

    enum ImportError: LocalizedError {
        case empty, missingColumns, noValidRows
        var errorDescription: String? {
            switch self {
            case .empty:          return "The file appears to be empty."
            case .missingColumns: return "Could not find the expected cTrader columns (Symbol, Direction, Closing time, Entry price, Net $). Make sure you're using a Spotware statement export."
            case .noValidRows:    return "No valid trade rows could be parsed from this file."
            }
        }
    }

    private static func priceStr(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", v)
            : String(format: "%.3f", v)
    }

    // ── Formatters ────────────────────────────────────────────────

    /// "26/06/2026 07:12:19.929" — cTrader Spotware statement format
    private static let cTraderDateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yyyy HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Full date+time for flat list rows
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy · HH:mm"
        return f
    }()

    /// Date-only header for group-by-day sections
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d, yyyy"
        return f
    }()

    /// Compact MMd · HH:mm used by inline AI-history rows.
    private static let shortFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d · HH:mm"; return f
    }()
}

// ── JournalEntryRow ───────────────────────────────────────────────────────────
// Owns its own hover state so mouse-moves only re-render this row,
// not the entire JournalView body (which would recompute filteredEntries,
// makeSummary, behavioralWarnings, etc. on every cursor movement).

private struct JournalEntryRow: View {
    let entry: JournalEntry
    var isChartActive: Bool
    var isSelected: Bool
    /// Primary row click → inspector pane (item 15). Previously a row
    /// click opened the edit sheet directly, which left the row's
    /// edit/chart/AI buttons redundantly fire-on-click; the inspector
    /// is a less disruptive read-only look at the trade, with the
    /// existing edit/chart/AI affordances still one click away.
    var onSelect: () -> Void
    var onEdit: () -> Void
    var onChart: () -> Void
    var onAI: () -> Void

    @State private var isHovered = false

    var body: some View {
        let hasLevels = entry.entry != nil || entry.takeProfit != nil || entry.stopLoss != nil
        let trailingPad: CGFloat = hasLevels ? 168 : 106
        return ZStack(alignment: .trailing) {
            Button { onSelect() } label: {
                rowContent(extraTrailingPad: trailingPad)
            }
            .buttonStyle(.plain)
            HStack(spacing: 6) {
                editButton
                if hasLevels { chartButton }
                aiButton
            }
            .padding(.trailing, Theme.Spacing.md)
            .allowsHitTesting(true)
        }
        .onHover { isHovered = $0 }
    }

    private func rowContent(extraTrailingPad: CGFloat) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            RoundedRectangle(cornerRadius: 2)
                .fill(entry.side.color)
                .frame(width: 3, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(entry.title.isEmpty ? entry.pairName : entry.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Color.textPrimary)
                        .lineLimit(1)
                    if entry.hasAIReference {
                        HStack(spacing: 3) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 8, weight: .bold))
                            Text("AI")
                                .font(.system(size: 8, weight: .heavy))
                        }
                        .foregroundStyle(Theme.Color.accentStart)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.Color.accentStart.opacity(0.15)))
                    }
                }
                HStack(spacing: 8) {
                    Text(Self.timeFmt.string(from: entry.date))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Color.textMuted)
                    Text("·").foregroundStyle(Theme.Color.textMuted)
                    Text(entry.pairName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.Color.textSecondary)
                    sideChip
                    if let lots = entry.lots {
                        Text(String(format: "%.2f L", lots))
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.Color.textMuted)
                    }
                    if let ep = entry.entry {
                        Text("·").foregroundStyle(Theme.Color.textMuted)
                        Text("@ \(Self.priceStr(ep))")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(Theme.Color.textMuted)
                    }
                }
            }
            Spacer()
            resultChip
            if entry.profitLoss != 0 || entry.result.isGraded {
                Text(String(format: "%+.2f", entry.profitLoss))
                    .font(.system(size: 15, weight: .bold).monospacedDigit())
                    .foregroundStyle(entry.profitLoss >= 0 ? Theme.Color.success : Theme.Color.danger)
                    .frame(width: 84, alignment: .trailing)
            }
        }
        .padding(Theme.Spacing.md)
        .padding(.trailing, extraTrailingPad)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md)
            .fill(isHovered ? Theme.Color.surfaceHi : Theme.Color.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md)
            .strokeBorder(borderStroke, lineWidth: isSelected ? 1.6 : 1))
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    private var borderStroke: Color {
        if isSelected { return Theme.Color.accentStart }
        return isHovered ? Theme.Color.accentStart.opacity(0.4) : Theme.Color.border
    }

    private var sideChip: some View {
        Text(entry.side.label.uppercased())
            .font(.system(size: 8, weight: .heavy))
            .tracking(0.4)
            .foregroundStyle(entry.side.color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(entry.side.color.opacity(0.16)))
    }

    private var resultChip: some View {
        Text(entry.result.label.uppercased())
            .font(.system(size: 9, weight: .heavy))
            .tracking(0.5)
            .foregroundStyle(entry.result.color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(entry.result.color.opacity(0.18)))
    }

    private var editButton: some View {
        Button { onEdit() } label: {
            HStack(spacing: 3) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 9, weight: .bold))
                Text("Edit")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(Theme.Color.textSecondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Theme.Color.surface))
            .overlay(Capsule().strokeBorder(Theme.Color.border, lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .help("Edit trade (opens the entry sheet)")
    }

    private var chartButton: some View {
        Button { onChart() } label: {
            HStack(spacing: 3) {
                Image(systemName: isChartActive ? "eye.slash" : "chart.line.uptrend.xyaxis")
                    .font(.system(size: 9, weight: .bold))
                Text(isChartActive ? "Hide" : "Chart")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(isChartActive ? Theme.Color.textMuted : Theme.Color.accentStart)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(isChartActive
                ? Theme.Color.surface : Theme.Color.accentStart.opacity(0.12)))
            .overlay(Capsule().strokeBorder(
                isChartActive ? Theme.Color.border : Theme.Color.accentStart.opacity(0.35),
                lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .help(isChartActive ? "Remove from chart" : "Show entry/TP/SL on chart")
    }

    private var aiButton: some View {
        Button { onAI() } label: {
            HStack(spacing: 3) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9, weight: .bold))
                Text("AI")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(Theme.Color.accentStart)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Theme.Color.accentStart.opacity(0.12)))
            .overlay(Capsule().strokeBorder(Theme.Color.accentStart.opacity(0.35), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .help("AI post-mortem — why this trade won or lost")
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy · HH:mm"
        return f
    }()

    private static func priceStr(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", v)
            : String(format: "%.3f", v)
    }
}

// MARK: – EntryInspector (item 15)

/// Right-side read-only inspector for a selected `JournalEntry` (item 15).
/// Lets the user click a row to see everything about the trade without
/// leaving the journal screen or opening modal sheets — including a
/// Quick-stub of the entry's last AI post-mortem excerpt and one-click
/// actions to edit the trade, open it on the chart, or run an AI review.
private struct EntryInspector: View {
    let entry: JournalEntry
    let isChartActive: Bool
    var onEdit: () -> Void
    var onChart: () -> Void
    var onAI: () -> Void
    var onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                headerRow
                Divider().background(Theme.Color.border)
                snapshot
                if entry.hasAIReference { aiExcerptCard }
                notesCard
                Spacer(minLength: 0)
                actionsRow
            }
            .padding(Theme.Spacing.md)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Color.surface)
    }

    private var headerRow: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(entry.result.color.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: entry.result.icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(entry.result.color)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title.isEmpty ? entry.pairName : entry.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                    .lineLimit(1)
                Text(EntryInspector.timeFmt.string(from: entry.date))
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.Color.textMuted)
            }
            Spacer()
            Button { onClose() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.Color.textMuted)
            }
            .buttonStyle(.plain)
        }
    }

    private var snapshot: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                chip(text: entry.side.label.uppercased(),
                     color: entry.side.color)
                chip(text: entry.result.label.uppercased(),
                     color: entry.result.color)
                Spacer()
                if entry.profitLoss != 0 || entry.result.isGraded {
                    Text(String(format: "%+.2f", entry.profitLoss))
                        .font(.system(size: 14, weight: .bold).monospacedDigit())
                        .foregroundStyle(entry.profitLoss >= 0 ? Theme.Color.success : Theme.Color.danger)
                }
            }
            metricRow("PAIR",   entry.pairName)
            metricRow("SIDE",   entry.side.label)
            metricRow("ENTRY",  entry.entry.map(Self.priceStr))
            metricRow("TP",     entry.takeProfit.map(Self.priceStr))
            metricRow("SL",     entry.stopLoss.map(Self.priceStr))
            metricRow("CLOSE",  entry.closePrice.map(Self.priceStr))
            metricRow("LOTS",   entry.lots.map { String(format: "%.2f L", $0) })
            if let e = entry.entry, let sl = entry.stopLoss, let tp = entry.takeProfit {
                let risk = abs(e - sl); let reward = abs(tp - e)
                let rr = risk > 0 ? reward / risk : 0
                metricRow("R:R", String(format: "1 : %.1f", rr))
            }
            if let open = entry.openDate {
                metricRow("DURATION", EntryInspector.durationStr(entry.date.timeIntervalSince(open)))
            }
        }
    }

    private var aiExcerptCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Color.accentStart)
                Text("FROM AI ANALYSIS")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Color.textMuted)
                Spacer()
            }
            if let label = entry.aiEngineLabel { chip(text: label, color: .gray.opacity(0.7)) }
            if let label = entry.aiKindLabel { chip(text: label, color: .gray.opacity(0.7)) }
            if let excerpt = entry.aiReportExcerpt, !excerpt.isEmpty {
                ScrollView { Text(excerpt).font(.system(size: 10)).foregroundStyle(Theme.Color.textSecondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 96)
                    .padding(Theme.Spacing.sm)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surfaceHi))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.Color.border, lineWidth: 1))
            }
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.Color.accentStart.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.Color.accentStart.opacity(0.25), lineWidth: 1))
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("NOTES")
                .font(.system(size: 9, weight: .heavy))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)
            ScrollView {
                Text(entry.notes.isEmpty ? "(none)" : entry.notes)
                    .font(.system(size: 11))
                    .foregroundStyle(entry.notes.isEmpty ? Theme.Color.textMuted : Theme.Color.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 120)
            .padding(Theme.Spacing.sm)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surfaceHi))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.Color.border, lineWidth: 1))
        }
    }

    private var actionsRow: some View {
        VStack(spacing: 6) {
            primaryButton(label: isChartActive ? "Remove from chart" : "Open on chart",
                           icon: isChartActive ? "eye.slash" : "chart.line.uptrend.xyaxis",
                           action: onChart)
            row(label: "Edit", icon: "square.and.pencil", action: onEdit)
            row(label: "AI post-mortem", icon: "sparkles", action: onAI)
        }
    }

    private func primaryButton(label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accentGradient))
        }
        .buttonStyle(.plain)
    }

    private func row(label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(label).font(.system(size: 11, weight: .semibold))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Theme.Color.textMuted)
            }
            .foregroundStyle(Theme.Color.textSecondary)
            .padding(.horizontal, Theme.Spacing.md).padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.Color.surfaceHi))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.Color.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func chip(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .heavy)).tracking(0.4)
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.16)))
    }

    private func metricRow(_ label: String, _ value: String?) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 9, weight: .heavy)).tracking(0.5)
                .foregroundStyle(Theme.Color.textMuted)
            Spacer()
            Text(value ?? "—")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(value == nil ? Theme.Color.textMuted : Theme.Color.textPrimary)
        }
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d, yyyy · HH:mm"; return f
    }()

    private static func priceStr(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", v) : String(format: "%.3f", v)
    }

    private static func durationStr(_ secs: TimeInterval) -> String {
        let s = Int(secs)
        if s < 60    { return "\(s)s" }
        if s < 3600  { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        return "\(s / 86400)d \((s % 86400) / 3600)h"
    }
}

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
