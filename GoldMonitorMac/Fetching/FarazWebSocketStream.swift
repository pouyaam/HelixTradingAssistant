import Foundation

/// Live price feed from Faraz's Socket.IO v4 WebSocket.
/// URL: `wss://faraz.io/srv09/realtime/?EIO=4&transport=websocket`
///
/// Subscribes to two room types per symbol:
///   - `term-room-@SYMBOL`            → spot tick (price + timestamp)
///   - `symbol-room-@SYMBOL@TF@0`     → OHLCV bar update (1m + 1D)
///
/// Socket.IO v4 (EIO=4) protocol is handled inline — no third-party lib:
///   1. EIO OPEN (`0{…}`) — server, contains ping interval.
///   2. SIO CONNECT (`40/customer,`) — we join the /customer namespace.
///   3. SIO CONNECT ack (`40/customer,{…}`) — server confirms.
///   4. Room joins (`42/customer,["join","room-name"]`) — one per room.
///   5. Events (`42/customer,["room-name",{payload}]`) — incoming data.
///   6. EIO PING (`2`) → EIO PONG (`3`) — server-initiated heartbeat.
@MainActor
final class FarazWebSocketStream {

    /// Faraz WS symbol (e.g. `@XAU_USD`) → internal pairID (`ounce`).
    /// Derived by inverting `FarazHistorySource.symbolByPairID` and
    /// prepending `@` (the WS always uses that prefix).
    static let pairIDByFarazSymbol: [String: String] = {
        var map: [String: String] = [:]
        for (pairID, sym) in FarazHistorySource.symbolByPairID {
            map["@\(sym)"] = pairID
        }
        return map
    }()

    /// Spot tick — called on the main actor per `term-room` event.
    var onTick: ((_ pairID: String, _ price: Double) -> Void)?
    /// Bar update — called on the main actor per `symbol-room` event.
    var onCandle: ((_ bar: OHLCBar) -> Void)?

    @Published private(set) var isConnected: Bool = false

    private var socket: URLSessionWebSocketTask?
    private var runTask: Task<Void, Never>?

    /// Cookie from the user's Faraz session (Settings). Sent as a
    /// request header on the WS upgrade; may be empty (some rooms work
    /// unauthenticated, but the customer namespace typically needs it).
    private let cookie: String

    /// Base URL for the Faraz service (e.g. `https://faraz.io`).
    /// The WebSocket path `/srv09/realtime/` is appended automatically.
    private let apiBaseURL: String

    /// Rooms to join after the /customer namespace handshake.
    private let rooms: [String]

    /// - Parameters:
    ///   - symbols: Faraz native symbols to subscribe (e.g. `["XAU_USD"]`).
    ///     For each we join the term-room and 1m + 1D symbol-rooms.
    ///   - cookie: Session cookie from Settings (may be empty).
    ///   - apiBaseURL: Base URL from Settings (defaults to `https://faraz.io`).
    init(symbols: [String], cookie: String = "", apiBaseURL: String = DataSourceConfig.defaultFarazAPIURL) {
        self.cookie     = cookie
        self.apiBaseURL = apiBaseURL
        var r: [String] = []
        for sym in symbols {
            r.append("term-room-@\(sym)")
            r.append("symbol-room-@\(sym)@1@0")
            r.append("symbol-room-@\(sym)@1D@0")
        }
        self.rooms = r
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

    // MARK: - Connect / reconnect loop

    private func runLoop() async {
        var backoff: Double = 1
        while !Task.isCancelled {
            do {
                try await connectAndStream()
                backoff = 1
            } catch {
                isConnected = false
                logEvent("WS ERR", error: error)
            }
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            backoff = min(backoff * 2, 30)
        }
    }

    private func connectAndStream() async throws {
        let wsBase = apiBaseURL.replacingOccurrences(of: "https://", with: "wss://")
                               .replacingOccurrences(of: "http://", with: "ws://")
        var req = URLRequest(url: URL(string: "\(wsBase)/srv09/realtime/?EIO=4&transport=websocket")!)
        req.setValue(apiBaseURL, forHTTPHeaderField: "Origin")
        req.setValue("Mozilla/5.0 HelixTradingApp/0.1", forHTTPHeaderField: "User-Agent")
        if !cookie.isEmpty {
            req.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        let task = URLSession.shared.webSocketTask(with: req)
        socket = task
        task.resume()
        logEvent("WS OPEN", error: nil)

        var namespaceConnected = false

        while !Task.isCancelled {
            let msg = try await task.receive()
            let text: String
            switch msg {
            case .string(let s): text = s
            case .data(let d):   text = String(data: d, encoding: .utf8) ?? ""
            @unknown default:    continue
            }
            guard !text.isEmpty else { continue }

            // EIO PING → respond with EIO PONG to keep the socket alive.
            if text == "2" {
                try? await task.send(.string("3"))
                continue
            }

            // EIO OPEN — server sent handshake JSON; join /customer namespace.
            if text.hasPrefix("0") && !namespaceConnected {
                try await task.send(.string("40/customer,"))
                continue
            }

            // SIO CONNECT ack on /customer — join every subscribed room.
            if text.hasPrefix("40/customer,") && !namespaceConnected {
                namespaceConnected = true
                isConnected = true
                logEvent("WS NAMESPACE OK", error: nil)
                for room in rooms {
                    let escaped = room.replacingOccurrences(of: "\"", with: "\\\"")
                    try await task.send(.string("42/customer,[\"join\",\"\(escaped)\"]"))
                }
                continue
            }

            // SIO EVENT on /customer: `42/customer,[eventName, payload]`
            if text.hasPrefix("42/customer,") {
                let body = String(text.dropFirst("42/customer,".count))
                handle(body)
            }
        }
    }

    // MARK: - Message dispatch

    private func handle(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
              arr.count >= 2,
              let roomName = arr[0] as? String,
              let payload  = arr[1] as? [String: Any]
        else { return }

        if roomName.hasPrefix("term-room-@") {
            handleTick(room: roomName, payload: payload)
        } else if roomName.hasPrefix("symbol-room-@") {
            handleCandle(room: roomName, payload: payload)
        }
    }

    // MARK: - Term-room: spot tick

    private func handleTick(room: String, payload: [String: Any]) {
        // room = "term-room-@XAU_USD"
        guard let price  = doubleFrom(payload["price"]) else { return }
        let sym = String(room.dropFirst("term-room-".count)) // "@XAU_USD"
        guard let pairID = Self.pairIDByFarazSymbol[sym] else { return }
        onTick?(pairID, price)
    }

    // MARK: - Symbol-room: OHLCV bar

    private func handleCandle(room: String, payload: [String: Any]) {
        // room = "symbol-room-@XAU_USD@1@0"  (TF = "1" → "1m")
        //      = "symbol-room-@XAU_USD@1D@0" (TF = "1D" → "1d")
        //
        // Split on "@" after stripping the prefix; leading "@" creates
        // an empty first component, so the layout is:
        //   ["", "XAU_USD", "1", "0"]   or   ["", "XAU_USD", "1D", "0"]
        let stripped = String(room.dropFirst("symbol-room-".count)) // "@XAU_USD@1@0"
        let parts = stripped.split(separator: "@", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4 else { return }
        let sym      = "@\(parts[1])"   // "@XAU_USD"
        let tfRaw    = parts[2]         // "1" or "1D"
        guard let pairID = Self.pairIDByFarazSymbol[sym] else { return }

        guard let open   = doubleFrom(payload["open"]),
              let high   = doubleFrom(payload["high"]),
              let low    = doubleFrom(payload["low"]),
              let close  = doubleFrom(payload["close"]),
              let timeMs = doubleFrom(payload["time"])
        else { return }

        let bar = OHLCBar(
            pairID: pairID,
            timeframe: farazTFToTag(tfRaw),
            bucketStart: Date(timeIntervalSince1970: timeMs / 1000),
            open: open, high: high, low: low, close: close,
            volume: doubleFrom(payload["volume"])
        )
        onCandle?(bar)
    }

    // MARK: - Helpers

    private func farazTFToTag(_ raw: String) -> String {
        switch raw {
        case "1":   return "1m"
        case "5":   return "5m"
        case "15":  return "15m"
        case "60":  return "1h"
        case "240": return "4h"
        case "1D":  return "1d"
        default:    return raw.lowercased()
        }
    }

    private func doubleFrom(_ val: Any?) -> Double? {
        if let d = val as? Double { return d }
        if let i = val as? Int    { return Double(i) }
        if let s = val as? String { return Double(s) }
        return nil
    }

    private func logEvent(_ method: String, error: Error?) {
        NetworkLog.shared.record(
            source: "faraz-ws",
            method: method,
            url: "\(apiBaseURL.replacingOccurrences(of: "https://", with: "wss://").replacingOccurrences(of: "http://", with: "ws://"))/srv09/realtime/",
            status: error == nil ? 101 : nil,
            durationMs: 0,
            response: nil,
            error: error
        )
    }
}
