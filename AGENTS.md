# HelixTradingApp — Native macOS App (Helix Trading Club)

> **Rebrand note**: the app is "Helix Trading App" (display name) /
> "Helix Trading Club" (org). The source directory `GoldMonitorMac/`
> kept its old name to avoid churning git history — only user-visible
> branding (bundle name, display name, window titles, copyright,
> keychain service, app-support dir) was renamed.

A SwiftUI desktop app that monitors gold-market prices, charts them with
indicators + drawings, and runs AI-driven technical analyses against them.
Built as a CleanMyMac X-style native UI on top of the same data model the
Go backend uses, with a separate independent live-fetch pipeline so the
app works without the server.

This file is the working brief for anyone (human or AI) editing this
codebase. If a behaviour or convention here conflicts with what you'd
guess from reading a single file, this document wins.

---

## Build & run

```bash
cd GoldMonitorMac
xcodegen generate                 # regenerates HelixTradingApp.xcodeproj from project.yml
open HelixTradingApp.xcodeproj
# ⌘R in Xcode
```

Or build from CLI:

```bash
xcodebuild \
  -project HelixTradingApp.xcodeproj \
  -scheme HelixTradingApp \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

`project.yml` is the source of truth for the Xcode project; the
`.xcodeproj` directory is **gitignored**. Always re-run `xcodegen generate`
after changing `project.yml` (adding a SwiftPM dep, changing
deployment target, etc.) — never edit the `.xcodeproj` files directly.

**Toolchain expected:** Xcode 15+, Swift 5.9, macOS 13+ deployment
target (we use Apple Charts which is iOS 16 / macOS 13 era).

---

## Architecture at a glance

```
App lifecycle
  HelixTradingApp          @main, three @StateObjects:
                             • AppState       — selected pair, db handle, errors
                             • FetchScheduler — periodic snapshot fetch (HD/TGJU/Digikala/…)
                             • YahooScheduler — periodic Yahoo Finance ticks for ounce
                           Boots the database, kicks both schedulers,
                           hands env objects to RootView.

RootView (Features/)
  HStack { SidebarView | mainArea }
  Auto-enters macOS fullscreen on first launch via WindowConfigurator.
  Sidebar collapses with a slide animation when chart fullscreen mode
  is on (AppState.isChartFullscreen).

DashboardView (Features/Dashboard/)
  The crown jewel. Holds:
    - Pair header (live price, change %, refresh button, fetch timer).
    - Chart card: chart type / timeframe / zoom / fullscreen / indicators
      menu / Layers popover / AI Analyze button — all in the header row.
      Body: ChartView + VolumeBarsView + OscillatorPanels (RSI/MACD/Stoch).
    - Stats row (24H high/low/change/volume).
    - Sheets: AnalysisSheet, IndicatorSettingsSheet.
  Owns: timeframe / chartType / indicator selections (@AppStorage),
  S/R + FVG + Scenario AI overlays (@State, pair-scoped via .task(id:)),
  AnalysisStore (@StateObject).
```

### Subsystems

| Folder | Responsibility |
|---|---|
| `App/` | `HelixTradingApp` (entry), `AppState` (global state), `Theme` (colors, spacing, gradients) |
| `Models/` | `Snapshot`, `Candle`, `TradingPair`, `MarketCalendar` (weekend filter for COMEX) |
| `Storage/` | `AppDatabase` (GRDB pool), `Schema` (CREATE TABLEs), `SnapshotRepo`, `OHLCRepo`, `Importer` (file picker → validate → swap), `ServerImporter` (HTTP import from the Go backend) |
| `Fetching/` | `PriceFetcher` (orchestrates 7 sources concurrently), `Sources.swift` (per-source HTTP), `BackendClient` (Go server import auth), `ProxyTransport` (SOCKS5 wiring), `YahooGoldSource` (Yahoo Finance for ounce) |
| `Scheduling/` | `FetchScheduler` (60s tick → PriceFetcher → DB write), `YahooScheduler` (10s tick → Yahoo → OHLC table) |
| `AI/` | `AIEngine` protocol, `ClaudeEngine` (Codex CLI shell-out + stream-json parser), `CodexEngine` (Coming Soon stub), `PromptBuilder` (per-kind system prompts + structured-data parsers), `AnalysisStore` (per-pair sessions + history persistence) |
| `Features/Dashboard/` | `DashboardView`, `ChartView` (Apple Charts price/candles), `VolumeBarsView`, `OscillatorPanel` (RSI/MACD/Stoch sub-charts), `Indicators` (SMA/EMA/Bollinger/UT Bot), `Oscillators` + `OscillatorConfig`, `UTBot`, `IndicatorSettingsSheet`, `ChartControls`, `FetchTimerView` |
| `Features/AIAnalysis/` | `AnalysisPanel` (kind/engine/history UI), `AnalysisSheet` (modal wrapper), `MarkdownTheme` (MarkdownUI styling) |
| `Features/Sidebar/` | `SidebarView` + `PairRow` |
| `Features/Settings/` | `SettingsView` (proxy / API keys / fetch interval) |
| `Features/Import/` | `ImportView` (file + server import flows) |
| `UI/` | `Card`, `PrimaryButton`, `SecondaryButton`, `KeychainHelper`, `WindowConfigurator` |

---

## Key patterns

### State persistence

We persist selectively — anything the user would expect to survive a
relaunch goes through `@AppStorage` (or UserDefaults via `didSet` for
non-View state). Anything ephemeral (pan/zoom, sheet visibility,
fullscreen) lives in plain `@State`.

| What | Where | Key |
|---|---|---|
| Selected pair | `AppState.selectedPairID` (@Published + UserDefaults) | `selectedPairID` |
| Chart timeframe | `@AppStorage` in DashboardView | `dashboard.timeframe` |
| Chart type (line / candle / heikinAshi) | `@AppStorage` | `dashboard.chartType` |
| Volume strip on/off | `@AppStorage` | `dashboard.showVolume` |
| Enabled indicators (CSV of rawValues) | `@AppStorage` | `dashboard.indicators` |
| Enabled oscillators | `@AppStorage` | `dashboard.oscillators` |
| Hidden indicators (Layers popover) | `@AppStorage` | `dashboard.hiddenIndicators` |
| Hidden oscillators | `@AppStorage` | `dashboard.hiddenOscillators` |
| Indicator parameters (RSI period, UT Bot key, MACD, etc.) | UserDefaults via `OscillatorConfig.save()` | `dashboard.indicator.config.v2` |
| Yahoo / fetch intervals | UserDefaults inside the schedulers | `fetch.interval` |
| AI analysis history | UserDefaults via `AnalysisStore.saveHistory()` (Codable, JSON) | `analysis.history.v1` |

`Set<EnumKind>` types are stored as comma-separated rawValue strings
because `@AppStorage` doesn't natively support `Set`. See
`enabledIndicators` / `setIndicator` in `DashboardView.swift` for the
pattern — copy it for any new set-of-enum state.

### AI analysis

Three layers:

1. **PromptBuilder** (`AI/PromptBuilder.swift`) — `AnalysisKind` enum
   (`full`, `supportResistance`, `fvg`, `multiTimeframe`) plus
   per-kind system prompts. For overlays-on-chart kinds the prompt
   demands a structured `### XXX_JSON` block at the end (`LEVELS_JSON`,
   `FVG_JSON`, `SCENARIO_JSON`). Parsers (`parseSRLevels`,
   `parseFVGZones`, `parseTAScenario`) brace-walk to extract them.

2. **AIEngine** (`AI/AIEngine.swift`) — protocol with `run(system:user:)`
   returning `AsyncThrowingStream<String, Error>`. Two implementations:
   - **ClaudeEngine** spawns `Codex --print --output-format stream-json
     --include-partial-messages --verbose`, writes the prompt to stdin,
     and uses `StreamJSONParser` to pull `content_block_delta` text
     events out of the NDJSON stream as they arrive. No API key —
     reuses the Codex CLI's own session.
   - **CodexEngine** is `availability: .comingSoon` — UI shows the pill
     but the run path is gated.

3. **AnalysisStore** (`AI/AnalysisStore.swift`) — `@MainActor`
   ObservableObject owned by DashboardView. Holds `[SessionKey: Session]`
   keyed by `(pairID, kind)` so each symbol has its own slot per kind
   (running pair A's TA while viewing pair B works correctly). On
   completion, parses the structured payloads and pushes a `HistoryEntry`
   onto the persisted `history` list (capped at 50).

Adding a new analysis kind:
1. Add a case to `AnalysisKind`, give it `label` / `noun`.
2. Add a `private static let systemXxx = "…"` system prompt.
3. Wire it in `systemPrompt(for:)`.
4. If structured data: define a `Codable` struct + `parseXxx(_:)`
   parser using `extractJSONBlock`.
5. If chart overlay: add `@State` to DashboardView, pass into
   ChartView, render via a new `@ChartContentBuilder`.
6. If the user prompt shape differs (e.g. `multiTimeframe` bundles
   multiple TFs), add a sibling `userPromptXxx`.
7. Update `AnalysisStore.recordCompletion` to save the new payload on
   `HistoryEntry`.
8. Update `AnalysisPanel.applyOverlayButtons` switch (it's exhaustive).

### Chart overlays

ChartView's X axis is **bar-index based** (`Double`), not time-based.
This is so weekend gaps for the ounce pair (COMEX is closed Sat/Sun)
don't open visible holes — consecutive bars sit flush regardless of
calendar gaps. All marks (candles, line, indicators, hover crosshair,
S/R, FVG, scenario) plot at `Double(barIndex)`. Pan/zoom moves a
`ClosedRange<Double>` `xDomain`, never a date range.

To add a new overlay:
- Add a `let overlayThing: SomeType` parameter on ChartView.
- Add a `@ChartContentBuilder` property like `overlayMarks`.
- Insert it into the main chart body (typically before `candleMarks`
  so it sits behind the price action, or after for top-layer markers).
- Fold its values into `yDomain` so it can't render off-screen.

### Layers popover

DashboardView's `layersPopoverContent` lists every drawable thing on the
chart with hide/show toggles + delete. The hide/show state for
indicators/oscillators uses parallel `hiddenIndicators` /
`hiddenOscillators` sets (persisted via `@AppStorage`); the AI overlays
use boolean `srVisible` / `fvgVisible` / `scenarioVisible` `@State`
flags.

When you add a new chart-drawable thing, also wire it into
`layersPopoverContent` so the user can hide it.

---

## Conventions & gotchas

- **macOS 13 baseline** — no `@Observable`, no
  `Stepper(value:in:step:format:)` from macOS 14, no `symbolEffect`,
  no `chartScrollableAxes`. Use `ObservableObject` + `@Published` +
  `@StateObject`. The `onChange` two-parameter form (with `initial:`)
  isn't available — use the single-closure form.
- **Apple Charts marks** can bleed visually past their plot area on
  pan/zoom — wrap chart-rendering views in `.clipped()` and the chart
  card's `Card { ... }` masks to a `RoundedRectangle` already.
- **The price tag** uses `.annotation(position: .overlay,
  alignment: .trailing)` so the capsule sits *inside* the plot area
  rather than spilling past it (which would conflict with `.clipped()`).
- **Process spawning under hardened runtime**: `ClaudeEngine` /
  `CodexEngine` use `Process` directly. We don't have any sandbox
  entitlements set in `project.yml` (no `App Sandbox`), which is
  intentional — the app needs to spawn the user's CLI binaries from
  `~/.local/bin` etc.
- **GRDB writes serialize, reads parallelize** under
  `DatabasePool`. Keep heavy queries off the main actor —
  `loadOunceCandles`, `SnapshotRepo.between`, etc. are `throws`-style
  sync calls but cheap; longer ops should be wrapped in `Task`.
- **Yahoo's chart endpoint** updates the *current* minute's partial
  bar with the latest trade price, so polling at 10s with the same
  endpoint gives the chart a live-feeling tail without buying a paid
  feed. See `YahooScheduler.tickIntervalSeconds` (10s) — bump if
  you start hitting rate limits.
- **Heikin Ashi** is a chart-render option (`ChartType.heikinAshi`).
  When selected, ChartView transforms `candles → displayCandles` via
  `HeikinAshi.transform` for candle/line/hover marks. Indicators
  still read raw closes — that's the TradingView convention.

---

## What this app is NOT

- **Not a backtester** — no historical replay, no order simulation.
- **Not a broker bridge** — analysis output is informational; we
  don't talk to any execution venues.
- **Not for the App Store** — uses unsandboxed process spawning,
  open ATS, Codex CLI shell-out. Distribution path is "build it
  yourself or grab a notarised DMG".
- **Not a server replacement** — the Go backend at the repo root is
  still the single source of truth for production data. The Mac app
  is a personal-use companion that imports from it.

---

## When you change something

- **Touched `project.yml`?** Run `xcodegen generate`.
- **Added a new SPM dependency?** Add it under `packages:` AND under
  `targets.HelixTradingApp.dependencies` in `project.yml`, then
  regenerate.
- **Added a new Swift file?** No need to update `project.yml` — the
  target uses recursive `sources: path: GoldMonitorMac` so new files
  are auto-included.
- **Changed an `@AppStorage` schema in a way old payloads can't decode?**
  Bump the storage key (e.g. `…config.v2` → `…config.v3`). See
  `OscillatorConfig.storageKey` for the pattern.
- **Added a Codable field to a persisted struct?** Make it optional
  and use a custom `init(from:)` with `decodeIfPresent` so older
  saved entries keep loading. See `AnalysisStore.HistoryEntry` and
  `PromptBuilder.TAScenario` for the back-compat patterns.
- **Always `xcodebuild build` after substantive changes** — the user
  prefers to know it compiles before reading the diff.
