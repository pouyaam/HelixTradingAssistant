# Strategy Sentinel — full signal-quality overhaul (2026-07-30)

## Summary

The user reported the Strategy Sentinel "doesn't produce good signals."
A code read confirmed the core problems: ranking degenerated to zone
size when volume was missing (gold!), evaluation ran on the live
unclosed bar, HTF aggregation repainted and was mislabeled, the score
ignored the OB engines' own grades and could hit the ≥70 notification
floor on volume rank alone, reaction setups staged stale entries, and
nothing was persisted so no win-rate feedback was possible.

Implemented the full improvement set in three stages: engine core
rework, GRDB persistence + outcome tracking, background multi-pair
scanning + drawer UI. 104 unit tests pass (19 new); macOS + iPad
targets build clean.

## Changes Made

### Stage 1 — engine core (`GoldMonitorMac/AI/StrategySentinel.swift`)

- **Closed bars only**: forming bar dropped via new `tfSeconds(_:)`;
  ≥60 closed-bar minimum; `currentPrice` = last closed close.
- **Honest volume**: `volumeIsReliable` (≥50% of the 200-bar window has
  volume). Reliable → `computeTradedVolume` allocates by overlap
  fraction (wide zones no longer win by size). Unreliable →
  `tradedVolume`/`volumeRank` = nil, "Vol n/a", no rank bonus, sort by
  grade → HTF-nested → narrower zone. No more `1.0`-per-candle
  fabrication.
- **Grades in the score**: `gradeBonus` A=20/B=10/C=0/Fresh=10/
  Tested=5/ROC=5. New score:
  `min(100, 40 + grade + rank(15/10/5, reliable only) + htf(20) +
  trend(15) + target(10))` — no single factor reaches the ≥70
  notification floor (rank#1 alone = 55, grade A alone = 60).
- EMA fixed at 50 (was floating with loaded history length).
- HTF aggregation wall-clock-aligned (`floor(ts/(tfSecs·factor))`
  bucketing — history prepends no longer shift HTF zones); corrected
  factor map (30m→4h was actually 2h; 1d→1W; removed self-comparison
  fallback).
- Retest filter: touch requires candle CLOSE in zone; candles at/before
  zone formation excluded (all 4 engines expose a formation index).
- Invalidation lookback scaled to ~6h of bars (was fixed 40); reaction
  remaining-R:R floor 0.8 → 1.0.
- `RadarAlert`: + `gradeLabel`, + `isStageable` (false for reaction),
  custom `init(from:)` (decodeIfPresent) for Codable back-compat.

### Stage 2 — persistence + outcomes

- `GoldMonitorMac/Storage/Schema.swift`: migration `v3_sentinel_signal`
  (table + `(pair_id, timeframe, outcome)` index).
- `GoldMonitorMac/Storage/SentinelSignalRepo.swift`: insert-or-ignore
  (first-seen `created_at` wins), unresolved fetch, COALESCE resolve,
  stats aggregate (total / byEngine / byScoreBucket 70-79·80-89·90-100;
  expired excluded from win-rate denominator).
- `GoldMonitorMac/AI/SentinelOutcome.swift`: pure, testable state
  machine. Fill = limit touch; pre-fill SL-gap or TP-runaway → expired;
  same-candle fill+stop → loss; post-fill both-touched → loss
  (conservative); >5 days unfilled → expired. TP on the fill candle is
  not credited.
- Engine integration: `attach(database:)` (wired in both app entry
  points), persist on every publish, outcome resolution for ALL
  unresolved rows of the evaluated pair/tf (independent of the active
  alert set), stored `created_at` restored onto republished alerts
  (fixes `isFresh` always-true), `@Published signalStats`.
- `GoldMonitorMacTests/SentinelOutcomeTests.swift`: 19 tests covering
  the state machine incl. SELL mirrors.

### Stage 3 — background scan + drawer UI

- `alertsByKey: [pairID|tf → [RadarAlert]]` backing store;
  `activeRadarAlerts` is now a flattened projection (same public
  shape). Per-key throttling, per-key change detection, per-key
  notified-id sets; keys not refreshed in 15 min are pruned.
- **Background sweep** (starts in `attach`): after a 45 s boot delay,
  every 5 min sweeps `TradingPair.seed()` × ["15m","1h"] minus the
  foreground-viewed key, ≤3 series concurrently, loading ~500 closed
  bars each via `OHLCCandleLoader.loadAsync` and running the SAME
  evaluation pipeline — persistence + outcome tracking for swept pairs
  included. Notifications (score ≥ 70) now fire for background pairs;
  a key's first-ever publish baselines silently to avoid a 16-series
  boot burst.
- `SentinelRadarDrawer.swift`: win-rate strip (overall + per-engine
  chips, ≥3 resolved), THIS PAIR / ALL scope chips
  (`@AppStorage("dashboard.sentinelDrawerScope")`, ALL tags rows with
  `SYM·tf`), ON/OFF master chip bound to `isSentinelActive`, STAGE
  disabled for non-stageable reaction setups (reason in popover),
  grade badge on rows, "Vol n/a" + hidden volume filter when volume is
  unreliable, no fabricated rank medals.

## Decisions & Reasoning

- Score floor logic: every term is now a genuine confluence factor; the
  ≥70 notification floor requires at least two (e.g. grade B + HTF, or
  rank#1 + HTF + trend).
- First-publish-per-key baselines silently — judged better than a boot
  notification burst; flip by seeding `notifiedIDsByKey` if unwanted.
- Outcome machine is pure/static so it's unit-testable without GRDB;
  repo SQL is exercised at runtime only (no GRDB-level tests added).
- Background sweep reuses the foreground pipeline verbatim instead of a
  second code path; skipping the foreground key avoids clobbering the
  viewed chart's 10s-refresh cadence.

## Verification

- `./run.sh --no-launch --quiet --skip-deps` — clean.
- `xcodebuild … -scheme HelixTradingApp … test` — 104/104 pass.
- `xcodebuild … -scheme HelixTradingAppiPad … 'generic/platform=iOS
  Simulator' build` — succeeded (drawer + sentinel compile into iPad).

## Unfinished / follow-ups

- Win rates need a few weeks of live data before the stats strip means
  anything; per-engine/per-bucket thresholds can then be tuned against
  real outcomes (this was the point of persisting).
- Foreground boot no longer notifies for pre-existing high-score alerts
  on the viewed pair (baselining side effect) — intentional, see above.
- Sentinel UI remains Mac-only; the engine/storage layers compile and
  run on iPad, so surfacing the drawer there is now mostly UI work.

## Follow-up (same day): zero-signal regression — fixed

After the overhaul the radar produced NO alerts at all. Diagnosed
empirically: instrumented the pipeline with per-stage counters and ran
it via a temporary XCTest against the real local database
(`~/Library/Application Support/HelixTrading/gold.db`). Counts showed
zones were found (31 on ounce/15m) but two filters killed everything:

1. **Invalidation scanned a fixed lookback window that included bars
   from BEFORE the zone formed** — a TP tag that predates the setup
   discarded it, and origin-region bars dipping below the SL killed
   fresh zones.
2. **Every bullish zone below current price was labeled REACTION** and
   judged by market-entry remaining R:R (floor raised to 1.0), so
   healthy pending pullbacks were discarded as stale.

Fix in `runEvaluation` (invalidation/lifecycle block rewritten):

- Invalidation now scans only bars SINCE the zone's formation index
  (all four engines expose one), capped at the ~6h window for old
  zones.
- Lifecycle is three-way and correct for limit-at-edge setups:
  price below a BUY zone's bottom → **broken, skipped** (previously
  surfaced as nonsense "pending" buys above market); price beyond the
  zone, never re-entered since formation → **PENDING pullback**
  (stageable, original R:R intact); entered-then-left → **REACTION**
  (only kept while remaining R:R ≥ 1.0 and < 70% of the move done).
- A TP touch invalidates IN-ZONE/REACTION setups but NOT pending ones
  — the opposing target zones come from the OB engines' active
  (un-mitigated) sets, so a historical tag of the target doesn't kill
  a pullback limit order.

Post-fix pipeline counts on the same real data: 18 alerts on
ounce/15m, 8 on ounce/1h, 17 on btc/1h (was 0/0/0). The temporary
instrumentation and debug test were removed after verification
(104/104 tests pass, macOS + iPad builds clean).
