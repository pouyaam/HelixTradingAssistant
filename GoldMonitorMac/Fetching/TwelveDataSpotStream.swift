import Foundation
import Combine

/// Live spot-price feed for the gold ounce via Twelve Data's WebSocket.
/// Streams `{event: "price", symbol: "XAU/USD", price: <Double>}` events
/// as fast as the upstream delivers — much fresher than polling
/// gold-api.com or Yahoo's chart endpoint every few seconds.
///
/// Designed to run for the lifetime of the app: on disconnect (server
/// drops, network hiccup, IP blocked) it reconnects with exponential
/// backoff (1s → 2s → 4s → … → 30s capped). The owning scheduler
/// reads `lastTickAt` to decide whether the stream is "fresh"; when
/// stale (no tick in N seconds), the scheduler falls back to its
/// gold-api polling path.
///
/// Per-tick events are NOT pushed into NetworkLog — they'd swamp the
/// buffer at 5–20 ticks/sec. Connection-level events (open / close /
/// subscribe-status / error) are recorded so the debug pane can still
/// show what's happening.
@MainActor
final class TwelveDataSpotStream: ObservableObject {
    /// Twelve Data API key — read from `DataSourceConfig` (set by
    /// the setup wizard or Settings). Empty string means "not
    /// configured" — the stream won't connect and the scheduler
    /// surfaces a "Configure Twelve Data in Settings" hint
    /// instead of silently failing.
    static var apiKey: String {
        UserDefaults.standard
            .data(forKey: "dataSourceConfig.v1")
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }?["twelveDataAPIKey"]
        ?? UserDefaults.standard.string(forKey: "twelveData.apiKey")
        ?? ""
    }

    /// Twelve Data symbols this stream subscribes to. Free-tier
    /// permits up to 8 symbols on one socket; we use 4 (XAU + BTC +
    /// SOL + ETH). The map from Twelve Data symbol → internal pair
    /// id is owned by the scheduler so this class stays generic.
    let symbols: [String]

    /// Wall-clock of the most recent `price` event on ANY symbol.
    /// Per-symbol freshness lives in `lastTickAt(for:)`.
    @Published private(set) var lastTickAt: Date?
    /// Last tick time per Twelve Data symbol. The scheduler uses the
    /// per-pair entry to decide when to fall back to gold-api (only
    /// applicable to XAU/USD anyway, but kept general).
    @Published private(set) var lastTickAtBySymbol: [String: Date] = [:]
    /// True once we've received any successful event in this session
    /// (handshake or tick). Flips back to false on connection error.
    @Published private(set) var isConnected: Bool = false

    /// Called on the main actor with each price tick, identified by
    /// the Twelve Data symbol so the scheduler can route to the
    /// right pair (`XAU/USD` → ounce, `BTC/USD` → btc, …).
    var onTick: ((_ symbol: String, _ price: Double) -> Void)?

    private var socket: URLSessionWebSocketTask?
    private var runTask: Task<Void, Never>?

    init(symbols: [String] = ["XAU/USD"]) {
        self.symbols = symbols
    }

    func start() {
        guard runTask == nil else { return }
        runTask = Task { await runLoop() }
    }

    func stop() {
        runTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        runTask = nil
        socket = nil
        isConnected = false
    }

    // ── Connect / reconnect loop ─────────────────────────────────────

    private func runLoop() async {
        var backoffSeconds: Double = 1
        while !Task.isCancelled {
            do {
                try await connectAndStream()
                backoffSeconds = 1   // a clean exit (cancellation) resets backoff
            } catch {
                isConnected = false
                logEvent(method: "WS ERR",
                         status: nil,
                         response: nil,
                         error: error)
            }
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
            // Exponential backoff capped at 30s — keeps us from
            // hammering the upstream during an extended outage while
            // still reconnecting promptly once the network recovers.
            backoffSeconds = min(backoffSeconds * 2, 30)
        }
    }

    private func connectAndStream() async throws {
        let url = try buildURL()
        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        task.resume()
        logEvent(method: "WS OPEN",
                 status: 101,
                 response: nil,
                 error: nil)

        // Tell the server which symbols we want. Twelve Data's free
        // tier lets you subscribe to up to 8 symbols on one socket;
        // we typically use 4 (XAU + BTC + SOL + ETH).
        let symbolList = symbols.joined(separator: ",")
        let subscribeJSON = "{\"action\":\"subscribe\",\"params\":{\"symbols\":\"\(symbolList)\"}}"
        try await task.send(.string(subscribeJSON))

        // Receive loop. Each `receive()` resolves with one message;
        // call it in a loop until cancelled or the socket errors.
        while !Task.isCancelled {
            let message = try await task.receive()
            switch message {
            case .string(let text):
                handle(text)
            case .data(let data):
                if let s = String(data: data, encoding: .utf8) {
                    handle(s)
                }
            @unknown default:
                break
            }
        }
    }

    private func buildURL() throws -> URL {
        var comps = URLComponents(string: "wss://ws.twelvedata.com/v1/quotes/price")!
        comps.queryItems = [.init(name: "apikey", value: Self.apiKey)]
        guard let url = comps.url else { throw URLError(.badURL) }
        return url
    }

    // ── Message dispatch ─────────────────────────────────────────────

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = obj["event"] as? String
        else { return }

        switch event {
        case "price":
            // Per-tick path — kept hot. No debug logging here.
            guard let price = priceFrom(obj),
                  let sym = obj["symbol"] as? String
            else { return }
            let now = Date()
            lastTickAt = now
            lastTickAtBySymbol[sym] = now
            isConnected = true
            onTick?(sym, price)

        case "subscribe-status":
            // Surfaces success / fail of our subscribe message. We
            // log it once so the user can see in the debug view
            // whether the API key + symbol were accepted.
            isConnected = true
            logEvent(method: "WS SUB",
                     status: 200,
                     response: data,
                     error: nil)

        case "heartbeat":
            // Twelve Data sends a heartbeat every ~60s when there
            // are no ticks. Treat it as proof of life; don't pollute
            // the log.
            isConnected = true

        default:
            // Unknown events (might be error envelopes from the
            // server) — log them so they're visible.
            logEvent(method: "WS MSG",
                     status: nil,
                     response: data,
                     error: nil)
        }
    }

    /// Twelve Data is inconsistent — `price` arrives as a Double in
    /// some messages and as a String in others. Coerce both.
    private func priceFrom(_ obj: [String: Any]) -> Double? {
        if let p = obj["price"] as? Double { return p }
        if let p = obj["price"] as? Int    { return Double(p) }
        if let s = obj["price"] as? String { return Double(s) }
        return nil
    }

    // ── Debug log integration ────────────────────────────────────────

    private func logEvent(method: String, status: Int?, response: Data?, error: Error?) {
        NetworkLog.shared.record(
            source: "twelve-data",
            method: method,
            url: "wss://ws.twelvedata.com/v1/quotes/price",
            status: status,
            durationMs: 0,
            response: response,
            error: error
        )
    }
}
