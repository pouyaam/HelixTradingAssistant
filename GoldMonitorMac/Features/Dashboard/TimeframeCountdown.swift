import SwiftUI

/// Counts down to the next candle close for the active timeframe.
/// Sits next to the chart's subtitle so the user can tell at a glance
/// when a fresh bar will print — useful for entries that key off close.
///
/// Bucket math matches `CandleAggregator.aggregate`: every bar boundary
/// is at a `seconds-since-epoch` value divisible by `timeframe.seconds`.
/// The next close = floor(now / bucketSize) * bucketSize + bucketSize.
struct TimeframeCountdown: View {
    let timeframe: Timeframe

    /// Refreshed once per second. Initialised with `Date()` so the
    /// first render already shows a meaningful value rather than 0.
    @State private var now: Date = Date()

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "hourglass")
                .font(.system(size: 9, weight: .semibold))
            Text("\(timeframe.label) closes in \(remainingText)")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(Theme.Color.textSecondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(Theme.Color.surface)
        )
        // `.common` keeps the tick firing during scrolls / drags — we
        // don't want the countdown to freeze while the user is panning
        // the chart.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { t in
            now = t
        }
    }

    // ── Math ──────────────────────────────────────────────────────────

    /// Seconds until the next candle boundary. Clamped to ≥ 0 so a
    /// tick that lands a hair past the boundary doesn't briefly show a
    /// negative number before the new bucket starts.
    private var remainingSeconds: Int {
        let bucketSize = timeframe.seconds
        guard bucketSize > 0 else { return 0 }
        let nowSecs = now.timeIntervalSince1970
        let bucketStart = floor(nowSecs / bucketSize) * bucketSize
        let nextClose = bucketStart + bucketSize
        return max(0, Int(nextClose - nowSecs))
    }

    /// "23m 14s" / "1h 04m 12s" / "12s" — compact, drops empty leading
    /// units so short-TF countdowns don't show useless `0h 0m 23s`.
    private var remainingText: String {
        let total = remainingSeconds
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%dh %02dm %02ds", h, m, s)
        } else if m > 0 {
            return String(format: "%dm %02ds", m, s)
        } else {
            return String(format: "%ds", s)
        }
    }
}
