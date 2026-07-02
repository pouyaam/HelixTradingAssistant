import SwiftUI
import UniformTypeIdentifiers

/// The trade journal screen (sidebar → Journal). A hand-written log of
/// trades the user actually took: position, profit/loss, free-form
/// notes, and — for ideas that came from an AI run — a reference back
/// to that analysis. Complements the Portfolio analytics (which grades
/// *paper* trades) with a record of real decisions and their outcomes.
struct JournalView: View {
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
    @State private var showBehavioralWarnings: Bool = true
    @State private var showReviewHistory: Bool = false
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
    }
    @State private var datePreset: DatePreset = .all
    @State private var customStart: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customEnd: Date = Date()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                header
                if journal.entries.isEmpty {
                    emptyState
                } else {
                    summaryCards
                    metricsStrip
                    analyticsSection
                    behavioralWarningsSection
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Color.canvas)
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
                JournalDayAISheet(entries: entries, day: day, periodTitle: aiPeriodTitle)
                    .environmentObject(app)
                    .environmentObject(dayReviewStore)
            }
        }
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
    }

    // ── Header ────────────────────────────────────────────────────
    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Label("Journal", systemImage: "book.closed.fill")
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
                if !journal.entries.isEmpty {
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
            // AI period analysis button (visible when a non-"all" period has entries)
            if !rangeEntries.isEmpty && datePreset != .all {
                Button {
                    openPeriodAI()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                        Text("AI \(datePreset.rawValue)")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accentGradient))
                }
                .buttonStyle(.plain)
                .help("Comprehensive AI review of all trades in this period")
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

    private func openPeriodAI() {
        let entries = rangeEntries
        guard !entries.isEmpty else { return }
        let title: String
        switch datePreset {
        case .today:     title = "Today — \(Self.dayFmt.string(from: Date()))"
        case .yesterday:
            let y = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
            title = "Yesterday — \(Self.dayFmt.string(from: y))"
        case .week:      title = "This Week"
        case .month:
            let f = DateFormatter(); f.dateFormat = "MMMM yyyy"
            title = f.string(from: Date())
        case .custom:
            title = "\(Self.dayFmt.string(from: customStart)) → \(Self.dayFmt.string(from: customEnd))"
        case .all:       title = "All Time"
        }
        aiDayEntries = entries
        aiDayDate = entries.first?.date ?? Date()
        aiPeriodTitle = title
    }

    private func blankDraft() -> JournalEntry {
        let pairID = app.selectedPairID ?? app.pairs.first?.id ?? ""
        let pairName = app.pairs.first { $0.id == pairID }?.name ?? ""
        return JournalEntry(pairID: pairID, pairName: pairName)
    }

    /// Draft pre-set to noon on a specific calendar day. Used by the
    /// day-header "+" button so the new entry lands in that day's group.
    private func draftFor(day: Date) -> JournalEntry {
        let pairID = app.selectedPairID ?? app.pairs.first?.id ?? ""
        let pairName = app.pairs.first { $0.id == pairID }?.name ?? ""
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
        return JournalEntry(date: noon, pairID: pairID, pairName: pairName)
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

    private struct BehaviorWarning: Identifiable {
        let id: String
        let icon: String
        let color: Color
        let title: String
        let detail: String
    }

    private var behavioralWarnings: [BehaviorWarning] {
        let sorted = rangeEntries.sorted { $0.date < $1.date }
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
        let all = journal.sorted
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
            Spacer().frame(height: 60)
            Image(systemName: "book.closed")
                .font(.system(size: 32))
                .foregroundStyle(Theme.Color.textMuted)
            Text("Your journal is empty.")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Color.textSecondary)
            Text("Log a trade manually, import a cTrader statement CSV, or hit \"Add to journal\" on an AI analysis to capture the idea with its reasoning attached.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
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
            }
            .padding(.top, Theme.Spacing.sm)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }


    // ── CSV export ────────────────────────────────────────────────

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.title = "Export Journal"
        panel.nameFieldStringValue = "journal_export.csv"
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let csv = buildExportCSV(journal.sorted)
        try? csv.write(to: url, atomically: true, encoding: .utf8)
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
                // `journal.entries` is re-read fresh on every iteration, so
                // a duplicate *within* the same file also gets caught
                // against rows added earlier in this same loop.
                let isDuplicate = journal.entries.contains {
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
}

// ── JournalEntryRow ───────────────────────────────────────────────────────────
// Owns its own hover state so mouse-moves only re-render this row,
// not the entire JournalView body (which would recompute filteredEntries,
// makeSummary, behavioralWarnings, etc. on every cursor movement).

private struct JournalEntryRow: View {
    let entry: JournalEntry
    var isChartActive: Bool
    var onEdit: () -> Void
    var onChart: () -> Void
    var onAI: () -> Void

    @State private var isHovered = false

    var body: some View {
        let hasLevels = entry.entry != nil || entry.takeProfit != nil || entry.stopLoss != nil
        let trailingPad: CGFloat = hasLevels ? 124 : 62
        return ZStack(alignment: .trailing) {
            Button { onEdit() } label: {
                rowContent(extraTrailingPad: trailingPad)
            }
            .buttonStyle(.plain)
            HStack(spacing: 6) {
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
            .strokeBorder(isHovered ? Theme.Color.accentStart.opacity(0.4) : Theme.Color.border, lineWidth: 1))
        .animation(.easeOut(duration: 0.12), value: isHovered)
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
