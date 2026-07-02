import Foundation

/// Trading-calendar helpers. Only used by the gold ounce pipeline today;
/// the Iranian Toman pairs trade on different schedules and aren't gated
/// through here.
enum MarketCalendar {
    /// COMEX (where GC=F trades) is on Eastern Time. We check the weekday
    /// in that timezone so a Friday-night bar in UTC still counts as a
    /// trading day, and a Sunday-evening bar (when COMEX reopens) isn't
    /// accidentally flagged as closed in some other zone.
    static let exchangeTimezone = TimeZone(identifier: "America/New_York")
        ?? TimeZone(secondsFromGMT: -5 * 3600)!

    /// True if `date` falls in a period COMEX is actually closed.
    ///
    /// COMEX gold futures trade Sunday 6:00 pm ET through Friday 5:00 pm ET
    /// with a daily 5pm→6pm maintenance break.  The rule:
    ///   • Saturday — always closed (full day).
    ///   • Sunday   — closed BEFORE 18:00 ET; open from 18:00 ET onward.
    ///   • Monday–Friday — open (the daily 5pm–6pm gap is short enough that
    ///     we do not filter it here; it produces at most one stale bar).
    ///
    /// Previously the entire Sunday was treated as closed, which caused
    /// Sunday-evening COMEX bars (valid trading bars that happen to fall on
    /// a Sunday in ET) to be silently dropped for users in timezones ahead
    /// of ET (e.g. Tehran UTC+4:30, where COMEX's Sunday 6 pm ET reopening
    /// is 2:30 am Monday local time).
    static func isClosedDay(_ date: Date) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = exchangeTimezone
        // Calendar weekday is 1-indexed: 1 = Sunday … 7 = Saturday.
        let wd = cal.component(.weekday, from: date)
        if wd == 7 { return true }   // Saturday: always closed
        if wd == 1 {
            // Sunday: closed before 18:00 ET, open from 18:00 ET (COMEX reopens).
            let hour = cal.component(.hour, from: date)
            return hour < 18
        }
        return false
    }
}
