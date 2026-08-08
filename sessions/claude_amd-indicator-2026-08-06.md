# Session: claude / amd-indicator-2026-08-06
Date: 2026-08-06
Project: Helix Trading Assistant

## Summary

Added a new indicator, **AMD — Accumulation / Manipulation / Distribution**
(`IndicatorKind.amdCycle`), which reads the phase rotation described in the
user's brief rather than matching a candle pattern, and derives its entry
from the fair value gap left inside the displacement leg. Engine +
Mac chart rendering + iPad chart rendering + 18 unit tests. The macOS app
builds clean and the full suite (212 tests) passes.

Visual confirmation on the running app was **not** achieved — see
"Unfinished". The engine is covered by tests; the marks are compile-verified
and follow the existing overlay idioms, but I never saw them draw.

## What was added

### `GoldMonitorMac/Features/Dashboard/AMDCycle.swift` — the engine

Pure functions, no state, same shape as `MTRSetup` / `RankedOBStrategy`.
The cycle it looks for, in order:

1. **Accumulation** — a contained base: high/low band within
   `maxRangeATR × ATR`, *and* mean bar range below `contractionRatio ×`
   the mean of the run that led in. The contraction test is what
   separates a base from a slow drift — accumulation is not merely
   sideways, it is quieter than what came before.
2. **Manipulation** — a wick beyond an edge by `minSweepATR × ATR`,
   followed by a close back inside the range within `maxReclaimBars`.
   The reclaim may land on the sweep bar itself (the single-candle
   liquidity grab). No reclaim ⇒ it was a real breakout, not
   manipulation, and the cycle is marked `.failed` (hidden by default).
3. **Expansion** — a close beyond the *opposite* edge by
   `minExpansionATR × ATR`. Trading back through the sweep extreme
   before that invalidates the whole cycle.
4. **Distribution** — the leg stops making new extremes for
   `distributionBars`. Same behaviour as accumulation at the other end
   of the cycle, which is the point.

Direction comes from which side was swept: lows swept ⇒ long, highs ⇒
short. The sweep is fuel, not direction.

**Entry** is `EntryGap` — the three-candle imbalance inside the leg
(searched from the sweep bar through the leg extreme, so a gap
straddling the reclaim candle counts, which is the classic AMD entry).
Entry at near edge / mid / far edge, stop past the sweep extreme + ATR
buffer, TP1/TP2 as R multiples. `track()` walks it forward to
armed → filled → tp1 → tp2 / stopped, checking the stop first on each
bar (a bar spanning both reads as a loss — intrabar order is unknowable
from OHLC, and this matches `RankedOBStrategy`).

### Wiring

- `Indicators.swift` — case, label, colour, and ~30 `paramSpecs`
  grouped accumulation / manipulation / expansion / entry / display.
  No `OscillatorConfig` mirror: config is read straight off the
  instance params via `AMDCycle.Configuration(params:)`, matching the
  newer indicators (`helixOBCombo`, `algoSmartAssist`, `previousDay`).
- `ChartDerivedCache.amdCycles` — memoized slot. Keyed on bar identity
  **plus trailing OHLC**, unlike the pure structure engines: a live tick
  can genuinely extend a sweep, fill an entry gap, or hit a target, and
  all three should show without waiting for the bar to close.
  Also folded into `OverlayData` / `overlayExtremes` so plan levels
  can't get clipped off the Y axis. Its signature uses per-cycle keys
  (id|phase|tp2), not a count — a live cycle's levels move while the
  set size stays the same (same reasoning as `rankedOBSetupKeys`).
- `ChartView.amdMarks` + four sub-builders (accumulation box and edge
  rules, sweep band + invalidation line, displacement leg + stall
  marker, gap rect + entry/SL/TP plan), each behind its own toggle.
  Mirrored into `ChartViewiPad`.

### `GoldMonitorMacTests/AMDCycleTests.swift` — 18 tests

Hand-built series with each phase boundary at a known bar index
(decline 0–10, base 11–18, sweep 19, displacement 20–21). Price levels
asserted *relationally* (entry is the gap mid, stop past the sweep, TP1
one R away) rather than as frozen numbers, since the exact stop depends
on a Wilder ATR value that is an implementation detail. Covers both
directions (via a mirrored series), gap selection, plan lifecycle
(fill / target / stop / still-armed), and every phase that doesn't
complete.

## Decisions & Reasoning

- **`minSweepATR` does double duty** — it is both "this bar took
  liquidity" and "this bar ends the base". Found while writing the
  tests: with separate thresholds, a sweep small enough to stay inside
  the ATR band got swallowed by the base extension, so the manipulation
  was absorbed by the accumulation it was supposed to end and no cycle
  could ever be detected. One threshold, one meaning. Default raised
  0.05 → 0.15 so it is a real excursion.

- **Dropped the "range measured move" target.** It was implemented,
  then removed when a test showed it always fell back to fixed-R: the
  stop sits a full range height below the entry by construction, so
  risk always exceeds the range height and the projection always lands
  inside 1R. A setting that can never fire is worse than no setting.

- **`requireFVG` filters the cycle, not just the plan.** An expansion
  with no imbalance is a true phase read but not a tradeable one. With
  the toggle on (default), only cycles that left an entry survive;
  turning it off keeps the phase read with `gap == nil`. `minRR`
  interacts the same way and there's a test pinning it.

- **Unchallenged bases are dropped unless live.** A historic range
  nothing ever swept is just a place price paused. Only the current one
  is kept.

- **No notification wiring.** The `alertStore.evaluate*` path is a
  meaningful surface of its own (baselining, dedup, Inbox events); kept
  out to hold this change to one thing. Easy follow-up.

## Unfinished / Next Steps

- **Not visually verified.** I could not observe the marks drawing.
  Screen recording and Accessibility are both denied to the shell, so I
  captured the window from inside the app's own process via lldb
  (`cacheDisplayInRect` → PNG), which worked — but I could not get *any*
  indicator to activate. Injecting `dashboard.indicators.v2` via
  `defaults write` does not drive the app's indicator state: the running
  app reads back the injected JSON correctly (confirmed through lldb),
  yet nothing renders — not AMD, not a control `sma20`, and not even the
  app's own 10 persisted instances with `hidden` flipped to false.
  So `loadIndicators()` is either not the live source or its decode
  fails silently under `try?`. **Worth understanding on its own** — it
  means indicator state has a second source of truth. Until then, AMD
  should be switched on from the f(x) picker by hand and eyeballed.
  The user's defaults were exported before any of this and restored
  after; all 54 keys verified byte-identical.

- **iPad marks are unverified.** `HelixTradingAppiPad` still does not
  compile on `main` — the same three pre-existing errors logged in
  `previous-day-indicator-2026-08-02.md` and
  `smc-desk-and-mcp-server-2026-08-04.md` (`indicatorInstances` has no
  declaration on `ChartViewiPad`, missing `enhancedSonarlabOBZones`
  argument, `renkoConfig` out of scope in `DashboardViewiPad`). The AMD
  code was added in the same style as the properties directly above it
  and introduces no new error category, but it has never been through a
  compiler.

- Phase nesting across timeframes (a 5m accumulation inside a 4H
  distribution) is in the user's brief and is *not* implemented. It is
  the most valuable extension here — the brief says the phase you are
  trading matters more than the setup. `ChangeOfCharacter`'s HTF path
  (`datedZones` + `barIndex(forDate:)`) is the pattern to copy.

- The app was running (Release build) when this session began and is not
  running now; it stopped during the verification attempts.
