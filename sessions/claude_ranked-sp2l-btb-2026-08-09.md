# Session: claude / ranked-sp2l-btb-2026-08-09
Date: 2026-08-09
Project: Helix Trading Assistant

## Summary

Added a new indicator, **SP2L + Pro BTB × Ranked OB**
(`IndicatorKind.rankedSP2LBTB`), a port of the PineScript v6 indicator of
the same name. Two trigger engines feed one grading engine: a setup only
becomes a signal if its confluence score clears a minimum grade.

Engine + Mac chart rendering + iPad chart rendering + derived-value cache
+ 26 unit tests. macOS builds clean; the full suite is **233 tests, 0
failures** (was 207).

Not visually confirmed on the running app — see "Unfinished".

## What was added

### `GoldMonitorMac/Features/Dashboard/RankedSP2LBTB.swift` — the engine

Pure functions, no state, same shape as `AMDCycle` / `RankedOrderBlocks`.

**Trigger 1 — SP2L.** A displacement bar (`|close − close[2]| ≥
spikeATR × ATR`) that also leaves a three-bar fair value gap arms that
gap. Price then has to trade back into the gap's near edge or its 50%
equilibrium (`entryModel`), still closing on the right side of the gap,
with an optional confirmation candle. A close through the far side
inverts the gap and kills the setup (Pine's "IFVG" label).

**Trigger 2 — Pro BTB.** A close through the last confirmed pivot with a
body ≥ `minBreakBodyATR × ATR` arms the broken level, optionally
requiring a fresh FVG that straddles it. The retest has to come back
within `retestToleranceATR × ATR` and close back on the breakout side,
and may not fire on the bar right after the break (that bar is the
breakout's own follow-through). The stop goes under the retest low or
the FVG floor, whichever is further.

**Grading.** Three independent legs, scored at the *trigger* bar:
Volume Profile (0–2), Ichimoku (0–3), order-block confluence (0–2, where
2 is an overlapping live block and 1 is one within `obProximityATR ×
ATR`). Total → A (≥70%) / B (≥40%) / C, gated by `minGrade`;
`obMode == .required` turns the confluence leg into a hard gate.

### Wiring

- `Indicators.swift` — case, label, colour, and 41 `paramSpecs` grouped
  general / SP2L / BTB / grading / trend / VP / Ichimoku / OB / display.
  No `OscillatorConfig` mirror: config is read off the instance params
  via `RankedSP2LBTB.Configuration(params:)`, matching the newer
  indicators (`amdCycle`, `helixOBCombo`, `algoSmartAssist`,
  `previousDay`). Pickers iterate `IndicatorKind.allCases`, so it shows
  up in the f(x) menu and the legend on both platforms for free.
- `ChartDerivedCache.rankedSP2LBTB` — memoized slot keyed on bar
  identity **plus trailing OHLC**, like `AMDSig`: the live bar can be
  the one that trades into an armed zone, and that trigger is the whole
  point of the overlay. Folded into `OverlayData` / `overlayExtremes`
  with per-setup keys (`id|status|tp`), not a count — a live plan's
  levels move while the set size stays put.
- `ChartView.rankedSP2LBTBMarks` + three sub-builders (confluence
  blocks, setup zone + broken level + plan, plan level), mirrored into
  `ChartViewiPad`.

### `GoldMonitorMacTests/RankedSP2LBTBTests.swift` — 26 tests

Two hand-built series with every structural bar at a known index: 20
flat bars set the ATR, then the setup prints where the comment says.
Covers both triggers, both directions (via a mirrored series), the entry
models, the confirmation gate, invalidation / expiry / still-armed,
outcome tracking, the direction and bias filters, the grade gate, and
required-vs-bonus OB confluence.

## Decisions & Reasoning

- **The OB engine is re-implemented here rather than calling
  `RankedOrderBlocks.compute`.** Confluence has to be judged against the
  blocks that were *live at the signal bar*; `compute` only returns the
  handful still standing at the end of the series, with no history and
  no per-bar breaker state. Sharing the code would have meant giving
  `RankedOrderBlocks` a second, history-retaining entry point — a change
  to a shipped indicator for the benefit of a new one. ~120 duplicated
  lines was the cheaper trade. (This is the same gap AGENTS.md's "Open
  work" already notes about retired Ranked-OB zones; if that ever gets
  fixed, this engine should switch to the shared path.)

- **Deliberate deviation: an unranked setup passes the "C — all setups"
  gate.** In Pine, `gradeOf` returns `"-"` when every scoring leg is
  disabled and `rankOf("-") == 0`, which is below *every* `minRank` —
  so turning the whole rubric off silently blocks every signal at any
  setting. Here `Grade.unranked.rank == 1`, so it passes C. Turning the
  rubric off should mean "no filter", not "no output". Pinned by
  `testUnrankedSetupsPassTheCGate`.

- **Outcome tracking is an addition, not a port.** Pine only draws
  entry/SL/TP lines for `tradeLen` bars and never says what happened.
  Every sibling engine here (`RankedOBStrategy`, `AMDCycle`, `MTRSetup`)
  walks the trade forward, and the chart needs it to know where to stop
  extending the plan lines. A bar spanning both levels reads as a loss —
  intrabar order is unknowable from OHLC, same call as the siblings.

- **VP, Ichimoku and the info table are not drawn; order blocks are.**
  Same call `RankedOrderBlocks` made — the app already ships standalone
  Volume Profile and Ichimoku indicators, so re-drawing them here would
  duplicate. Order blocks are the exception: they are half the
  indicator's name and the thing "confluence" means visually, so they
  render faintly behind the setups with their grade badge
  (`showOrderBlocks`, default on).

- **Superseded zones are kept, not dropped.** Pine holds one armed slot
  per engine per direction and simply overwrites it, while leaving the
  old FVG *box* drawn. Overwriting here retires the old zone as
  `.expired` so the box still has something to render, which matches
  what the Pine chart actually looks like.

- **Grading runs lazily, not per bar.** Pine calls `gradeSetup` four
  times on every bar; here it runs only on candidate trigger bars and
  once at the right edge for display. Same result — the gate reads the
  trigger bar's grade either way — without an O(n × vpLookback) scan.

- **Test series had to be built to leave no *second* imbalance.** The
  first draft's pullback bars accidentally printed a bear FVG (bar 23's
  high sat under bar 21's low), arming a second setup and breaking six
  assertions. Every bar after the displacement now overlaps its
  two-bars-back neighbour on purpose, and the outcome-variant tests
  select the long SP2L explicitly instead of taking `setups.first`.

## Verification

- `xcodebuild -scheme HelixTradingApp -destination 'platform=macOS'
  build` → **BUILD SUCCEEDED**, no new warnings.
- `... test` → **233 tests, 0 failures** (26 new).

## Unfinished / Next Steps

- **iPad edits are compile-unverified.** `HelixTradingAppiPad` still
  does not build on `main` — the same three pre-existing errors logged
  in `previous-day-indicator-2026-08-02.md`,
  `smc-desk-and-mcp-server-2026-08-04.md`,
  `claude_amd-indicator-2026-08-06.md` and
  `claude_remove-pinbar-combo-2026-08-09.md`. Confirmed the root cause
  this time: **`ChartViewiPad` never declares `indicatorInstances`** —
  it is read at lines ~173/180/187/233/4101 (helixOBCombo,
  algoSmartAssist, amdCycle, enhancedSonarlabOB) and declared nowhere,
  while only `indicators` and `indicatorConfig` are stored properties.
  The new code adds a sixth reference at ~204, i.e. another symptom of
  the existing break, not a new category. The other two are the missing
  `enhancedSonarlabOBZones` argument (~4634) and `renkoConfig` out of
  scope in `DashboardViewiPad` (~735). Spun out as its own task.

- **Not visually verified.** Same wall as the AMD session: indicator
  state could not be driven from outside the app. The indicator needs
  switching on from the f(x) picker by hand and eyeballing — in
  particular the zone left edge (`armIndex − 2.5`, since an FVG spans
  three bars) and the badge legibility where a setup zone and a
  confluence block overlap.

- **No notification wiring.** The `alertStore.evaluate*` path
  (baselining, dedup, Inbox events) is a surface of its own and was
  kept out to hold this change to one thing — same call the AMD session
  made. This engine is a better fit for it than most, since a
  grade-A signal is exactly the kind of thing worth a push.

- The Pine info table (last entry / SL / TP / grade / bias) is not
  ported. `Output.bias` is computed and exposed but nothing renders it;
  the chart legend is the natural home if it is ever wanted.
