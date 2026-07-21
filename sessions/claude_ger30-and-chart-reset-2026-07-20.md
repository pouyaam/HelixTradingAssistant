# Re-frame the chart on pair / timeframe switch

**Date:** 2026-07-19

## Problem

Switching symbol or timeframe only cleared `xDomain` / `yDomain`. A nil Y
hands the price axis back to the **overlay-inclusive** auto-fit, so a
far-away indicator / target line belonging to the newly-loaded series can
squash the candles into a sliver. The chart needs the same framing the
Reset action applies.

## Approach

Clearing at switch time is too early — the new bars don't exist yet. So
the switch now *defers* a `resetChart()` until the load that actually
produces candles.

- `DashboardView` — new `pendingChartReset` @State, set in the
  `.task(id: app.selectedPairID)` and the `onChange(of: timeframe)`
  alongside the existing nils; consumed by `consumePendingChartReset()`
  inside `reloadCandles()`.
- `ChartPaneView.load()` — keyed on `pairID|timeframe`, so reaching it
  always means the series changed; the nils were replaced with a direct
  `resetChart()` (no deferral needed, `load()` already has the bars).
- `DashboardViewiPad` (`ChartPlotiPad`) — same flag/consume pair as the
  Mac dashboard, set in the `.task(id: "pairID|tf|reloadToken")`.

## Two ordering traps

1. **`followLatestIfPinned` must run before the reset.** It compares
   against the *previous* series' bar count, which is meaningless across
   a switch. Running it first means it sees the still-nil domain and
   bails; the reset then pins a window framed to the new bars. Later
   backfill reloads find the flag cleared and edge-track that window
   normally, which is what keeps the view at the live edge as deep
   history fills in behind it.
2. **The reset must not fire on an empty series.** `warmHistory()`
   reloads twice (after `ensureDeepHistory`, then after `backfillAll`),
   and the first load can yield zero bars. `consumePendingChartReset()`
   therefore no-ops while `candles.isEmpty` and the flag survives to the
   next load — otherwise the chart frames a placeholder domain and
   leaves the real data unframed.

Both `reloadCandles()` implementations early-return when the loaded
series is unchanged; the flag is consumed on that path too, for the case
where the new pair/TF was already cached.

## Follow-up: stale chart flash on symbol switch

Reported after the above landed: switching symbol briefly showed the
*previous* chart, then snapped. Cause was separate from the framing work
— `candles` still held the outgoing pair's bars for the whole duration of
the async SQLite read, so the chart rendered old data under the new
symbol until the load returned.

- `DashboardView` — `candles = []` + `recomputeTotalVolume()` now run
  synchronously in the pair `.task`, before `reloadCandles()` suspends.
- The skeleton overlay condition became
  `(isBackfillingCurrentTF || isLoading) && candles.isEmpty` — a symbol
  switch clears the bars before any backfill is marked in-flight, so
  without `isLoading` that moment renders as a blank plot instead of a
  skeleton.
- `ChartPaneView.load()` — same pre-clear.
- **iPad deliberately does NOT pre-clear.** `ChartPlotiPad`'s
  `loadCandles` is a synchronous blocking read, so the swap is atomic
  from the view's perspective and no stale frame exists. Clearing first
  would only introduce a blank frame at the `await` suspension point.
  (I added the clear there first, then reverted it — don't "fix" this
  again without checking whether that loader is still synchronous.)

## Build / verification

Both targets build clean (`platform=macOS`,
`generic/platform=iOS Simulator`). **Not verified at runtime** — this is
chart framing behaviour that needs a human to switch symbols and
timeframes and watch the scaling.
