import Foundation
import Combine
import SwiftUI
import UserNotifications
import AppKit

/// Common shape of `OrderBlocks.Zone` / `SteroidOrderBlocks.Zone` — lets
/// `ScannerStore.retestedZone(in:price:marginFrac:)` work over either
/// without duplicating the containment math per zone type.
fileprivate protocol OBZoneLike {
    var index: Int { get }
    var high: Double { get }
    var low: Double { get }
}
extension OrderBlocks.Zone: OBZoneLike {}
extension SteroidOrderBlocks.Zone: OBZoneLike {}

struct ScannerSetup: Identifiable, Codable, Equatable {
    let id: String // pairID + strategy + direction + time
    let pairID: String
    let pairName: String
    let strategy: StrategyKind
    let direction: SetupDirection
    let entry: Double
    let stopLoss: Double
    let takeProfit: Double
    let riskReward: Double
    let detectedAt: Date
    
    enum StrategyKind: String, Codable {
        case swing = "Swing (4H/1H/15M)"
        case scalp = "Scalp (15M/5M/1M)"
    }
    
    enum SetupDirection: String, Codable {
        case long = "Long"
        case short = "Short"
        
        var arrow: String {
            switch self {
            case .long: return "↑"
            case .short: return "↓"
            }
        }
        
        var color: Color {
            switch self {
            case .long: return Theme.Color.success
            case .short: return Theme.Color.danger
            }
        }
    }
}

struct OpportunityLog: Identifiable, Codable, Equatable {
    let id: UUID
    let pairID: String
    let pairName: String
    let strategy: String
    let direction: String
    let entry: Double
    let stopLoss: Double
    let takeProfit: Double
    let riskReward: Double
    let timestamp: Date
}

@MainActor
final class ScannerStore: ObservableObject {
    @Published var isScanning = false
    @Published var activeSetups: [ScannerSetup] = []
    @Published var opportunityHistory: [OpportunityLog] = []
    
    @Published var enableSwingScan = true
    @Published var enableScalpScan = true
    
    @Published var scannedPairIDs: Set<String> = [] {
        didSet {
            saveScannedPairs()
        }
    }
    
    private var timer: Timer?
    private let database: AppDatabase
    let pairs: [TradingPair]
    private let notificationInbox: NotificationInbox

    /// `ScannerSetup.id` values that were active as of the previous
    /// scan (pair+strategy+direction+zone-index — stable while the
    /// same underlying setup is still valid). Compared against each
    /// fresh scan's ids to detect "just appeared" vs "still the same
    /// setup as last time".
    ///
    /// This replaces an older dedup that checked whether *any* log
    /// entry existed within a rolling 3600-second window — which
    /// meant a setup that stayed valid for longer than an hour fell
    /// outside every prior log entry's window and got re-notified
    /// (and re-logged) roughly every hour for as long as it remained
    /// open. Comparing against the setup's own stable id instead
    /// means it only notifies once, on the scan where it first
    /// becomes active.
    private var previousActiveSetupIDs: Set<String> = []
    /// Skip notifying (but still seed `previousActiveSetupIDs`) on
    /// the very first scan after launch — otherwise every setup
    /// that's already active when the app opens fires a notification
    /// as if it were brand new. Mirrors `AlertStore`'s order-block
    /// baseline-seeding guard.
    private var hasSeededBaseline = false

    private static let historyKey = "scanner.history.v1"
    private static let scannedPairsKey = "scanner.scannedPairs.v1"

    init(database: AppDatabase, pairs: [TradingPair], notificationInbox: NotificationInbox) {
        self.database = database
        self.pairs = pairs
        self.notificationInbox = notificationInbox
        loadHistory()
        loadScannedPairs()
        if scannedPairIDs.isEmpty {
            scannedPairIDs = Set(pairs.map { $0.id })
        }
        requestNotificationPermission()
        startTimer()
        
        // Run first scan after 2 seconds to warm up
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            Task { @MainActor [weak self] in
                await self?.performScan()
            }
        }
    }
    
    deinit {
        timer?.invalidate()
    }
    
    func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                await self.performScan()
            }
        }
    }
    
    func triggerManualScan() {
        Task {
            await performScan()
        }
    }
    
    func togglePairScan(pairID: String) {
        if scannedPairIDs.contains(pairID) {
            scannedPairIDs.remove(pairID)
        } else {
            scannedPairIDs.insert(pairID)
        }
    }
    
    private func loadHistory() {
        if let data = UserDefaults.standard.data(forKey: Self.historyKey),
           let decoded = try? JSONDecoder().decode([OpportunityLog].self, from: data) {
            opportunityHistory = decoded
        }
    }
    
    private func saveHistory() {
        if let data = try? JSONEncoder().encode(opportunityHistory) {
            UserDefaults.standard.set(data, forKey: Self.historyKey)
        }
    }
    
    private func loadScannedPairs() {
        guard let saved = UserDefaults.standard.stringArray(forKey: Self.scannedPairsKey) else { return }
        // Guard against a `saved` set built from an older pair catalog
        // (same class of bug `AppState.bootDatabase` already guards
        // against for `selectedPairID` — "may point at a legacy Iran
        // pair from an older install"). Unvalidated, a stale save could
        // silently intersect down to zero real pairs, which makes
        // `performScan()`'s `enabledPairs` loop run zero times forever
        // — no error, no setups, ever, regardless of the market. Only
        // fall back to "scan everything" when NONE of the saved IDs
        // still exist; otherwise respect whichever subset the user
        // deliberately kept.
        let validIDs = Set(pairs.map(\.id))
        let filtered = Set(saved).intersection(validIDs)
        scannedPairIDs = filtered.isEmpty ? validIDs : filtered
    }
    
    private func saveScannedPairs() {
        UserDefaults.standard.set(Array(scannedPairIDs), forKey: Self.scannedPairsKey)
    }
    
    func clearHistory() {
        opportunityHistory = []
        saveHistory()
    }
    
    func performScan() async {
        guard !isScanning else { return }
        isScanning = true
        
        let enabledPairs = pairs.filter { scannedPairIDs.contains($0.id) }
        let enableSwing = enableSwingScan
        let enableScalp = enableScalpScan
        let repo = database.ohlcRepo
        
        // Dispatch the scan calculation to a detached background thread pool.
        // This keeps GRDB reads and Aggregator aggregation completely off the main thread.
        let newSetups = await Task.detached(priority: .userInitiated) {
            var results: [ScannerSetup] = []
            let until = Date()
            
            for pair in enabledPairs {
                let respectsWeekend = pair.category != .crypto
                
                // Swing
                if enableSwing {
                    let h4 = Self.loadOHLCCandlesBg(repo: repo, pairID: pair.id, tf: .h4, until: until, dropClosedDays: respectsWeekend)
                    let h1 = Self.loadOHLCCandlesBg(repo: repo, pairID: pair.id, tf: .h1, until: until, dropClosedDays: respectsWeekend)
                    let m15 = Self.loadOHLCCandlesBg(repo: repo, pairID: pair.id, tf: .m15, until: until, dropClosedDays: respectsWeekend)
                    
                    if h4.count > 20, h1.count > 20, m15.count > 20 {
                        if let setup = Self.checkSwingSetupBg(isBullish: true, pair: pair, h4: h4, h1: h1, m15: m15) {
                            results.append(setup)
                        }
                        if let setup = Self.checkSwingSetupBg(isBullish: false, pair: pair, h4: h4, h1: h1, m15: m15) {
                            results.append(setup)
                        }
                    }
                }
                
                // Scalp
                if enableScalp {
                    let m15 = Self.loadOHLCCandlesBg(repo: repo, pairID: pair.id, tf: .m15, until: until, dropClosedDays: respectsWeekend)
                    let m5 = Self.loadOHLCCandlesBg(repo: repo, pairID: pair.id, tf: .m5, until: until, dropClosedDays: respectsWeekend)
                    let m1 = Self.loadOHLCCandlesBg(repo: repo, pairID: pair.id, tf: .m1, until: until, dropClosedDays: respectsWeekend)
                    
                    if m15.count > 20, m5.count > 20, m1.count > 20 {
                        if let setup = Self.checkScalpSetupBg(isBullish: true, pair: pair, m15: m15, m5: m5, m1: m1) {
                            results.append(setup)
                        }
                        if let setup = Self.checkScalpSetupBg(isBullish: false, pair: pair, m15: m15, m5: m5, m1: m1) {
                            results.append(setup)
                        }
                    }
                }
            }
            return results
        }.value
        
        // Process alarm triggers and save history back on Main Actor.
        await MainActor.run {
            let newActiveIDs = Set(newSetups.map(\.id))
            // A setup is "just appeared" when its id wasn't active on
            // the previous scan. On the very first scan after launch
            // there is no "previous scan" to compare against, so we
            // only seed the baseline instead of notifying for
            // whatever's already open.
            let justAppeared = hasSeededBaseline
                ? newSetups.filter { !previousActiveSetupIDs.contains($0.id) }
                : []

            for setup in justAppeared {
                let log = OpportunityLog(
                    id: UUID(),
                    pairID: setup.pairID,
                    pairName: setup.pairName,
                    strategy: setup.strategy.rawValue,
                    direction: setup.direction.rawValue,
                    entry: setup.entry,
                    stopLoss: setup.stopLoss,
                    takeProfit: setup.takeProfit,
                    riskReward: setup.riskReward,
                    timestamp: setup.detectedAt
                )
                opportunityHistory.insert(log, at: 0)
                if opportunityHistory.count > 100 {
                    opportunityHistory = Array(opportunityHistory.prefix(100))
                }
                saveHistory()

                playAlarmSound()
                triggerNotification(for: setup)
            }
            previousActiveSetupIDs = newActiveIDs
            hasSeededBaseline = true
            activeSetups = newSetups
            isScanning = false
        }
    }
    
    // ─── Static Nonisolated Scanning Core Helpers ───

    /// Among `zones` (already filtered to the wanted direction and
    /// exhaustion state), find the one `price` is *currently* inside
    /// (± a margin scaled to the zone's own height and to price), and
    /// prefer the most recently formed match when several qualify.
    ///
    /// This replaces the old "take the chronologically last zone, then
    /// check if price happens to be in *that one*" logic, which failed
    /// as soon as price moved on from the newest block — a block
    /// doesn't stop being a valid retest zone just because a newer one
    /// has since formed elsewhere. Scanning every non-exhausted zone
    /// for containment is what "is price retesting an order block
    /// right now" actually means.
    nonisolated private static func retestedZone<Z: OBZoneLike>(
        in zones: [Z], price: Double, marginFrac: Double
    ) -> Z? {
        let matches = zones.filter { z in
            let margin = max((z.high - z.low) * 0.2, price * marginFrac)
            return price >= z.low - margin && price <= z.high + margin
        }
        return matches.max(by: { $0.index < $1.index })
    }

    nonisolated private static func checkSwingSetupBg(
        isBullish: Bool,
        pair: TradingPair,
        h4: [Candle],
        h1: [Candle],
        m15: [Candle]
    ) -> ScannerSetup? {
        let currentPrice = m15.last?.close ?? 0.0
        guard currentPrice > 0 else { return nil }
        
        let h4Zones = SteroidOrderBlocks.compute(
            h4, periods: 5, threshold: 0.0, useWicks: false,
            detectSteroids: true, volumeMultiplier: 1.2
        ).filter { $0.isBullish == isBullish && $0.status != .exhausted }

        guard retestedZone(in: h4Zones, price: currentPrice, marginFrac: 0.005) != nil else { return nil }

        let h1Zones = OrderBlocks.compute(
            h1, periods: 5, threshold: 0.0, useWicks: false, detectSteroids: false
        ).filter { $0.isBullish == isBullish && $0.status != .exhausted }
        
        guard h1Zones.contains(where: { zone in
            let hzHeight = zone.high - zone.low
            let hzMargin = max(hzHeight * 0.2, currentPrice * 0.005)
            return currentPrice >= zone.low - hzMargin && currentPrice <= zone.high + hzMargin
        }) else { return nil }
        
        let m15Zones = OrderBlocks.compute(
            m15, periods: 5, threshold: 0.0, useWicks: false, detectSteroids: false
        ).filter { $0.isBullish == isBullish && $0.status == .fresh }
        
        guard let recent15MZone = m15Zones.last,
              (m15.count - 1 - recent15MZone.index) <= 15
        else { return nil }
        
        let entry = isBullish ? recent15MZone.high : recent15MZone.low
        let stopLoss = isBullish ? recent15MZone.low : recent15MZone.high
        let risk = abs(entry - stopLoss)
        guard risk > 0 else { return nil }
        
        let takeProfit = isBullish ? (entry + 3.0 * risk) : (entry - 3.0 * risk)
        
        return ScannerSetup(
            id: "\(pair.id)-swing-\(isBullish ? "L" : "S")-\(recent15MZone.index)",
            pairID: pair.id,
            pairName: pair.name,
            strategy: .swing,
            direction: isBullish ? .long : .short,
            entry: entry,
            stopLoss: stopLoss,
            takeProfit: takeProfit,
            riskReward: 3.0,
            detectedAt: Date()
        )
    }
    
    nonisolated private static func checkScalpSetupBg(
        isBullish: Bool,
        pair: TradingPair,
        m15: [Candle],
        m5: [Candle],
        m1: [Candle]
    ) -> ScannerSetup? {
        let currentPrice = m1.last?.close ?? 0.0
        guard currentPrice > 0 else { return nil }
        
        let m15Zones = SteroidOrderBlocks.compute(
            m15, periods: 5, threshold: 0.0, useWicks: false,
            detectSteroids: true, volumeMultiplier: 1.2
        ).filter { $0.isBullish == isBullish && $0.status != .exhausted }

        guard let m15Zone = retestedZone(in: m15Zones, price: currentPrice, marginFrac: 0.002) else { return nil }
        let margin = max((m15Zone.high - m15Zone.low) * 0.2, currentPrice * 0.002)

        let recent5M = m5.suffix(4)
        guard !recent5M.isEmpty else { return nil }
        
        let has5MRejection = isBullish
            ? recent5M.contains(where: { $0.low <= m15Zone.high + margin && $0.close >= m15Zone.low })
            : recent5M.contains(where: { $0.high >= m15Zone.low - margin && $0.close <= m15Zone.high })
            
        guard has5MRejection else { return nil }
        
        let m1Zones = OrderBlocks.compute(
            m1, periods: 5, threshold: 0.0, useWicks: false, detectSteroids: false
        ).filter { $0.isBullish == isBullish && $0.status == .fresh }
        
        guard let recent1MZone = m1Zones.last,
              (m1.count - 1 - recent1MZone.index) <= 10
        else { return nil }
        
        let entry = isBullish ? recent1MZone.high : recent1MZone.low
        let stopLoss = isBullish ? recent1MZone.low : recent1MZone.high
        let risk = abs(entry - stopLoss)
        guard risk > 0 else { return nil }
        
        let takeProfit = isBullish ? (entry + 2.0 * risk) : (entry - 2.0 * risk)
        
        return ScannerSetup(
            id: "\(pair.id)-scalp-\(isBullish ? "L" : "S")-\(recent1MZone.index)",
            pairID: pair.id,
            pairName: pair.name,
            strategy: .scalp,
            direction: isBullish ? .long : .short,
            entry: entry,
            stopLoss: stopLoss,
            takeProfit: takeProfit,
            riskReward: 2.0,
            detectedAt: Date()
        )
    }
    
    nonisolated private static func loadOHLCCandlesBg(
        repo: OHLCRepo,
        pairID: String,
        tf: Timeframe,
        until: Date,
        dropClosedDays: Bool
    ) -> [Candle] {
        let sourceTF = sourceTimeframeTagBg(for: tf)
        let needsFold = sourceTF != tf.rawValue
        do {
            let bars = try repo.read(
                pairID: pairID,
                timeframe: sourceTF,
                since: Date.distantPast,
                until: until,
                dropClosedDays: dropClosedDays
            )
            if !bars.isEmpty {
                return needsFold ? OHLCAggregator.fold(bars: bars, into: tf)
                                 : bars.map { $0.toCandle() }
            }
            if sourceTF == "1h" || sourceTF == "1d" {
                let fallback = try repo.read(
                    pairID: pairID, timeframe: "5m",
                    since: Date.distantPast, until: until, dropClosedDays: dropClosedDays
                )
                if !fallback.isEmpty {
                    return OHLCAggregator.fold(bars: fallback, into: tf)
                }
            }
        } catch {
            print("[ScannerStore] failed to load candles for \(pairID) \(tf.rawValue): \(error)")
        }
        return []
    }
    
    nonisolated private static func sourceTimeframeTagBg(for tf: Timeframe) -> String {
        switch tf {
        case .m1:             return "1m"
        case .m5, .m15, .m30: return "5m"
        case .h1, .h4:        return "1h"
        case .d1:             return "1d"
        }
    }
    
    private func playAlarmSound() {
        NSSound(named: "Hero")?.play()
    }
    
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    
    private func triggerNotification(for setup: ScannerSetup) {
        // `setup.strategy.rawValue` already encodes the confluence
        // timeframes (e.g. "Swing (4H/1H/15M)"), so that's what we
        // surface as this notification's timeframe context.
        notificationInbox.record(
            dedupKey: "scanner|\(setup.id)",
            cooldown: 60 * 60 * 4,
            pairID: setup.pairID,
            pairLabel: setup.pairName,
            category: .scanner,
            title: "🚨 New \(setup.strategy.rawValue) Opportunity!",
            body: "\(setup.pairName) \(setup.direction.rawValue) setup spotted! Entry: \(Self.formatPrice(setup.entry)) · SL: \(Self.formatPrice(setup.stopLoss)) · TP: \(Self.formatPrice(setup.takeProfit))",
            timeframeLabel: setup.strategy.rawValue
        )
    }
    
    static func formatPrice(_ v: Double) -> String {
        if v >= 10_000 { return String(format: "%.0f", v) }
        if v >= 100    { return String(format: "%.2f", v) }
        return String(format: "%.4f", v)
    }
}
