import Foundation

/// Deterministic outcome tracking for persisted Strategy Sentinel signals.
///
/// Pure and synchronous: given a signal's geometry + the closed candle
/// series, decide what happened since the signal was born. The engine calls
/// this once per unresolved DB row on each evaluation pass and persists the
/// returned event — no state lives here.
enum SentinelOutcome {

    /// Terminal outcome of a signal. `expired` means the trade never
    /// happened (invalidated before fill, or went stale) and must not count
    /// toward win rate.
    enum Kind: String, Codable {
        case win
        case loss
        case expired
    }

    /// What one evaluation pass concluded about a signal.
    enum Event: Equatable {
        /// Nothing new — no fill, no touch of SL/TP, not stale.
        case unchanged
        /// Entry was touched; position is now open.
        case filled(at: Date)
        /// Terminal outcome without a (new) fill: pre-fill invalidation or
        /// staleness, or resolution of an already-filled signal.
        case resolved(Kind, at: Date, price: Double)
        /// One pass saw both the fill and the resolution (same candle, or a
        /// later candle when the fill hadn't been persisted yet).
        case filledThenResolved(filledAt: Date, outcome: Kind, at: Date, price: Double)
    }

    /// Signals that never filled expire after this much dead time.
    static let stalenessLimit: TimeInterval = 5 * 24 * 3600

    /// Evaluate a signal against the closed candle series (any still-forming
    /// bar must already have been dropped by the caller). Only candles with
    /// `id > createdAt` are considered, in time order.
    ///
    /// Semantics (BUY; SELL is the exact mirror):
    /// - Pre-fill: a candle whose range covers `entry` fills at entry. If
    ///   that same candle also touches SL, it's a fill + immediate loss
    ///   (conservative — we can't know which came first). A TP touch on the
    ///   fill candle is NOT credited as a win (same uncertainty, opposite
    ///   direction — don't hand out wins we can't prove).
    /// - Pre-fill expiry: SL touched by a candle that never traded at entry
    ///   (price gapped through the zone) → `expired`; TP reached by a candle
    ///   entirely past entry (ran away without us) → `expired`.
    /// - Post-fill: first candle touching SL → loss at SL; TP → win at TP;
    ///   both in one candle → loss (conservative).
    /// - Staleness: never filled and the last closed candle is more than
    ///   `stalenessLimit` after `createdAt` → `expired`.
    static func evaluate(
        direction: RadarAlert.SetupDirection,
        entry: Double,
        sl: Double,
        tp: Double,
        createdAt: Date,
        filledAt: Date?,
        candles: [Candle]
    ) -> Event {
        var filledAt = filledAt
        /// Whether the fill was already persisted before this pass — if not
        /// and we resolve, the event must carry the fill time along.
        let fillPersisted = (filledAt != nil)

        /// Wrap a terminal resolution, folding in an unpersisted fill.
        func terminal(_ kind: Kind, _ at: Date, _ price: Double) -> Event {
            if !fillPersisted, let f = filledAt {
                return .filledThenResolved(filledAt: f, outcome: kind, at: at, price: price)
            }
            // Either the fill was already persisted, or this is a pre-fill
            // invalidation / staleness expiry with no fill at all.
            return .resolved(kind, at: at, price: price)
        }

        for c in candles where c.id > createdAt {
            if let f = filledAt {
                // Post-fill — only candles after the fill bar count.
                guard c.id > f else { continue }
                switch direction {
                case .buy:
                    if c.low <= sl { return terminal(.loss, c.id, sl) }
                    if c.high >= tp { return terminal(.win, c.id, tp) }
                case .sell:
                    if c.high >= sl { return terminal(.loss, c.id, sl) }
                    if c.low <= tp { return terminal(.win, c.id, tp) }
                }
            } else {
                switch direction {
                case .buy:
                    let touchesEntry = c.low <= entry && c.high >= entry
                    if touchesEntry {
                        filledAt = c.id
                        if c.low <= sl {
                            return .filledThenResolved(filledAt: c.id, outcome: .loss, at: c.id, price: sl)
                        }
                    } else if c.low <= sl {
                        // Gapped through the zone into the stop without ever
                        // trading at entry — invalidated pre-fill.
                        return .resolved(.expired, at: c.id, price: sl)
                    } else if c.high >= tp {
                        // Ran away to target without us.
                        return .resolved(.expired, at: c.id, price: tp)
                    }
                case .sell:
                    let touchesEntry = c.high >= entry && c.low <= entry
                    if touchesEntry {
                        filledAt = c.id
                        if c.high >= sl {
                            return .filledThenResolved(filledAt: c.id, outcome: .loss, at: c.id, price: sl)
                        }
                    } else if c.high >= sl {
                        return .resolved(.expired, at: c.id, price: sl)
                    } else if c.low <= tp {
                        return .resolved(.expired, at: c.id, price: tp)
                    }
                }
            }
        }

        // Staleness: never filled and the series has run long past the
        // signal's useful life.
        if filledAt == nil, let last = candles.last,
           last.id.timeIntervalSince(createdAt) > stalenessLimit {
            return .resolved(.expired, at: last.id, price: last.close)
        }

        if !fillPersisted, let f = filledAt {
            return .filled(at: f)
        }
        return .unchanged
    }
}
