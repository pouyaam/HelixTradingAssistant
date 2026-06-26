import Foundation
import SwiftUI

/// Trading Sessions overlay — shades each major session (Tokyo, London,
/// New York) with its high-low box, open/close/average lines, and a
/// summary label, resetting once per local trading day.
///
/// Ported from TradingView's built-in "Trading Sessions" Pine v6 study.
/// The Pine walks bars while `time("", session, tz)` reports in-session,
/// growing a box (session high/low), dashed open & close lines, and a
/// dotted average line, then starts a fresh box when a new day begins or
/// the session ends. We reproduce that per-run aggregation here as a
/// pure function over the candle series; `ChartView` maps each
/// `SessionRun` into a `RectangleMark` + `RuleMark`s, mirroring how the
/// Order Block / FVG overlays render.
///
/// Because the chart's X axis is bar-index based (not wall-clock — so
/// weekend/overnight gaps don't open holes), each run carries the integer
/// `start`/`end` bar indices of its first/last in-session bar; no
/// date→index lookup is needed at render time.
///
/// Scope note: the Pine lets the user edit each session's name, time,
/// timezone, and colour. We bake the three canonical presets (regular
/// cash hours, matching the Pine defaults) and let the user toggle each
/// on/off — consistent with how the rest of the app's indicators expose
/// only scalar knobs. Adding fully custom sessions later just means
/// growing `catalog` (and a config-driven editor).
enum TradingSessions {

    /// A session definition: a daily local-clock window in a given time
    /// zone, with a display name and hue.
    struct SessionDef: Identifiable, Hashable {
        let id: String
        let name: String
        /// "HHMM-HHMM" window in `timezone`'s local clock. A trailing
        /// Pine day-mask (":1234567") is tolerated and ignored.
        let session: String
        /// IANA tz id (e.g. "Asia/Tokyo") the window is expressed in.
        let timezone: String
        /// Base hue; the box fills at low opacity, the lines at full.
        let color: Color
    }

    /// The canonical three sessions, matching the Pine source's defaults:
    /// regular cash-session hours in each venue's own time zone. DST is
    /// handled automatically (see `localDayAndMinute`). Colours mirror the
    /// Pine's blue / orange / green.
    static let catalog: [SessionDef] = [
        SessionDef(id: "tokyo",   name: "Tokyo",    session: "0900-1500", timezone: "Asia/Tokyo",
                   color: Color(red: 0.16, green: 0.38, blue: 1.00)),
        SessionDef(id: "london",  name: "London",   session: "0830-1630", timezone: "Europe/London",
                   color: Color(red: 1.00, green: 0.60, blue: 0.00)),
        SessionDef(id: "newYork", name: "New York", session: "0930-1600", timezone: "America/New_York",
                   color: Color(red: 0.03, green: 0.60, blue: 0.51)),
    ]

    /// One rendered session instance: a single local day's worth of one
    /// session, aggregated across the bars that fell inside its window.
    struct SessionRun: Identifiable, Hashable {
        let sessionID: String
        let name: String
        let color: Color
        /// Bar indices (into the input series) of the first & last
        /// in-session bar. The box spans `start...end`.
        let start: Int
        let end: Int
        let high: Double
        let low: Double
        /// Open of the first in-session bar; close of the last.
        let open: Double
        let close: Double
        /// Mean close across the run's bars (Pine's dotted avg line).
        let average: Double

        /// Session range — `high - low`. The Pine shows this divided by
        /// the symbol's mintick; we show it in price terms (the app spans
        /// pairs with very different ticks, so a price delta reads cleaner).
        var range: Double { high - low }
        var id: String { "\(sessionID)-\(start)" }
    }

    /// Aggregate `candles` into session runs for every def in `defs`,
    /// returned in bar order (interleaved across sessions).
    ///
    /// Empty on daily-or-coarser data: sessions are an intraday concept
    /// (the Pine `runtime.error`s on `timeframe.isdwm`). ChartView is
    /// timeframe-agnostic, so we infer that from the median bar spacing
    /// instead of being told the `Timeframe`.
    static func compute(_ candles: [Candle], defs: [SessionDef] = catalog) -> [SessionRun] {
        guard candles.count >= 2, !defs.isEmpty else { return [] }
        // Intraday guard: once bars are ~a day apart or coarser, a session
        // window collapses to a single bar and the overlay is meaningless.
        guard medianSpacingSeconds(candles) < 20 * 3600 else { return [] }

        var out: [SessionRun] = []
        for def in defs {
            appendRuns(for: def, candles: candles, into: &out)
        }
        return out
    }

    // MARK: - Per-session walk

    /// Grow boxes for one session across the whole series. Mirrors the
    /// Pine `update()` state machine: in-session bars extend the current
    /// box; a new local day (Pine's `timeframe.change("1D")`) or leaving
    /// the window closes it so the next in-session bar opens a fresh one.
    private static func appendRuns(for def: SessionDef, candles: [Candle], into out: inout [SessionRun]) {
        guard let window = parseWindow(def.session) else { return }
        let tz = TimeZone(identifier: def.timezone) ?? TimeZone(secondsFromGMT: 0)!

        // Accumulator for the run currently being grown. `startIdx < 0`
        // means "no open run".
        var startIdx = -1
        var endIdx = -1
        var dayKey = Int.min
        var hi = 0.0, lo = 0.0, openP = 0.0, closeP = 0.0, sumClose = 0.0
        var nBars = 0

        func flush() {
            guard startIdx >= 0, nBars > 0 else { return }
            out.append(SessionRun(
                sessionID: def.id, name: def.name, color: def.color,
                start: startIdx, end: endIdx,
                high: hi, low: lo, open: openP, close: closeP,
                average: sumClose / Double(nBars)
            ))
        }

        for (i, c) in candles.enumerated() {
            let (day, minute) = localDayAndMinute(c.id, tz: tz)
            if window.contains(minute) {
                // Open a new box when nothing is growing or the local day
                // rolled over (a new session starts each trading day).
                if startIdx < 0 || day != dayKey {
                    flush()
                    startIdx = i; endIdx = i; dayKey = day
                    hi = c.high; lo = c.low; openP = c.open; closeP = c.close
                    sumClose = c.close; nBars = 1
                } else {
                    endIdx = i
                    hi = Swift.max(hi, c.high)
                    lo = Swift.min(lo, c.low)
                    closeP = c.close
                    sumClose += c.close; nBars += 1
                }
            } else if startIdx >= 0 {
                // Left the window — finalise the box; the next in-session
                // bar will open a new one.
                flush()
                startIdx = -1; nBars = 0
            }
        }
        flush()
    }

    // MARK: - Time helpers

    /// Minute-of-day in-session test, derived from "HHMM-HHMM". Handles
    /// overnight windows where the start minute is after the end minute
    /// (e.g. "2200-0500").
    private struct MinuteWindow {
        let start: Int   // 0...1439
        let end: Int
        func contains(_ m: Int) -> Bool {
            // End is exclusive, matching Pine: a bar stamped exactly at
            // the close minute belongs to the next period, not this one.
            start <= end ? (m >= start && m < end) : (m >= start || m < end)
        }
    }

    private static func parseWindow(_ raw: String) -> MinuteWindow? {
        // Drop any trailing day mask ("0930-1600:23456" → "0930-1600").
        let timePart = raw.split(separator: ":").first.map(String.init) ?? raw
        let halves = timePart.split(separator: "-")
        guard halves.count == 2,
              let s = minutes(of: halves[0]),
              let e = minutes(of: halves[1]) else { return nil }
        return MinuteWindow(start: s, end: e)
    }

    private static func minutes(of hhmm: Substring) -> Int? {
        guard hhmm.count == 4, let v = Int(hhmm) else { return nil }
        let h = v / 100, m = v % 100
        guard (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    /// Local day index (days since the Unix epoch) and minute-of-day for
    /// `date` in `tz`. Uses the instant's true UTC offset so daylight-
    /// saving shifts are respected, without a `Calendar` round-trip per
    /// bar (this runs across the full history).
    private static func localDayAndMinute(_ date: Date, tz: TimeZone) -> (day: Int, minute: Int) {
        let local = date.timeIntervalSince1970 + Double(tz.secondsFromGMT(for: date))
        let day = Int((local / 86_400).rounded(.down))
        let minute = Int((local - Double(day) * 86_400) / 60)
        return (day, Swift.min(1439, Swift.max(0, minute)))
    }

    /// Median gap between consecutive bars, in seconds. Sampled from the
    /// tail (not a full sort of the series) so the intraday guard stays
    /// cheap on deep history.
    private static func medianSpacingSeconds(_ candles: [Candle]) -> TimeInterval {
        let n = candles.count
        let sampleCount = Swift.min(20, n - 1)
        guard sampleCount > 0 else { return .greatestFiniteMagnitude }
        var deltas: [TimeInterval] = []
        deltas.reserveCapacity(sampleCount)
        for k in 0..<sampleCount {
            let i = n - 1 - k
            deltas.append(candles[i].id.timeIntervalSince1970 - candles[i - 1].id.timeIntervalSince1970)
        }
        deltas.sort()
        return deltas[deltas.count / 2]
    }
}
