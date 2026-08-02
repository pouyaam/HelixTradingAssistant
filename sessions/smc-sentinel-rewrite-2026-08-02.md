# Strategy Sentinel rewritten as an ALGOSMART-only SMC engine (2026-08-02)

## Ask

Take the ALGOSMART ASSIST v2 indicator (verified/fixed earlier the same day —
see [algosmart-assist-fidelity-2026-08-02.md](algosmart-assist-fidelity-2026-08-02.md))
and build the supplied SMC/ICT strategy on top of it, replacing the whole
Sentinel Radar so it runs on that strategy *only*.

## What changed

### New — `GoldMonitorMac/AI/SMCSentinelEngine.swift`

A pure, synchronous, testable engine. It reads nothing but
`AlgoSmartAssist.calculate` output, in the order the strategy states:

1. **Context** — the HTF's most recent confirmed BOS/CHoCH sets the *only*
   direction the radar trades. There are no counter-trend setups: in this
   strategy a LTF CHoCH is a trigger, not a context.
2. **Liquidity grab** — an IDM sweep or an "X" sweep of a prior swing, after
   the context event. Key insight from reading the indicator: `drawIDM` is
   only ever called inside the `low < idmLow` / `high > idmHigh` branch, so a
   drawn IDM line *is* a completed inducement sweep — no separate detection
   needed.
3. **POI mitigation** — a demand (long) / supply (short) zone whose midpoint
   is on the correct side of the indicator's live 0.5 line: discount for
   longs, premium for shorts. This is a hard filter, per the strategy.
4. **Trigger** — a SCOB bar of the right polarity whose *close* is inside the
   POI, or a LTF CHoCH in our direction after the grab.
5. **Execution** — entry at the trigger close (or the POI edge while waiting),
   stop beyond the zone, TP1 at equilibrium (or 1:2 when equilibrium is
   nearer than 1R), TP2 at the opposing zone / major swing / 3R.

Setups are dropped when the stop is already taken out or price has run >70%
of the way to TP1.

### Rewritten — `GoldMonitorMac/AI/StrategySentinel.swift`

The four-order-block-engine, traded-volume-ranking pass is **gone** entirely:
no more `VolumeRankedOrderBlocks` / `RankedOrderBlocks` / `SonarlabOrderBlocks`
/ `EnhancedSonarlabOrderBlocks` / `OrderBlocks` fan-in, no HTF zone nesting, no
EMA trend filter, no volume rank. `evaluateSymbol` now aggregates the HTF
series and delegates to `SMCSentinelEngine.scan`.

`RadarAlert` reshaped around SMC:

- added `takeProfit2`, `zoneTop`, `zoneBottom`, `equilibrium`
- removed `volumeRank`, `tradedVolume`, `isHTFNested`
- `SetupStatus` is now the strategy's own lifecycle —
  `waitingForPOI` / `mitigating` / `active` / `invalidated`
  (was `pending` / `inZone` / `reaction`)
- `ConfluenceBreakdown` re-fielded to SMC confluences (IDM sweep, liquidity
  sweep, equilibrium side, trigger, fresh zone, LTF alignment) plus the
  context/grab/trigger descriptions

New `@Published var marketContext` carries the *narrative* half of a scan —
HTF event, equilibrium, premium/discount state, and which rule is currently
blocking — so an empty radar can explain itself instead of just showing
nothing. `publishResultsIfChanged` now replaces only the scanned symbol's
alerts instead of the whole array.

### Reworked — `GoldMonitorMac/UI/SentinelRadarDrawer.swift`

- Stage tabs → ACTIVE / IN POI / WAITING / ALL.
- Volume threshold menu deleted; ⚡HTF chip became ⚡TRIGGERED.
- Header gained the market-context line (HTF event · 0.5 level · DISCOUNT or
  PREMIUM badge); empty state names the blocking rule.
- Row: rank medal → trigger badge; volume → POI band + TP2; the strategy
  rationale now renders as its own two-line read.
- Spatial bar shows the entry→TP2 run under the entry→TP1 leg.
- Confluence accordion and the detail popover rebuilt on the SMC breakdown
  (HTF context, liquidity grab @ level, POI band, equilibrium, trigger,
  TP1/TP2).

### `AlgoSmartAssist.swift`

Added `AlgoSmartAssist.Caption` (`idm` / `choch` / `bos` / `sweep` / `mid` /
`pdh` / `pdl`) and replaced the inline string literals. The indicator
flattens BOS, CHoCH, IDM and sweep lines into one `lines` array, so the
strategy can only tell them apart by caption — that coupling should not be
stringly-typed on both sides.

## Decisions

- **Direction is HTF-only.** The radar will show all longs or all shorts, not
  both, because the strategy's step 1 defines direction from HTF context. This
  is a deliberate behaviour change from the old both-sides radar.
- **The grab is gated on the HTF context bar mapped into LTF space**, not on
  the newest LTF structure event. First implementation used the latter and
  produced almost no setups: within one leg the indicator prints
  BOS → IDM sweep → BOS, so gating on the newest LTF BOS discards the very
  sweep that qualifies the setup. `scan` therefore takes `htfFactor`.
- **Stop buffer** is `max(3 ticks, 0.08 × ATR)`. The strategy says "2-5
  pips/ticks", but a raw tick count means nothing across instruments with very
  different volatility, so it is floored on ATR. Documented in the test.
- **Invalidated setups are computed but not published** — a dead setup is not
  actionable, and the drawer sorts by proximity. The enum case exists so the
  status is expressible.
- HTF context is a *precondition*, so it is reported in the breakdown rather
  than scored; only the discriminating confluences carry points
  (base 40 + LTF align 10 + IDM 15 / sweep 10 + equilibrium 10 + trigger 15 +
  fresh zone 10, capped at 100).

## Tests — `GoldMonitorMacTests/SMCSentinelEngineTests.swift` (14 new)

The indicator is path-dependent (structure builds bar by bar from index 0), so
hand-authoring a series that lands on one exact setup is brittle. The suite is
split:

- **Exact** assertions on the pure helpers: tick size, ATR-floored stop
  buffer, caption filtering, major-swing selection, and the trigger rules
  (SCOB must *close* inside the POI; wrong-polarity SCOBs and pre-grab
  triggers are ignored).
- **Invariants** over generated markets (10 seeds × 2 directions × 5 end
  phases): whatever setups come out, each must follow the HTF context
  direction, mitigate a POI on the correct side of equilibrium, place the stop
  beyond the zone, run TP1/TP2 the right way with ≥1R, be backed by a grab,
  carry a trigger if ACTIVE, and have a score equal to the sum of its
  published breakdown. The test asserts it is **not vacuous**, which caught
  two real problems.

Building that generator was itself informative: a smooth random walk produces
**zero** order blocks, because the indicator's POI detection needs a genuine
imbalance (`low[i-3] > high[i-1]`). The generator had to be given explicit
3-bar impulse legs before any zone appeared, and then rebalanced so pullbacks
actually retest those zones — with impulses too large, price never returns and
every setup is correctly rejected as "already gone".

## Verification

`xcodegen generate` → `xcodebuild build` → **BUILD SUCCEEDED** (macOS).
`xcodebuild test` → **112 tests, 0 failures**.

### Known issues not caused by this work

- **iPad target does not build.** `OscillatorPanel.swift:487,660` reference
  `ChartView`, which is excluded from the iPad target. Those lines are in
  committed `HEAD`, not in the uncommitted diff — pre-existing breakage from
  earlier WIP. The Mac target is unaffected.
- **`RenkoTests.testRenkoConfigRawValueEncodingAndEquality` is flaky** (1 fail
  in 6 runs), not fixed. `RenkoConfig` is both `Equatable` and
  `RawRepresentable`, so the stdlib `RawRepresentable ==` shadows the
  memberwise one and equality compares *encoded JSON strings*; `JSONEncoder`
  key order varies per process. Filed as its own task earlier today; the fix
  is an explicit structural `==`.

## Follow-up: chart lag with the indicator on

Reported after the rewrite: the chart is laggy whenever ALGOSMART ASSIST is
active. Measured rather than guessed — `AlgoSmartAssist.calculate` over a
synthetic series at default UI params:

| bars | calc | marks | of which `.annotation` SwiftUI views |
|------|------|-------|--------------------------------------|
| 500  | 2.1 ms  | 228  | 50  |
| 1000 | 5.4 ms  | 462  | 104 |
| 2000 | 15.5 ms | 866  | 166 |
| 3000 | 28.5 ms | 1094 | 232 |

Two independent causes, both fixed:

1. **No viewport culling** (the dominant one). `algoSmartAssistMarks` emitted
   marks for the *entire* series regardless of the visible domain, and Swift
   Charts lays out every mark it is handed on every pan/zoom frame. With the
   default 180-bar window over 3k bars that is ~95% wasted work. The file
   already had the idiom for this (`guard bx >= domain.lowerBound - 1 …` in
   `newsMarkers`); this indicator simply never used it.

   Added `AlgoSmartAssist.Output.culled(loBar:hiBar:barCount:lastIndex:labelBudget:)`
   — put on the model rather than in the view so it is unit-testable — and the
   renderer now calls it with the current `effectiveXDomain`. Labels get an
   extra density cap (80) because each one hosts a real SwiftUI view via
   `.annotation`; past the cap they are evenly strided, not truncated, so
   survivors stay spread across the window. `liveLines` are never culled —
   they are anchored to the right edge, which is the point of them.

   Result, trailing 180-bar window: 1000 bars 462 → 116 marks (104 → 22
   annotated); 3000 bars 1094 → 131 marks (232 → 21). The cost now scales with
   the viewport instead of with history depth.

2. **Recompute on every live tick.** `AlgoSmartAssistSig` keyed on the trailing
   bar's close/high/low, so each 1 Hz rewrite of the forming bar re-ran the
   full ~28 ms pass on the main thread during view update. Every comparable
   structural engine in the cache (`OBSig`, `SonarlabOBSig`,
   `EnhancedSonarlabOBSig`) deliberately keys on count + firstTS + params for
   exactly this reason. Aligned it with them. Visible effect: BOS/CHoCH now
   confirm on bar close rather than intra-bar — which is how the Pine script's
   own structure rules read anyway (`close > lastH`, not `high > lastH`).

Guarded by 6 tests in `GoldMonitorMacTests/AlgoSmartAssistCullingTests.swift`:
the cull must drop most marks on a default window, every survivor must really
overlap the window, live lines must survive, the label budget must be enforced
*and* strided rather than truncated, culling must be a no-op when everything
fits, and empty output must be safe.

## Unfinished

- The drawer is still Mac single-chart only (grid panes and iPad have no
  sentinel UI) — same coverage as before this change.
- Not verified interactively against live data; build + unit tests only.
- `SMCSentinelEngine.scan` re-runs `AlgoSmartAssist.calculate` on both series
  per scan rather than sharing `ChartDerivedCache`'s memoised LTF result. It
  runs detached at ≤1 scan / 3 s, so it has not been a problem, but the two
  now compute the same thing twice with different params.
