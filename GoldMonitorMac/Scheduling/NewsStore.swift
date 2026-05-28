import Foundation
import Combine

/// Owns the rolling ForexFactory weekly cache and the user's filter
/// state for the News tab. Refreshes automatically every 5 minutes
/// while the tab is on screen, plus on explicit pull-to-refresh.
///
/// One source of truth for the entire News surface — the view binds
/// `@EnvironmentObject` and reads `filteredEvents` for the visible
/// list, no separate state holders.
@MainActor
final class NewsStore: ObservableObject {

    // ── Raw feed ──────────────────────────────────────────────────

    /// The full weekly event list as fetched. Date-filtered + currency-
    /// filtered downstream via `filteredEvents`.
    @Published private(set) var events: [ForexFactoryEvent] = []

    @Published private(set) var lastFetchAt: Date?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: String?

    // ── User filters ──────────────────────────────────────────────

    /// Selected day. Defaults to "today" in the user's local zone —
    /// the date selector chip drives this. Compared against the
    /// event's `date` string (ISO "YYYY-MM-DD"), so timezone math
    /// happens once at parse time and not on every render.
    @Published var selectedDate: Date = Calendar.current.startOfDay(for: Date())

    /// Whitelisted currencies. Empty == show everything. Matches the
    /// web app's default of USD-only on first load — gold traders
    /// usually care about USD events most.
    @Published var currencyFilter: Set<String> = ["USD"]

    /// Whether each impact bucket is included in the filtered view.
    /// All on by default — the user pares down rather than building
    /// up.
    @Published var showHigh: Bool = true
    @Published var showMedium: Bool = true
    @Published var showLow: Bool = true

    // ── Internals ─────────────────────────────────────────────────

    private var refreshTask: Task<Void, Never>?
    /// 5-minute auto-refresh. ForexFactory's weekly feed only updates
    /// when a new event fires (which is at most a few times per
    /// hour during US sessions), so a 5-min cadence is plenty.
    private let refreshInterval: TimeInterval = 300

    // MARK: - Public API

    /// Kick off a one-shot fetch immediately. Idempotent — repeated
    /// calls coalesce into a single in-flight request.
    func refresh() {
        guard !isLoading else { return }
        Task { await fetchOnce() }
    }

    /// Start auto-refreshing. Call when the News tab appears; the
    /// scheduler also fires an immediate fetch so the user doesn't
    /// stare at an empty list for 5 minutes.
    func startAutoRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            // First load right away.
            await self?.fetchOnce()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self?.refreshInterval ?? 300) * 1_000_000_000)
                if Task.isCancelled { break }
                await self?.fetchOnce()
            }
        }
    }

    /// Stop the auto-refresh loop. Called when the News tab is no
    /// longer visible so we don't burn network on a hidden surface.
    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: - Derived views

    /// Date string for the currently-selected day, in the same ISO
    /// format ForexFactory events use after parsing. Used by the
    /// list filter without recomputing on every event.
    var selectedDateISO: String {
        Self.isoFormatter.string(from: selectedDate)
    }

    /// Events for the selected day + currency/impact filter, sorted
    /// chronologically. All-day / tentative events sort to the top.
    var filteredEvents: [ForexFactoryEvent] {
        let dateKey = selectedDateISO
        let wantedCurrencies = currencyFilter
        return events
            .filter { $0.date == dateKey }
            .filter { wantedCurrencies.isEmpty || wantedCurrencies.contains($0.currency) }
            .filter { impactPasses($0.impactLevel) }
            .sorted { lhs, rhs in
                switch (lhs.eventAt, rhs.eventAt) {
                case (nil, nil): return lhs.title < rhs.title
                case (nil, _):   return true
                case (_, nil):   return false
                case (let a?, let b?): return a < b
                }
            }
    }

    /// Currencies present in the current feed — drives the filter
    /// chip row. Deterministic order so chips don't shuffle between
    /// refreshes.
    var availableCurrencies: [String] {
        Array(Set(events.map(\.currency))).sorted()
    }

    /// High/medium/low counts for the selected day — used to badge
    /// the impact toggles so the user sees "5 high events today".
    func impactCount(_ level: ForexFactoryEvent.ImpactLevel) -> Int {
        let dateKey = selectedDateISO
        return events.filter { $0.date == dateKey && $0.impactLevel == level }.count
    }

    // MARK: - Helpers

    private func impactPasses(_ level: ForexFactoryEvent.ImpactLevel) -> Bool {
        switch level {
        case .high:    return showHigh
        case .medium:  return showMedium
        case .low:     return showLow
        case .unknown: return showHigh || showMedium || showLow
        }
    }

    private func fetchOnce() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await ForexFactorySource.fetchThisWeek()
            self.events = fetched
            self.lastFetchAt = Date()
            self.lastError = nil
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
