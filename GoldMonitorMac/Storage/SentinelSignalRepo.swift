import Foundation
import GRDB

/// A persisted Strategy Sentinel signal — one row per radar alert, keyed by
/// the alert's deterministic UUID string. `createdAt` is captured on first
/// sight and never moves (INSERT OR IGNORE), so `RadarAlert.isFresh` can be
/// rebuilt from the stored value instead of regenerating every pass.
///
/// Dates are stored as epoch-seconds REAL (the table predates any GRDB
/// Codable date strategy, and epoch keeps ordering/comparison trivial).
struct SentinelSignalRecord: Codable, Equatable {
    let id: String
    let pairID: String
    let timeframe: String
    let direction: String   // "BUY" / "SELL"
    let engine: String
    let grade: String
    let entry: Double
    let sl: Double
    let tp: Double
    let score: Int
    let htfNested: Bool
    let volumeRank: Int?
    let createdAt: Date
    var filledAt: Date? = nil
    var outcome: String? = nil    // "win" / "loss" / "expired"
    var outcomeAt: Date? = nil
    var outcomePrice: Double? = nil
}

/// Aggregate win/loss stats over resolved sentinel signals.
///
/// `expired` signals never traded (invalidated pre-fill or went stale), so
/// they count toward `resolved` but are excluded from the win-rate
/// denominator — winRate is wins / (wins + losses), nil when nothing ever
/// filled and resolved.
struct SentinelSignalStats: Equatable {
    struct Breakdown: Equatable {
        var resolved: Int = 0   // wins + losses + expired
        var wins: Int = 0
        var losses: Int = 0
        var expired: Int = 0
        var winRate: Double? {
            let traded = wins + losses
            return traded > 0 ? Double(wins) / Double(traded) : nil
        }
    }

    /// All resolved signals.
    var total = Breakdown()
    /// Same breakdown per detection engine (e.g. "Ranked OB").
    var byEngine: [String: Breakdown] = [:]
    /// Same breakdown per score bucket: "70-79", "80-89", "90-100".
    /// Scores below 70 (never notified) fall in "0-69".
    var byScoreBucket: [String: Breakdown] = [:]

    static func scoreBucket(for score: Int) -> String {
        switch score {
        case 90...: return "90-100"
        case 80..<90: return "80-89"
        case 70..<80: return "70-79"
        default: return "0-69"
        }
    }
}

/// Reads and writes against the `sentinel_signal` table. Schema is created
/// by [`Schema.swift`](./Schema.swift) (migration `v3_sentinel_signal`).
/// Mirrors `OHLCRepo`'s shape: sync wrappers for already-background callers,
/// `async throws` variants that suspend onto GRDB's queues for main-actor
/// callers, and pure `Database`-taking helpers both route through.
struct SentinelSignalRepo {
    let pool: DatabasePool

    // ── Sync API ──────────────────────────────────────────────────────

    /// First-seen-wins insert: existing ids keep their original row (so
    /// `created_at` stays the alert's true birth time across re-evaluations
    /// and relaunches).
    func insertIgnoring(_ signals: [SentinelSignalRecord]) throws {
        guard !signals.isEmpty else { return }
        try pool.write { db in try Self._insertIgnoring(signals, db) }
    }

    /// All signals for the pair/timeframe that haven't reached an outcome
    /// yet (`outcome IS NULL`) — both un-attempted and filled-but-open.
    func unresolved(pairID: String, timeframe: String) throws -> [SentinelSignalRecord] {
        try pool.read { db in try Self._unresolved(pairID: pairID, timeframe: timeframe, db) }
    }

    /// Stored `created_at` per signal id — lets the engine republish alerts
    /// with their original birth time instead of `Date()`.
    func createdAts(ids: [String]) throws -> [String: Date] {
        guard !ids.isEmpty else { return [:] }
        return try pool.read { db in try Self._createdAts(ids: ids, db) }
    }

    /// Outcome update. Any field left nil is preserved (COALESCE), so a fill
    /// can be recorded on its own (`filledAt` only, outcome still nil) and a
    /// later resolution never wipes it.
    func resolve(id: String, filledAt: Date?, outcome: String?,
                 outcomeAt: Date?, outcomePrice: Double?) throws {
        try pool.write { db in
            try Self._resolve(id: id, filledAt: filledAt, outcome: outcome,
                              outcomeAt: outcomeAt, outcomePrice: outcomePrice, db)
        }
    }

    /// Win/loss aggregates across every resolved signal.
    func stats() throws -> SentinelSignalStats {
        try pool.read { db in try Self._stats(db) }
    }

    // ── Async API (off-main via GRDB's queues) ────────────────────────

    /// Async, off-main. See `insertIgnoring(_:)`.
    func insertIgnoring(_ signals: [SentinelSignalRecord]) async throws {
        guard !signals.isEmpty else { return }
        try await pool.write { db in try Self._insertIgnoring(signals, db) }
    }

    /// Async, off-main. See `unresolved(pairID:timeframe:)`.
    func unresolved(pairID: String, timeframe: String) async throws -> [SentinelSignalRecord] {
        try await pool.read { db in try Self._unresolved(pairID: pairID, timeframe: timeframe, db) }
    }

    /// Async, off-main. See `createdAts(ids:)`.
    func createdAts(ids: [String]) async throws -> [String: Date] {
        guard !ids.isEmpty else { return [:] }
        return try await pool.read { db in try Self._createdAts(ids: ids, db) }
    }

    /// Async, off-main. See `resolve(id:filledAt:outcome:outcomeAt:outcomePrice:)`.
    func resolve(id: String, filledAt: Date?, outcome: String?,
                 outcomeAt: Date?, outcomePrice: Double?) async throws {
        try await pool.write { db in
            try Self._resolve(id: id, filledAt: filledAt, outcome: outcome,
                              outcomeAt: outcomeAt, outcomePrice: outcomePrice, db)
        }
    }

    /// Async, off-main. See `stats()`.
    func stats() async throws -> SentinelSignalStats {
        try await pool.read { db in try Self._stats(db) }
    }

    // ── Pure DB operations (take a Database handle) ────────────────────

    private static func _insertIgnoring(_ signals: [SentinelSignalRecord], _ db: Database) throws {
        for s in signals {
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO sentinel_signal
                    (id, pair_id, timeframe, direction, engine, grade,
                     entry, sl, tp, score, htf_nested, volume_rank, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    s.id, s.pairID, s.timeframe, s.direction, s.engine, s.grade,
                    s.entry, s.sl, s.tp, s.score, s.htfNested,
                    s.volumeRank as DatabaseValueConvertible,
                    s.createdAt.timeIntervalSince1970,
                ]
            )
        }
    }

    private static func _unresolved(pairID: String, timeframe: String, _ db: Database) throws -> [SentinelSignalRecord] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT * FROM sentinel_signal
            WHERE pair_id = ? AND timeframe = ? AND outcome IS NULL
            ORDER BY created_at ASC
            """,
            arguments: [pairID, timeframe]
        )
        return rows.map(Self.record(from:))
    }

    private static func _createdAts(ids: [String], _ db: Database) throws -> [String: Date] {
        var result: [String: Date] = [:]
        // Chunk the IN-list so very large alert sets can't exceed SQLite's
        // variable-binding limit (999 by default).
        let chunkSize = 500
        for start in stride(from: 0, to: ids.count, by: chunkSize) {
            let slice = Array(ids[start..<min(start + chunkSize, ids.count)])
            let placeholders = slice.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, created_at FROM sentinel_signal WHERE id IN (\(placeholders))",
                arguments: StatementArguments(slice)
            )
            for row in rows {
                guard let id: String = row["id"], let ts: Double = row["created_at"] else { continue }
                result[id] = Date(timeIntervalSince1970: ts)
            }
        }
        return result
    }

    private static func _resolve(id: String, filledAt: Date?, outcome: String?,
                                 outcomeAt: Date?, outcomePrice: Double?, _ db: Database) throws {
        try db.execute(
            sql: """
            UPDATE sentinel_signal SET
                filled_at = COALESCE(?, filled_at),
                outcome = COALESCE(?, outcome),
                outcome_at = COALESCE(?, outcome_at),
                outcome_price = COALESCE(?, outcome_price)
            WHERE id = ?
            """,
            arguments: [
                filledAt?.timeIntervalSince1970 as DatabaseValueConvertible,
                outcome as DatabaseValueConvertible,
                outcomeAt?.timeIntervalSince1970 as DatabaseValueConvertible,
                outcomePrice as DatabaseValueConvertible,
                id,
            ]
        )
    }

    private static func _stats(_ db: Database) throws -> SentinelSignalStats {
        // The table stays small (one row per emitted signal), so aggregate
        // in Swift from a single projection instead of stacking GROUP BYs.
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT engine, score, outcome FROM sentinel_signal WHERE outcome IS NOT NULL"
        )
        var stats = SentinelSignalStats()
        for row in rows {
            guard let outcome: String = row["outcome"] else { continue }
            let engine: String = row["engine"] ?? "Unknown"
            let score: Int = row["score"] ?? 0
            let bucket = SentinelSignalStats.scoreBucket(for: score)

            func apply(_ b: inout SentinelSignalStats.Breakdown) {
                b.resolved += 1
                switch outcome {
                case "win": b.wins += 1
                case "loss": b.losses += 1
                case "expired": b.expired += 1
                default: break
                }
            }
            apply(&stats.total)
            apply(&stats.byEngine[engine, default: .init()])
            apply(&stats.byScoreBucket[bucket, default: .init()])
        }
        return stats
    }

    // ── Row decoding ──────────────────────────────────────────────────

    private static func record(from row: Row) -> SentinelSignalRecord {
        let created: Double = row["created_at"] ?? 0
        let filled: Double? = row["filled_at"]
        let outcomeAt: Double? = row["outcome_at"]
        let htf: Int = row["htf_nested"] ?? 0
        return SentinelSignalRecord(
            id: row["id"] ?? "",
            pairID: row["pair_id"] ?? "",
            timeframe: row["timeframe"] ?? "",
            direction: row["direction"] ?? "",
            engine: row["engine"] ?? "",
            grade: row["grade"] ?? "",
            entry: row["entry"] ?? 0,
            sl: row["sl"] ?? 0,
            tp: row["tp"] ?? 0,
            score: row["score"] ?? 0,
            htfNested: htf != 0,
            volumeRank: row["volume_rank"],
            createdAt: Date(timeIntervalSince1970: created),
            filledAt: filled.map { Date(timeIntervalSince1970: $0) },
            outcome: row["outcome"],
            outcomeAt: outcomeAt.map { Date(timeIntervalSince1970: $0) },
            outcomePrice: row["outcome_price"]
        )
    }
}
