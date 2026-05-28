import SwiftUI

/// The trade journal screen (sidebar → Journal). A hand-written log of
/// trades the user actually took: position, profit/loss, free-form
/// notes, and — for ideas that came from an AI run — a reference back
/// to that analysis. Complements the Portfolio analytics (which grades
/// *paper* trades) with a record of real decisions and their outcomes.
struct JournalView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var journal: JournalStore

    /// Result filter — nil = all.
    @State private var filter: JournalEntry.Result? = nil
    /// Presented add/edit sheet target. New + existing entries both
    /// flow through here; we detect which by id membership in the store.
    @State private var sheetEntry: JournalEntry? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                header
                if journal.entries.isEmpty {
                    emptyState
                } else {
                    summaryCards
                    filterRow
                    entryList
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
    }

    // ── Header ────────────────────────────────────────────────────
    private var header: some View {
        HStack {
            Label("Journal", systemImage: "book.closed.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.Color.textPrimary)
            Spacer()
            Button {
                sheetEntry = blankDraft()
            } label: {
                Label("New entry", systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
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

    private var summary: Summary {
        var s = Summary()
        for e in journal.entries {
            s.count += 1
            s.net += e.profitLoss
            switch e.result {
            case .win:  s.wins += 1
            case .loss: s.losses += 1
            case .open: s.open += 1
            case .breakeven: break
            }
        }
        return s
    }

    private var summaryCards: some View {
        let s = summary
        return HStack(spacing: Theme.Spacing.md) {
            statCard(label: "ENTRIES", value: "\(s.count)",
                     subtitle: "\(s.open) open", tint: Theme.Color.textPrimary)
            statCard(label: "WIN RATE", value: String(format: "%.0f%%", s.winRate * 100),
                     subtitle: "\(s.wins)W / \(s.losses)L", tint: s.winRate >= 0.5 ? Theme.Color.success : Theme.Color.danger)
            statCard(label: "NET P/L", value: String(format: "%+.2f", s.net),
                     subtitle: "all entries", tint: s.net >= 0 ? Theme.Color.success : Theme.Color.danger)
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
        HStack(spacing: 6) {
            Text("FILTER")
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

    private func filterChip(label: String, value: JournalEntry.Result?) -> some View {
        let selected = filter == value
        return Button {
            filter = value
        } label: {
            Text(label)
                .font(.system(size: 11, weight: selected ? .bold : .medium))
                .foregroundStyle(selected ? .white : Theme.Color.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(
                    selected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.Color.surface)))
        }
        .buttonStyle(.plain)
    }

    // ── List ──────────────────────────────────────────────────────
    private var filteredEntries: [JournalEntry] {
        let all = journal.sorted
        guard let f = filter else { return all }
        return all.filter { $0.result == f }
    }

    private var entryList: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ForEach(filteredEntries) { entry in
                Button { sheetEntry = entry } label: { row(entry) }
                    .buttonStyle(.plain)
            }
            if filteredEntries.isEmpty {
                Text("No entries match this filter.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Color.textMuted)
                    .padding(.vertical, Theme.Spacing.lg)
            }
        }
    }

    private func row(_ entry: JournalEntry) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            // Side accent bar.
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
                    Text(Self.dateFmt.string(from: entry.date))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Color.textMuted)
                    Text("·").foregroundStyle(Theme.Color.textMuted)
                    Text(entry.pairName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.Color.textSecondary)
                    sideChip(entry.side)
                }
            }
            Spacer()
            resultChip(entry.result)
            if entry.profitLoss != 0 || entry.result.isGraded {
                Text(String(format: "%+.2f", entry.profitLoss))
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundStyle(entry.profitLoss >= 0 ? Theme.Color.success : Theme.Color.danger)
                    .frame(width: 88, alignment: .trailing)
            }
        }
        .padding(Theme.Spacing.md)
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
            Text("Log a trade with the result and your notes — or hit \"Add to journal\" on an AI analysis to capture the idea with its reasoning attached.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
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
            .padding(.top, Theme.Spacing.sm)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy · HH:mm"
        return f
    }()
}
