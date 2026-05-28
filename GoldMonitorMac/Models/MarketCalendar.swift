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

    /// True if `date` falls on Saturday or Sunday in exchange-local time.
    /// COMEX is closed all of Saturday and most of Sunday — we treat the
    /// whole calendar weekend as closed since Yahoo doesn't return data
    /// for those hours anyway.
    static func isClosedDay(_ date: Date) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = exchangeTimezone
        // Calendar weekday is 1-indexed: 1 = Sunday … 7 = Saturday.
        let wd = cal.component(.weekday, from: date)
        return wd == 1 || wd == 7
    }
}
