import SwiftUI

/// Tiny "Updated Ns ago · next in Ns" status chip. Pure presentation — the
/// caller hands in a last-fetch timestamp, an interval, and an in-flight
/// flag. Internally ticks once per second so the countdown advances even
/// when nothing else in the view is changing.
///
/// Designed to sit inline next to the refresh button in the dashboard
/// pair header.
struct FetchTimerView: View {
    let lastFetchAt: Date?
    let intervalSeconds: Int
    let isFetching: Bool

    /// Re-renders once per second. Initial value seeded with `Date()` so
    /// the chip shows a sensible "Xs ago" immediately on first appear.
    @State private var now: Date = Date()

    private var elapsed: Int {
        guard let last = lastFetchAt else { return 0 }
        return max(0, Int(now.timeIntervalSince(last)))
    }

    /// Seconds remaining until the next scheduled fetch. Clamped to ≥ 0 so
    /// a tick that runs slightly late doesn't show a negative number.
    private var remaining: Int {
        guard lastFetchAt != nil else { return intervalSeconds }
        return max(0, intervalSeconds - elapsed)
    }

    var body: some View {
        HStack(spacing: 6) {
            // Status dot — amber while fetching, green when idle, grey
            // before the very first fetch lands.
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
                .overlay(Circle().strokeBorder(Theme.Color.surface, lineWidth: 0.5))

            Text(labelText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.Color.textMuted)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(Theme.Color.surface)
                .overlay(Capsule().strokeBorder(Theme.Color.border, lineWidth: 0.5))
        )
        // Auto-tick every second. `.common` keeps it firing during scrolling.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { t in
            now = t
        }
    }

    private var dotColor: Color {
        if isFetching { return Theme.Color.warn }
        if lastFetchAt == nil { return Theme.Color.textMuted }
        return Theme.Color.success
    }

    private var labelText: String {
        if lastFetchAt == nil {
            return isFetching ? "Fetching…" : "Waiting…"
        }
        if isFetching {
            return "Fetching… · last \(elapsed)s ago"
        }
        return "Updated \(elapsed)s ago · next in \(remaining)s"
    }
}
