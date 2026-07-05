import Foundation
import GRDB

/// A single OHLC bar persisted to the `ohlc` table. Lighter than `Candle`
/// — keeps `pairID` and `timeframe` alongside so the same value can be
/// upserted, read back, and re-mapped without losing context.
struct OHLCBar: Hashable {
    let pairID: String
    let timeframe: String      // "1m", "5m", etc. — opaque to the repo.
    let bucketStart: Date
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Double?

    /// Convert to the chart-rendering Candle. Pair/timeframe context isn't
    /// needed once we hand the bar to Apple Charts; volume rides along so
    /// the chart can render its volume sub-series.
    func toCandle() -> Candle {
        Candle(id: bucketStart, open: open, high: high, low: low, close: close, volume: volume)
    }
}

/// Reads and writes against the `ohlc` table. Schema is created by
/// [`Schema.swift`](./Schema.swift) — `UNIQUE(pair_id, timeframe, bucket_start)`
/// lets us upsert without explicit row-existence checks.
///
/// Date encoding: we serialize `bucket_start` with a single ISO-8601
/// formatter (no fractional seconds) so the UNIQUE constraint actually
/// dedupes — if encoding drifts between writes, the same minute gets
/// inserted twice.
struct OHLCRepo {
    let pool: DatabasePool

    // ── Sync API ──────────────────────────────────────────────────────
    //
    // Kept for the chart-read path (`DashboardView.candles`) and other
    // callers already off the hot path. Each delegates to a pure
    // `Database`-taking helper (see "Pure DB operations" below) so the
    // sync and async variants can't drift apart.

    /// Idempotent batch insert. Uses SQLite's `ON CONFLICT ... DO UPDATE`
    /// so re-running gap-fill doesn't pile up duplicates and a corrected
    /// bar (e.g. a closing tick) overwrites the stale one.
    func upsertMany(_ bars: [OHLCBar]) throws {
        guard !bars.isEmpty else { return }
        try pool.write { db in try Self._upsertMany(bars, db) }
    }

    /// Latest `bucket_start` for the given pair+timeframe, or nil if the
    /// table is empty for that key. Used by the gap-fill logic to decide
    /// what range to fetch from Yahoo.
    func latestBucket(pairID: String, timeframe: String) throws -> Date? {
        try pool.read { db in try Self._latestBucket(pairID: pairID, timeframe: timeframe, db) }
    }

    /// Earliest `bucket_start` for the given pair+timeframe, or nil if
    /// the table is empty for that key. Used by Replay's date-jump to
    /// bound the picker to the range we actually have data for.
    func earliestBucket(pairID: String, timeframe: String) throws -> Date? {
        try pool.read { db in try Self._earliestBucket(pairID: pairID, timeframe: timeframe, db) }
    }

    /// All bars in `[since, until]`, oldest first. The chart code calls
    /// this with a window appropriate for the visible timeframe.
    ///
    /// `dropClosedDays` filters out Sat/Sun bars after decoding — defense
    /// in depth in case any weekend rows snuck in before ingest filtering
    /// was added. Cheap (linear scan over already-fetched rows), so on
    /// by default for callers reading the ounce series.
    func read(pairID: String, timeframe: String, since: Date, until: Date,
              dropClosedDays: Bool = false) throws -> [OHLCBar] {
        try pool.read { db in
            try Self._read(pairID: pairID, timeframe: timeframe, since: since,
                           until: until, dropClosedDays: dropClosedDays, db)
        }
    }

    /// One-shot cleanup: remove every weekend bar for the given pair.
    /// SQLite has no native weekday function, so we decode each row's
    /// timestamp in Swift and `DELETE` by id. Linear over `ohlc` rows
    /// for `pairID`, but this only runs once per launch and the table
    /// stays bounded (~10k rows for ounce after a month at 5m bars).
    /// Returns the number of rows actually deleted.
    @discardableResult
    func deleteClosedDayBars(pairID: String) throws -> Int {
        try pool.write { db in try Self._deleteClosedDayBars(pairID: pairID, db) }
    }

    /// Number of rows for a (pair, timeframe). Used by smoke tests + the
    /// import screen to confirm bootstrap landed data.
    func count(pairID: String, timeframe: String) throws -> Int {
        try pool.read { db in try Self._count(pairID: pairID, timeframe: timeframe, db) }
    }

    // ── Async API ─────────────────────────────────────────────────────
    //
    // GRDB 7's `DatabasePool.write/read { }` async overloads dispatch the
    // closure onto GRDB's own writer/reader queues and suspend the caller
    // — so when a `@MainActor` caller `await`s these, the SQLite work runs
    // OFF the main thread and the UI never stalls. Use these from the
    // schedulers' hot paths (periodic sync, live-tick bar rolling,
    // bootstrap, pan-left backfill) where the old sync calls were blocking
    // the main actor during multi-thousand-row upserts.

    /// Async, off-main batch upsert. See `upsertMany(_:)`.
    func upsertMany(_ bars: [OHLCBar]) async throws {
        guard !bars.isEmpty else { return }
        try await pool.write { db in try Self._upsertMany(bars, db) }
    }

    /// Async, off-main. See `latestBucket(pairID:timeframe:)`.
    func latestBucket(pairID: String, timeframe: String) async throws -> Date? {
        try await pool.read { db in try Self._latestBucket(pairID: pairID, timeframe: timeframe, db) }
    }

    /// Async, off-main. See `earliestBucket(pairID:timeframe:)`.
    func earliestBucket(pairID: String, timeframe: String) async throws -> Date? {
        try await pool.read { db in try Self._earliestBucket(pairID: pairID, timeframe: timeframe, db) }
    }

    /// Async, off-main. See `read(pairID:timeframe:since:until:dropClosedDays:)`.
    func read(pairID: String, timeframe: String, since: Date, until: Date,
              dropClosedDays: Bool = false) async throws -> [OHLCBar] {
        try await pool.read { db in
            try Self._read(pairID: pairID, timeframe: timeframe, since: since,
                           until: until, dropClosedDays: dropClosedDays, db)
        }
    }

    /// Async, off-main. See `deleteClosedDayBars(pairID:)`.
    @discardableResult
    func deleteClosedDayBars(pairID: String) async throws -> Int {
        try await pool.write { db in try Self._deleteClosedDayBars(pairID: pairID, db) }
    }

    /// Async, off-main. Wipe every stored bar for a pair across all
    /// timeframes. Used when the user switches the pair's data source in
    /// Settings — the old provider's bars are cleared so the new one
    /// refetches from a clean slate (rather than interleaving two
    /// providers' OHLC, which can disagree on a given minute).
    func deleteAll(pairID: String) async throws {
        try await pool.write { db in try Self._deleteAll(pairID: pairID, db) }
    }

    /// Atomic live-tick bar roll. Inserts a fresh bar at `bucketStart`
    /// (open=high=low=close=price) or, if one already exists, expands
    /// high/low and advances close — `open` is captured once and never
    /// moved. Unlike `upsertMany` (which overwrites OHLC with the
    /// authoritative payload), the max/min/close merge happens in SQL via
    /// `ON CONFLICT DO UPDATE`, so the whole read-modify-write is one
    /// write transaction. That means concurrent ticks for the same bucket
    /// can't race a stale read and drop a high/low, and we avoid the
    /// separate pre-read the scheduler used to do on the main thread.
    func upsertLiveTickBar(pairID: String, timeframe: String,
                           bucketStart: Date, price: Double) async throws {
        try await pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO ohlc
                    (pair_id, timeframe, bucket_start, open, high, low, close, volume)
                VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
                ON CONFLICT(pair_id, timeframe, bucket_start) DO UPDATE SET
                    high  = max(high, excluded.high),
                    low   = min(low,  excluded.low),
                    close = excluded.close
                """,
                arguments: [
                    pairID, timeframe, Self.iso.string(from: bucketStart),
                    price, price, price, price,
                ]
            )
        }
    }

    // ── Pure DB operations (take a Database handle) ────────────────────
    //
    // The single source of truth for each query/mutation. Both the sync
    // and async wrappers above route through these, so SQL + decoding
    // logic lives in exactly one place.

    private static func _upsertMany(_ bars: [OHLCBar], _ db: Database) throws {
        // Batched multi-row INSERT — 8 params per row, SQLite limit
        // is 999 variables, so 124 rows per statement.
        // (Batch-upsert Performance Fix.)
        let chunkSize = 124
        for chunkStart in stride(from: 0, to: bars.count, by: chunkSize) {
            let end = min(chunkStart + chunkSize, bars.count)
            let chunk = bars[chunkStart..<end]
            var valueClauses: [String] = []
            var args: [DatabaseValueConvertible] = []
            for b in chunk {
                valueClauses.append("(?, ?, ?, ?, ?, ?, ?, ?)")
                args.append(contentsOf: [
                    b.pairID, b.timeframe, Self.iso.string(from: b.bucketStart),
                    b.open, b.high, b.low, b.close, b.volume as DatabaseValueConvertible,
                ])
            }
            try db.execute(
                sql: """
                INSERT INTO ohlc
                    (pair_id, timeframe, bucket_start, open, high, low, close, volume)
                VALUES \(valueClauses.joined(separator: ", "))
                ON CONFLICT(pair_id, timeframe, bucket_start) DO UPDATE SET
                    open = excluded.open,
                    high = excluded.high,
                    low  = excluded.low,
                    close = excluded.close,
                    volume = excluded.volume
                """,
                arguments: StatementArguments(args)
            )
        }
    }

    private static func _latestBucket(pairID: String, timeframe: String, _ db: Database) throws -> Date? {
        let raw = try String.fetchOne(
            db,
            sql: """
            SELECT bucket_start FROM ohlc
            WHERE pair_id = ? AND timeframe = ?
            ORDER BY bucket_start DESC LIMIT 1
            """,
            arguments: [pairID, timeframe]
        )
        guard let raw = raw else { return nil }
        return Self.iso.date(from: raw)
    }

    private static func _earliestBucket(pairID: String, timeframe: String, _ db: Database) throws -> Date? {
        let raw = try String.fetchOne(
            db,
            sql: """
            SELECT bucket_start FROM ohlc
            WHERE pair_id = ? AND timeframe = ?
            ORDER BY bucket_start ASC LIMIT 1
            """,
            arguments: [pairID, timeframe]
        )
        guard let raw = raw else { return nil }
        return Self.iso.date(from: raw)
    }

    private static func _read(pairID: String, timeframe: String, since: Date, until: Date,
                              dropClosedDays: Bool, _ db: Database) throws -> [OHLCBar] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT bucket_start, open, high, low, close, volume
            FROM ohlc
            WHERE pair_id = ? AND timeframe = ?
              AND bucket_start >= ? AND bucket_start <= ?
            ORDER BY bucket_start ASC
            """,
            arguments: [
                pairID,
                timeframe,
                Self.iso.string(from: since),
                Self.iso.string(from: until),
            ]
        )
        return rows.compactMap { row -> OHLCBar? in
            guard let rawTS: String = row["bucket_start"],
                  let date = Self.iso.date(from: rawTS) else { return nil }
            if dropClosedDays && MarketCalendar.isClosedDay(date) { return nil }
            return OHLCBar(
                pairID: pairID,
                timeframe: timeframe,
                bucketStart: date,
                open:  row["open"]  ?? 0,
                high:  row["high"]  ?? 0,
                low:   row["low"]   ?? 0,
                close: row["close"] ?? 0,
                volume: row["volume"]
            )
        }
    }

    private static func _deleteClosedDayBars(pairID: String, _ db: Database) throws -> Int {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, bucket_start FROM ohlc WHERE pair_id = ?",
            arguments: [pairID]
        )
        var ids: [Int64] = []
        for row in rows {
            guard let raw: String = row["bucket_start"],
                  let date = Self.iso.date(from: raw),
                  let id: Int64 = row["id"] else { continue }
            if MarketCalendar.isClosedDay(date) {
                ids.append(id)
            }
        }
        guard !ids.isEmpty else { return 0 }
        // Batch the deletes in chunks so we don't blow past SQLite's
        // variable-binding limit (999 by default) on very large imports.
        let chunkSize = 500
        for chunk in stride(from: 0, to: ids.count, by: chunkSize) {
            let slice = Array(ids[chunk..<min(chunk + chunkSize, ids.count)])
            let placeholders = slice.map { _ in "?" }.joined(separator: ",")
            try db.execute(
                sql: "DELETE FROM ohlc WHERE id IN (\(placeholders))",
                arguments: StatementArguments(slice)
            )
        }
        return ids.count
    }

    private static func _deleteAll(pairID: String, _ db: Database) throws {
        try db.execute(sql: "DELETE FROM ohlc WHERE pair_id = ?", arguments: [pairID])
    }

    private static func _count(pairID: String, timeframe: String, _ db: Database) throws -> Int {
        try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM ohlc WHERE pair_id = ? AND timeframe = ?",
            arguments: [pairID, timeframe]
        ) ?? 0
    }

    // ── Date encoding ─────────────────────────────────────────────────
    //
    // ISO-8601 with no fractional seconds. Yahoo bars land on minute
    // boundaries, so this format is lossless. Critical that read + write
    // use the *same* formatter — otherwise the UNIQUE index dedupes nothing.
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
