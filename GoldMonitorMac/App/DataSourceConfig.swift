import Foundation
import Combine

/// Which upstream drives the price + history for the Faraz-capable pairs
/// (gold XAU/USD plus the BTC/SOL/ETH majors). Indices stay on Yahoo
/// regardless. Switching this in Settings wipes the stored bars for
/// those pairs and refetches from the newly-selected source (see
/// `YahooScheduler.switchGoldSource`). The name is kept for back-compat
/// with the persisted blob even though it now governs more than gold.
enum GoldDataSource: String, CaseIterable, Identifiable, Codable {
    /// Default: Twelve Data WebSocket live ticks + Yahoo history bars.
    case twelveData
    /// Faraz customer TradingView-UDF feed (cookie-authenticated),
    /// polled every 10s. See `FarazHistorySource`.
    case faraz

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .twelveData: return "Twelve Data + Yahoo"
        case .faraz:      return "Faraz"
        }
    }
}

/// User-configurable data-source endpoints + credentials captured by
/// the setup wizard. Single source of truth for any URL / port / API
/// key that used to be hardcoded in the source tree — the
/// open-source build ships with no secrets and asks the user to
/// supply them on first launch.
///
/// Persisted to UserDefaults under the `dataSourceConfig.v1` key
/// (one blob, not per-field, so a future schema bump is one key
/// rename away). `@Published` so any view bound to it re-renders
/// when the wizard saves.
@MainActor
final class DataSourceConfig: ObservableObject {
    /// App-wide singleton bound at the root of the view tree.
    /// Sub-systems (TwelveData stream, ForexFactory fetcher,
    /// ClaudeEngine) read from this instance via the
    /// EnvironmentObject they're given.
    static let shared = DataSourceConfig()

    /// Twelve Data API key — drives the live crypto WebSocket
    /// feed. Free tier on twelvedata.com gives ~800 requests/day
    /// + WS access. Empty string means "feature off"; the stream
    /// stays disconnected and the UI shows a "configure in
    /// Settings" hint.
    @Published var twelveDataAPIKey: String

    /// ForexFactory calendar feed URL. Hardcoded default points
    /// at the public free feed; users can swap in a mirror or
    /// a paid alternative without code changes.
    @Published var forexFactoryURL: String

    /// Path to the `claude` CLI binary. Empty string means
    /// "auto-detect" — `ClaudeEngine` walks a list of common
    /// install locations + the PATH. The wizard surfaces the
    /// resolved path so the user can see what was picked and
    /// override if needed.
    @Published var claudeBinaryPath: String

    /// Active upstream for the gold ounce. Changing this triggers a
    /// clear-and-refetch of the ounce series (the scheduler observes it).
    @Published var goldSource: GoldDataSource

    /// Faraz session cookie, copied from a logged-in browser. Sent as the
    /// `Cookie` header on every Faraz request. Empty = Faraz can't fetch
    /// (the scheduler surfaces a "set your cookie" hint).
    @Published var farazCookie: String

    /// Base URL of the Faraz API. Defaults to `https://faraz.io` — override
    /// if your Faraz instance is hosted at a different domain or path prefix.
    @Published var farazAPIURL: String

    private static let storageKey = "dataSourceConfig.v1"

    /// Stable defaults — the FF feed URL is public, the rest
    /// are blank-by-default so a fresh install nudges the user
    /// through the wizard.
    private static let defaultForexFactoryURL = "https://nfs.faireconomy.media/ff_calendar_thisweek.xml"
    nonisolated static let defaultFarazAPIURL = "https://faraz.io"

    private init() {
        let saved = Self.load()
        self.twelveDataAPIKey = saved.twelveDataAPIKey
        self.forexFactoryURL  = saved.forexFactoryURL
        self.claudeBinaryPath = saved.claudeBinaryPath
        // New fields are optional in the persisted blob so older payloads
        // (which predate them) still decode — fall back to sane defaults.
        self.goldSource   = saved.goldSource.flatMap(GoldDataSource.init(rawValue:)) ?? .twelveData
        self.farazCookie  = saved.farazCookie ?? ""
        self.farazAPIURL  = saved.farazAPIURL ?? Self.defaultFarazAPIURL
    }

    /// Apply a freshly-configured snapshot and persist. Called by
    /// the wizard's Save action.
    func update(twelveDataAPIKey: String, forexFactoryURL: String, claudeBinaryPath: String) {
        self.twelveDataAPIKey = twelveDataAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.forexFactoryURL  = forexFactoryURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.claudeBinaryPath = claudeBinaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    /// Switch the active gold source + Faraz cookie and persist. The
    /// scheduler observes `$goldSource` and, on a real change, clears the
    /// stored ounce bars and refetches from the new upstream.
    func updateGoldSource(_ source: GoldDataSource, farazCookie: String, farazAPIURL: String) {
        self.farazCookie  = farazCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = farazAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.farazAPIURL  = trimmedURL.isEmpty ? Self.defaultFarazAPIURL : trimmedURL
        // Set the source LAST: its `didSet`/publish is the trigger the
        // scheduler keys off, and by then the cookie is already in place.
        self.goldSource = source
        save()
    }

    /// Persist a session cookie captured by the in-app Faraz login flow
    /// (`FarazLoginSheet`). Subsequent Faraz requests read `farazCookie`
    /// fresh each call, so the next scheduled tick picks this up; the
    /// scheduler also observes `$farazCookie` to restart the live WS.
    func setFarazCookie(_ cookie: String) {
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != farazCookie else { return }
        farazCookie = trimmed
        save()
    }

    // ── Persistence ────────────────────────────────────────────────

    private struct Stored: Codable {
        var twelveDataAPIKey: String
        var forexFactoryURL: String
        var claudeBinaryPath: String
        // Optional so a pre-existing `dataSourceConfig.v1` blob (written
        // before these fields existed) still decodes instead of resetting
        // every field to its default.
        var goldSource: String?
        var farazCookie: String?
        var farazAPIURL: String?
    }

    private func save() {
        let s = Stored(
            twelveDataAPIKey: twelveDataAPIKey,
            forexFactoryURL:  forexFactoryURL,
            claudeBinaryPath: claudeBinaryPath,
            goldSource:  goldSource.rawValue,
            farazCookie: farazCookie,
            farazAPIURL: farazAPIURL
        )
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private static func load() -> Stored {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let s = try? JSONDecoder().decode(Stored.self, from: data)
        {
            return s
        }
        return Stored(
            twelveDataAPIKey: "",
            forexFactoryURL:  defaultForexFactoryURL,
            claudeBinaryPath: "",
            goldSource:  GoldDataSource.twelveData.rawValue,
            farazCookie: ""
        )
    }
}
