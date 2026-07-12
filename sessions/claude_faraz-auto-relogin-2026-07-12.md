# Session: claude / faraz-auto-relogin-2026-07-12
Date: 2026-07-12
Project: HelixTradingApp (macOS + iPad/iPhone)

## Summary
Implemented automatic Faraz re-login: when a Faraz API call returns HTTP
401, the app now opens an in-app browser (WKWebView) pointed at faraz.io,
lets the user log in, captures the resulting session cookies, and saves
them so the feed resumes — on both the macOS app and the iPad/iPhone app.
Also added a manual "Log in to Faraz…" button in both Settings screens.
Verified builds on macOS + iPhone 17 sim; smoke-tested the login sheet on
the iPhone sim (WKWebView loads faraz.io, capture button gated on cookie
presence).

## Changes Made
- `GoldMonitorMac/Fetching/FarazAuthCoordinator.swift`: new @MainActor
  singleton. `reportUnauthorized()` (nonisolated, 30s cooldown) flips
  `isPresentingLogin`; `completeLogin(cookieHeader:)` persists via
  `DataSourceConfig.setFarazCookie`; `presentLoginManually()` for Settings.
- `GoldMonitorMac/Fetching/FarazLoginWebView.swift`: new. `FarazWebController`
  (reads faraz-domain cookies from the WKWebView's httpCookieStore, joins to
  a `name=value; …` header), cross-platform `FarazWebViewRepresentable`
  (#if os(macOS) NSViewRepresentable / #if os(iOS) UIViewRepresentable),
  and `FarazLoginSheet` (header + Use-this-session button + nav strip + web).
- `GoldMonitorMac/Fetching/FarazHistorySource.swift`: on 401, call
  `FarazAuthCoordinator.shared.reportUnauthorized()` before throwing.
- `GoldMonitorMac/App/DataSourceConfig.swift`: `setFarazCookie(_:)` (sets +
  saves; no-op if unchanged).
- `GoldMonitorMac/Scheduling/YahooScheduler.swift`: observe
  `$farazCookie` (dropFirst/removeDuplicates) → `reloadFarazAfterAuth`
  (restart WS + backfill faraz pairs + bump dataResetToken) while Faraz is
  active; cancel the subscription in `stop()`.
- `GoldMonitorMac/Features/RootView.swift` (macOS) and
  `ipadapp/.../RootViewiPad.swift`: present `FarazLoginSheet` via
  `@ObservedObject FarazAuthCoordinator.shared`.
- `GoldMonitorMac/Features/Settings/DataSourcesCard.swift` +
  `ipadapp/.../Settings/SettingsViewiPad.swift`: "Log in to Faraz…" button.

## Decisions & Reasoning
- Detect 401 at the HTTP history path (reliable status code) rather than
  the WS upgrade (opaque failure). The WS restarts once the cookie updates.
- Capture ALL faraz-domain cookies and join them — matches exactly what
  `FarazHistorySource` sends on the `Cookie` header; no guessing the auth
  cookie name.
- Cookie change restarts the WS + backfills but does NOT wipe stored bars
  (source unchanged, only the credential) — distinct from switchGoldSource.
- 30s reprompt cooldown so a burst of 401s (many pairs × timeframes) only
  opens one sheet.
- Shared files live in `GoldMonitorMac/` so both targets compile them;
  platform split via `#if os(...)`.

## Verified
- `xcodebuild` green: macOS + iPhone 17 (26.5).
- iPhone sim smoke test: login sheet renders, WKWebView loads faraz.io,
  "Use this session" disabled until faraz cookies exist. (Temp auto-present
  used for the screenshot, then reverted.)

## Unfinished / Next Steps
- Could auto-detect the specific auth cookie to enable one-tap capture
  without the explicit "Use this session" tap.
- These changes currently sit on branch `redesign/ipad-iphone-adaptive`
  (same branch as the UI redesign) — not yet committed.
