# Previous Day indicator — PDH/PDL + previous-session volume profile (2026-08-02)

## Request

An indicator marking the previous day's high and low, plus that day's volume
profile drawn on the right side of the chart showing POC / high / low, with
settings to enable or disable every option.

## What was added

`IndicatorKind.previousDay` — "Previous Day (PDH/PDL + VP)".

Nothing new was invented where the codebase already had machinery:

- `VolumeProfile.buildCore` (histogram + POC + value area) is `private` to
  `VolumeProfile.swift`, so the new computation lives in that file next to
  `compute` / `computeLastTrend` / `computeVisibleRange` rather than in a new
  file that would have needed the internals opened up.
- Rendering reuses `vpHistogramMarks` (the right-margin two-tone histogram)
  and `vpTPONote`, the same helpers the visible-range and ZigZag profiles use.

### Engine — `GoldMonitorMac/Features/Dashboard/VolumeProfile.swift`

- `PreviousDayVP` — startBar/endBar, high/low (+ the bars that printed them),
  open/close, computed `mid`, and the full profile (buckets, bucketSize,
  poc/vah/val and their indices, hasRealVolume).
- `computePreviousDay(_:bucketCount:valueAreaPct:)` — profiles the last
  **completed** session. Returns `nil` when the series spans fewer than two
  sessions; inventing a PDH/PDL out of a partial session would put a level on
  the chart that never existed.
- `sessionRanges(_:)` — extracted the trading-day splitting that `compute`
  did inline, so both paths agree on exactly where a session begins (the
  18:00 ET boundary in `tradingDayStart`). `compute` now calls it, which
  deleted its duplicate copy.

The previous day is settled by definition, so `startBar`/`endBar` and the
levels never move intraday — which is the entire point of trading against
them.

### Cache — `ChartDerivedCache.previousDayVP`

Keyed on bar identity + bucketCount + valueAreaPct, with no trailing OHLC,
matching the convention the other structural engines use. A settled session
cannot change until a new bar arrives, so re-deriving it on every live tick
would be pure waste.

### Rendering — `ChartView.previousDayMarks`

PDH / PDL / mid / open / close as horizontal rules (optionally extended to
the right edge), the previous session's histogram in the right margin, and
POC / VAH / VAL levels. Inserted after `algoSmartAssistMarks` in the stack.

### Settings — every element individually switchable

`showPDH`, `showPDL`, `showMid`, `showOpenClose`, `extendRight`,
`showLevelLabels`, `showProfile`, `showPOC`, `showValueArea`,
`extendProfileLevels`, `highlightSession`, plus `bucketCount` (10–100),
`valueAreaPct` (50–95) and `profileWidth` (4–45% of the visible view).

Params are read directly off the indicator instance (the newer
`algoSmartAssist` pattern) rather than being plumbed through
`oscillatorConfig`, so the indicator is self-contained. All five indicator
menus iterate `IndicatorKind.allCases`, so it appears with no menu wiring.

## Tests

`GoldMonitorMacTests/PreviousDayVPTests.swift` — 14 tests. The ones that
matter most:

- `testUsesPreviousSessionNotTheOneInProgress` — today spikes to 500/10 and
  is ignored; PDH/PDL come from yesterday's 130/70.
- `testBucketVolumeSumsToTheSessionVolumeOnly` — today's volume must not leak
  into the profile.
- `testAgreesWithSessionProfileBounds` — guards the `sessionRanges`
  refactor: `compute`'s session bounds still match the previous-day path.
- Plus nil-guards, high/low bar indices, POC/value-area containment,
  up/down split, TPO fallback, and bucket count.

**135 tests, 0 failures.** macOS build clean.

## Drive-by

`OscillatorPanel.swift` called `ChartView.priceExact` / `ChartView.priceShort`,
but `ChartView.swift` is excluded from the iPad target (`project.yml:113`), so
those two lines broke the iPad build. Swapped to `PriceFormat.exact` /
`PriceFormat.short`, which are byte-for-byte identical implementations in a
file the iPad target does compile. Zero behaviour change.

## Not done — iPad target is broken on `main` (pre-existing)

Building `HelixTradingAppiPad` to check this change was iPad-safe surfaced
breakage that landed with PR #5 and is unrelated to this work:

- `ChartViewiPad.swift` references `indicatorInstances`, which it has no
  property for (helixOBCombo, algoSmartAssist, enhancedSonarlabOrderBlock).
- `ChartViewiPad.swift:4315` — missing `enhancedSonarlabOBZones` argument.
- `DashboardViewiPad.swift:735` — `renkoConfig` not in scope.

None of the errors mention `previousDay`; the Mac-side work simply outran the
iPad target again. It needs `indicatorInstances` plumbing on `ChartViewiPad`
and a renko config on `DashboardViewiPad` — its own task, flagged separately.
The new indicator is Mac-only for now, same coverage as AlgoSmart.
