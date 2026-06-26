# Confluence Trade Scanner (CTS) — Improvement Plan

> Working plan to make the Confluence Trade Scanner reliable + reproducible.
> Pick up from the unchecked boxes. Each task lists the file(s), the change,
> and how to verify it.

## Guiding principle

An LLM scanner's quality is capped by (a) the data we feed it and (b) how
much *detection* and *scoring* we offload to the model instead of doing in
code. "Perfect" = move **detection** and **scoring** into deterministic
Swift, and leave the model to **rank, narrate, and judge edge cases**.

## Current pipeline (as of this plan)

- **Kind**: `AnalysisKind.confluenceScanner` (raw value `"betaTSA"`).
- **Stage 1** (`systemConfluenceScanner`, PromptBuilder.swift:290) — Supply &
  Demand only. Emits `SUPPLY_DEMAND_JSON`, `SCENARIO_JSON` (main),
  `ALT_SCENARIO_JSON` (alt).
- **Stage 2 / Expand** (`systemConfluenceScannerExpand`, PromptBuilder.swift:380)
  — user-triggered. Adds market structure + scores every scenario 1–10.
  Emits `SCENARIOS_JSON`.
- **User prompts**: `userPromptConfluenceScanner` (916),
  `userPromptConfluenceScannerExpand` (996). Both bundle 60 bars × {15m,1h,4h}
  via `mtfSections` (675).
- **Per-bar serialization**: `ohlcLine` (582) — timestamp + OHLCV, **no bar
  index**.
- **Indicators**: per-TF aggregate `MarketSnapshot.compute` (MarketSnapshot.swift:45),
  not per-bar.
- **Parsers**: `parseScoredScenarios` (1204), `parseSupplyDemandZones`,
  `parseTAScenario`/`parseTAAltScenario`.
- **Store flow**: `runConfluenceScanner` (AnalysisStore.swift:529),
  `runConfluenceScannerExpand` (562), expand marker `<!--helix-expand-mark-->`.
- **Auto-trader**: queues `ScoredScenario` by score, falls through on
  invalidation (currently SL touch only — `invalidated_when` is free text).

---

## P0 — correctness bugs that silently mislead (do first, low risk)

- [ ] **P0.1 — Emit bar indices in OHLC lines.**
  - File: `GoldMonitorMac/AI/PromptBuilder.swift` — `ohlcLine` (582),
    `mtfSections` (675).
  - Change: prefix each line with an explicit signed offset index, e.g.
    `[-59] 2026-05-29T… O=… H=… L=… C=…`, where the latest bar is `[-1]`
    (matches the chart's negative-offset overlay convention). Update both
    CTS system prompts to say "use these exact bar indices for
    `barStart`/`barEnd`."
  - Why: model currently *guesses* `barStart`/`barEnd` by counting list
    position → zones render at the wrong X on the chart.
  - Verify: run a scanner, confirm `SUPPLY_DEMAND_JSON` indices line up with
    the bars the prose describes; zones land on the right candles.

- [ ] **P0.2 — Validate trade geometry in the parsers.**
  - File: `PromptBuilder.swift` — `parseScoredScenarios` (1204),
    `parseTAScenario`/`parseTAAltScenario`.
  - Change: drop any scenario that violates `tp > entry > sl` (long) /
    `sl > entry > tp` (short), or where entry is > N×ATR from last close
    (hallucination guard). Need last-close + ATR threaded into the parser or
    a post-filter step in `recordCompletion`.
  - Verify: feed a deliberately malformed `SCENARIOS_JSON` (e.g. long with
    tp < entry) and confirm it's dropped, not queued.

- [ ] **P0.3 — Enforce an R:R floor.**
  - File: `PromptBuilder.swift` parsers + scoring rubric text (Expand prompt
    413–421); profile minimum from `StrategyProfile`.
  - Change: compute `R:R = |tp-entry| / |entry-sl|`; hard-filter rows below
    the profile's minimum R:R, and add R:R to the rubric so the model
    self-selects. Surface R:R in the ranked-scenario card.
  - Verify: scenarios under the floor never reach the auto-trader queue.

## P1 — the big lever: detection + scoring in code

- [ ] **P1.4 — Precompute S&D zone *candidates* in Swift.**
  - New: a `SupplyDemandDetector` (e.g. `GoldMonitorMac/AI/` or
    `Features/Dashboard/Indicators`-adjacent) implementing the prose algo:
    impulse = body ≥ 1.5×ATR(14); walk back 1–3 base candles; band =
    [low,high] of base; tag demand/supply, strength, fresh.
  - Change: pass candidate zones (with **real bar indices**) into
    `userPromptConfluenceScanner`; flip the model's job from "find zones" to
    "rank these + explain." Model may add/discard with justification.
  - Why: makes overlays **reproducible run-to-run** and fixes P0.1 for free.
  - Verify: same bars → same zones across repeated runs.

- [ ] **P1.5 — Feed precomputed confluence flags for scoring.**
  - File: detector output + `MarketSnapshot`.
  - Change: per candidate, compute booleans the rubric needs — RSI aligns
    with bias, EMA50/200 trend direction, FVG present, S/R touch count,
    freshness, cross-TF nesting (1h zone inside 4h zone). Pass as structured
    flags so scoring is mechanical + auditable, not vibes.
  - Verify: score is explainable from the flags; identical inputs → identical
    scores.

- [ ] **P1.6 — Pass precomputed swing highs/lows + clustered S/R levels.**
  - Reuse SR detection logic (whatever feeds `parseSRLevels` / the S/R kind).
  - Change: supply swing points + multi-touch levels to both CTS stages
    instead of asking the model to rediscover them from 60 bars.
  - Verify: structure scenarios reference the supplied levels, not invented
    ones.

## P2 — flow, cost, feedback loop

- [ ] **P2.7 — Single authoritative scored list.**
  - Stage 1 main/alt vs Stage 2 `SCENARIOS_JSON` can disagree. Decide: fold
    scoring into Stage 1, OR make Stage 2 explicitly supersede Stage 1 for the
    auto-trader. One source of truth.

- [ ] **P2.8 — Slim the Expand prompt.**
  - File: `userPromptConfluenceScannerExpand` (996).
  - Change: pass Stage 1's *structured JSON* (zones + scenarios) instead of
    the full markdown report. Cheaper; model builds on data not prose.

- [ ] **P2.9 — Structured `invalidated_when`.**
  - File: `ScoredScenario` (1178), `parseScoredScenarios` (1204), auto-trader.
  - Change: `{price, tf, condition}` instead of free text, so the fallback
    queue triggers programmatically (not only on SL touch).

- [ ] **P2.10 — Close the loop with outcome stats.**
  - You already persist `Outcome` (hitTP/hitSL) on `HistoryEntry`.
  - Change: surface per-type, per-score-bucket win rate; feed it back via
    `PromptBuilder.PriorRunHint` (933) so the model self-corrects. This is the
    only way to *measure* "perfect" — without it the rubric is tuned blind.

## Data-quality checks (cross-cutting)

- [ ] Confirm volume is populated for CTS timeframes (Yahoo XAU/USD volume is
  unreliable). If not, drop the "−1 thin volume" rubric line — it's noise.
- [ ] Stale-data guard: warn if the latest bar is old (market closed / fetch
  stalled) before running a scan.

## Suggested order

1. P0.1 → P0.2 → P0.3 (one pass, immediately verifiable).
2. P1.4 (algorithmic zones) — biggest single quality jump; subsumes P0.1.
3. P1.5, P1.6 (mechanical scoring + supplied levels).
4. P2.7 / P2.8 (flow + cost).
5. P2.9 / P2.10 (auto-trader loop + measurement).

## Acceptance / "done" signals

- Zones land on the correct candles on the chart, every run.
- Re-running on identical bars yields identical zones + scores.
- No scenario with bad geometry or sub-floor R:R ever reaches the queue.
- Per-type win rate is visible and trending the rubric toward profit.
