# Helix Trading App v1.1

Charting controls, smarter AI analysis, and more data sources.

## ✨ Highlights

- **Order Blocks indicator** — institutional bullish/bearish order-block zones with an equilibrium midline. Toggle it from the indicators menu and tune the run length / % threshold / wick options in indicator settings.
- **Trading Sessions indicator** — shades the Tokyo, London, and New York sessions as per-day high/low boxes with dashed open/close lines and a dotted average. Toggle it from the indicators menu; choose which sessions and lines show in indicator settings. Intraday timeframes only.
- **NY Open Setup** — a built-in strategy that detects the New York 5-minute opening-range breakout with an FVG retest: it marks the opening range, the breakout fair-value gap, and the entry / stop / target plan (entry at FVG 50%, stop beyond the range, 2R target). Fires an alert when price retests the entry and offers one-click activation as a paper/live trade. Works on the 1m and 5m charts; tune the breakout strength and kill-zone in indicator settings.
- **Vertical price scaling** — drag the price axis to compress or expand the candles, TradingView-style. Double-click the axis to snap back to auto-fit.
- **Free chart panning** — click and drag anywhere on the chart to move through time and price together, in any direction.
- **Model + effort on the analysis page** — click an engine icon to pick its model and reasoning effort right where you run analyses. Opus 4.8 added, and Codex models now show too.
- **Consistent reasoning trace** — the thinking stream now shows for every model, not just Sonnet (reasoning effort now maps to real thinking budgets).
- **Faraz for crypto** — Bitcoin, Solana, and Ethereum can now be sourced from Faraz, just like gold.
- **A "What's New" popup** that surfaces these notes after each update.

---

# Helix Trading App v1.0

The first release of **Helix Trading App** — a native macOS app for monitoring gold-market prices, charting them with indicators and drawings, and running AI-driven technical analysis. CleanMyMac-style UI, its own independent live-fetch pipeline (works without the server), and a focus on a chart that stays smooth even over deep history.

## ✨ Highlights

### 📈 Full price history, not just the last week
The chart now loads your **entire stored OHLC history** — how far back you look is purely a matter of panning and zooming. Pan to the left edge of an intraday chart and older **1-minute / 5-minute bars page in automatically** (infinite scroll), pulled from Twelve Data's historical API to reach well past Yahoo's intraday limits.

### ⚡ Smooth at any depth
- **Windowed rendering** keeps the number of drawn candles bounded, so panning and zooming stay responsive even with months of minute bars loaded.
- **Derived-data memoization** means moving the chart no longer recomputes indicators, Heikin-Ashi candles, UT Bot, and oscillators over the whole history on every frame.
- A **loading shimmer** covers the plot while a timeframe's history fills in.

### 🧵 Fully async data pipeline (no more UI stalls)
All network fetching and database work for every tracked pair now runs **off the main thread**. Background syncs for other symbols no longer freeze the chart you're interacting with. Live ticks update the price instantly while the bar-writing happens behind the scenes.

### ⏪ Replay mode (TradingView-style back-testing)
Rewind the chart to any historical bar, then **step forward one candle at a time or auto-play**. AI analyses launched during replay treat the cursor as "now," so you can back-test how an analysis would have read at that moment.

### ⏭️ MetaTrader-style "scroll to latest"
When you've panned back through history, a button appears in the bottom-left of the chart — one click **jumps back to the newest candle while keeping your zoom level**. Works in Replay too (jumps to the replay cursor). When you're already pinned to the live edge, new bars keep themselves in view automatically.

### 🤖 AI technical analysis
Run full TA, support/resistance, fair-value-gap, and multi-timeframe analyses that render as overlays directly on the chart, with per-symbol history.

## 📦 Install

Download `HelixTradingApp-1.0.dmg` below, open it, and drag the app to **Applications**.

> **Note:** This build is signed for personal use (not notarised). On first launch, right-click the app → **Open** → **Open** to get past Gatekeeper.

## 🛠️ Build from source

```bash
git clone git@github.com:pouyaam/HelixTradingAssistant.git
cd HelixTradingAssistant
./run.sh                 # bootstrap deps, build, and launch
./run.sh --sign          # build + ad-hoc-sign + package a .dmg into ./dist/
```

Requires Xcode 15+ and macOS 13+.

## ⚠️ Known limitations
- Not notarised — Gatekeeper needs the right-click-Open step on first launch.
- Not a backtester for orders, not a broker bridge — analysis output is informational only.
- The Codex AI engine is a "Coming Soon" stub; Claude is the active engine.
