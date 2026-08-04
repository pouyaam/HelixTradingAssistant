import Foundation
import Combine

/// User-facing configuration and live status for the local MCP server.
///
/// Owns the server rather than the other way round: the app boots this
/// object, hands it the database once ready, and it decides whether to
/// listen. That keeps every start/stop trigger — the enable toggle, a
/// port edit, the database arriving — in one place instead of scattered
/// across the app entry point.
///
/// Persistence is UserDefaults; the token is deliberately included. It
/// guards a loopback socket that is already unreachable off-machine, so
/// it is a convenience for shared hosts, not a secret worth the Keychain
/// prompt that `KeychainHelper` would impose on every launch.
@MainActor
final class MCPServerSettings: ObservableObject {

    private enum Key {
        static let enabled = "mcp.server.enabled"
        static let port    = "mcp.server.port"
        static let token   = "mcp.server.token"
        static let maxBars = "mcp.server.maxBars"
    }

    /// The port the user asked for in the wizard-free default install.
    static let defaultPort: UInt16 = 4321

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Key.enabled)
            apply()
        }
    }

    /// Kept as a string so the text field can hold a half-typed value
    /// without the binding fighting the user on every keystroke.
    @Published var portText: String {
        didSet {
            guard portText != oldValue else { return }
            UserDefaults.standard.set(portText, forKey: Key.port)
        }
    }

    @Published var token: String {
        didSet {
            guard token != oldValue else { return }
            UserDefaults.standard.set(token, forKey: Key.token)
        }
    }

    @Published var maxBars: Int {
        didSet {
            guard maxBars != oldValue else { return }
            UserDefaults.standard.set(maxBars, forKey: Key.maxBars)
        }
    }

    @Published private(set) var state: MCPHTTPServer.State = .stopped
    /// Last handled tool call, for the activity line in Settings.
    @Published private(set) var lastActivity: String?

    private let server = MCPHTTPServer()
    private var repo: OHLCRepo?

    init() {
        let d = UserDefaults.standard
        isEnabled = d.bool(forKey: Key.enabled)
        portText = d.string(forKey: Key.port) ?? String(Self.defaultPort)
        token = d.string(forKey: Key.token) ?? ""
        let storedBars = d.integer(forKey: Key.maxBars)
        maxBars = storedBars > 0 ? storedBars : 5000

        server.onStateChange = { [weak self] state in
            self?.state = state
        }
        server.onToolCall = { [weak self] name, ok, elapsed in
            let ms = Int(elapsed * 1000)
            self?.lastActivity = "\(ok ? "✓" : "✕") \(name) · \(ms) ms · \(Self.clockFormatter.string(from: Date()))"
        }
    }

    /// Called once the database is open. Starts the server if the user
    /// had it enabled — without a repo there is nothing to serve, so an
    /// enabled server before boot completes would only 500.
    func attach(database: AppDatabase) {
        repo = database.ohlcRepo
        apply()
    }

    /// Push the current configuration at the server. Safe to call
    /// repeatedly — `start` is idempotent for an unchanged config.
    func apply() {
        guard let repo else { return }
        guard isEnabled else {
            server.stop()
            return
        }
        server.start(repo: repo, configuration: configuration)
    }

    /// Restart on the current settings. Bound to the Apply button, since
    /// port and token edits shouldn't tear the listener down on every
    /// keystroke.
    func restart() {
        guard isEnabled else { return }
        server.stop()
        apply()
    }

    // MARK: - Derived

    var port: UInt16 {
        // Ports below 1024 need root, which this app doesn't have; fall
        // back rather than failing to bind with a confusing error.
        guard let value = UInt16(portText.trimmingCharacters(in: .whitespaces)), value >= 1024 else {
            return Self.defaultPort
        }
        return value
    }

    var configuration: MCPHTTPServer.Configuration {
        MCPHTTPServer.Configuration(
            port: port,
            token: token.trimmingCharacters(in: .whitespacesAndNewlines),
            maxBars: maxBars
        )
    }

    var endpoint: String { "http://127.0.0.1:\(port)/mcp" }

    var isPortValid: Bool {
        guard let value = UInt16(portText.trimmingCharacters(in: .whitespaces)) else { return false }
        return value >= 1024
    }

    var statusText: String {
        switch state {
        case .stopped:          return isEnabled ? "Starting…" : "Off"
        case .starting:         return "Starting…"
        case .running(let p):   return "Listening on 127.0.0.1:\(p)"
        case .failed(let msg):  return msg
        }
    }

    /// The `claude mcp add` line for this server — the fastest path from
    /// "it's running" to "a client is using it".
    var claudeCodeCommand: String {
        var cmd = "claude mcp add --transport http helix-trading \(endpoint)"
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { cmd += " --header \"Authorization: Bearer \(t)\"" }
        return cmd
    }

    /// `mcpServers` config block for clients that take JSON (Cursor,
    /// Claude Desktop, Windsurf).
    var jsonConfig: String {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let headers = t.isEmpty ? "" : """
        ,
                "headers": { "Authorization": "Bearer \(t)" }
        """
        return """
        {
          "mcpServers": {
            "helix-trading": {
              "type": "http",
              "url": "\(endpoint)"\(headers)
            }
          }
        }
        """
    }

    /// Generate a random token. Base64url of 24 bytes — long enough that
    /// guessing it is not the weak link, short enough to paste.
    func generateToken() {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
