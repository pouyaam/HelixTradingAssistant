import Foundation
import Combine

/// Lightweight debug log of every HTTP request/response the app makes
/// to a known source (Yahoo, Twelve Data, etc.). When the
/// "Debug logging" toggle is on, fetch sites call `record(...)` after
/// every round-trip; the bug-icon popup in the dashboard renders the
/// entries newest-first with status, duration, and a body preview so
/// the user can see exactly what the upstream returned.
///
/// Persisted to UserDefaults under `debug.networkLog.*` so log entries
/// (and the enable flag) survive a relaunch — the user can come back
/// later and inspect why something failed.
///
/// `@MainActor`-isolated because the @Published properties drive
/// SwiftUI views directly; instrumented call sites dispatch to main
/// with a one-line `Task { @MainActor in NetworkLog.shared.record(...) }`.
@MainActor
final class NetworkLog: ObservableObject {
    static let shared = NetworkLog()

    /// One captured request/response pair. `responsePreview` is
    /// truncated to `Self.bodyCap` UTF-8 bytes so the persisted log
    /// stays under UserDefaults' size limit even after a long session.
    struct Entry: Identifiable, Codable, Equatable, Sendable {
        let id: UUID
        let date: Date
        /// Origin tag — "yahoo" / "twelve-data" / etc. Used
        /// for grouping and colouring in the debug view.
        let source: String
        /// HTTP method ("GET", "POST"). String rather than enum so
        /// non-HTTP sources (process spawn etc.) can use "EXEC".
        let method: String
        let url: String
        /// HTTP status code when present (nil for transport errors or
        /// non-HTTP entries).
        let status: Int?
        /// Round-trip duration in milliseconds.
        let durationMs: Double
        /// First `bodyCap` bytes of the response body, decoded as
        /// UTF-8. Binary responses fall back to a `<N bytes binary>`
        /// placeholder.
        let responsePreview: String
        /// `Error.localizedDescription` when the call failed.
        let error: String?
    }

    @Published private(set) var entries: [Entry] = []

    /// User-facing toggle. When off, `record(...)` is a no-op so the
    /// log stays clean and we don't pay for the (small) write
    /// overhead during normal use. Persisted automatically.
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
        }
    }

    /// Pending debounced persistence work, cancelled + rescheduled on
    /// each new record so a burst collapses into a single write.
    private var saveWorkItem: DispatchWorkItem?

    private static let enabledKey = "debug.networkLog.enabled"
    private static let entriesKey = "debug.networkLog.entries.v1"
    /// Ring-buffer cap. 200 entries × ~4 KB ≈ 800 KB on disk in the
    /// worst case — comfortably under UserDefaults' soft limit.
    private static let cap = 200
    /// Response-body truncation. 4 KB covers every JSON gold/spot
    /// response in this app; longer bodies (Yahoo's full bar series)
    /// get clipped with an explicit `…[truncated]` suffix.
    private static let bodyCap = 4096

    private init() {
        // Default capture ON when the user has never set it. Without
        // this, the launch-time Yahoo backfill (which fires once at
        // startup, before the debug popup is ever opened) is never
        // captured, making it look like Yahoo isn't being called. The
        // user can still flip it off from the popup; that choice
        // persists.
        if UserDefaults.standard.object(forKey: Self.enabledKey) == nil {
            self.isEnabled = true
        } else {
            self.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
        loadEntries()
    }

    /// Append a captured round-trip. Safe to call from any actor —
    /// internal mutation happens on the main actor.
    func record(
        source: String,
        method: String = "GET",
        url: String,
        status: Int?,
        durationMs: Double,
        response: Data?,
        error: Error?
    ) {
        guard isEnabled else { return }
        let preview = Self.makePreview(from: response)
        let entry = Entry(
            id: UUID(),
            date: Date(),
            source: source,
            method: method,
            url: url,
            status: status,
            durationMs: durationMs,
            responsePreview: preview,
            error: error?.localizedDescription
        )
        entries.insert(entry, at: 0)
        if entries.count > Self.cap {
            entries = Array(entries.prefix(Self.cap))
        }
        scheduleSave()
    }

    /// Wipe the log without flipping the enabled flag. Used by the
    /// "Clear" button in the debug popup.
    func clear() {
        entries = []
        scheduleSave()
    }

    // ── Persistence ──────────────────────────────────────────────────

    private func loadEntries() {
        guard let data = UserDefaults.standard.data(forKey: Self.entriesKey),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else { return }
        entries = decoded
    }

    /// Coalesced, off-main persistence. The previous version encoded the
    /// whole (up to 200-entry, ~800 KB) array and wrote it to
    /// UserDefaults on the main actor on EVERY `record(...)` call — at
    /// startup, with many requests firing back to back (×4 once Faraz
    /// drives crypto too), that stalled the main thread badly. Now we
    /// debounce the save and run the JSON encode off-main; only the
    /// snapshot read happens on the main actor.
    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistSnapshot() }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func persistSnapshot() {
        let snapshot = entries   // main-actor read
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            UserDefaults.standard.set(data, forKey: Self.entriesKey)
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────

    /// Convert a response body to a readable preview. UTF-8 decode
    /// first; fall back to a `<N bytes binary>` placeholder so binary
    /// data (rare in our pipeline) doesn't blow up the JSON encoder.
    private static func makePreview(from data: Data?) -> String {
        guard let data = data else { return "" }
        let truncated = data.prefix(bodyCap)
        guard let text = String(data: truncated, encoding: .utf8) else {
            return "<\(data.count) bytes binary>"
        }
        if data.count > bodyCap {
            return text + "\n…[truncated, total \(data.count) bytes]"
        }
        return text
    }
}
