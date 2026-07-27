# Ranked Order Block notifications

**Date:** 2026-07-21

## Goal

The Ranked OB indicator rendered zones on the chart but never fired
notifications, unlike plain OB / Steroid OB / CHoCH.

## Changes

- `Features/Alerts/Alerts.swift`
  - `BlockZoneSnapshot` gained `var detail: String? = nil` — an optional
    body suffix, used here to carry the confluence grade.
  - New `evaluateRankedOrderBlocks(_:pairID:pairLabel:)`, mapping
    `RankedOrderBlocks.Zone` through the shared `evaluateBlockZones`
    diff under namespace `"rob"`, label "Ranked Order Block",
    category `.orderBlock`.
  - `notifyBlockLifecycle` appends ` · <detail>` to the body.
- `Features/Dashboard/DashboardView.swift` — `notifyOrderBlockEvents`
  gained a `rankedOrderBlockActive` branch (gated by the eye icon +
  master switch, like the others).

Both existing call sites (`reloadCandles` and the 1 Hz
`refreshTrailingCandles`) fan out to it, so zones are re-evaluated on
live ticks as well as reloads.

## Gotchas

- **`showBreakers` must be forced on for the notify computation.**
  `RankedOrderBlocks.compute` *removes* breaker zones from its result
  when `showBreakers` is false, so a zone flipping to breaker would
  silently vanish from the set rather than fire an invalidation. The
  notify path takes its own copy of the config with `showBreakers = true`
  and leaves the chart layer reading the user's real setting. This
  exactly mirrors why CHoCH forces `showMitigated: true`.
- **`.retested` can never fire for Ranked OB.** The zone model has only
  `isBreaker` — there's no "price came back and tested it" state to map
  to `.tested`. So it emits *formed* and *exhausted/invalidated* only.
  Adding a retest event would mean extending the indicator itself, not
  the alert layer.
- **The grade is deliberately NOT part of the zone key.** A zone that
  gets re-scored as price evolves is still the same zone; folding the
  grade into `stableKey` would re-fire "formed" on every re-grade.

## Known edge case (not addressed)

With `combineOverlapping` on, a merged zone's top/bottom — and therefore
its `stableKey` — depend on which zones are in the render set at the
time. If the set shifts (a new zone enters the freshest `zonesPerSide`),
a merge can resolve differently and produce a key that reads as a brand
new zone, firing a spurious "formed". Inherent to the price-range keying
the codebase deliberately chose over index keying; worth watching in the
Inbox before deciding whether it needs a fix.

## Scope

Mac only — `DashboardViewiPad` has no `notifyOrderBlockEvents` equivalent
(the iPad target has no strategy-notification fan-out at all). Both
targets build clean since `Alerts.swift` is shared.

## Unverified

Not exercised at runtime. Needs the indicator enabled with the eye icon
on, then a zone forming / breaking, to confirm the Inbox entries and the
grade suffix read correctly.
