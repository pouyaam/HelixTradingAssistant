import Foundation

/// Shared OHLC read + timeframe-folding logic. Originally lived as
/// private helpers on `DashboardView`; pulled out so the multi-chart
/// grid's independent panes (`ChartPaneView`) can load candles for
/// their own pair/timeframe the exact same way the primary chart does,
/// without duplicating the fold-fallback logic.
enum OHLCCandleLoader {
    /// The stored series a given display timeframe folds up from.
    /// 1m/5m/1h/1d are stored natively; 15m/30m/4h are folded from 5m/1h
    /// at read time (see `OHLCAggregator.fold`).
    static func sourceTimeframeTag(for tf: Timeframe) -> String {
        switch tf {
        case .m1:             return "1m"
        case .m5, .m15, .m30: return "5m"
        case .h1, .h4:        return "1h"
        case .d1:             return "1d"
        }
    }

    /// Reads the native source series for `tf` and folds it up if
    /// needed. Falls back to folding from 5m when a native 1h/1d series
    /// is missing (older DB from before they were ingested, or the
    /// bootstrap pull hasn't landed yet) so the chart never blanks out.
    static func load(
        repo: OHLCRepo,
        pairID: String,
        tf: Timeframe,
        since: Date,
        until: Date,
        dropClosedDays: Bool
    ) -> [Candle] {
        let sourceTF = sourceTimeframeTag(for: tf)
        let needsFold = sourceTF != tf.rawValue
        do {
            let bars = try repo.read(
                pairID: pairID,
                timeframe: sourceTF,
                since: since,
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
                    since: since, until: until, dropClosedDays: dropClosedDays
                )
                return OHLCAggregator.fold(bars: fallback, into: tf)
            }
            return []
        } catch {
            return []
        }
    }

    /// Async version — uses the async `repo.read()` so the SQLite
    /// work runs off the main thread. Call from `@MainActor` contexts
    /// via `await` to keep the UI responsive during large reads.
    /// (Data-fetching Performance Fix.)
    static func loadAsync(
        repo: OHLCRepo,
        pairID: String,
        tf: Timeframe,
        since: Date,
        until: Date,
        dropClosedDays: Bool
    ) async -> [Candle] {
        let sourceTF = sourceTimeframeTag(for: tf)
        let needsFold = sourceTF != tf.rawValue
        do {
            let bars = try await repo.read(
                pairID: pairID,
                timeframe: sourceTF,
                since: since,
                until: until,
                dropClosedDays: dropClosedDays
            )
            if !bars.isEmpty {
                return needsFold ? OHLCAggregator.fold(bars: bars, into: tf)
                                 : bars.map { $0.toCandle() }
            }
            if sourceTF == "1h" || sourceTF == "1d" {
                let fallback = try await repo.read(
                    pairID: pairID, timeframe: "5m",
                    since: since, until: until, dropClosedDays: dropClosedDays
                )
                return OHLCAggregator.fold(bars: fallback, into: tf)
            }
            return []
        } catch {
            return []
        }
    }
}
