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

    /// Idempotent batch insert. Uses SQLite's `ON CONFLICT ... DO UPDATE`
    /// so re-running gap-fill doesn't pile up duplicates and a corrected
    /// bar (e.g. a closing tick) overwrites the stale one.
    func upsertMany(_ bars: [OHLCBar]) throws {
        guard !bars.isEmpty else { return }
        try pool.write { db in
            for b in bars {
                try db.execute(
                    sql: """
                    INSERT INTO ohlc
                        (pair_id, timeframe, bucket_start, open, high, low, close, volume)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(pair_id, timeframe, bucket_start) DO UPDATE SET
                        open = excluded.open,
                        high = excluded.high,
                        low  = excluded.low,
                        close = excluded.close,
                        volume = excluded.volume
                    """,
                    arguments: [
                        b.pairID,
                        b.timeframe,
                        Self.iso.string(from: b.bucketStart),
                        b.open, b.high, b.low, b.close,
                        b.volume,
                    ]
                )
            }
        }
    }

    /// Latest `bucket_start` for the given pair+timeframe, or nil if the
    /// table is empty for that key. Used by the gap-fill logic to decide
    /// what range to fetch from Yahoo.
    func latestBucket(pairID: String, timeframe: String) throws -> Date? {
        try pool.read { db in
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
    }

    /// One-shot cleanup: remove every weekend bar for the given pair.
    /// SQLite has no native weekday function, so we decode each row's
    /// timestamp in Swift and `DELETE` by id. Linear over `ohlc` rows
    /// for `pairID`, but this only runs once per launch and the table
    /// stays bounded (~10k rows for ounce after a month at 5m bars).
    /// Returns the number of rows actually deleted.
    @discardableResult
    func deleteClosedDayBars(pairID: String) throws -> Int {
        try pool.write { db in
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
            // variable-binding limit (999 by default) on very large
            // imports.
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
    }

    /// Number of rows for a (pair, timeframe). Used by smoke tests + the
    /// import screen to confirm bootstrap landed data.
    func count(pairID: String, timeframe: String) throws -> Int {
        try pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM ohlc WHERE pair_id = ? AND timeframe = ?",
                arguments: [pairID, timeframe]
            ) ?? 0
        }
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
