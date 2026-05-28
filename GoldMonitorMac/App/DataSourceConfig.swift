import Foundation
import Combine

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

    private static let storageKey = "dataSourceConfig.v1"

    /// Stable defaults — the FF feed URL is public, the rest
    /// are blank-by-default so a fresh install nudges the user
    /// through the wizard.
    private static let defaultForexFactoryURL = "https://nfs.faireconomy.media/ff_calendar_thisweek.xml"

    private init() {
        let saved = Self.load()
        self.twelveDataAPIKey = saved.twelveDataAPIKey
        self.forexFactoryURL  = saved.forexFactoryURL
        self.claudeBinaryPath = saved.claudeBinaryPath
    }

    /// Apply a freshly-configured snapshot and persist. Called by
    /// the wizard's Save action.
    func update(twelveDataAPIKey: String, forexFactoryURL: String, claudeBinaryPath: String) {
        self.twelveDataAPIKey = twelveDataAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.forexFactoryURL  = forexFactoryURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.claudeBinaryPath = claudeBinaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    // ── Persistence ────────────────────────────────────────────────

    private struct Stored: Codable {
        var twelveDataAPIKey: String
        var forexFactoryURL: String
        var claudeBinaryPath: String
    }

    private func save() {
        let s = Stored(
            twelveDataAPIKey: twelveDataAPIKey,
            forexFactoryURL:  forexFactoryURL,
            claudeBinaryPath: claudeBinaryPath
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
            claudeBinaryPath: ""
        )
    }
}
