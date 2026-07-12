# Helix Trading App v1.4

**Adaptive iPhone + iPad redesign, and automatic Faraz re-login.**

## New Features

- **iPhone support** — the touch app is no longer iPad-only. `TARGETED_DEVICE_FAMILY` is now `1,2` with iPhone orientations, and the whole UI adapts to compact width. One codebase drives both form factors.
- **Adaptive navigation** — `AdaptiveRootView` picks the shell by size class: iPad (regular width) keeps the `NavigationSplitView` with a **Navigate + live Watchlist** sidebar; iPhone (compact width) gets a bottom `TabView` (Chart · Markets · Journal · Inbox · More).
- **Markets watchlist** — a first-class searchable, category-grouped pair list, replacing the pair-selector dropdown that used to be buried in the chart header.
- **Automatic Faraz re-login** — when a Faraz API call returns HTTP 401, the app now opens an in-app faraz.io browser (`WKWebView`), lets you log in, captures the session cookies, and saves them so the feed resumes — on macOS **and** iPad/iPhone. A "Log in to Faraz…" button in Settings triggers the same flow proactively (no more DevTools copy-paste). After capture, the live WebSocket restarts and history backfills automatically.

## Design System

- **`AdaptiveMetrics`** — size-class-aware spacing, type ramp, and tap targets (≥44pt) read from the environment.
- **Touch controls** — `IconButton` (≥44pt hit area + haptics), `PillButton`, `SegmentedChips`, and a unified `Surface` card, replacing the copy-pasted 32×32 buttons throughout the chart chrome.

## iPad / iPhone UI

- **Chart toolbar decomposed** — the crammed single-row `IPadChartHeaderToolbar` is split into composed control groups: on iPhone a slim primary row (timeframe · type · Analyze) plus a horizontally scrollable icon row; on iPad a single clean row. The network-debug tool moved out of the always-visible chrome into a `•••` overflow menu.
- **Indicator settings** — the draggable floating panel stays on iPad; iPhone presents a proper detented `.sheet` (its fixed 360pt width didn't fit small iPhones).

## Bug Fixes

- **iPad AI overlay could not be dismissed** — the analysis page's close and "Add to chart" buttons set the macOS-only `AppState.showAnalysisFullPage`, which the iPad dashboard never observed. Dismissal now routes through an `onClose` callback wired to the dashboard's local state.
- Modernized the analysis history sheet's deprecated `NavigationView` → `NavigationStack`; removed no-op `.help()` tooltips from the touch app.

---

Full history: see [CHANGELOG.md](./CHANGELOG.md).
