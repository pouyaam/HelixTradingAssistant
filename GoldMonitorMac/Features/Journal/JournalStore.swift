import Foundation
import SwiftUI
import Combine

/// A hand-written trade journal entry. Unlike the paper-trade simulator
/// (`Trade` / `TradeStore`, which mechanically replays live ticks) the
/// journal is what the user types themselves: the trade they actually
/// took, what they made or lost, and — when the idea came from an AI
/// run — a reference back to that analysis so the reasoning lives next
/// to the result.
///
/// Persisted to UserDefaults (`journal.entries.v1`) as JSON. The custom
/// decoder treats every non-essential field as optional so adding new
/// fields later won't wipe an existing journal on upgrade.
struct JournalEntry: Identifiable, Codable, Equatable {
    let id: UUID
    /// When the trade happened (user-editable — defaults to "now").
    var date: Date
    /// When the row was first created. Immutable; used as a stable
    /// secondary sort.
    let createdAt: Date

    /// Which `Journal` this entry belongs to. Defaults to
    /// `defaultJournalID` — the id `JournalStore` seeds its
    /// single migrated journal with — so entries written before
    /// multi-journal support existed keep loading into the same
    /// journal rather than vanishing.
    var journalID: UUID

    var pairID: String
    var pairName: String
    /// Optional one-line headline ("NFP fade", "London breakout long").
    var title: String
    /// Free-form journaling — the user's own notes on the trade.
    var notes: String

    // ── Position ──────────────────────────────────────────────────
    var side: Side
    /// Entry / take-profit / stop-loss / size. All optional so a pure
    /// note (no concrete position) is still a valid entry.
    var entry: Double?
    var takeProfit: Double?
    var stopLoss: Double?
    var lots: Double?
    /// When the trade was opened. Populated by cTrader imports; nil for
    /// legacy entries or manual entries where only `date` (close time) is set.
    var openDate: Date?
    /// Actual closing price. Set by cTrader imports; nil for entries
    /// where close price wasn't recorded.
    var closePrice: Double?

    // ── Outcome ──────────────────────────────────────────────────
    var result: Result
    /// Realised profit/loss in account currency. 0 reads as breakeven
    /// / not-yet-recorded.
    var profitLoss: Double

    // ── AI analysis reference ─────────────────────────────────────
    /// The history entry that seeded this journal row, when it came
    /// from an AI run. Lets a future "open analysis" jump back to it.
    var sourceHistoryEntryID: UUID?
    /// Engine that produced the analysis ("Claude" / "Codex").
    var aiEngineLabel: String?
    /// Analysis kind label ("Technical Analysis", "Confluence Trade Scanner", …).
    var aiKindLabel: String?
    /// Timeframe(s) the analysis ran on.
    var aiTimeframeLabel: String?
    /// A snapshot of the analysis report, captured at add time so the
    /// journal keeps the reasoning even after the rolling AI history
    /// (capped at 50) prunes the original.
    var aiReportExcerpt: String?

    enum Side: String, Codable, CaseIterable, Identifiable {
        case long, short, neutral
        var id: String { rawValue }
        var label: String {
            switch self {
            case .long:    return "Long"
            case .short:   return "Short"
            case .neutral: return "Neutral"
            }
        }
        var color: Color {
            switch self {
            case .long:    return Theme.Color.success
            case .short:   return Theme.Color.danger
            case .neutral: return Theme.Color.info
            }
        }
    }

    enum Result: String, Codable, CaseIterable, Identifiable {
        case win, loss, breakeven, open
        var id: String { rawValue }
        var label: String {
            switch self {
            case .win:       return "Win"
            case .loss:      return "Loss"
            case .breakeven: return "Breakeven"
            case .open:      return "Open"
            }
        }
        var color: Color {
            switch self {
            case .win:       return Theme.Color.success
            case .loss:      return Theme.Color.danger
            case .breakeven: return Theme.Color.textSecondary
            case .open:      return Theme.Color.warn
            }
        }
        /// Whether this result counts toward win/loss stats (open +
        /// breakeven don't move the win rate denominator).
        var isGraded: Bool { self == .win || self == .loss }
    }

    /// Does this entry carry a reference to an AI analysis?
    var hasAIReference: Bool {
        sourceHistoryEntryID != nil
            || aiKindLabel != nil
            || (aiReportExcerpt?.isEmpty == false)
    }

    /// Fixed id for the single journal that existed before multi-journal
    /// support. `JournalStore` seeds a "My Journal" with this exact id on
    /// first load after upgrading, so entries written by older builds
    /// (which never had a `journalID` field) decode straight into it.
    static let defaultJournalID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        createdAt: Date = Date(),
        journalID: UUID = JournalEntry.defaultJournalID,
        pairID: String,
        pairName: String,
        title: String = "",
        notes: String = "",
        side: Side = .long,
        entry: Double? = nil,
        takeProfit: Double? = nil,
        stopLoss: Double? = nil,
        lots: Double? = nil,
        openDate: Date? = nil,
        closePrice: Double? = nil,
        result: Result = .open,
        profitLoss: Double = 0,
        sourceHistoryEntryID: UUID? = nil,
        aiEngineLabel: String? = nil,
        aiKindLabel: String? = nil,
        aiTimeframeLabel: String? = nil,
        aiReportExcerpt: String? = nil
    ) {
        self.id = id
        self.date = date
        self.createdAt = createdAt
        self.journalID = journalID
        self.pairID = pairID
        self.pairName = pairName
        self.title = title
        self.notes = notes
        self.side = side
        self.entry = entry
        self.takeProfit = takeProfit
        self.stopLoss = stopLoss
        self.lots = lots
        self.openDate = openDate
        self.closePrice = closePrice
        self.result = result
        self.profitLoss = profitLoss
        self.sourceHistoryEntryID = sourceHistoryEntryID
        self.aiEngineLabel = aiEngineLabel
        self.aiKindLabel = aiKindLabel
        self.aiTimeframeLabel = aiTimeframeLabel
        self.aiReportExcerpt = aiReportExcerpt
    }

    /// Defensive decoder: only `id` is required. Everything else falls
    /// back to a sensible default so a payload written by an older
    /// build (or a future one missing a field) still loads instead of
    /// silently dropping the whole journal.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? (try c.decodeIfPresent(Date.self, forKey: .date) ?? Date())
        journalID = try c.decodeIfPresent(UUID.self, forKey: .journalID) ?? JournalEntry.defaultJournalID
        pairID = try c.decodeIfPresent(String.self, forKey: .pairID) ?? ""
        pairName = try c.decodeIfPresent(String.self, forKey: .pairName) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        side = try c.decodeIfPresent(Side.self, forKey: .side) ?? .long
        entry = try c.decodeIfPresent(Double.self, forKey: .entry)
        takeProfit = try c.decodeIfPresent(Double.self, forKey: .takeProfit)
        stopLoss = try c.decodeIfPresent(Double.self, forKey: .stopLoss)
        lots = try c.decodeIfPresent(Double.self, forKey: .lots)
        openDate = try c.decodeIfPresent(Date.self, forKey: .openDate)
        closePrice = try c.decodeIfPresent(Double.self, forKey: .closePrice)
        result = try c.decodeIfPresent(Result.self, forKey: .result) ?? .open
        profitLoss = try c.decodeIfPresent(Double.self, forKey: .profitLoss) ?? 0
        sourceHistoryEntryID = try c.decodeIfPresent(UUID.self, forKey: .sourceHistoryEntryID)
        aiEngineLabel = try c.decodeIfPresent(String.self, forKey: .aiEngineLabel)
        aiKindLabel = try c.decodeIfPresent(String.self, forKey: .aiKindLabel)
        aiTimeframeLabel = try c.decodeIfPresent(String.self, forKey: .aiTimeframeLabel)
        aiReportExcerpt = try c.decodeIfPresent(String.self, forKey: .aiReportExcerpt)
    }
}

/// A named container for journal entries. The user can keep separate
/// journals (e.g. "Prop firm challenge", "Personal account", "Backtests")
/// each with its own trades and win-rate stats, rather than one flat
/// list. `JournalEntry.journalID` is the foreign key tying entries to
/// their journal.
struct Journal: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    let createdAt: Date

    init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }

    /// Defensive decoder, same idiom as `JournalEntry` — only `id` is
    /// required so a future/older payload shape still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Journal"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

/// Persistent store for the trade journal. Mirrors the shape of
/// `TradeStore` / `AnalysisStore` (UserDefaults-backed, @MainActor) so
/// it slots into the same environment-object pattern at the app root.
///
/// Holds every journal's entries in one flat array (scoped by
/// `journalID`) rather than one array per journal — that's what lets a
/// single `id == entry.id` lookup (edit sheet, "Add to journal" from the
/// AI analysis page, etc.) work without knowing which journal an entry
/// lives in ahead of time.
@MainActor
final class JournalStore: ObservableObject {
    @Published private(set) var entries: [JournalEntry] = []
    @Published private(set) var journals: [Journal] = []
    /// The journal the user most recently had open. Used as the target
    /// for entries created *outside* the Journal screen (e.g. "Add to
    /// journal" from an AI analysis run), which have no journal context
    /// of their own to draw on.
    @Published private(set) var lastUsedJournalID: UUID

    private static let entriesKey = "journal.entries.v1"
    private static let journalsKey = "journal.journals.v1"
    private static let lastUsedKey = "journal.lastUsedJournalID.v1"

    init() {
        lastUsedJournalID = JournalEntry.defaultJournalID
        load()
    }

    // ── Journals ──────────────────────────────────────────────────

    /// Oldest-created first — new journals land at the end of the list.
    var sortedJournals: [Journal] { journals.sorted { $0.createdAt < $1.createdAt } }

    @discardableResult
    func addJournal(name: String) -> Journal {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let journal = Journal(name: trimmed.isEmpty ? "Untitled Journal" : trimmed)
        journals.append(journal)
        lastUsedJournalID = journal.id
        saveJournals()
        saveLastUsed()
        return journal
    }

    func renameJournal(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = journals.firstIndex(where: { $0.id == id }) else { return }
        journals[idx].name = trimmed
        saveJournals()
    }

    /// Deletes the journal AND every entry filed under it.
    func removeJournal(_ id: UUID) {
        journals.removeAll { $0.id == id }
        entries.removeAll { $0.journalID == id }
        // If the deleted journal was the "last used" target, entries
        // added from outside the Journal screen (e.g. "Add to journal"
        // on an AI run) would otherwise silently land under a journal
        // id that no longer exists — orphaned and invisible everywhere.
        if lastUsedJournalID == id {
            lastUsedJournalID = journals.first?.id ?? JournalEntry.defaultJournalID
            saveLastUsed()
        }
        saveJournals()
        saveEntries()
    }

    /// Marks `id` as the journal most recently opened, so entries added
    /// from elsewhere in the app (no journal context of their own) land
    /// here. Called when the user opens a journal's detail screen.
    func markLastUsed(_ id: UUID) {
        guard lastUsedJournalID != id else { return }
        lastUsedJournalID = id
        saveLastUsed()
    }

    // ── Entries (scoped to a journal) ────────────────────────────

    func entries(in journalID: UUID) -> [JournalEntry] {
        entries.filter { $0.journalID == journalID }
    }

    /// A journal's entries, newest-first (by trade date, then creation).
    func sorted(in journalID: UUID) -> [JournalEntry] {
        entries(in: journalID).sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.createdAt > $1.createdAt
        }
    }

    /// Win-rate / P&L summary for a journal — what the journal-list row
    /// shows without loading the full entry list into that screen.
    struct Stats {
        var count = 0
        var wins = 0
        var losses = 0
        var net = 0.0
        var graded: Int { wins + losses }
        var winRate: Double { graded == 0 ? 0 : Double(wins) / Double(graded) }
    }

    func stats(for journalID: UUID) -> Stats {
        var s = Stats()
        for e in entries where e.journalID == journalID {
            s.count += 1
            s.net += e.profitLoss
            switch e.result {
            case .win:  s.wins += 1
            case .loss: s.losses += 1
            default:    break
            }
        }
        return s
    }

    func add(_ entry: JournalEntry) {
        entries.append(entry)
        saveEntries()
    }

    /// Insert if new, replace in place if an entry with the same id
    /// already exists. Used by the edit sheet.
    func upsert(_ entry: JournalEntry) {
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx] = entry
        } else {
            entries.append(entry)
        }
        saveEntries()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        saveEntries()
    }

    // ── Persistence ──────────────────────────────────────────────
    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.entriesKey),
           let decoded = try? JSONDecoder().decode([JournalEntry].self, from: data) {
            entries = decoded
        }
        if let data = UserDefaults.standard.data(forKey: Self.journalsKey),
           let decoded = try? JSONDecoder().decode([Journal].self, from: data) {
            journals = decoded
        }
        // Migration: installs from before multi-journal support have
        // entries (or don't) but no journals list yet — seed the single
        // journal every pre-existing entry already decodes into via
        // `JournalEntry.defaultJournalID`.
        if journals.isEmpty {
            journals = [Journal(id: JournalEntry.defaultJournalID, name: "My Journal")]
            saveJournals()
        }
        if let raw = UserDefaults.standard.string(forKey: Self.lastUsedKey),
           let id = UUID(uuidString: raw),
           journals.contains(where: { $0.id == id }) {
            lastUsedJournalID = id
        } else {
            lastUsedJournalID = journals.first?.id ?? JournalEntry.defaultJournalID
        }
    }

    private func saveEntries() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.entriesKey)
    }

    private func saveJournals() {
        guard let data = try? JSONEncoder().encode(journals) else { return }
        UserDefaults.standard.set(data, forKey: Self.journalsKey)
    }

    private func saveLastUsed() {
        UserDefaults.standard.set(lastUsedJournalID.uuidString, forKey: Self.lastUsedKey)
    }
}
