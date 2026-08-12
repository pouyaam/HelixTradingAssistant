# Session: claude / ebp-engulfing-bar-play-2026-08-11
Date: 2026-08-11
Project: Helix Trading Assistant

## Summary

Added a new indicator, **EBP · Engulfing Bar Play**
(`IndicatorKind.engulfingBarPlay`), a port of the PineScript v6
indicator "EBP – Engulfing Bar Play (Omar Agag)". One pattern, one
trade model, one position at a time.

Engine + Mac chart rendering + iPad chart rendering + derived-value
cache + notification wiring + 28 unit tests. macOS builds clean; the
full suite is **261 tests, 0 failures** (was 233).

Not visually confirmed on the running app — see "Unfinished".

## What was added

### `GoldMonitorMac/Features/Dashboard/EngulfingBarPlay.swift` — the engine

Pure functions, no state, same shape as `RankedSP2LBTB` / `AMDCycle`.

**The pattern.** A bullish EBP sweeps *below* the previous candle's low,
makes that sweep with its lower shadow only (the body never trades under
the swept low), closes back above the previous candle's body — or its
high, with `requireFullEngulf` — and follows a bearish candle. Bearish is
the mirror. On a wide outside bar both tests can read true; bullish wins,
as in the original.

**The trade model.** The EBP candle's own range is the fib: 0 at the
extreme it pushed toward, 1 at the one it swept. A close within
`strongClosePercent` of the extreme is *strong* — entry at a 25%
retrace, stop at 75%, both inside the candle. Anything further back is
*indecisive* — entry at the midpoint, stop behind the whole candle. A
close already past the 50% level would leave a limit on the wrong side of
price, so `marketEntryBeyondHalf` takes that one at the close. Target is
`riskReward × risk` off the fill.

**The state machine.** Ported bar for bar: a resting limit fills when
price trades through it, and the fill bar *also* runs the management
block, so a bar can fill, arm the breakeven and resolve all at once (this
is pinned by `testBreakevenCanArmOnTheFillBarItself` — it caught me out
while writing the fixtures). An unfilled limit cancels after
`expiryBars`. `breakevenOnNewExtreme` moves the stop to entry on a new
extreme past the EBP candle; being stopped there is `.breakeven`, counted
as neither a win nor a loss.

### Wiring

- `Indicators.swift` — case, label, colour, and 20 `paramSpecs` grouped
  pattern / trade-model / display. No `OscillatorConfig` mirror: config
  is read off the instance params via
  `EngulfingBarPlay.Configuration(params:)`, matching the newer
  indicators. Pickers iterate `IndicatorKind.allCases`, so it appears in
  the f(x) menu and the legend on both platforms for free.
- `ChartDerivedCache.engulfingBarPlay` — memoized slot keyed on bar
  identity **plus trailing OHLC**, like `RankedSP2LBTBSig`: the live bar
  can be the one that fills a limit or reaches a level. Folded into
  `OverlayData` / `overlayExtremes` with per-setup keys
  (`id|status|stopLoss`), not a count — the breakeven rule moves a stop
  without changing the set size.
- `ChartView.ebpMarks` + `ebpSetupMark` / `ebpPlanLevel` / `ebpTag`,
  mirrored into `ChartViewiPad`. The entry line is dashed while the
  order rests and solid once filled, matching the original's dashed
  limit / solid market line.
- `Alerts.evaluateEngulfingBarPlaySetups` + `DashboardView`'s
  `notifyOrderBlockEvents` — armed / entered / TP / SL / breakeven /
  expired transitions into the Inbox, on the same baseline-then-diff
  pattern as the SP2L/BTB evaluator.

### Tests — 28 across two files

`EngulfingBarPlayTests.swift` (22): both directions (via a mirrored
series), every pattern gate, the three entry paths, target geometry,
fill / TP / SL / expiry / breakeven, the skipped-while-working rule, the
display cap, and the stats tally. `EngulfingBarPlayAlertTests.swift` (6,
counted with the suite): one notification per transition, silence on a
re-evaluated unchanged set, and no notification for `.skipped`.

## Follow-up in the same session — three settings asks

The user then asked for a source-timeframe setting, notifications, and
an EBP tab in the Sentinel radar. Suite is now **265 tests, 0 failures**.

### 1. "Detect on timeframe" (`sourceTimeframe`)

Default `chart`; anything else detects on that timeframe's candles and
projects the result onto the displayed series **by date**, exactly the
way the HTF CHoCH overlay already works:

- `Setup` gained `barDate` / `triggerDate` / `resolveDate`, stamped in a
  post-pass in `compute` (bar indices only mean something inside the
  series they came from).
- `DashboardView.reloadExternalEBP()` mirrors `reloadHTFChoch()` — a
  separate `OHLCCandleLoader` read for the chosen timeframe, computed off
  the main actor, hung on `@State ebpExternal` + `ebpExternalLabel`, and
  re-run from the same four indicator-mutation hooks CHoCH uses.
- `ChartView.ebpAnchors` resolves a setup's X anchors either from its bar
  index (chart timeframe) or through `barIndex(forDate:)` (pinned). A
  projected candle is drawn its *real* width — a 4H bar spans 16 columns
  of a 15m chart — by projecting `barDate + sourceSeconds`, and its tag
  carries the timeframe so it doesn't read as a bar that isn't there.
- `ebpExternalLabel` doubles as the "is external" flag: `DashboardView`
  sets it only once the foreign series is loaded, so the chart falls back
  to its own computation while a load is in flight, and when the chosen
  timeframe *is* the one in view (detecting it twice would be waste).

### 2. Notifications

- A `notify` bool (default on) in the indicator's settings, layered under
  the existing layer-eye and global master switches.
- `evaluateEngulfingBarPlaySetups` gained a `timeframeLabel` override, so
  a pinned-timeframe setup reports the timeframe it actually printed on.
  The label also keys the baseline and the dedup key: switching the
  setting re-seeds instead of firing a burst of "new" setups.

### 3. Sentinel radar EBP tab

- `StrategySentinel` gained `ebpSnapshots` (per pair) +
  `publishEBP` / `clearEBP`. `EBPRadarSnapshot` is deliberately *not* a
  `RadarAlert`: EBP has no confluence rubric, so the radar mirrors the
  engine's own output rather than inventing a score.
- `SentinelRadarDrawer` gained a `SourceTab` (SMC / EBP) above the
  existing filters; the SMC panel moved into `smcPanel` untouched and the
  new `ebpPanel` shows the stats row then the setups newest-first. The
  rail's badge and label follow the active tab.
- `DashboardView.refreshEBP` is the single feed: one computation fans out
  to the radar and (when enabled) the Inbox, so the two can never
  disagree. It sits *outside* `notifyOrderBlockEvents` because the radar
  should track the chart whenever the indicator is on it, while
  notifications answer to three separate switches.

**This is where the Pine info table finally landed** — `Output.stats` was
computed-but-unrendered in the first pass; the radar's EBP tab is now its
UI, so the "no UI for Stats" item below is closed.

## Decisions & Reasoning

- **`htfOnly` became `minTimeframeMinutes`.** Pine reads
  `timeframe.in_seconds()` and hard-codes a 4H floor; a Swift engine only
  ever sees candles. The bar size is inferred from the *smallest*
  positive gap between consecutive bars — weekend and holiday gaps can
  only widen that, never shrink it — and the floor became a free
  parameter defaulting to off, since 4H is a preference, not a property
  of the pattern.

- **Every detection is a `Setup`; only one is ever traded.** The original
  holds a single state machine, so a pattern printing while an order is
  working is plotted (the triangle still draws) but never traded. Marking
  those `.skipped` with no plan keeps the chart honest about what the eye
  can see, keeps `stats` counting only real trades, and avoids inventing
  a concurrency model the model doesn't have.

- **`.breakeven` is its own status, not a `hitSL` variant.** Pine's
  counter deliberately skips a BE exit in both the win and loss tallies
  (`nWin := nWin` is the giveaway). A separate status is the only way to
  keep `winRate` matching the original while still telling the chart the
  trade is over.

- **The stats table is computed but not drawn.** The Pine info table
  (setups / wins / losses / win % / total R) is exposed as
  `Output.stats`, and nothing renders it — the same call `RankedSP2LBTB`
  made about its info table and `Output.bias`. The chart legend is the
  natural home if it is ever wanted; the data being there means a future
  UI needs no engine change.

- **A doji clamps rather than divides by zero.** `high == low` makes the
  fib meaningless, but it must not produce a NaN that poisons the
  Y-domain scan, so the range floors at `.ulpOfOne`.

- **Test fixtures assert exact prices.** Unlike the ATR-derived engines,
  every EBP level is a pure fraction of one candle's range, so the plan
  is frozen as literal numbers (entry 100.375, stop 99.725, target
  101.675) rather than asserted relationally. A change in the model can't
  hide behind a tolerance.

## Verification

- `xcodebuild -scheme HelixTradingApp -destination 'platform=macOS'
  build` → **BUILD SUCCEEDED**, no new warnings.
- `... test` → **261 tests, 0 failures** (28 new).

## Unfinished / Next Steps

- **iPad edits are compile-unverified.** `HelixTradingAppiPad` still does
  not build on `main` — the same pre-existing errors logged in
  `claude_ranked-sp2l-btb-2026-08-09.md` (chiefly `ChartViewiPad` never
  declaring `indicatorInstances`). The new code adds another reference to
  that undeclared property, i.e. one more symptom of the existing break,
  not a new category.

- **Not visually verified.** Same wall as the AMD and SP2L/BTB sessions:
  indicator state can't be driven from outside the app. Worth eyeballing
  the label density on a series with many patterns — EBP fires far more
  often than the setup engines, and `maxSetups` (default 8) is the only
  thing holding the tag count down.

- **No `IndicatorSettingsSheet` grouping.** The 22 params render as one
  flat list, like every other indicator. The source / pattern /
  trade-model / display split exists only as comments in `paramSpecs`.

- **The iPad chart ignores the source-timeframe setting.** `ChartViewiPad`
  keeps computing EBP off its own candles; `ebpExternal` is a Mac-side
  `DashboardView` load and there is no iPad equivalent (the iPad target
  doesn't build on `main` anyway). On iPad the setting is silently
  "chart timeframe".

- **The pinned-timeframe notify path trails by up to one refresh.**
  `refreshEBP` reads the `ebpExternal` that `reloadExternalEBP` last
  loaded rather than recomputing, so a notification can lag the true
  state by one candle-refresh cycle — negligible for a higher-timeframe
  pattern, but it would matter if someone ever pins EBP to a timeframe
  *below* the chart's.
