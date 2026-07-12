# SMC Indicator Hardening — WIP

**Branch:** `codex/strengthen-smc-indicators`  
**Status:** Compiles; needs hands-on chart testing before merge.

## What changed

- CHoCH now waits for confirmed HH+HL / LL+LH structure, rejects a missing
  opposite-colour origin candle, and sends alerts for the actionable
  OB∩FVG band rather than a chart-only display union.
- Chart-derived SMC overlays invalidate on live OHLCV updates instead of
  waiting for a new candle.
- Sonarlab OB sensitivity is now compared in the same percentage unit the
  UI displays.
- Standard OBs now require a directional majority, ATR-sized displacement,
  and a break of recent structure; labels show a `Q` quality score.
- Steroid OBs require both prior relative-volume confirmation and an HVN
  overlap. Profiles use only data available at the block confirmation bar,
  so qualification does not repaint with future candles. Missing volume no
  longer fabricates a Steroid validation.

## Responsiveness fix

The first chart calculation is synchronous. The initial Steroid version
rebuilt a full-history volume profile for every candidate block and could
make the app unresponsive on launch. The work is now bounded:

- standard OB lifecycle: at most 64 recent candidates;
- Steroid validation: at most 24 candidates;
- each profile: a 120-bar historical window.

## Manual test checklist

- Launch with Order Blocks and Steroid OB enabled on a deep 1m history;
  confirm the app remains interactive immediately.
- Compare a known strong impulse: standard OB should require an ATR move and
  structure break, while Steroid should be a smaller `RVOL+HVN` subset.
- Verify a feed without candle volume shows no strict Steroid blocks.
- Let a live bar update its wick/close and confirm retest/exhaustion display
  changes without waiting for a new bar.
- Check CHoCH alert text and range match the visible confluence area.

## Verification

`xcodebuild -project HelixTradingApp.xcodeproj -scheme HelixTradingApp -configuration Debug -destination 'platform=macOS' build` succeeded after the responsiveness fix.

## Caveat

The candidate limits deliberately favour current actionable zones over a
complete historical scan. This is appropriate for the chart and alerts but
should be revisited if these detectors are later used for exhaustive
backtesting.
