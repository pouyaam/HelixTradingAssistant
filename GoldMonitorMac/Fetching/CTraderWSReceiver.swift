import Foundation
import Network

/// Lightweight WebSocket-ish server that listens for incoming messages
/// from the companion cTrader cBot (`CTraderBridge/HelixBridgeBot.cs`).
///
/// "WebSocket-ish" because the framing is the subset we need:
///   • Newline-delimited JSON messages over a plain TCP connection.
///   • No WS upgrade handshake — the cBot sends raw JSON-per-line.
///
/// We chose this over a real WS handshake because the cBot side gets
/// dramatically simpler (no SHA-1 of the Sec-WebSocket-Key, no opcode
/// framing) and the security model is identical when both sides are
/// loopback. If we ever expose this to a LAN, we can swap in a real WS
/// library on both sides without changing the message schema.
///
/// Message types — all share a `type` discriminator:
///
///   {"type":"hello","symbol":"XAUUSD","tf":"M1","account":"demo-12345","bot":"0.1"}
///   {"type":"tick","symbol":"XAUUSD","bid":2340.55,"ask":2340.62,"ts":"2026-05-15T10:23:45.123Z"}
///   {"type":"bar","symbol":"XAUUSD","tf":"M1","o":2340.10,"h":2340.65,"l":2339.90,"c":2340.55,"v":182,"ts":"2026-05-15T10:23:00Z"}
///   {"type":"ping","ts":"..."}
///
/// The receiver is symbol-agnostic — it just decodes and forwards to
/// the scheduler via callbacks. Symbol → pairID mapping lives one
/// level up so the same receiver can grow into multi-symbol streaming
/// later without touching this file.
@MainActor
final class CTraderWSReceiver: ObservableObject {

    // MARK: - Public message types

    struct Hello: Codable, Equatable {
        let symbol: String
        let tf: String?
        let account: String?
        let bot: String?
    }

    struct Tick: Codable, Equatable {
        let symbol: String
        let bid: Double
        let ask: Double
        let ts: Date?

        /// Midpoint price — the value we feed into the OHLC pipeline.
        /// Bid/ask are kept on the message for future spread UI but the
        /// chart uses mid because that matches how Twelve Data + Yahoo
        /// report prices (last trade ~= mid).
        var mid: Double { (bid + ask) / 2 }
    }

    struct Bar: Codable, Equatable {
        let symbol: String
        let tf: String
        let o: Double
        let h: Double
        let l: Double
        let c: Double
        let v: Double?
        let ts: Date?
    }

    /// Lifecycle event for an auto-trader-placed order, emitted by
    /// the cBot as the broker confirms each state change. Matches
    /// `Trade.LiveOrderState` raw values + `Trade.CloseReason`
    /// raw values 1-to-1 so the upstream consumer can decode
    /// directly into those enums.
    struct OrderStatus: Codable, Equatable {
        let client: String
        let cTrader_id: String
        let helix_id: String?
        let state: String           // placed | filled | rejected | cancelled | closed
        let fill_price: Double?
        let close_price: Double?
        let close_reason: String?   // hitTP | hitSL | trailing | manual | cancelled
        let reject_reason: String?
    }

    /// Reply to a `request_state` command — a snapshot of every
    /// position + working order the cBot currently knows about
    /// for its symbol. Helix reconciles against this on (re)connect.
    struct StateSnapshot: Codable, Equatable {
        struct Position: Codable, Equatable {
            let cTrader_id: String
            let helix_id: String?
            let side: String     // buy | sell
            let lots: Double
            let entry: Double
            let tp: Double?
            let sl: Double?
        }
        struct Order: Codable, Equatable {
            let cTrader_id: String
            let helix_id: String?
            let side: String     // buy | sell
            let lots: Double
            let entry: Double
            let tp: Double?
            let sl: Double?
        }
        let client: String
        let positions: [Position]
        let orders: [Order]
    }

    enum Status: Equatable {
        case stopped
        case listening(port: UInt16)
        case connected(remote: String)
        case error(String)
    }

    // MARK: - Callbacks (set by scheduler)

    var onHello: ((Hello) -> Void)?
    var onTick:  ((Tick)  -> Void)?
    var onBar:   ((Bar)   -> Void)?
    var onOrderStatus: ((OrderStatus) -> Void)?
    var onStateSnapshot: ((StateSnapshot) -> Void)?
    /// Fires on every status transition. Lets the scheduler publish
    /// connection state for the Settings UI without coupling the
    /// receiver to ObservableObject machinery.
    var onStatus: ((Status) -> Void)?

    // MARK: - State

    @Published private(set) var status: Status = .stopped

    private var listener: NWListener?
    /// Active connection. cTrader cBots run one connection at a time;
    /// if a second client dials in we drop the old one — keeps state
    /// simple and matches the "single producer" assumption.
    private var connection: NWConnection?

    /// Per-connection inbound buffer. Messages are newline-delimited
    /// JSON; we accumulate bytes here until we see a `\n` and decode
    /// the chunk up to that point. Reset on every (re)connect.
    private var inboundBuffer = Data()

    private let queue = DispatchQueue(label: "club.helixtrading.ctrader-ws", qos: .userInitiated)

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Lifecycle

    /// Start listening on `port` of the loopback interface. Idempotent:
    /// calling start while already running stops the existing listener
    /// first (e.g. when the user changes the port in Settings).
    func start(port: UInt16 = 7878) {
        stop()
        do {
            let params = NWParameters.tcp
            // Loopback only — the cBot runs on the same machine. If we
            // ever want LAN, flip this off and add a shared-secret
            // check in the hello message. `requiredLocalEndpoint`
            // looks like the right knob but it's outbound-only — it's
            // for NWConnection, not NWListener, and setting it here
            // throws EINVAL (Network.NWError 22 - Invalid argument).
            params.acceptLocalOnly = true
            params.allowLocalEndpointReuse = true
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                throw NSError(
                    domain: "CTraderWSReceiver",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid port \(port)"]
                )
            }
            let l = try NWListener(using: params, on: nwPort)
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.handleListenerState(state, port: port) }
            }
            l.start(queue: queue)
            self.listener = l
        } catch {
            let s: Status = .error("listener failed: \(error.localizedDescription)")
            status = s
            onStatus?(s)
        }
    }

    func stop() {
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
        inboundBuffer.removeAll(keepingCapacity: false)
        let s: Status = .stopped
        status = s
        onStatus?(s)
    }

    // MARK: - NWListener / NWConnection plumbing

    private func handleListenerState(_ state: NWListener.State, port: UInt16) {
        switch state {
        case .ready:
            let s: Status = .listening(port: port)
            status = s
            onStatus?(s)
        case .failed(let err):
            let s: Status = .error("listener: \(err.localizedDescription)")
            status = s
            onStatus?(s)
        case .cancelled:
            // Only emit `stopped` if we didn't already publish a more
            // specific terminal state (e.g. error) immediately before.
            if case .listening = status {
                let s: Status = .stopped
                status = s
                onStatus?(s)
            }
        default:
            break
        }
    }

    private func accept(_ conn: NWConnection) {
        // Single-producer policy: drop any existing connection. The
        // cBot's reconnect loop will pick a fresh slot on its next
        // try, so this is benign even if we have a stale connection
        // around.
        connection?.cancel()
        inboundBuffer.removeAll(keepingCapacity: false)
        connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handleConnectionState(state, conn: conn) }
        }
        conn.start(queue: queue)
        scheduleRead(on: conn)
    }

    private func handleConnectionState(_ state: NWConnection.State, conn: NWConnection) {
        switch state {
        case .ready:
            let remote = conn.endpoint.debugDescription
            let s: Status = .connected(remote: remote)
            status = s
            onStatus?(s)
        case .failed(let err):
            let s: Status = .error("conn: \(err.localizedDescription)")
            status = s
            onStatus?(s)
            // Tear down so the listener can take a fresh connection.
            connection?.cancel()
            connection = nil
        case .cancelled:
            // Listener stays alive; we just no longer have an attached
            // client. Drop back to "listening" so the UI reads correctly.
            if listener != nil, case .connected = status {
                if let port = currentListenPort() {
                    let s: Status = .listening(port: port)
                    status = s
                    onStatus?(s)
                }
            }
        default:
            break
        }
    }

    private func currentListenPort() -> UInt16? {
        if case .listening(let p) = status { return p }
        return listener?.port.flatMap { UInt16(exactly: $0.rawValue) }
    }

    /// Pull the next chunk from the socket, append to the inbound
    /// buffer, drain any complete `\n`-terminated messages, recurse.
    private func scheduleRead(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self = self else { return }
                if let data = data, !data.isEmpty {
                    self.inboundBuffer.append(data)
                    self.drainBuffer()
                }
                if let error = error {
                    let s: Status = .error("recv: \(error.localizedDescription)")
                    self.status = s
                    self.onStatus?(s)
                    return
                }
                if isComplete {
                    // EOF — the cBot closed the connection cleanly.
                    conn.cancel()
                    return
                }
                self.scheduleRead(on: conn)
            }
        }
    }

    /// Split `inboundBuffer` on `\n` and decode each complete line.
    /// Leftover bytes after the last newline stay in the buffer for
    /// the next read pass — handles cBot messages that span TCP frames.
    private func drainBuffer() {
        let newline: UInt8 = 0x0A
        while let nlIndex = inboundBuffer.firstIndex(of: newline) {
            let lineData = inboundBuffer.prefix(upTo: nlIndex)
            inboundBuffer.removeSubrange(0...nlIndex)
            guard !lineData.isEmpty else { continue }
            decode(line: Data(lineData))
        }
    }

    private func decode(line: Data) {
        // Cheap discriminator probe — read `type` first via a tiny
        // wrapper so we don't run all three decoders speculatively on
        // every message.
        struct Envelope: Decodable { let type: String }
        guard let env = try? decoder.decode(Envelope.self, from: line) else { return }
        switch env.type {
        case "hello":
            if let h = try? decoder.decode(Hello.self, from: line) { onHello?(h) }
        case "tick":
            if let t = try? decoder.decode(Tick.self, from: line) { onTick?(t) }
        case "bar":
            if let b = try? decoder.decode(Bar.self, from: line) { onBar?(b) }
        case "ping":
            break
        case "order_status":
            if let s = try? decoder.decode(OrderStatus.self, from: line) { onOrderStatus?(s) }
        case "state_snapshot":
            if let snap = try? decoder.decode(StateSnapshot.self, from: line) { onStateSnapshot?(snap) }
        default:
            break
        }
    }

    // MARK: - Outbound writes

    /// Write a single newline-delimited JSON line to the connected
    /// cBot. No-op when there's no active connection (the
    /// AutoTraderEngine checks `status` before staging commands,
    /// but this fail-soft default keeps callers null-safe).
    ///
    /// Writes hop onto the receiver's private queue to avoid races
    /// with the read loop, then surface back to MainActor only for
    /// error reporting — sends are fire-and-forget; the cBot acks
    /// via `order_status`.
    func sendLine(_ json: String) {
        guard let conn = connection else { return }
        let payload = (json + "\n").data(using: .utf8) ?? Data()
        queue.async {
            conn.send(content: payload, completion: .contentProcessed { error in
                if let error = error {
                    Task { @MainActor in
                        let s: Status = .error("send: \(error.localizedDescription)")
                        self.status = s
                        self.onStatus?(s)
                    }
                }
            })
        }
    }
}
