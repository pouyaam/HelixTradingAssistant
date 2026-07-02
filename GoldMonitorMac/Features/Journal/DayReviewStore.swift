import Foundation

/// A saved AI review of a trading day, week, or month — the output of
/// `JournalDayAISheet`. Unlike per-trade AI post-mortems (which fold
/// into a single `JournalEntry`'s `notes`), a day/week/month review
/// isn't tied to one entry, so it gets its own persisted history
/// here rather than being bolted onto an arbitrary trade.
///
/// Persisted to UserDefaults (`journal.dayReviews.v1`) as JSON, same
/// idiom as `JournalStore` — defensive decoder so future/older
/// payload shapes still load.
struct DayReviewEntry: Identifiable, Codable, Equatable {
    let id: UUID
    /// Start of the reviewed period (the `day` passed to
    /// `JournalDayAISheet`, or the earliest trade's date for a
    /// week/month review).
    let periodStart: Date
    /// Header label as shown in the sheet — the formatted day, or a
    /// week/month title ("This Week", "January 2026", …).
    let periodTitle: String
    let tradeCount: Int
    let winRate: Double
    let netPL: Double
    let engineLabel: String
    let modelLabel: String
    let report: String
    let thinking: String?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        periodStart: Date,
        periodTitle: String,
        tradeCount: Int,
        winRate: Double,
        netPL: Double,
        engineLabel: String,
        modelLabel: String,
        report: String,
        thinking: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.periodStart = periodStart
        self.periodTitle = periodTitle
        self.tradeCount = tradeCount
        self.winRate = winRate
        self.netPL = netPL
        self.engineLabel = engineLabel
        self.modelLabel = modelLabel
        self.report = report
        self.thinking = thinking
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        periodStart = try c.decodeIfPresent(Date.self, forKey: .periodStart) ?? Date()
        periodTitle = try c.decodeIfPresent(String.self, forKey: .periodTitle) ?? ""
        tradeCount = try c.decodeIfPresent(Int.self, forKey: .tradeCount) ?? 0
        winRate = try c.decodeIfPresent(Double.self, forKey: .winRate) ?? 0
        netPL = try c.decodeIfPresent(Double.self, forKey: .netPL) ?? 0
        engineLabel = try c.decodeIfPresent(String.self, forKey: .engineLabel) ?? ""
        modelLabel = try c.decodeIfPresent(String.self, forKey: .modelLabel) ?? ""
        report = try c.decodeIfPresent(String.self, forKey: .report) ?? ""
        thinking = try c.decodeIfPresent(String.self, forKey: .thinking)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

/// Persistent store for saved day/week/month AI reviews. Mirrors
/// `JournalStore`'s shape (UserDefaults-backed, @MainActor) so it
/// slots into the same environment-object pattern.
@MainActor
final class DayReviewStore: ObservableObject {
    @Published private(set) var reviews: [DayReviewEntry] = []

    private static let storageKey = "journal.dayReviews.v1"
    private static let cap = 200

    init() {
        load()
    }

    /// Newest first.
    var sorted: [DayReviewEntry] { reviews.sorted { $0.createdAt > $1.createdAt } }

    func add(_ review: DayReviewEntry) {
        reviews.append(review)
        if reviews.count > Self.cap {
            reviews = Array(reviews.suffix(Self.cap))
        }
        save()
    }

    func remove(_ id: UUID) {
        reviews.removeAll { $0.id == id }
        save()
    }

    func clearAll() {
        reviews = []
        save()
    }

    // ── Persistence ──────────────────────────────────────────────
    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([DayReviewEntry].self, from: data)
        else { return }
        reviews = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(reviews) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
