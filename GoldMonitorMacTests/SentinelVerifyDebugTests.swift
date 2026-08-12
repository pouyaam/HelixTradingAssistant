import Foundation
import XCTest
@testable import HelixTradingApp

/// TEMPORARY verification for the simplified sentinel detection
/// (VROB + CHoCH + mandatory HTF). Runs the real pipeline against the
/// user's real stored candles and prints the alerts it yields.
final class SentinelVerifyDebugTests: XCTestCase {

    @MainActor
    func testSimplifiedPipelineYieldsAlerts() async throws {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/HelixTrading/gold.db")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("no local database")
        }
        let db = try AppDatabase(url: url)

        let outURL = URL(fileURLWithPath: "/tmp/sentinel_verify.txt")
        try? "".write(to: outURL, atomically: true, encoding: .utf8)
        func emit(_ line: String) {
            let data = (line + "\n").data(using: .utf8)!
            if let h = try? FileHandle(forWritingTo: outURL) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            }
        }

        let series: [(pairID: String, symbol: String, tf: Timeframe, dropWeekends: Bool)] = [
            ("ounce", "XAU/USD", .m15, true),
            ("ounce", "XAU/USD", .h1, true),
            ("btc", "BTC/USD", .h1, false),
        ]

        let sentinel = StrategySentinel.shared
        for s in series {
            let until = Date()
            let since = until.addingTimeInterval(-900 * s.tf.seconds)
            let candles = await OHLCCandleLoader.loadAsync(
                repo: db.ohlcRepo, pairID: s.pairID, tf: s.tf,
                since: since, until: until, dropClosedDays: s.dropWeekends
            )
            guard candles.count > 61 else { emit("DBG [\(s.pairID)|\(s.tf.rawValue)] loaded=\(candles.count) — skip"); continue }

            // Raw detector inventory: how many CHoCH events / VROB zones
            // does this series even have right now?
            let closed = Array(candles.dropLast())
            let atrVal = SMCEvidence.wilderATR(closed, period: 14) ?? 1.0

            let higher = s.tf.higher
            let htfName = higher?.rawValue ?? "—"
            let htfCandles = higher.map {
                StrategySentinel.aggregateCandles(closed, into: $0)
            } ?? []
            var htfCfg = VolumeRankedOrderBlocks.Config()
            htfCfg.swingLength = 3
            htfCfg.zonesPerSide = 8
            htfCfg.showBreakers = false
            let htfZones = VolumeRankedOrderBlocks.compute(htfCandles, config: htfCfg).filter { !$0.isBreaker }
            emit("DBG [\(s.pairID)|\(s.tf.rawValue)] htf=\(htfName) bars=\(htfCandles.count) atr=\(String(format: "%.2f", atrVal))")
            for z in htfZones {
                emit("    htf \(z.isBullish ? "BULL" : "BEAR") grade=\(z.grade.rawValue) [\(String(format: "%.1f", z.bottom))-\(String(format: "%.1f", z.top))]")
            }

            let choch = ChangeOfCharacter.compute(closed, swingLength: 5, minSwingPct: 0.2, requireFVG: false, showMitigated: true, maxZones: 20)
            var cfg = VolumeRankedOrderBlocks.Config()
            cfg.swingLength = s.tf.rawValue.contains("1m") || s.tf.rawValue.contains("5m") ? 5 : 10
            cfg.zonesPerSide = 8
            cfg.showBreakers = false
            let vrob = VolumeRankedOrderBlocks.compute(closed, config: cfg).filter { !$0.isBreaker }

            for cz in choch.sorted(by: { $0.chochIndex > $1.chochIndex }).prefix(8) {
                let match = vrob.filter { z in
                    z.isBullish == cz.isBullish &&
                    z.startIndex <= cz.chochIndex &&
                    z.bottom <= cz.obHigh + 0.5 * atrVal &&
                    z.top >= cz.obLow - 0.5 * atrVal
                }.min { a, b in
                    let ga = a.grade.rawValue == "A" ? 1 : (a.grade.rawValue == "B" ? 2 : 3)
                    let gb = b.grade.rawValue == "A" ? 1 : (b.grade.rawValue == "B" ? 2 : 3)
                    if ga != gb { return ga < gb }
                    return abs(a.startIndex - cz.chochIndex) < abs(b.startIndex - cz.chochIndex)
                }
                var line = "    gate \(cz.isBullish ? "BULL" : "BEAR")@\(cz.chochIndex) ob=[\(String(format: "%.1f", cz.obLow))-\(String(format: "%.1f", cz.obHigh))]"
                if let z = match {
                    let isNested = htfZones.contains(where: { h in
                        h.isBullish == z.isBullish && z.bottom <= h.top + 0.25 * atrVal && z.top >= h.bottom - 0.25 * atrVal
                    })
                    line += " -> vrob[\(String(format: "%.1f", z.bottom))-\(String(format: "%.1f", z.top))] grade=\(z.grade.rawValue) nested=\(isNested)"
                } else {
                    line += " -> no vrob match"
                }
                emit(line)
            }
            emit("DBG [\(s.pairID)|\(s.tf.rawValue)] lastClose=\(String(format: "%.2f", closed.last!.close))")

            let key = "\(s.pairID)|\(s.tf.rawValue)"
            let before = sentinel.lastScanTimestamp
            sentinel.evaluateSymbol(
                pairID: s.pairID, symbol: s.symbol, timeframe: s.tf.rawValue,
                candles: candles, htfCandles: htfCandles, htfLabel: htfName
            )

            // Pipeline runs detached — poll until this key (re)publishes.
            for _ in 0..<100 {
                try await Task.sleep(nanoseconds: 100_000_000)
                if sentinel.lastScanTimestamp != before { break }
            }
            let alerts = sentinel.activeRadarAlerts.filter { "\($0.pairID)|\($0.timeframe)" == key }
            emit("DBG [\(key)] loaded=\(candles.count) alerts=\(alerts.count)")
            for a in alerts.prefix(5) {
                emit("    score=\(a.confluenceScore) \(a.direction.rawValue) \(a.status.rawValue) entry=\(a.entryPrice) :: \(a.rationale)")
            }
        }
    }

}

