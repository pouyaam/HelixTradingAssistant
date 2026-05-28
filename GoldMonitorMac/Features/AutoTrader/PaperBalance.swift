import Foundation
import Combine
import SwiftUI

/// Running paper-trading account balance. Starts at a user-set
/// notional (default $10,000), then walks with realised P/L of
/// every closed paper trade across every pair. Same balance feeds
/// the auto-trader's risk-% lot sizing (so losses compound: a 1%
/// risk after a string of losses is smaller in absolute dollars
/// than before).
///
/// Single source of truth across the app:
/// - `AutoTraderEngine.placeOrder` reads `currentBalance` for
///   sizing.
/// - `AutoTraderCard` displays it.
/// - `ActivateTradeSheet` could also read it, but keeps using the
///   user-settable `trade.accountBalance` AppStorage for now (the
///   activation sheet is the manual path; paper balance tracking
///   is for the auto-trader flow).
@MainActor
final class PaperBalance: ObservableObject {
    /// Starting balance — user-configurable from the Auto-trader
    /// settings card. Defaults to $10,000.
    @AppStorage("paper.startingBalance") var startingBalance: Double = 10_000

    /// Running balance = `startingBalance + sum(realisedPL)` over
    /// every closed paper trade. Computed from `tradeStore.byPair`
    /// on each refresh. Published so SwiftUI views observe.
    @Published private(set) var currentBalance: Double = 10_000
    @Published private(set) var realisedPL: Double = 0
    @Published private(set) var totalTrades: Int = 0
    @Published private(set) var wins: Int = 0
    @Published private(set) var losses: Int = 0

    private weak var tradeStore: TradeStore?
    private var cancellables = Set<AnyCancellable>()

    func attach(tradeStore: TradeStore) {
        self.tradeStore = tradeStore
        recompute(from: tradeStore.byPair)
        tradeStore.$byPair
            .receive(on: DispatchQueue.main)
            .sink { [weak self] byPair in
                self?.recompute(from: byPair)
            }
            .store(in: &cancellables)
    }

    /// Recalculate the running balance from the current trade
    /// store snapshot. Cheap — runs on every store mutation, but
    /// the cost is `O(total trades across all pairs)` which is
    /// bounded by `TradeStore.perPairCap × len(catalog)` (~200).
    private func recompute(from byPair: [String: [Trade]]) {
        var pl: Double = 0
        var wins = 0
        var losses = 0
        var total = 0
        for (_, trades) in byPair {
            for t in trades where t.isPaper && t.isClosed {
                total += 1
                let close = t.closePrice ?? 0
                let p = t.currentPL(at: close)
                pl += p
                if t.status == .closedHitTP { wins += 1 }
                if t.status == .closedHitSL { losses += 1 }
            }
        }
        self.realisedPL = pl
        self.totalTrades = total
        self.wins = wins
        self.losses = losses
        self.currentBalance = startingBalance + pl
    }

    /// Manual reset — wipes the historic paper trades' contribution
    /// to the balance by re-baselining `startingBalance` to whatever
    /// the user supplies, and dropping closed trades from the store.
    /// Used by the "Reset paper account" affordance in Settings.
    func resetToFresh(amount: Double, in tradeStore: TradeStore) {
        startingBalance = amount
        // Drop closed paper trades to reset the running ledger.
        for (pairID, list) in tradeStore.byPair {
            let kept = list.filter { !($0.isPaper && $0.isClosed) }
            tradeStore.replaceList(kept, for: pairID)
        }
        recompute(from: tradeStore.byPair)
    }
}
