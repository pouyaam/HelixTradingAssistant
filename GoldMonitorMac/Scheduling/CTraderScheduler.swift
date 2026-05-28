import Foundation
import Combine

/// Persisted user configuration for the cTrader bridge. Stored as a
/// single Codable blob in UserDefaults so adding fields later doesn't
/// require new keys — bump the version suffix on the storage key if
/// you ever change the schema in a way old payloads can't decode.
struct CTraderConfig: Codable, Equatable {
    /// Master switch — when false, the scheduler stays dormant and the
    /// fallback chain reverts to TwelveData → Yahoo as if cTrader
    /// didn't exist.
    var enabled: Bool
    /// Loopback port the receiver listens on. Defaults to 7878; user-
    /// configurable in case it collides with something else they run.
    var port: UInt16

    static let `default` = CTraderConfig(enabled: false, port: 7878)

    private static let key = "ctrader.bridge.config.v1"

    static func load() -> CTraderConfig {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(CTraderConfig.self, from: data)
        else { return .default }
        return decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

/// Orchestrates the cTrader bridge: owns the WS receiver, maps the
/// cBot's `XAUUSD` symbol to the internal `ounce` pair, and feeds
/// ticks/bars into the same OHLC + live-price pipeline TwelveData and
/// Yahoo use.
///
/// Decoupled from YahooScheduler via the `liveTickSink` injected at
/// `start(...)` time — the scheduler just calls a closure when a tick
/// arrives, and YahooScheduler's `applyExternalTick` does the actual
/// work. Keeps the two components testable independently.
@MainActor
final class CTraderScheduler: ObservableObject {

    // MARK: - Published state (drives the Settings card)

    @Published private(set) var config: CTraderConfig = .load()
    @Published private(set) var status: CTraderWSReceiver.Status = .stopped
    /// Last incoming tick wall-clock — drives the "X seconds ago" chip
    /// and the staleness gate exposed via `isFreshForXAUUSD`.
    @Published private(set) var lastTickAt: Date?
    /// Last decoded `hello` payload — shows the cBot's account label
    /// + version in the Settings card.
    @Published private(set) var lastHello: CTraderWSReceiver.Hello?

    /// Wire callbacks the auto-trader subscribes to. Kept as
    /// closures (vs `@Published`) because order status events are
    /// one-shot side-effecting and we don't want SwiftUI to diff
    /// the last-N-events history on every render.
    var onOrderStatus: ((CTraderWSReceiver.OrderStatus) -> Void)?
    var onStateSnapshot: ((CTraderWSReceiver.StateSnapshot) -> Void)?

    // MARK: - Constants

    /// Symbol mapping: cBot sends `XAUUSD`, internal pair id is `ounce`.
    /// Hardcoded for v1; if you add more symbols later, replace with a
    /// dictionary fed from `TradingPair.catalog`.
    private static let symbolToPairID: [String: String] = [
        "XAUUSD": "ounce",
        "XAU/USD": "ounce",
    ]

    /// Tick is considered "fresh" if it arrived within this many
    /// seconds. The gate that decides whether TwelveData / gold-api /
    /// Yahoo should be allowed to overwrite the live price reads this.
    /// 10s is well past the cTrader cBot's normal tick cadence and
    /// matches TwelveData's own streamStaleSeconds threshold.
    private static let freshnessThreshold: TimeInterval = 10

    // MARK: - Private state

    private var receiver: CTraderWSReceiver?
    private var liveTickSink: ((Double, String, String) -> Void)?
    /// Struct value (not a reference type), so no weakness needed —
    /// the scheduler outlives its repo only at app teardown.
    private var ohlcRepo: OHLCRepo?

    /// Coalescing buffer: the most-recent tick we've received but not
    /// yet propagated downstream. cTrader can fire 50–100 ticks/sec
    /// during active sessions; the chart + DB-write + @Published
    /// cascade can't keep up with that, and the user can't see the
    /// difference anyway. We accept every incoming tick (cheap memory
    /// write here) but flush at most `flushHz` times per second.
    private var pendingTickPrice: Double?
    private var pendingTickPairID: String?
    private var flushTimer: DispatchSourceTimer?
    /// 2 Hz — the live price tag updates twice a second, which is
    /// indistinguishable from a higher rate for the human eye. The
    /// downstream `@Published` cascade (latestPrices, lastUpdateAt,
    /// activeLiveSource) all get throttled by this same rate. 5 Hz
    /// turned out to be the threshold where the SwiftUI redraw cost
    /// + 4 SQLite ops/flush started pegging the main thread on
    /// moderately busy charts.
    private static let flushHz: Int = 2

    // MARK: - Lifecycle

    /// Wire up the receiver and start listening if the persisted
    /// config says we should. Safe to call multiple times — repeated
    /// calls reapply the current config.
    ///
    /// - Parameters:
    ///   - database: source of `ohlcRepo` for bar writes.
    ///   - liveTickSink: where to forward decoded ticks. Signature is
    ///     `(price, pairID, source)` so the sink reuses YahooScheduler's
    ///     internal `applyLiveTick` shape.
    func start(
        database: AppDatabase,
        liveTickSink: @escaping (Double, String, String) -> Void
    ) {
        self.ohlcRepo = database.ohlcRepo
        self.liveTickSink = liveTickSink

        let r = CTraderWSReceiver()
        // The receiver invokes these callbacks from its own MainActor
        // methods (the receive loop already hopped onto MainActor
        // before calling `drainBuffer`), so no extra Task hop here —
        // each hop is a context switch we'd pay on every tick.
        r.onStatus = { [weak self] s in
            self?.status = s
            // On a fresh connection, ask the cBot for its current
            // position + working-order snapshot so the auto-trader
            // can reconcile any state drift across a Helix crash
            // or cBot restart. Fire-and-forget — the cBot's reply
            // arrives via the `state_snapshot` callback.
            if case .connected = s {
                self?.requestStateSnapshot()
            }
        }
        r.onHello = { [weak self] h in self?.lastHello = h }
        r.onTick = { [weak self] t in self?.handleTick(t) }
        r.onBar = { [weak self] b in self?.handleBar(b) }
        r.onOrderStatus = { [weak self] s in self?.onOrderStatus?(s) }
        r.onStateSnapshot = { [weak self] s in self?.onStateSnapshot?(s) }
        self.receiver = r

        startFlushTimer()

        if config.enabled {
            r.start(port: config.port)
        }
    }

    /// Spin up the coalescing timer. Fires `flushHz` times per second
    /// on the main queue. The handler is a cheap "anything pending?"
    /// check so leaving it running while the bridge is disabled costs
    /// effectively nothing.
    private func startFlushTimer() {
        flushTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        let interval = DispatchTimeInterval.milliseconds(1000 / Self.flushHz)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.flushPendingTick()
            }
        }
        t.resume()
        flushTimer = t
    }

    deinit {
        flushTimer?.cancel()
    }

    /// Update the user-facing config. Restarts the receiver if any
    /// connection-affecting field changed.
    func updateConfig(_ new: CTraderConfig) {
        let prev = config
        config = new
        new.save()
        // Restart the listener if the user flipped enabled or moved
        // the port. We don't bother diffing surgically — restart is
        // cheap (listener creation is ~microseconds) and avoids subtle
        // edge cases where the port silently doesn't change.
        if prev != new {
            receiver?.stop()
            if new.enabled {
                receiver?.start(port: new.port)
            }
        }
    }

    /// Used by YahooScheduler's gating logic to decide whether
    /// TwelveData / gold-api ticks should be allowed to overwrite the
    /// live price for the ounce pair. Returns true while a cTrader
    /// tick landed within the last `freshnessThreshold` seconds.
    func isFreshForXAUUSD() -> Bool {
        guard config.enabled, let last = lastTickAt else { return false }
        return Date().timeIntervalSince(last) < Self.freshnessThreshold
    }

    // MARK: - Message handlers

    private func handleTick(_ t: CTraderWSReceiver.Tick) {
        guard let pairID = Self.symbolToPairID[t.symbol.uppercased()] else { return }
        // Stash latest tick; the repeating flush timer is what
        // actually propagates downstream. Updating two locals is
        // ~nanoseconds even at 100 Hz, so this branch is safe to run
        // on every quote without measurably moving CPU.
        pendingTickPrice = t.mid
        pendingTickPairID = pairID
    }

    /// Drain the coalescing buffer. Runs `flushHz` times per second.
    /// When nothing is pending (e.g. a quiet market or the bridge is
    /// disabled) the function returns immediately — no @Published
    /// writes, no DB hits.
    private func flushPendingTick() {
        guard let price = pendingTickPrice,
              let pairID = pendingTickPairID
        else { return }
        pendingTickPrice = nil
        pendingTickPairID = nil
        lastTickAt = Date()
        liveTickSink?(price, pairID, "ctrader")
    }

    private func handleBar(_ b: CTraderWSReceiver.Bar) {
        guard let pairID = Self.symbolToPairID[b.symbol.uppercased()],
              let repo = ohlcRepo,
              let ts = b.ts
        else { return }
        // Map the cBot's timeframe label (M1, M5, …) onto our internal
        // format ("1m", "5m", …). Unknown TFs are dropped on the floor
        // rather than guessed — bad data is worse than missing data.
        guard let tf = Self.timeframeLabel(b.tf) else { return }
        let bar = OHLCBar(
            pairID: pairID,
            timeframe: tf,
            bucketStart: ts,
            open: b.o,
            high: b.h,
            low: b.l,
            close: b.c,
            volume: b.v
        )
        try? repo.upsertMany([bar])
    }

    private static func timeframeLabel(_ raw: String) -> String? {
        switch raw.uppercased() {
        case "M1": return "1m"
        case "M5": return "5m"
        case "M15": return "15m"
        case "M30": return "30m"
        case "H1", "M60": return "1h"
        case "H4": return "4h"
        case "D1": return "1d"
        default: return nil
        }
    }

    // MARK: - Outbound commands (auto-trader → cBot)

    /// Place a new order via the cBot. `helix_id` is generated by
    /// the caller (typically a UUID) and threaded back on every
    /// `order_status` event so the auto-trader can find the
    /// matching local Trade. `client` matches the cBot's
    /// `hello.symbol` so multi-client routing (future) works.
    ///
    /// Fire-and-forget; the cBot acks asynchronously via
    /// `order_status` events. No-op when not connected.
    func sendPlaceOrder(
        helixID: String,
        client: String,
        side: String,            // "buy" | "sell"
        entryKind: String,       // "market" | "limit"
        entry: Double,
        tp: Double,
        sl: Double,
        lots: Double,
        trailingATR: Double? = nil,
        atrPeriod: Int = 14,
        atrValue: Double? = nil
    ) {
        var payload: [String: Any] = [
            "type": "place_order",
            "id": helixID,
            "client": client,
            "side": side,
            "entry_kind": entryKind,
            "entry": entry,
            "tp": tp,
            "sl": sl,
            "lots": lots,
            "atr_period": atrPeriod,
        ]
        if let trailing = trailingATR { payload["trailing_atr"] = trailing }
        if let atr = atrValue          { payload["atr_value"] = atr }
        sendJSON(payload)
    }

    func sendModifyOrder(helixID: String, cTraderID: String, tp: Double?, sl: Double?) {
        var payload: [String: Any] = [
            "type": "modify_order",
            "id": helixID,
            "cTrader_id": cTraderID,
        ]
        if let tp = tp { payload["tp"] = tp }
        if let sl = sl { payload["sl"] = sl }
        sendJSON(payload)
    }

    func sendCancelOrder(helixID: String, cTraderID: String) {
        sendJSON([
            "type": "cancel_order",
            "id": helixID,
            "cTrader_id": cTraderID,
        ])
    }

    func sendClosePosition(helixID: String, cTraderID: String) {
        sendJSON([
            "type": "close_position",
            "id": helixID,
            "cTrader_id": cTraderID,
        ])
    }

    /// Ask the cBot for a snapshot of its current positions +
    /// working orders. Used after (re)connect to reconcile against
    /// the local TradeStore — anything the local store thinks is
    /// live but isn't in the snapshot gets marked closed.
    func requestStateSnapshot() {
        sendJSON([
            "type": "request_state",
            "id": UUID().uuidString,
        ])
    }

    /// Serialize a command payload to JSON + push it through the
    /// receiver's `sendLine`. Falls through silently when the
    /// payload can't be serialised (shouldn't happen — all values
    /// are JSON-safe primitives — but we don't want to crash on a
    /// programmer error).
    private func sendJSON(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let line = String(data: data, encoding: .utf8)
        else { return }
        receiver?.sendLine(line)
    }
}
