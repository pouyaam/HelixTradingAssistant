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

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        createdAt: Date = Date(),
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

/// Persistent store for the trade journal. Mirrors the shape of
/// `TradeStore` / `AnalysisStore` (UserDefaults-backed, @MainActor) so
/// it slots into the same environment-object pattern at the app root.
@MainActor
final class JournalStore: ObservableObject {
    @Published private(set) var entries: [JournalEntry] = []

    private static let storageKey = "journal.entries.v1"

    init() {
        load()
    }

    /// Entries newest-first (by trade date, then creation).
    var sorted: [JournalEntry] {
        entries.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.createdAt > $1.createdAt
        }
    }

    func add(_ entry: JournalEntry) {
        entries.append(entry)
        save()
    }

    /// Insert if new, replace in place if an entry with the same id
    /// already exists. Used by the edit sheet.
    func upsert(_ entry: JournalEntry) {
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx] = entry
        } else {
            entries.append(entry)
        }
        save()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clearAll() {
        entries = []
        save()
    }

    // ── Persistence ──────────────────────────────────────────────
    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([JournalEntry].self, from: data)
        else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
