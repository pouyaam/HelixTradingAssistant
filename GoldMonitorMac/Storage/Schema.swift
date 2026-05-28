import Foundation
import GRDB

/// SQLite schema for HelixTradingApp. The open-source build only
/// keeps the OHLC candle table — Iran-specific snapshot tables were
/// removed when that data pipeline was stripped. Existing databases
/// that still carry a `snapshots` table just leave it sitting there
/// untouched; nothing in the app reads from it anymore.
enum Schema {
    static let version = 2

    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1_ohlc") { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS ohlc (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                pair_id TEXT NOT NULL,
                timeframe TEXT NOT NULL,
                bucket_start TEXT NOT NULL,
                open REAL NOT NULL,
                high REAL NOT NULL,
                low REAL NOT NULL,
                close REAL NOT NULL,
                volume REAL,
                UNIQUE(pair_id, timeframe, bucket_start)
            );

            CREATE INDEX IF NOT EXISTS idx_ohlc_pair_tf_start
                ON ohlc(pair_id, timeframe, bucket_start DESC);
            """)
        }
    }
}
