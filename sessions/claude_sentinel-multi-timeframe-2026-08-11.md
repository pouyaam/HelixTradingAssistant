# Session: claude / sentinel-multi-timeframe-2026-08-11
Date: 2026-08-11
Project: Helix Trading Assistant

## Summary

The SMC Sentinel Radar now scans a **set** of timeframes at once instead
of only whatever the chart is showing. Rows from every scanned timeframe
land in one list, each tagged with a TF badge and filterable by a TF chip.
Selection persists across launches; the default (`[]` = follow the chart)
is exactly the old behaviour.

Getting there required fixing four separate correctness bugs in the
HTF-context path, all of which were also wrong on the MCP and Smart-Money-
Desk paths. macOS builds clean with no new warnings; the full suite is
**281 tests, 0 failures** (was 265).

Not visually confirmed on the running app — see "Unfinished".

## The bugs this fixes

The sentinel built its HTF context by folding the *chart's* candles, and
the fold was broken three ways plus one in the engine:

1. **Index-based fold.** `aggregateCandles` sliced
   `candles[i..<i+factor]` from array index 0. Infinite-scroll history
   paging **prepends** bars, so every HTF bar shifted and the radar's
   traded direction could flip. A previous session fixed this; the
   2026-08-02 SMC rewrite reintroduced it. Now bucketed on
   `floor(ts / tfSeconds)`, and `testFoldIsInvariantUnderPrependedHistory`
   is the regression test the old fix lacked.
2. **`30m → 4h` with factor 4** — 2h bars labelled 4h.
3. **`d1` fell through to `default: (4, "1h")`** — a daily chart got
   4-day bars labelled "1h" as its *higher* timeframe.
4. **`context.bar * htfFactor`** in `SMCSentinelEngine.scan` assumed HTF
   bar 0 aligns with LTF bar 0. True for a fold-from-index-0 series,
   false for any independently loaded one — so it was **already wrong**
   for `MCPToolbox` and `AnalysisStore`, which both pass real DB-loaded
   HTF candles. Replaced with a date lookup, and `htfFactor` is gone
   from the whole call chain (net deletion).

## What changed

### `Models/Candle.swift` — one ladder

`Timeframe.higher: Timeframe?`, roughly the 4× ladder traders layer
(15m → 1h → 4h → 1d), with the sub-5m steps jumping further so a 1m entry
isn't contextualised by 5m noise. `nil` for `.d1` — no weekly bars are
stored, so callers fall back to the daily's own read.

Three hand-maintained copies deleted and pointed here:
`AnalysisPage.higherTimeframe(above:)`, `MCPToolbox.higherTimeframe(above:)`
(its comment already admitted it mirrored the first), and
`StrategySentinel.getHTFInfo`. Two intended behaviour changes: a **5m**
chart's context is 30m rather than 1h, and **1d** now has no HTF at all.

### `AI/SMCSentinelEngine.swift` — map the context bar by date

`htfFactor` dropped. The context bar's `Date` is taken from
`htfCandles[context.bar].id` and binary-searched into the LTF series via
`firstBar(in:atOrAfter:)`. `StructureLine.endBar` is a plain index into
the array handed to `calculate`, so the date is always recoverable. The
`htf == nil` branch stays — that context is already in LTF space.

Ripples: `SMCEvidence.build`, `AnalysisStore`'s factor computation,
`MCPToolbox.HTFSeries.factor`, four test call sites.

### `AI/StrategySentinel.swift` — keyed by pair *and* timeframe

`activeRadarAlerts` and `marketContext` were keyed by `pairID` alone, so a
second timeframe on the same pair overwrote the first. The backing store
is now `[String: [RadarAlert]]` keyed `"pairID|tf"` (`scanKey(_:_:)`), with
`activeRadarAlerts` kept as a flattened projection so every existing
consumer still compiles. Accessors: `alerts(pairID:timeframe:)`,
`marketContext(pairID:timeframe:)`.

**One entry point.** `scan(pairID:symbol:chartTimeframe:chartCandles:
respectsWeekend:until:)` prunes, evaluates the chart's timeframe from the
in-memory candles, and kicks off the auxiliary ones. `DashboardView` calls
this from both former `evaluateSymbol` sites.

**Auxiliary timeframes** load their own candles via
`OHLCCandleLoader.loadAsync` — the same call `reloadHTFChoch` and
`reloadExternalEBP` already use for a foreign timeframe, which folds
15m/30m/4h from the stored 5m/1h series itself. Bounded by a per-key 30s
floor, a per-key in-flight guard, `maxScanBars = 600`, and a per-TF
`since` window (`windowStart(before:tf:)`).

**HTF context** for the chart's own timeframe comes from a 60s-TTL cache
so the 1 Hz chart path doesn't take a DB read every pass; while the first
read is in flight it returns `[]` and `evaluateSymbol` falls back to the
wall-clock fold.

Things the multi-key store forced, each of which was a latent bug:

- **Per-key throttle.** The 3-second throttle was three scalar fields —
  one shared slot, so scanning N timeframes would have each starve the
  rest. Now `[String: (key:, at:)]`.
- **Per-key publish stamp.** Auxiliary loads complete out of order; a
  stale result would clobber a newer one. `publishedStamp[key]` drops any
  result older than what that key already published.
- **Geometry-seeded alert ids.** The seed included `zoneID`, which carries
  a **bar index** — it churns every time the sliding window moves, which
  resets the drawer's hover and expanded-accordion state under the user's
  cursor. Seeds off zone top/bottom now.
- **A real hash.** `deterministicUUID` was a byte-XOR fold that collided
  on any two same-length seeds with characters swapped 16 apart — exactly
  what near-identical zone prices look like. Now 4-lane FNV-1a.
- **Silent first publish.** `notifiedKeys` baselines a key on its first
  publish, so ticking "4h" on doesn't fire a burst of notifications for
  setups that have been resting there for hours. Same re-seed rule the EBP
  work used when its source timeframe changed.
- **`replay.cursor` as `until`.** The scan was reading up to `Date()`
  regardless of replay position — a look-ahead hole in backtesting.

`prune(pairID:keeping:)` drops non-live keys from all five stores, and
drops `htfCache` by pair (its keys are *higher* timeframes, which need not
be in the live set, so it can't be filtered against `liveKeys`). Switching
pair prunes on the next scan; the drawer prunes synchronously on toggle so
deselection reads as instant.

`scanTimeframes: Set<Timeframe>` persists through a UserDefaults `didSet`
under `sentinel.scanTimeframes.v1` (non-View state, per AGENTS.md).

### `UI/SentinelRadarDrawer.swift` — pick them, then filter by them

The panel is pinned to 300pt, so the controls are frugal:

- **TF picker** — a multi-select `Menu` in the filter row beside the score
  menu. A `Menu` rather than a pill row for the reason `TimeframeSelector`
  records: pills "devoured horizontal space". The chart's timeframe is
  always scanned, so its row shows pinned and non-interactive. Label reads
  `TF · 3` or `TF · CHART`.
- **TF filter chips** — rendered only once more than one timeframe is in
  play, with an `ALL` chip.
- **Row badge** — `alert.timeframe` was only in the detail popover. Now a
  capsule beside the direction pill, tinted when it isn't the chart's TF.
  With that badge present the flat nearest-entry-first sort stays as-is.
- **Context header** carries a TF badge, since there is one context per
  scanned timeframe and the header shows one.
- **Empty state** lists one blocker line per scanned timeframe
  (`4h · no liquidity grab`) so an empty radar still explains itself.
- `badgeCount` follows `symbolAlerts`, which honours the TF filter — the
  badge always equals what is in the list.
- Two strandings handled: removing the timeframe the list is filtered to
  clears the filter, and so does moving the chart's timeframe out from
  under it.

`focusOnRadarAlert` switches the chart to the alert's timeframe first.
Selection otherwise needed no work — it runs off prices, not bar indices,
so a 4h alert draws correctly on a 15m chart.

## Tests

`GoldMonitorMacTests/SentinelMultiTimeframeTests.swift`, 16 tests, all
against pure statics so none needs GRDB or the main actor (`scanKey`,
`liveKeys`, `aggregateCandles`, `windowStart`, `deterministicUUID`,
`maxScanBars` are `nonisolated`):

- Ladder is strictly coarser at every rung and terminates from every rung.
- Fold is invariant under prepended history — the regression test for bug 1.
- Fold buckets snap to wall clock from a mid-hour start; OHLCV is
  preserved within a bucket.
- Scan keys separate timeframes on one pair; `liveKeys` covers exactly the
  selection, empties without a pair, and drops a deselected timeframe.
- `windowStart` clears `maxScanBars` for every timeframe.
- Alert ids are stable, timeframe-scoped, collision-free across 600
  adjacent zone prices, and valid v4 UUIDs.
- Context mapping on a misaligned HTF series (starting 30h before the LTF
  series, as a real DB read does) plus both clamp ends — bug 4.

Updated: four `htfFactor:` call sites in `SMCSentinelEngineTests`;
`SentinelVerifyDebugTests` lost its stale `htfName`/`htfFactor` ladder,
its private `aggregateCandles` copy, and its `tfSecs` duplicate of
`Timeframe.seconds`.

## Unfinished

- **Not run in the UI.** The picker, chips, badges and per-TF blocker
  lines compile and the logic is unit-tested, but nothing here has been
  seen on screen. Worth doing manually: 15m chart, select 15m + 1h + 4h,
  confirm three distinct badges, chips filter, deselect removes rows
  immediately, pair switch clears the lot. Cross-check one 4h row against
  `smc_brief(symbol:, timeframe: "4h")` from the helix-trading MCP server
  — same engine, so entry/SL/TP should agree.
- **Cross-TF duplicate setups.** The same POI found on 1h and 4h produces
  two rows with distinct ids. That is arguably correct (different context,
  different invalidation) but it is a product call nobody has made.
- **Auxiliary scans are driven by the chart's bar count.** A timeframe
  whose bar closes while the chart is quiet waits for the next chart tick.
  In practice `refreshTrailingCandles` runs at 1 Hz so this is bounded by
  the 30s per-key floor, not by chart activity.
- **iPad target** untouched — it does not build on `main` and has no radar
  drawer.
- `SentinelSignalRepo` still has no callers and its `v3_sentinel_signal`
  migration is still unregistered in `Schema.swift`. Persisting the radar
  across launches remains separate work.

## Pre-existing warnings, deliberately left

`NotificationInbox.swift:173` (main-actor `defaultCooldown` from a
nonisolated context) and `DashboardView.swift:2129`
(`indicatorLegendOverlay` disables its `ViewBuilder` with an explicit
`return`). Neither is touched by this work.
