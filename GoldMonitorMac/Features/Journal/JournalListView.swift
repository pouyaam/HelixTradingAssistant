import SwiftUI

/// The trade journal screen (sidebar → Journal). Landing screen: a list
/// of the user's journals — each a separate, independently-tracked log
/// of trades (e.g. "Prop firm challenge", "Personal account",
/// "Backtests") — with win rate / P&L at a glance, an "all-time" AI
/// review, rename, and delete. Tapping a row pushes `JournalDetailView`
/// (the original single-journal screen) scoped to that journal.
struct JournalView: View {
    @EnvironmentObject private var journal: JournalStore

    /// nil ⇒ showing the list; set ⇒ showing that journal's detail
    /// screen. Deliberately plain `@State` (not `AppState`) — journal
    /// navigation doesn't need to be visible outside this feature, the
    /// way the selected pair or chart overlays do.
    @State private var openJournalID: UUID? = nil

    var body: some View {
        if let id = openJournalID, journal.journals.contains(where: { $0.id == id }) {
            JournalDetailView(journalID: id, onBack: { openJournalID = nil })
        } else {
            JournalListView(onOpen: { openJournalID = $0 })
        }
    }
}

/// The list of journals. Extracted from `JournalView` so the container
/// above stays a trivial switch between list/detail.
private struct JournalListView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var journal: JournalStore
    @EnvironmentObject private var dayReviewStore: DayReviewStore

    let onOpen: (UUID) -> Void

    /// The row currently in inline-rename mode (double-click or the
    /// "Rename" action), plus its working text. Mirrors the tab-rename
    /// pattern already used in `AnalysisPage`.
    @State private var renamingID: UUID? = nil
    @State private var renameText: String = ""
    @FocusState private var renameFocused: Bool

    @State private var pendingDelete: Journal? = nil
    @State private var aiJournal: Journal? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                header
                if journal.sortedJournals.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: Theme.Spacing.sm) {
                        ForEach(journal.sortedJournals) { j in
                            journalRow(j)
                        }
                    }
                }
            }
            .padding(Theme.Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Color.canvas)
        .alert("Delete journal?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let j = pendingDelete { journal.removeJournal(j.id) }
            }
        } message: {
            if let j = pendingDelete {
                let count = journal.stats(for: j.id).count
                Text("This deletes \"\(j.name)\" and its \(count) trade\(count == 1 ? "" : "s"). This can't be undone.")
            }
        }
        .sheet(item: $aiJournal) { j in
            let entries = journal.sorted(in: j.id)
            JournalDayAISheet(
                entries: entries,
                day: entries.first?.date ?? Date(),
                periodTitle: "\(j.name) — All Time",
                periodScope: .all,
                behavioralHints: JournalDetailView.behavioralHints(for: entries),
                journalID: j.id
            )
            .environmentObject(app)
            .environmentObject(dayReviewStore)
        }
    }

    // ── Header ────────────────────────────────────────────────────
    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Label("Journal", systemImage: "book.closed.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.Color.textPrimary)
            Spacer()
            Button {
                createJournal()
            } label: {
                Label("New journal", systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accentGradient))
            }
            .buttonStyle(.plain)
        }
    }

    /// Adds a new journal and immediately drops it into rename mode
    /// (focused text field) so the user can type a real name right
    /// away, instead of a separate "name your journal" prompt.
    private func createJournal() {
        let j = journal.addJournal(name: "New Journal")
        startRename(j)
    }

    // ── Rows ──────────────────────────────────────────────────────

    /// Deliberately NOT a `Button` wrapping the whole row — the row
    /// contains a `TextField` (rename) and its own `Button`s (AI /
    /// rename / delete), and nesting those inside an outer `Button`'s
    /// label breaks their focus/tap handling on macOS. Same convention
    /// `AnalysisPage.tabChip` uses for its rename-able tab: a plain
    /// container with `.onTapGesture` for the "open" action, so
    /// SwiftUI's hit-testing lets the inner controls claim their own
    /// taps first.
    private func journalRow(_ j: Journal) -> some View {
        let stats = journal.stats(for: j.id)
        let isRenaming = renamingID == j.id
        return HStack(spacing: Theme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Theme.Color.accentStart.opacity(0.15))
                    .frame(width: 38, height: 38)
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Color.accentStart)
            }
            VStack(alignment: .leading, spacing: 3) {
                if isRenaming {
                    TextField("Journal name", text: $renameText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.Color.textPrimary)
                        .focused($renameFocused)
                        .onSubmit { commitRename(j) }
                        .onChange(of: renameFocused) { focused in
                            if !focused { commitRename(j) }
                        }
                } else {
                    Text(j.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.Color.textPrimary)
                        .lineLimit(1)
                        .onTapGesture(count: 2) { startRename(j) }
                }
                HStack(spacing: 8) {
                    Text("\(stats.count) trade\(stats.count == 1 ? "" : "s")")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Color.textMuted)
                    if stats.graded > 0 {
                        Text("·").foregroundStyle(Theme.Color.textMuted)
                        Text(String(format: "%.0f%% win rate", stats.winRate * 100))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(stats.winRate >= 0.5 ? Theme.Color.success : Theme.Color.danger)
                    }
                }
            }
            Spacer()
            if stats.count > 0 {
                Text(String(format: "%+.2f", stats.net))
                    .font(.system(size: 14, weight: .bold).monospacedDigit())
                    .foregroundStyle(stats.net >= 0 ? Theme.Color.success : Theme.Color.danger)
            }
            rowActions(j, hasEntries: stats.count > 0)
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.Color.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.Color.border, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isRenaming else { return }
            onOpen(j.id)
        }
    }

    private func rowActions(_ j: Journal, hasEntries: Bool) -> some View {
        HStack(spacing: 6) {
            if hasEntries {
                Button {
                    aiJournal = j
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
                .help("AI review of every trade in this journal")
            }
            Button {
                startRename(j)
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Theme.Color.surfaceHi))
            }
            .buttonStyle(.plain)
            .help("Rename journal")
            Button {
                pendingDelete = j
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Color.danger)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Theme.Color.danger.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .help("Delete journal")
        }
    }

    private func startRename(_ j: Journal) {
        renamingID = j.id
        renameText = j.name
        renameFocused = true
    }

    private func commitRename(_ j: Journal) {
        guard renamingID == j.id else { return }
        journal.renameJournal(j.id, to: renameText)
        renamingID = nil
    }

    // ── Empty state ───────────────────────────────────────────────
    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Spacer().frame(height: 60)
            Image(systemName: "book.closed")
                .font(.system(size: 32))
                .foregroundStyle(Theme.Color.textMuted)
            Text("No journals yet.")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Color.textSecondary)
            Text("Create a journal to start logging trades — you can keep separate journals for different accounts or strategies.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button {
                createJournal()
            } label: {
                Label("New journal", systemImage: "plus")
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
}
