# Faraz expiry-gap backfill + "clear all data & refetch" (2026-07-30)

## Summary

Two related fixes around the Faraz feed:

1. **Expiry gap is no longer lost.** When the Faraz session cookie
   expired, every fetch 401'd; after the user re-logged in, the bars
   missed during the outage stayed missing forever — the post-login
   `reloadFarazAfterAuth` called `backfillAll`, but `ensureDeepHistory`
   early-returns on its session `deepBackfilled` latch, and the periodic
   sync only reaches ~30 bars back. Now the re-login path clears the
   latches, and the Faraz deep fetch extends its `from` anchor back to
   the last stored bar whenever that bar is older than the default
   12000-bar window, so any gap (re-login or app-offline) gets bridged.
2. **Settings → Data sources gained "Clear all data & refetch"** (Mac
   `DataSourcesCard` + iPad `SettingsViewiPad`): confirmation alert →
   new `YahooScheduler.resetAllData()` wipes every pair's OHLC series
   and refetches from the active source, then bumps `dataResetToken`
   so all charts reload.

## Changes Made

- `GoldMonitorMac/Scheduling/YahooScheduler.swift`
  - `ensureDeepHistory` Faraz branch: reads
    `repo.latestBucket(pairID:timeframe:)`; if it's older than
    `now − 12000·tfSecs`, widens `countback` (cap 200k bars) so the
    fetch reaches back to the last stored bar and fills the gap.
  - `reloadFarazAfterAuth`: calls `clearDeepBackfilled()` before
    `backfillAll` so the refetch actually runs after a re-login.
  - New `resetAllData()`: clears latches, `repo.deleteAll` +
    `latestPrices[pair] = nil` for every managed pair, `backfillAll`
    per pair in a TaskGroup, `dataResetToken &+= 1`. Mirrors
    `switchGoldSource` but covers all pairs and leaves streams alone.
- `GoldMonitorMac/Features/Settings/DataSourcesCard.swift` (Mac)
  - New "STORED MARKET DATA" section with a danger-capsule
    "Clear all data & refetch" button, confirmation `.alert`, and an
    inline ProgressView while `resetAllData()` runs. Took
    `@EnvironmentObject yahoo: YahooScheduler`.
- `ipadapp/HelixTradingApp-iPad/Features/Settings/SettingsViewiPad.swift`
  - Same clear-data block at the bottom of the Data Sources card.
- `AGENTS.md` — Faraz feature bullet now notes the post-re-login gap
  backfill.

### Drive-by fixes (pre-existing iPad-target breakage, blocking verification)

- `ipadapp/.../DashboardViewiPad.swift`: `ChartPlotiPad` referenced
  `chartTheme` (a `private` member of `DashboardViewiPad`) — added its
  own `@AppStorage("dashboard.chartTheme")` + computed var. Also split
  the `ChartViewiPad` call out of `body` into a `chartSection` computed
  property; the single-expression body had pushed the compiler past its
  type-check budget.

## Decisions & Reasoning

- Chose latch-clearing + last-stored-bar anchoring over a separate
  gap-detection pass: `ensureDeepHistory` is already the single funnel
  for deep Faraz fetches (bootstrap, re-login, manual reset), so one
  anchor extension fixes every path, including app-closed outages.
- `resetAllData` reuses `backfillAll`/`ensureDeepHistory` routing
  (Faraz vs Yahoo per pair) rather than duplicating source-selection
  logic.
- Left `DataSourceConfig.setFarazCookie`'s identical-cookie no-op as is:
  after a real expiry the new session cookie always differs, so the
  `$farazCookie` sink fires; an identical capture means the cookie was
  never the problem.

## Unfinished

- None. Verified: `xcodebuild` Debug builds succeed for both the
  `HelixTradingApp` (macOS) and `HelixTradingAppiPad` (iOS Simulator)
  schemes.
