# Sentinel Radar → right-edge chart drawer (2026-07-27)

## Summary

The Strategy Sentinel's presentation was reworked per user feedback: the
on-chart highlights (entry/TP/SL RuleMarks + shaded zones + rank badges)
and the horizontal HUD row above the chart are gone. In their place is a
collapsible drawer pinned to the chart's right edge: a thin always-visible
rail that expands into a panel listing the sentinel's ranked setups.
Rows can be filtered by direction (LONG/SHORT), HTF nesting, and traded
volume (same dynamic percentile thresholds as before), and are sorted by
entry-price distance from the live price — nearest first.

## Changes Made

- `GoldMonitorMac/Features/Dashboard/ChartView.swift`
  - Deleted `sentinelRadarMarks` (ChartContent builder) and its insertion
    into the mark stack.
  - Removed the now-unused `showSentinelRadar` and `currentPairID` params
    (they existed only for the sentinel overlay; they were never in the
    `Equatable` gate, so `==` is untouched).
- `GoldMonitorMac/UI/SentinelRadarDrawer.swift` (new; replaces
  `GoldMonitorMac/UI/StrategyRadarHUDView.swift`, deleted)
  - `SentinelRadarDrawer`: right-edge rail (`SENTINEL` vertical label +
    alert-count badge + chevron, `@AppStorage("dashboard.sentinelDrawerExpanded")`,
    default collapsed) + 250px expanded panel.
  - Panel: direction chips (ALL/LONG/SHORT), ⚡ HTF toggle, volume-threshold
    Menu (dynamic p25/p50/p75 thresholds, same logic as the old HUD),
    ScrollView of setup rows sorted nearest-first by `|entry − livePrice|`
    (falls back to confluence score when no live price).
  - Row: rank medal, direction + HTF badges, entry price, Δ distance to
    live price, R:R, engine label, traded volume, info popover
    (`AlertDetailView`, kept verbatim) and a stage button that reuses
    `DashboardView.handleRadarAlertSelection` (opens the trade box).
  - `.menuStyle(.borderlessButton)` is `#if os(macOS)`-guarded — the file
    compiles into the iPad target too (it's under `GoldMonitorMac/UI/`,
    not excluded in `project.yml`).
  - Dropped `SentinelGuideView` (its sample-card legend described the old
    HUD layout). The hover-preview scenario was briefly dropped too, then
    restored per follow-up: hovering a drawer row shows that setup's
    entry/TP/SL on the chart via the existing `taScenario` overlay
    (`onHoverAlert` → `DashboardView.hoverRadarScenario`).
- `GoldMonitorMac/Features/Dashboard/DashboardView.swift`
  - Removed the `StrategyRadarHUDView` row above the chart card.
  - Removed `hoverRadarScenario` @State and the
    `showSentinelRadar` @AppStorage (key `dashboard.showSentinelRadar`
    abandoned; no UI toggled it).
  - Added `SentinelRadarDrawer` as `.overlay(alignment: .trailing)` on the
    chart overlay chain in `chartCardContent`.
- Regenerated `HelixTradingApp.xcodeproj` with `xcodegen generate` (stale
  file reference to the deleted HUD file broke the first build).

### Drive-by fixes (pre-existing iPad-target breakage, blocking verification)

The iPad target hadn't compiled since earlier Mac-only commits; fixed the
three blockers found while verifying the shared drawer file builds on iOS:

- `project.yml`: added `CommandPaletteView.swift` (imports AppKit, added in
  3118bbf; its only consumer `RootView` is already iPad-excluded) to the
  iPad target's `excludes`.
- `GoldMonitorMac/Features/Dashboard/OscillatorPanel.swift`: guarded the
  `.scrollZoom(...)` call with `#if os(macOS)` — `scrollZoom` lives in the
  iPad-excluded, AppKit-based `ScrollZoomCatcher.swift`.
- `ipadapp/HelixTradingApp-iPad/Features/Dashboard/ChartViewiPad.swift`:
  added the missing `volumeRankedOBZones: []` argument to the
  `ChartDerivedCache.OverlayData` init (shared struct gained the field in
  the Mac Volume-Ranked OB merge; not wired on iPad, same pattern as the
  existing Ichimoku `[]` placeholders).
- `ipadapp/HelixTradingApp-iPad/Features/Dashboard/DashboardViewiPad.swift`:
  updated the `OscillatorPanel` call site for the shared panel's new
  signature — `xDomain` is now a `@Binding` and `hoverCrosshairX` is
  required; added a local `hoverCrosshairX` @State (crosshair sync between
  price chart and panels still not wired on iPad).

## Decisions & Reasoning

- Drawer is an overlay, not an HStack sibling, so expanding it never
  re-lays-out the chart (avoids tickling the Equatable/perf machinery).
- Kept the sentinel engine (`StrategySentinel.evaluateSymbol`) and its
  Inbox notifications untouched — only presentation changed.
- The stage action (tap ➕) still sets `taScenario` + opens the trade box,
  which is user-initiated, unlike the always-on chart highlights.
- Old key `dashboard.sentinelCollapsed` abandoned in favour of
  `dashboard.sentinelDrawerExpanded` (semantics inverted with the drawer).

## Unfinished

- Drawer exists only on the Mac single-chart layout (same coverage as the
  old HUD). Grid panes and the iPad target have no sentinel UI — engine
  still runs where `evaluateSymbol` is called.
- Not verified interactively (build-only check).
