# Renko rewrite + performance — 2026-08-02

## Goal
Read the Renko code, find/fix performance issues. Escalated mid-task to a
full rewrite of the Renko engine ("the way it is implemented is wrong").

## What changed
`GoldMonitorMac/Models/Renko.swift` — rewrote `enum Renko`.

### Correctness (old bugs)
- Reversal branches mixed `currentOpen` and `currentClose` inconsistently
  and never applied the traditional one-box reversal gap, so reversal
  brick counts/positions were wrong.
- Six near-duplicate emit blocks (dir 0/±1 × cont/reversal) — fragile,
  easy to drift out of sync.

### New algorithm (canonical traditional Renko)
- Single state pair: `anchor` (close of last brick) + `direction`.
- Close price is the only trigger; high/low only feed optional wicks.
- Continuation: `floor(move/box)` bricks stepping from `anchor`.
- Reversal: needs `2×box`; one-box gap then `floor(move/box) − 1` bricks.
- One shared `emitRun(count:from:step:candle:)` closure — no per-branch
  duplication, no per-candle temporary array.

### Performance
- `computeATR`: was allocating a full `[Double]` of `n−1` true ranges just
  to average the last `period`. Now walks only the trailing `period` bars
  → O(period) time, O(1) space (was O(n)/O(n)).
- `transform`: single pass, direct append via `emitRun` (no per-candle
  `pending` allocation), `reserveCapacity(candles.count)`. Kept the
  `maxBricksPerCandle` (500) and `maxTotalBricks` (200k) guards.
- Added `box.isFinite` guard to prevent a runaway loop on a bad box size.
- Kept the public surface stable: `computeATR`, `transform`; added
  `boxSize(for:config:)`. `RenkoConfig` untouched, so the
  `ChartDerivedCache.baseDisplayCandles` call site is unchanged.

## Verification
- `xcodebuild ... build` → BUILD SUCCEEDED.
- All 5 `RenkoTests` pass (up/down/reversal/ATR/config-roundtrip).
- The earlier one-off `testRenkoConfigRawValueEncodingAndEquality`
  failure was collateral from an unrelated crash, not real — it passes
  reliably now (also verified equal in an isolated repro).

## Index-out-of-range crash (fixed)
The `Fatal error: Index out of range` (ContiguousArrayBuffer.swift:692) was
**real**, not a teardown artifact. Symbolicated the `.ips`:

    Array.subscript.getter
    closure #1 in ChartView.candleMarks(indices:)
    …Charts…
    ObservableObjectPublisher.send()
    YahooScheduler.backfilling.modify
    YahooScheduler.ensureDeepHistory(pairID:sourceTF:)
    DashboardView.warmHistoryAsync()

Root cause: `candleMarks`/`lineMarks` subscript `cs = displayCandles`, but
`indices` come from `renderIndices`, which is sized to raw `candles.count`.
When the drawn series is a **different length** — Renko bricks, or a live
backfill/replay mutating the array *mid-SwiftUI-update* (the re-entrant
"Publishing changes from within view updates" path in the trace) — `cs[i]`
runs off the end.

Fix: added `renderSafeIndices(_:count:)` (zero-alloc fast path when indices
already fit; filters only on a real mismatch) and routed both price-series
builders through it. Applied to macOS `ChartView.swift` and iPad
`ChartViewiPad.swift` (both draw Renko via `displayCandles`).

Verified: RenkoTests run 3×, no Fatal error, all green (previously the
crash fired at the end of *every* run).

## Blank Renko chart (the real bug) — fixed
After the crash fix Renko still drew *nothing*. The clamp had converted a
crash into a blank chart, and the underlying cause was the one flagged
earlier: **the X window lived in candle index space while Renko draws a
brick array.**

    effectiveXDomain = defaultDomain(count: candles.count)   // 360 candles
    renderIndices(domain: 179.5...359.5, count: 360)         // 226 indices
    clamp to brick array (12 bricks)                         // → 0 drawn

Simulated it: for bricks = 12/40/120 vs 360 candles, drawn = **0** every
time. Any series with fewer bricks than candles (i.e. the normal case)
rendered empty.

Fix (macOS `ChartView` + iPad `ChartViewiPad`):
- `drawnBarCount` = `displayCandles.count` — the series actually drawn.
  For line/candle/HA this **equals** `candles.count` (HA is 1:1, the
  live-price patch preserves length), so it is a no-op outside Renko.
- `effectiveXDomain` and `renderIndices` now measure in that space.
- `effectiveXDomain` also ignores a **pinned** window that no longer
  intersects the drawn series (`visibleBounds == nil`) and falls back to
  the default window. That self-heals a stale candle-space zoom carried
  across a chart-type/box-size switch, and covers the parent views that
  pin candle-space domains (`ChartPaneView.resetChart/scrollToLatest`,
  `DashboardView`) — no state mutation during a view update, so it can't
  reintroduce "Publishing changes from within view updates".
- iPad `resetChart()` now frames the drawn series too.
- Hover state now reads `displayCandles`, not raw `candles` — otherwise
  the tooltip reported a time-candle's OHLC at a brick index.

`renderSafeIndices` is kept as the safety net for the mid-render mutation
race (the actual crash trigger); it is a no-op now that indices are sized
correctly.

Verified **visually**: launched the app, chart type = Renko — bricks draw
with uniform body heights in a contiguous staircase, colour flipping on
reversal with the one-box gap, wicks spanning each brick's source
segment. App stays alive, no new crash report.
Regression tests added: `testRenkoBricksProduceNonEmptyRenderWindow`,
`testStaleCandleSpaceDomainIsDetectedAsNonIntersecting`. 7/7 pass.

## Shadows removed
Renko bricks were drawing wicks (the long spikes that made the chart read
as noisy candles). A brick is a **fixed price move, not a time period**,
so there is no intrabar excursion for a shadow to describe — traditional
Renko is pure boxes.

- `Renko.transform`: `high`/`low` are now the body bounds. This also
  deleted the per-candle `segHigh`/`segLow` accumulation entirely — two
  fewer min/max per candle and less state in the loop.
- `RenkoConfig.showWicks` removed (struct, init, `Storage`). A previously
  persisted payload still carries the key; `JSONDecoder` ignores unknown
  keys so existing settings keep decoding — covered by
  `testLegacyRawValueWithShowWicksStillDecodes`.
- "Show Wicks" toggle removed from `RenkoSettingsView` — a config that
  produces a non-Renko chart is a footgun.

New invariant tests: `testRenkoBricksHaveNoShadows` (high/low == body
bounds for both fixed and ATR modes, against candles with wide highs/lows)
and `testRenkoBricksAreUniformHeightAndContiguous` (every body exactly one
box; continuation opens at the previous close; reversal starts one box
off). 10/10 pass.

Verified on screen: clean boxes, no shadows. Hover tooltip on an up brick
reads O 4,032.39 / H 4,037.70 / L 4,032.39 / C 4,037.70 — high == close,
low == open.

## Known remaining Renko limitation (not a regression)
The price chart is now in brick index space, but `VolumeBarsView` and
`OscillatorPanel` still window on `candles.count`, and indicator/overlay
marks are computed on raw candles at candle indices. In Renko mode those
panels/overlays therefore don't line up with the bricks (they're plotted
off-window and clipped). Making them Renko-aware means recomputing them
on the brick series — a design decision, not a bug fix.

## Unrelated pre-existing issue (NOT touched)
`HelixTradingAppiPad` scheme fails to compile: `OscillatorPanel.swift:487`
/`:660` — "cannot find 'ChartView' in scope" (iPad target includes
OscillatorPanel but not the macOS-only ChartView). Confirmed present with
my iPad edit stashed, so it predates this work. macOS app builds clean.
