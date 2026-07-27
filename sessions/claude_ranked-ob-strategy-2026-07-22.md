# Ranked OB strategy layer — 2026-07-22

## Goal

The Ranked OB indicator drew graded zones and notified on their
lifecycle, but a zone is a *location*, not a trade. Add the layer that
turns a graded zone into a plan: confirmation, entry, stop, targets —
and a switch inside the indicator that surfaces it.

## What landed

### Engine change — `RankedOrderBlocks.Zone` gained two fields

- **`confirmIndex`** — the BOS bar that *created* the zone, as opposed
  to `startIndex` (the order-block candle, several bars earlier). Every
  bar between the two sits inside the zone by construction, so anything
  watching for price *returning* has to start its scan at `confirmIndex`
  or it arms instantly on its own formation. This was the single field
  without which the strategy is impossible.
- **`atr`** — Wilder ATR at `confirmIndex`. The engine already computed
  the series and threw it away; stop placement needs it.

Merged zones take the *later* half's `confirmIndex`/`atr` — a retest
scan must not start before both halves exist.

### New file — `Features/Dashboard/RankedOBStrategy.swift`

Pure function `compute(candles, zones, config) -> [Setup]`. Three gates:

1. **Grade filter** — A only / A+B / all. `.unranked` always passes:
   with both ranking legs off there is nothing to grade on, and
   filtering would silently produce zero setups.
2. **Arrival** — price taps the zone's proximal edge → `armed`.
3. **Confirmation** — `.rejection` (wick in, close back out, close in
   the far third of its range), `.microBOS` (close beyond the reaction
   extreme, needs ≥2 bars of reaction), `.fvg` (three-bar displacement
   in the trade's direction), or `.touch` (no gate — a plain limit).

Geometry is fixed at zone formation so the plan and its R:R are
displayable long before it triggers: entry at the near edge / mid / far
edge, stop at the far edge ∓ `slATRBuffer × atr`, TP1 at `tp1R`, TP2 at
`tp2R` or the nearest opposing zone's proximal edge. A-grade zones get
+1R when `gradeScaledTargets` is on. Stop moves to breakeven after TP1.

`.confirmClose` is the exception — it can't know its entry until the
confirmation bar closes, so it shows the zone mid as provisional
(`isProvisionalEntry`) and re-bases entry/TP on trigger. The stop never
moves.

Breakers are a second setup for free: a bullish block that failed is
resistance, so its retest is a short. Off by default (`tradeBreakers`).

Two conventions in the replay, both deliberately pessimistic:

- **A bar covering both the stop and a target counts as the stop.**
  Intrabar order is unknowable from OHLC; assuming the good outcome is
  how a backtest learns to lie.
- **No fill on the confirmation bar.** Caught while writing the tests:
  a rejection candle that also traded through the entry price would
  have filled from the same bar whose *close* produced the signal.
  Straightforward lookahead bias. `.confirmClose` is the one exception,
  since it fills at that close by definition.

### Wiring

- `Indicators.swift` — 12 new `strat*` params on `.rankedOrderBlock`
  (the floating per-instance panel builds itself from these).
- `Oscillators.swift` — `robStrat*` persisted fields (lenient
  `decodeIfPresent`) + `rankedOBStrategyConfiguration`.
- `DashboardView.swift` — param→config sync + the notify branch.
- `ChartDerivedCache.swift` — memo slot keyed on candles + zone
  identities + config; `OverlayData.rankedOBSetups` (defaulted, so the
  iPad call site didn't need touching before it was wired) feeding the
  auto Y-domain. The extremes signature keys on each plan's SL/TP2, not
  just the count — a `.confirmClose` re-base moves the levels without
  changing the set size.
- `ChartView.swift` + `ChartViewiPad.swift` — `rankedOBStrategyMarks`:
  entry (dashed, direction-tinted), SL, TP1, TP2, faint until filled;
  arm/fill dots; `A 4/5 LONG · 2.4R` badge, gated on the existing
  `robShowLabels`.
- `Alerts.swift` — `evaluateRankedOBStrategy`, firing only on `armed` /
  `entered` / `hitTP` / `hitSL` under category `.strategy`. Plan
  *creation* deliberately doesn't notify: `evaluateRankedOrderBlocks`
  already fires when the zone forms, and a plan is that zone with
  levels attached. Keyed on the zone's price range, never on
  `Setup.id` — that folds in bar indices, the exact thing that caused
  the original order-block notification flood.
- `IndicatorSettingsSheet.swift` — a collapsible strategy block in the
  global sheet, plus `robStrategyDescription`: the settings read back as
  the sentence they encode ("On A- and B-grade zones: wait for price to
  return, then wait for a rejection candle within 5 bars…"). Six pickers
  don't tell you what the strategy *is*; that line does.

## Verification

- `xcodebuild` Debug: macOS ✅, iPad simulator ✅.
- `xcodebuild test`: 85 tests, 0 failures (20 new in
  `RankedOBStrategyTests`). Coverage: plan arithmetic, grade filtering,
  min-R:R rejection, opposing-zone targets, the full tap→confirm→fill→TP
  walk, no-fill-on-the-trigger-bar, rejection/micro-BOS/confirm-close
  confirmation, pre-entry invalidation, window expiry, same-bar TP+SL,
  breakeven-after-TP1, breaker inversion, and one integration test that
  drives the *real* `RankedOrderBlocks.compute` so `confirmIndex` and
  `atr` are checked against the engine rather than my assumptions.

**Not exercised at runtime.** Needs the indicator enabled with the eye
on and "Strategy: draw entry / SL / TP" ticked, on a chart where a
graded zone gets retested, to confirm the four rule marks and the badge
render where they should. The last Ranked-OB session found three
annotation bugs that only appeared on screen — worth the same pass here,
though these marks copy the NY-Open/SP2L pattern that already works
rather than the centred-PointMark pattern that didn't.

## Follow-ups worth considering

- Grade hit-rate study. Blocked on the scope note below rather than on
  effort: the replay already resolves trades, it just can't see zones
  the indicator has retired.
- Surface `RankedOBStrategy.headline(_:)` in the pane legend — it's
  written and tested, nothing renders it yet.

## Known scope limit (documented, not fixed)

Setups live and die with the zones on screen. `RankedOrderBlocks.compute`
returns the freshest `zonesPerSide` per side and drops a breaker once
price passes clean through its far side, so a resolved trade whose zone
has been fully consumed disappears from the overlay rather than
lingering as history. That keeps the chart honest about what's still
tradeable and is why this is a live-assist layer, not a backtester.
Losers *are* visible while their breaker survives — the common case.
