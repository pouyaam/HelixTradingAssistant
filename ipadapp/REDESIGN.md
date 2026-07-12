# Helix iPad / iPhone Redesign

Working brief for the UI/UX overhaul of the touch app
(`HelixTradingAppiPad` target). This target reuses the entire
`GoldMonitorMac/` source tree and overrides touch-specific views under
`ipadapp/HelixTradingApp-iPad/`.

## Goals

1. **Touch-first UX** — every interactive control ≥44pt, no hover
   tooltips, no draggable desktop panels, no debug chrome in production.
2. **One adaptive codebase, two form factors** — a single set of views
   keyed off `@Environment(\.horizontalSizeClass)`:
   - **regular** (iPad, big iPhone landscape) → `NavigationSplitView`
     (sidebar + columns).
   - **compact** (iPhone portrait) → `TabView` bottom bar + sheets.
3. **The chart is the hero** — a small, uncluttered chrome; everything
   else is progressively disclosed.
4. **iPhone-ready** — `TARGETED_DEVICE_FAMILY = "1,2"`, iPhone
   orientations, safe-area aware.

## Decisions (locked)

- Navigation: **adaptive split-view + tab bar** (not a single TabView).
- Scope: **full redesign into one adaptive codebase** (not a restyle).

## Architecture

```
AdaptiveRootView                       (replaces RootViewiPad)
  @Environment(\.horizontalSizeClass)
  regular → SplitRootView              NavigationSplitView { Sidebar(nav+watchlist) } detail
  compact → TabRootView                TabView { Chart · Markets · AI · Journal · More }
```

Both drive the same `AppState.selectedSidebarItem` / `selectedPairID`,
so screen logic is never duplicated.

### Design system (`ipadapp/.../DesignSystem/`)

- `AdaptiveMetrics.swift` — size-class-aware spacing / font ramp / tap
  targets (`Metrics.tap = 44`), read from the environment.
- `TouchControls.swift` — `IconButton` (44pt hit area + haptic),
  `SegmentedChips`, `PillButton`, `SheetScaffold`.
- `Surface.swift` — unified card/elevation on top of the existing
  `Theme.Color` tokens (dark palette kept).

The old `ThemeiPad` / `CardiPad` are folded into these.

## Screen redesign

| Screen | Change |
|---|---|
| Chart | Replace crammed `IPadChartHeaderToolbar` with: minimal **top bar** (pair · timeframe · type · ••• overflow), floating **drawing tool rail** (right edge, shown only in draw mode), **bottom action bar** (Analyze + indicators/layers/alerts/fullscreen). Indicator settings → `.sheet` with `.presentationDetents`. Remove debug ladybug (gate in Settings). |
| Markets | New first-class searchable watchlist (was a header dropdown). |
| AI | Adaptive columns: regular = report + plans side by side; compact = stacked. Full-height sheet on iPhone. |
| Journal / News / Portfolio / Inbox / Settings | `Form`/`List` + `NavigationStack`, tap-target + spacing passes. |

## Phases (each ends with a green `xcodebuild build`)

1. **Foundation** — design system + enable `1,2` device family. No behavior change.
2. **Navigation** — `AdaptiveRootView` (split ↔ tab) + Markets watchlist.
3. **Chart chrome** — decompose the toolbar; settings → detented sheet.
4. **AI + secondary screens** — adaptive columns, Form/List passes.
5. **iPhone polish** — compact verification, safe area, haptics, orientation.
6. **QA** — iPhone + iPad simulators, confirm chart perf unchanged.

## Guardrails

- Keep `ChartPlotiPad`'s local `xDomain`/`yDomain` isolation untouched —
  it's what keeps pan/zoom off the dashboard's hot path.
- Extend the shared `Theme`, don't fork it (avoid Mac regressions).
- All target/build changes go through `project.yml` (the `.xcodeproj`
  is generated); re-run `xcodegen generate`.
- Sweep AppKit-only `.help()` tooltips (no-op on iOS).
