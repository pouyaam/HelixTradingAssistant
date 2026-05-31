import Foundation
import Combine

/// Ephemeral controller for TradingView-style chart **Replay**.
///
/// Replay rewinds the chart to a chosen historical bar and lets the
/// user step forward one candle at a time (or auto-play), so AI
/// analysis can be back-tested against data as it looked at that
/// moment. The whole feature hinges on a single shared `cursor: Date`:
/// the dashboard loads candles up to the cursor instead of `Date()`,
/// and because every timeframe folds from the same base data, advancing
/// the cursor moves *all* timeframes consistently.
///
/// Deliberately NOT persisted — replay is always entered fresh; a stale
/// cursor surviving a relaunch would be baffling.
@MainActor
final class ReplayController: ObservableObject {
    /// Replay mode on/off. When on, the dashboard clips candle loads to
    /// `cursor` instead of the live `Date()`.
    @Published var isActive = false

    /// The "now" of the replay — bars at or before this instant are
    /// revealed; everything after is hidden. `nil` while active means
    /// the user hasn't anchored yet (the picking phase).
    @Published var cursor: Date?

    /// True between hitting Replay and clicking a start bar.
    @Published var isPickingAnchor = false

    /// Auto-play running.
    @Published var isPlaying = false

    /// Wall-clock seconds per revealed bar. Lower = faster playback.
    @Published var stepInterval: TimeInterval = 1.0

    /// Bumped by the auto-play timer. The dashboard observes this and
    /// advances the cursor by one bar per increment. A counter (rather
    /// than a closure on the controller) keeps the stepping logic —
    /// which needs the dashboard's bar timestamps and DB handle — in
    /// the view where it belongs, and sidesteps capturing a value-type
    /// View in a long-lived closure.
    @Published var tick = 0

    private var timer: Timer?

    /// Enter replay and begin the anchor-picking phase.
    func arm() {
        isActive = true
        isPickingAnchor = true
        cursor = nil
        isPlaying = false
    }

    /// Commit the clicked start bar (or date-jump) as the replay cursor.
    func setAnchor(_ date: Date) {
        cursor = date
        isPickingAnchor = false
    }

    /// Re-enter the picking phase without dropping the current cursor,
    /// so the user can jump the anchor to a new date mid-replay. Pauses
    /// playback so bars don't advance underneath the picker.
    func beginRepick() {
        pause()
        isPickingAnchor = true
    }

    /// Leave replay entirely and return to live data.
    func exit() {
        pause()
        isActive = false
        isPickingAnchor = false
        cursor = nil
    }

    func play() {
        guard isActive, cursor != nil else { return }
        isPlaying = true
        schedule()
    }

    func pause() {
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    func togglePlay() { isPlaying ? pause() : play() }

    /// Re-arm the timer at the current `stepInterval`. Called when the
    /// user changes speed while playback is running.
    func reschedule() {
        guard isPlaying else { return }
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] _ in
            // The timer fires on the main run loop; hop onto the main
            // actor for the @Published mutation.
            Task { @MainActor in self?.tick += 1 }
        }
    }

    deinit { timer?.invalidate() }
}
