# Session: scroll-wheel zoom on both axes (X + Y)

Date: 2026-07-21
Agent: kimi

## Summary

The chart's scroll-wheel zoom only scaled the X (time/bar-index) axis.
The user asked for the vertical wheel to zoom both directions — price
scale included. The wheel now scales X and Y together, anchored on the
cursor so the bar and the price under the pointer both stay put
(TradingView convention).

## Changes Made

- `GoldMonitorMac/Features/Dashboard/ScrollZoomCatcher.swift`
  - `ScrollZoomModifier` now takes a `yDomain` binding plus an
    `autoYDomain: (ClosedRange<Double>) -> ClosedRange<Double>?`
    closure (the chart's auto-fit price window for the pre-zoom X
    domain, used only while no manual Y scale is pinned).
  - New `applyYZoom` scales the price window by the same per-event
    clamped factor as X, anchoring on the cursor's Y fraction
    (`upperBound - yFraction * span`, since SwiftUI global Y grows
    downward and price grows upward). Span floored at
    `max(abs(center) * 1e-6, 1e-6)` so repeated zoom-ins can't collapse
    the axis to a zero-width sliver.
  - `View.scrollZoom` extension signature updated accordingly.
- `GoldMonitorMac/Features/Dashboard/DashboardView.swift` — single
  chart call site passes `$yDomain` and
  `ChartWindow.candleYDomain(candles:domain:)` as the auto-fit
  fallback; comment updated.
- `GoldMonitorMac/Features/Dashboard/ChartPaneView.swift` — grid-pane
  call site updated the same way.

## Decisions & Reasoning

- Reused the existing `yDomain` pinning mechanism (the same one the
  price-axis drag and double-click-to-auto-fit use), so scroll-zooming
  Y behaves identically: it stays pinned until the user double-clicks
  the price axis or hits the reset control — no new state, no new
  reset path.
- `ChartWindow.candleYDomain` (candles-only, 5% padding) as the
  auto-fit fallback matches the Reset control's framing semantics and
  avoids pulling indicator/overlay extremes into the first-scroll
  base.
- iPad unaffected: the modifier is AppKit-only and both call sites are
  macOS paths.

## Verification

- `xcodebuild -project HelixTradingApp.xcodeproj -scheme
  HelixTradingApp -configuration Debug -destination 'platform=macOS'
  build` → **BUILD SUCCEEDED**.

## Unfinished

- None. Feel/sensitivity (`zoomPerLine = 0.06`) is unchanged; tune if
  the combined-axis zoom feels too aggressive.
