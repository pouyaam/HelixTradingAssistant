import Foundation
import SwiftUI
import Combine
import UserNotifications

// MARK: - Alert model

/// One price alert. Three flavours: a manually-set crossing alert
/// ("notify when XAU crosses 4,720"), a scenario-trigger alert that
/// auto-fires when an active TA scenario's entry fills, and a
/// scenario-invalidation alert that fires when a scenario's SL
/// gets touched. Scenario-derived alerts are auto-created when the
/// user adds a scenario to the chart so the user doesn't have to
/// remember; manual alerts come from the chart's right-click /
/// alert button (TODO once wired).
///
/// Codable so the AlertStore can persist them across launches.
/// Optional fields use `decodeIfPresent` shape — keep that in mind
/// when adding new fields so older payloads keep loading.
struct PriceAlert: Identifiable, Codable, Equatable {
    let id: UUID
    let pairID: String
    let kind: Kind
    /// For price-crossing kinds: the absolute price level.
    /// For RSI kinds: the RSI threshold (0-100).
    let level: Double
    let title: String
    let body: String
    let createdAt: Date

    var firedAt: Date?
    /// User-controllable disable toggle. Separate from `firedAt`:
    /// fired alerts can be re-armed; disabled alerts stay inert
    /// until re-enabled. Decoded with default `true` so older
    /// persisted alerts load as enabled.
    var enabled: Bool
    let sourceScenarioID: String?

    enum Kind: String, Codable {
        case crossUp           // price rises through `level`
        case crossDown         // price falls through `level`
        case scenarioEntry     // any-direction touch — bias from scenario
        case scenarioSL        // any-direction touch — bias from scenario
        case rsiCrossAbove     // RSI crosses above `level` (e.g. 70 = overbought)
        case rsiCrossBelow     // RSI crosses below `level` (e.g. 30 = oversold)
    }

    /// Armed = enabled AND not fired. Fired-but-enabled alerts
    /// stay inert until re-armed; disabled alerts always inert.
    var isArmed: Bool { enabled && firedAt == nil }
    /// Indicator-driven alerts need different evaluator data
    /// (RSI series vs raw price tick).
    var isIndicatorAlert: Bool {
        switch kind {
        case .rsiCrossAbove, .rsiCrossBelow: return true
        default: return false
        }
    }

    init(
        id: UUID,
        pairID: String,
        kind: Kind,
        level: Double,
        title: String,
        body: String,
        createdAt: Date,
        firedAt: Date? = nil,
        enabled: Bool = true,
        sourceScenarioID: String? = nil
    ) {
        self.id = id
        self.pairID = pairID
        self.kind = kind
        self.level = level
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.firedAt = firedAt
        self.enabled = enabled
        self.sourceScenarioID = sourceScenarioID
    }

    /// Custom decoder so older persisted alerts (no `enabled`
    /// column) load as enabled.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        pairID = try c.decode(String.self, forKey: .pairID)
        kind = try c.decode(Kind.self, forKey: .kind)
        level = try c.decode(Double.self, forKey: .level)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decode(String.self, forKey: .body)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        firedAt = try c.decodeIfPresent(Date.self, forKey: .firedAt)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        sourceScenarioID = try c.decodeIfPresent(String.self, forKey: .sourceScenarioID)
    }
}

// MARK: - AlertStore

/// Per-app persistent store of price alerts. Lives at the
/// DashboardView scope alongside TradeStore / DrawingStore. The
/// evaluator hooks the same live-price observers the trade
/// evaluator uses, so alerts fire on the same tick cadence.
///
/// Persisted to UserDefaults under `alerts.v1`. Capped at 100
/// alerts total — fired ones aren't deleted automatically (the
/// user might want to re-arm), but `removeFired()` is a one-click
/// cleanup in the alerts list.
@MainActor
final class AlertStore: ObservableObject {
    @Published private(set) var alerts: [PriceAlert] = []

    private static let storageKey = "alerts.v1"
    private static let cap = 100

    /// Tracks the last observed price per pair so a crossing
    /// alert can detect direction (was 4,710 → now 4,725 ⇒ crossed
    /// 4,720 upward). Without this we'd fire `.crossUp` on the
    /// very first tick that arrives above `level`, which is
    /// usually undesired ("the price was already up there before
    /// I set the alert").
    private var lastSeenPrice: [String: Double] = [:]
    /// Per-pair last RSI value so the indicator evaluator can
    /// detect a cross (prior < threshold → now >= threshold).
    /// Updated by `evaluateRSI(_:for:)`; reset on app launch
    /// (transient — alerts only fire on a real cross, not on the
    /// first observation after a relaunch).
    private var lastSeenRSI: [String: Double] = [:]

    init() {
        load()
        requestNotificationPermission()
    }

    // ── Reads ─────────────────────────────────────────────────────

    func alerts(for pairID: String) -> [PriceAlert] {
        alerts.filter { $0.pairID == pairID }
    }

    func armedAlerts(for pairID: String) -> [PriceAlert] {
        alerts.filter { $0.pairID == pairID && $0.isArmed }
    }

    // ── Mutations ─────────────────────────────────────────────────

    func add(_ alert: PriceAlert) {
        // Prevent duplicate scenario alerts (same scenario, same
        // kind) — the chart can re-add the same scenario on
        // re-render and we don't want a thicket of identical
        // alerts firing in parallel.
        if let scenarioID = alert.sourceScenarioID,
           alerts.contains(where: {
               $0.sourceScenarioID == scenarioID && $0.kind == alert.kind && $0.pairID == alert.pairID
           })
        {
            return
        }
        alerts.append(alert)
        if alerts.count > Self.cap {
            alerts = Array(alerts.suffix(Self.cap))
        }
        save()
    }

    func remove(id: UUID) {
        alerts.removeAll { $0.id == id }
        save()
    }

    /// Drop every alert tied to the given scenario fingerprint —
    /// called when the user clears a scenario from the chart so
    /// stale entry/SL alerts don't keep firing on unrelated
    /// retests.
    func removeForScenario(_ scenarioID: String) {
        alerts.removeAll { $0.sourceScenarioID == scenarioID }
        save()
    }

    /// Drop every scenario-derived alert whose fingerprint starts
    /// with `prefix`. The dashboard composes its fingerprints as
    /// `pairID|slot|scenarioID`, so passing `pairID|slot|` removes
    /// every alert in that slot regardless of which scenario
    /// produced them — what you want when the slot is being
    /// cleared or replaced.
    func removeWithSourcePrefix(_ prefix: String) {
        let before = alerts.count
        alerts.removeAll { ($0.sourceScenarioID ?? "").hasPrefix(prefix) }
        if alerts.count != before { save() }
    }

    func reArm(id: UUID) {
        guard let idx = alerts.firstIndex(where: { $0.id == id }) else { return }
        alerts[idx].firedAt = nil
        save()
    }

    /// Toggle a single alert's `enabled` flag. Disabled alerts
    /// stay in the store (so the user can re-enable later) but
    /// the evaluator skips them.
    func setEnabled(_ on: Bool, id: UUID) {
        guard let idx = alerts.firstIndex(where: { $0.id == id }) else { return }
        alerts[idx].enabled = on
        save()
    }

    func removeFired() {
        alerts.removeAll { !$0.isArmed && $0.firedAt != nil }
        save()
    }

    // ── Evaluator ─────────────────────────────────────────────────

    /// Run every armed alert for `pairID` against the new price.
    /// Direction-sensitive crossings consult `lastSeenPrice` so a
    /// crossUp alert only fires when price was below the level on
    /// the prior tick. Scenario-derived alerts (entry, SL) treat
    /// any touch as a trigger.
    func evaluate(price: Double, for pairID: String) {
        let prior = lastSeenPrice[pairID]
        defer { lastSeenPrice[pairID] = price }

        var changed = false
        for idx in alerts.indices {
            let a = alerts[idx]
            // Price-only path — skip indicator alerts (RSI etc.),
            // they're handled by `evaluateRSI(_:for:)` from the
            // dashboard's candle-update observer.
            guard a.pairID == pairID, a.isArmed, !a.isIndicatorAlert else { continue }
            var didFire = false
            switch a.kind {
            case .crossUp:
                if let prior = prior, prior < a.level, price >= a.level {
                    didFire = true
                }
            case .crossDown:
                if let prior = prior, prior > a.level, price <= a.level {
                    didFire = true
                }
            case .scenarioEntry, .scenarioSL:
                if let prior = prior {
                    let crossedUp   = prior <  a.level && price >= a.level
                    let crossedDown = prior >  a.level && price <= a.level
                    didFire = crossedUp || crossedDown
                }
            case .rsiCrossAbove, .rsiCrossBelow:
                continue
            }
            if didFire {
                alerts[idx].firedAt = Date()
                notify(alert: alerts[idx], price: price)
                changed = true
            }
        }
        if changed { save() }
    }

    /// Indicator evaluator — call when a fresh RSI value lands
    /// for `pairID` (typically after a candle close on the
    /// analysis timeframe). Fires `.rsiCrossAbove` / `.rsiCrossBelow`
    /// alerts whose threshold was crossed since the last sample.
    /// `pricePeek` is the most-recent tick used purely for the
    /// notification body (so the user sees both the RSI value
    /// AND where price was when it crossed).
    func evaluateRSI(_ rsi: Double, pricePeek: Double?, for pairID: String) {
        let prior = lastSeenRSI[pairID]
        defer { lastSeenRSI[pairID] = rsi }

        var changed = false
        for idx in alerts.indices {
            let a = alerts[idx]
            guard a.pairID == pairID, a.isArmed else { continue }
            var didFire = false
            switch a.kind {
            case .rsiCrossAbove:
                if let prior = prior, prior < a.level, rsi >= a.level {
                    didFire = true
                }
            case .rsiCrossBelow:
                if let prior = prior, prior > a.level, rsi <= a.level {
                    didFire = true
                }
            default:
                continue
            }
            if didFire {
                alerts[idx].firedAt = Date()
                notifyRSI(alert: alerts[idx], rsi: rsi, pricePeek: pricePeek)
                changed = true
            }
        }
        if changed { save() }
    }

    // ── Notifications ─────────────────────────────────────────────

    /// Ask for notification permission once at first launch.
    /// Silently no-ops on subsequent launches (UNUserNotificationCenter
    /// caches the decision). The user can also flip the toggle in
    /// macOS System Settings → Notifications.
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            // Granted-or-not, no fallback to wire. The notify()
            // call below is best-effort and silently fails when
            // permission is denied.
        }
    }

    private func notify(alert: PriceAlert, price: Double) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body + " · now \(Self.formatPrice(price))"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: alert.id.uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private func notifyRSI(alert: PriceAlert, rsi: Double, pricePeek: Double?) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        var body = alert.body + " · RSI " + String(format: "%.1f", rsi)
        if let p = pricePeek { body += " · price " + Self.formatPrice(p) }
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: alert.id.uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private static func formatPrice(_ v: Double) -> String {
        if v >= 10_000 { return String(format: "%.0f", v) }
        if v >= 100    { return String(format: "%.2f", v) }
        return String(format: "%.4f", v)
    }

    // ── Persistence ───────────────────────────────────────────────

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([PriceAlert].self, from: data)
        else { return }
        alerts = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(alerts) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
