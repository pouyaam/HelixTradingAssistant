import Foundation
import Combine

/// Coordinates the "Faraz session expired → log in again" flow.
///
/// When any Faraz request receives HTTP 401 (`FarazHistorySource` throwing
/// `.unauthorized`), it calls `reportUnauthorized()`. That flips
/// `isPresentingLogin`, which the app root (`RootView` on macOS,
/// `RootViewiPad` on iPad/iPhone) observes to present `FarazLoginSheet` —
/// an in-app WKWebView pointed at faraz.io. Once the user logs in and taps
/// "Use this session", the captured cookie header is persisted via
/// `DataSourceConfig.setFarazCookie(_:)` and the feed resumes.
///
/// Shared singleton (built into both the macOS and iPad/iPhone targets).
@MainActor
final class FarazAuthCoordinator: ObservableObject {
    static let shared = FarazAuthCoordinator()

    /// Drives the login sheet in the app root.
    @Published var isPresentingLogin = false

    /// Human-readable reason shown in the sheet header (why it opened).
    @Published private(set) var lastReason: String?

    /// A burst of 401s (many pairs × timeframes failing at once, or a
    /// tight polling loop) must only open the sheet once. Suppress
    /// re-prompts within this window after the last prompt.
    private var lastPromptAt: Date?
    private let repromptCooldown: TimeInterval = 30

    private init() {}

    /// Report an authentication failure from a Faraz request. Safe to call
    /// from any context — hops to the main actor.
    nonisolated func reportUnauthorized(
        reason: String = "Your Faraz session expired. Log in again to resume live data."
    ) {
        Task { @MainActor in
            FarazAuthCoordinator.shared.presentLoginIfNeeded(reason: reason)
        }
    }

    /// Open the login sheet unless it's already up or we prompted recently.
    func presentLoginIfNeeded(reason: String) {
        guard !isPresentingLogin else { return }
        if let last = lastPromptAt, Date().timeIntervalSince(last) < repromptCooldown {
            return
        }
        lastPromptAt = Date()
        lastReason = reason
        isPresentingLogin = true
    }

    /// Let the user open the login flow manually (e.g. a Settings button),
    /// bypassing the cooldown.
    func presentLoginManually() {
        lastPromptAt = Date()
        lastReason = nil
        isPresentingLogin = true
    }

    /// Persist a freshly captured cookie header and dismiss. Resetting
    /// `lastPromptAt` lets a subsequent genuine expiry re-prompt immediately.
    func completeLogin(cookieHeader: String) {
        let trimmed = cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        DataSourceConfig.shared.setFarazCookie(trimmed)
        isPresentingLogin = false
        lastReason = nil
        lastPromptAt = nil
    }

    /// Dismiss without capturing.
    func cancel() {
        isPresentingLogin = false
    }
}
