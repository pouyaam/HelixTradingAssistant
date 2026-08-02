# ALGOSMART ASSIST v2 — presence check + Pine fidelity pass (2026-08-02)

## Ask

Confirm the "ALGOSMART ASSIST v2" indicator (PineScript v6, by Crypto Smart /
AlbaTherium & Ma Bang Chu) is in the project, and read the code so the Swift
port matches the original exactly.

## Findings

Already present and fully wired — no new integration needed:

- `GoldMonitorMac/Features/Dashboard/AlgoSmartAssist.swift` — the port.
- `Indicators.swift:176` `case algoSmartAssist`, display name at :208,
  accent colour at :240, param schema at :574.
- `ChartDerivedCache.swift:830-855` — memoised slot with a
  count/first-ts/last-ts/last-OHLC/params signature.
- `ChartView.swift:541` output accessor, `:894` mark inclusion,
  `:5641` `algoSmartAssistMarks` renderer.
- `project.yml` globs the `GoldMonitorMac` folder, so the file needs no
  explicit spec entry.

The port was structurally faithful — including Pine's own quirks, which are
deliberately preserved:

- `if findIDM and isCocUp and isCocUp` (duplicated condition in the source)
  is ported as `findIDM && isCocUp`, matching the source's actual behaviour
  rather than the probably-intended `isBosUp`.
- `processZones` breaker branches use `continue` + explicit removal; that is
  equivalent to Pine, where the breaker branch does not delete but the
  subsequent delete check always catches the same bar.
- `maxBarHistory` compared in bar counts is equivalent to Pine's
  `time - leftZone > len*maxBarHistory` with `len = curTf*1000`.

## Divergences found and fixed

1. **`handleZone` containment check used the wrong zone.** Pine captures
   `topZone`/`botZone` from the previous last zone once, up front, and keeps
   using those values for `if not (_top <= topZone and _bot >= botZone)` even
   after the zone was merged away. The port re-read `zones.last`, which after
   a merge is a *different, older* zone — so a valid new order block could be
   suppressed. Now captured in one `if let` block.

2. **Live CHoCH was drawn only in a down leg.** Pine calls
   `drawLiveStrc(showliveChoch, not isCocUp, ...)` — the second argument is
   the *trend*, not a gate; the line always draws when enabled. In an up leg
   it should sit on `lastL` (the downside invalidation level). The port
   skipped it entirely when `isCocUp`, hiding that level, and also inverted
   the label colour (Pine: `trend ? bull : bear` with `trend = not isCocUp`).

3. **IDM caption never turned red.** Pine's `drawIDM` sets
   `colorText = trend and H_lastH > L_lastHH or not trend and H_lastLL > L_lastL
   ? color.red : colorIDM`. `L_lastHH` / `H_lastLL` were computed but unused.
   Added `StructureLabel.isWarning`, honoured in `algoSmartAssistLabelView`.

4. **IDM label sat on the wrong side.** Pine uses
   `style = getStyleLabel(not trend)`; the port passed `isBullish: trend`,
   which the renderer maps to annotation position. Now `!trend`.

5. **The five `leng*` extension inputs were missing.** `lengPdhl`, `lengMid`,
   `lengBos`, `lengChoch`, `lengIDM` are Pine inputs; the renderer hardcoded
   `lastIndex + 30` for every live line. Added `LiveLine.extendBars`, wired
   the params through `Indicators.swift`, and used it in `ChartView.swift`.

6. **PDH/PDL lines started at a fixed offset.** Pine's `getPdhlBar` scans back
   to the bar that actually printed the level. Added `pdhlBar(candles:value:isHigh:)`,
   falling back to `lastIdx - lengPdhl` when no match is found.

`calculatePDHL` remains a calendar-day approximation of
`request.security(syminfo.tickerid, 'D', [high[1], low[1]])` — acceptable on
intraday timeframes, which is where this indicator is used.

## Verification

`xcodegen generate` + `xcodebuild ... build` → **BUILD SUCCEEDED**.

`xcodebuild ... test` → 98 tests, 1 failure:
`RenkoTests.testRenkoConfigRawValueEncodingAndEquality()`. **Pre-existing and
unrelated** to this work (touches only `Models/Renko.swift`, which this session
did not modify). Root cause identified: `RenkoConfig` is both `Equatable` and
`RawRepresentable`, so the stdlib `RawRepresentable ==` shadows the synthesized
memberwise one and equality compares encoded JSON *strings*; `JSONEncoder` key
order is not stable, so identical configs can compare unequal. Filed as a
separate task rather than fixed here — it also means Renko config diffing
(AppStorage / SwiftUI) can spuriously report changes.

## Files touched

- `GoldMonitorMac/Features/Dashboard/AlgoSmartAssist.swift`
- `GoldMonitorMac/Features/Dashboard/Indicators.swift` (AlgoSmart params only)
- `GoldMonitorMac/Features/Dashboard/ChartView.swift` (AlgoSmart renderer only)
