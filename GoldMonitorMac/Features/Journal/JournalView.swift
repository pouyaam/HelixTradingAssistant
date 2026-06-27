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

    @State private var filter: JournalEntry.Result? = nil
    @State private var sheetEntry: JournalEntry? = nil
    @State private var groupByDay: Bool = false
    @State private var showAnalytics: Bool = true
    /// Tracks any import error message to surface in an alert.
    @State private var importError: String? = nil
    @State private var aiEntry: JournalEntry? = nil

    // ── Date range ────────────────────────────────────────────────
    enum DatePreset: String, CaseIterable, Identifiable {
        case all = "All"
        case today = "Today"
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
                    analyticsSection
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
            // Import from cTrader
            Button {
                importCTraderCSV()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Import CSV")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Theme.Color.textSecondary)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.Color.surface))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.Color.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Import trades from a cTrader statement CSV")
            // Export CSV
            if !journal.entries.isEmpty {
                Button {
                    exportCSV()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Export CSV")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Theme.Color.textSecondary)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.Color.surface))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.Color.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
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

    // ── Summary ───────────────────────────────────────────────────
    private struct Summary {
        var count = 0
        var wins = 0
        var losses = 0
        var open = 0
        var net = 0.0
        var graded: Int { wins + losses }
        var winRate: Double { graded == 0 ? 0 : Double(wins) / Double(graded) }
    }

    private func makeSummary(_ entries: [JournalEntry]) -> Summary {
        var s = Summary()
        for e in entries {
            s.count += 1
            s.net += e.profitLoss
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
            // Result filter
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
            }
        }
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

    // ── Flat list ─────────────────────────────────────────────────
    private var filteredEntries: [JournalEntry] {
        guard let f = filter else { return rangeEntries }
        return rangeEntries.filter { $0.result == f }
    }

    private func entryList(_ entries: [JournalEntry]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
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
        let hasLevels = entry.entry != nil || entry.takeProfit != nil || entry.stopLoss != nil
        // trailing buttons: AI always visible, chart button only when levels exist
        let buttonCount = hasLevels ? 2 : 1
        let trailingPad: CGFloat = CGFloat(buttonCount) * 62
        return ZStack(alignment: .trailing) {
            Button { sheetEntry = entry } label: {
                row(entry, extraTrailingPad: trailingPad)
            }
            .buttonStyle(.plain)
            HStack(spacing: 6) {
                if hasLevels {
                    showOnChartButton(entry)
                }
                aiAnalyzeButton(entry)
            }
            .padding(.trailing, Theme.Spacing.md)
            .allowsHitTesting(true)
        }
    }

    // ── Grouped by day ────────────────────────────────────────────

    private struct DayGroup: Identifiable {
        let day: Date       // midnight of that calendar day
        let entries: [JournalEntry]
        var id: Date { day }
    }

    private var groupedList: some View {
        let groups = makeDayGroups(filteredEntries)
        return VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
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

    // ── Row ───────────────────────────────────────────────────────

    private func row(_ entry: JournalEntry, extraTrailingPad: CGFloat = 0) -> some View {
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
                    sideChip(entry.side)
                    if let lots = entry.lots {
                        Text(String(format: "%.2f L", lots))
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.Color.textMuted)
                    }
                }
            }
            Spacer()
            resultChip(entry.result)
            if entry.profitLoss != 0 || entry.result.isGraded {
                Text(String(format: "%+.2f", entry.profitLoss))
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundStyle(entry.profitLoss >= 0 ? Theme.Color.success : Theme.Color.danger)
                    .frame(width: 78, alignment: .trailing)
            }
        }
        .padding(Theme.Spacing.md)
        .padding(.trailing, extraTrailingPad)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.Color.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.Color.border, lineWidth: 1))
    }

    private func sideChip(_ side: JournalEntry.Side) -> some View {
        Text(side.label.uppercased())
            .font(.system(size: 8, weight: .heavy))
            .tracking(0.4)
            .foregroundStyle(side.color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(side.color.opacity(0.16)))
    }

    private func resultChip(_ result: JournalEntry.Result) -> some View {
        Text(result.label.uppercased())
            .font(.system(size: 9, weight: .heavy))
            .tracking(0.5)
            .foregroundStyle(result.color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(result.color.opacity(0.18)))
    }

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

    // ── Show on chart ─────────────────────────────────────────────

    private func showOnChartButton(_ entry: JournalEntry) -> some View {
        let isActive = app.journalChartEntry?.id == entry.id
        return Button {
            if isActive {
                app.journalChartEntry = nil
            } else {
                app.selectedPairID = entry.pairID
                app.journalChartEntry = entry
                app.selectedSidebarItem = .dashboard
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: isActive ? "eye.slash" : "chart.line.uptrend.xyaxis")
                    .font(.system(size: 9, weight: .bold))
                Text(isActive ? "Hide" : "Chart")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(isActive ? Theme.Color.textMuted : Theme.Color.accentStart)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(isActive
                ? Theme.Color.surface
                : Theme.Color.accentStart.opacity(0.12)))
            .overlay(Capsule().strokeBorder(
                isActive ? Theme.Color.border : Theme.Color.accentStart.opacity(0.35),
                lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .help(isActive ? "Remove from chart" : "Show entry/TP/SL on chart")
    }

    private func aiAnalyzeButton(_ entry: JournalEntry) -> some View {
        Button {
            aiEntry = entry
        } label: {
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

    /// Opens an NSOpenPanel, parses the cTrader statement CSV, and
    /// upserts each row as a JournalEntry. Skips rows whose id already
    /// exists (idempotent — re-importing the same file is safe).
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
            for entry in imported {
                // Don't duplicate: skip if this exact trade date+side+entry is already logged
                let isDuplicate = journal.entries.contains {
                    abs($0.date.timeIntervalSince(entry.date)) < 1 &&
                    $0.side == entry.side &&
                    $0.entry == entry.entry
                }
                if !isDuplicate {
                    journal.add(entry)
                    added += 1
                }
            }
            if added == 0 {
                importError = "No new trades found — all rows were already in your journal."
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
