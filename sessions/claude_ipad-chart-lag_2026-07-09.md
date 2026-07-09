# Session: claude / ipad-chart-lag_2026-07-09

Date: 2026-07-09
Project: HelixTradingApp (iPad target)

## Summary
User reported the iPad chart is laggy/not smooth compared to the Mac app in any
state. Investigated both chart implementations (`ChartViewiPad.swift` vs the
Mac `ChartView.swift`) and the shared `ChartDerivedCache` / `ChartWindowing`.
The rendering code, windowing (≤1500 marks), and memoized derived cache are
essentially identical across platforms, so the difference wasn't the chart
itself — it was **where the zoom-window state lived**.

Root cause: on Mac the pan/zoom domain (`xDomain`/`yDomain`) is scoped to an
isolated chart view (`ChartPaneView` / the primary chart card). On iPad both
were top-level `@State` on the 996-line `DashboardViewiPad`, and were read by
views spread across its `body`. So every pan/zoom gesture frame mutated that
state and forced SwiftUI to re-evaluate the ENTIRE dashboard body each frame —
pair header, the multi-chart `ChartGridView`, the (hidden) `AnalysisPageiPad`
overlay, the stats row, and the toolbar menus — even though only the chart
moved. That per-frame whole-tree re-evaluation was the lag.

Fix: isolated the domain into a new local child view `ChartPlotiPad` (price
chart + oscillator panels + volume bars, sharing one xDomain/yDomain as its own
`@State`). Now a pan re-renders only that subtree, matching the Mac
architecture. Verified with `xcodebuild ... -scheme HelixTradingAppiPad` →
BUILD SUCCEEDED.

## Changes Made
- `ipadapp/HelixTradingApp-iPad/Features/Dashboard/DashboardViewiPad.swift`:
  - Removed `xDomain`/`yDomain` `@State` from `DashboardViewiPad` (added a note
    explaining why they must NOT be hoisted here).
  - Removed the two explicit `xDomain = nil / yDomain = nil` resets (in the
    `.task(id: selectedPairID)` and `onChange(of: timeframe)`); reset is now
    driven by changing the child's `.id`.
  - Replaced the inline `ChartViewiPad` + oscillator panels + volume block in
    `chartCard(_:)` with a single `ChartPlotiPad(...)` call carrying
    `.id("\(pair.id)|\(timeframe.rawValue)")` (fresh auto-fit window per
    pair/timeframe).
  - Added `private struct ChartPlotiPad: View` at end of file — owns
    xDomain/yDomain locally, hosts the chart + oscillators + volume.

## Decisions & Reasoning
- Extracted only the plotting region (not the whole `chartCard`) because the
  chart header/toolbar reads a lot of parent state (timeframe, chart type,
  indicator/layer menus, sheets); pulling it all in would have been very
  invasive. The toolbar doesn't read the domain, so leaving it in the parent is
  fine — the parent body simply no longer re-renders during pan.
- Used `.id(pair|timeframe)` for reset instead of passing the domain bindings
  back up: a new id re-creates the subtree with nil domains, exactly matching
  the old reset semantics, and keeps the domain (user's zoom) stable across live
  1 Hz candle ticks (same id → view persists).

## Follow-up (same day) — fullscreen candle loss + reset button

Root cause of "grid fullscreen → exit → candles lost": in `DashboardViewiPad`
`showsGrid = multiChart.layout != .single && !app.isChartFullscreen`. Both the
grid-wide "Fullscreen Grid" button and a per-pane fullscreen set
`app.isChartFullscreen = true` (via `ChartGridView`), which flipped `showsGrid`
to false — collapsing the whole grid to zero-frame and swapping in the
unrelated single `chartCard`. So fullscreen in grid mode showed the wrong chart
and, combined with the `guard isVisible` gate in `ChartPaneView`'s load `.task`,
panes could come back blank.

Changes:
- `DashboardViewiPad.swift`: `showsGrid = multiChart.layout != .single`
  (dropped the `&& !app.isChartFullscreen`). Grid now stays shown for any
  multi-chart layout; fullscreen is handled inside `ChartGridView`. Fixes both
  grid-wide and per-pane fullscreen.
- `ChartPaneView.swift` (shared): `.onChange(of: isVisible)` now does a full
  `load()` when `candles.isEmpty` (else the cheap `refreshTrailing()`), so a
  pane that never loaded while hidden behind a fullscreen sibling repopulates
  when it reappears.
- Reset button in the tap-and-hold menu:
  - `ChartPaneView.optionsMenu` (grid panes): added "Reset Zoom" (nils
    xDomain/yDomain). Shared, so Mac benefits too.
  - `ChartPlotiPad` (single chart): added a `.contextMenu` with "Reset Zoom"
    (the single chart previously had no tap-hold menu — only double-tap).

Build: `xcodebuild -scheme HelixTradingAppiPad` → BUILD SUCCEEDED.

## Follow-up (same day) — indicators never drawing on iPad

Symptom: no indicators rendered on the iPad chart in any state (single / grid /
fullscreen). Root cause was the memoization key for the line indicators
(SMA/EMA/Bollinger):

- `ChartViewiPad` builds `indicators.map { IndicatorInstance(kind: $0) }` on
  every render, and `IndicatorInstance.init` mints a fresh random UUID each
  time. `ChartDerivedCache.IndicatorSig` keyed on the full instance (UUID
  included), so the signature never matched twice → the background compute in
  `resolve()` was cancelled and restarted forever.
- Compounding it: there are TWO call sites per render — `indicatorMarks` and
  `autoYDomain` — each with different fresh UUIDs, so the second call cancelled
  the first's in-flight task within the same render. The compute never landed →
  points stayed empty → nothing drew. (Zone indicators like Order Blocks use
  UUID-free signatures, which is why only the line indicators were affected;
  the Mac only hits the second call site with stable `indicatorInstances`, so
  it never thrashed.)

Fix: `ChartDerivedCache.swift` — key `IndicatorSig` on a new `IndicatorKey`
(kind + params + hidden), NOT the instance's `id`. Now the signature is stable
across renders: the compute lands once and every later render (including during
pan) hits the cache fast-path. This fixes drawing in ALL states (single chart
via `ChartPlotiPad`, and every grid layout / fullscreen via `ChartPaneView` —
both go through `ChartViewiPad` + this cache) and removes the perpetual
recompute loop (a CPU drain that also caused constant redraws). Both iPad and
Mac targets build.

## Follow-up (same day) — remaining CPU hotspots (all states still laggy)

Profiled the per-frame work by counting how often each expensive computed
property is read per render. Fixes, biggest first:

1. **`displayCandles` — 13× full-array copies per frame (THE big one).**
   `ChartViewiPad` reads the `displayCandles` computed property ~13× per render
   (candle marks, line marks, UT Bot, hover, auto-Y). Each read called
   `ChartDerivedCache.displayCandles`, which patches the live price onto the
   last bar via `var patched = base; patched[last] = …` — and because the cache
   still holds a reference to `base`, that mutation forces a full O(n) COPY of
   the whole candle array. On deep history that's ~13 full-array copies (tens of
   MB alloc) every frame — the dominant pan/zoom cost. Fixed by memoizing the
   patched array on (base signature + live price) in `ChartDerivedCache.swift`;
   now it rebuilds once per tick and all reads hit the cache.

2. **Two hidden charts doing live work (single ↔ grid).** `DashboardViewiPad`
   kept BOTH the single `chartCard` and the whole `ChartGridView` mounted, the
   hidden one collapsed to frame 0. So in single mode the grid's slot-0 pane was
   a live chart loading candles + refreshing every tick, and in grid mode the
   single chart re-rendered hidden — pure wasted CPU on every tick / fullscreen
   toggle. Switched the frame-0 trick to a real `if showsGrid { grid } else
   { chartCard }`. Layout switch (rare) rebuilds; fullscreen enter/exit does not
   (showsGrid unchanged).

3. **AnalysisPageiPad rendered while hidden.** It was always mounted (frame 0),
   so its body — which renders the AI report markdown — re-evaluated on every
   dashboard re-render (tick, fullscreen toggle). Gated behind `if showAnalysis`.

4. **`autoYDomain` per-frame allocations.** Ran every horizontal-pan frame;
   replaced two throwaway `.map{}.min()/.max()` arrays with a single-pass
   min/max and bound `displayCandles` once.

5. **iOS mark budget.** `ChartWindow.maxRenderedBars` lowered to 700 on iOS
   (vs 1500 on macOS) — Swift Charts renders every mark, so this halves
   candlestick layout cost on a deep zoom-out. `#if os(iOS)` in the shared
   `ChartWindowing.swift`.

Both iPad and Mac targets build.

## Unfinished / Next Steps
- Grid panes pass `Set(pane.indicatorInstances.map(\.kind))` into
  `ChartViewiPad`, which rebuilds instances with DEFAULT params — so per-pane
  custom indicator parameters aren't honored in grid mode (indicators still
  draw, just with defaults). Out of scope here; note for later.
- Behavior fixes verified to compile, not yet touch-tested on device/sim. Smoke
  test: grid per-pane + grid-wide fullscreen enter/exit keeps candles; Reset
  Zoom in both menus rescales; pan/zoom still smooth.
- Watch the single chart's new `.contextMenu`: iOS long-press can slightly
  delay pan start. ChartPaneView already combines contextMenu + gestures fine,
  and double-tap reset remains, but if pan feels sticky, replace the main
  chart's contextMenu with a visible control.
- If deep zoom-out is still heavy on older iPads, lower
  `ChartWindow.maxRenderedBars` under `#if os(iOS)` (shared `ChartWindowing.swift`).
