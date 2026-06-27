# Changelog

All notable changes to Helix Trading App are documented here.

---

## [v1.2] — 2026-06-27

**Fair Value Gaps, smarter journal, AI trade post-mortems, and chart fixes.**

### New Features

- **Fair Value Gap indicator** — LuxAlgo-ported FVG detector overlays bullish and bearish imbalance zones directly on the chart. Each gap extends rightward from where it formed, with a 50% midline and a direction capsule. Mitigated gaps (price closed back inside) dim to lower opacity with dashed borders. Tune the minimum gap size and toggle mitigated zones in Indicator Settings.

- **Journal date-range filter** — Filter the journal by Today, This Week, This Month, or a custom date range. The summary cards (entries, win rate, net P/L) and all three analytics charts (daily P/L, cumulative curve, win-rate trend) update live to reflect only the selected window.

- **AI trade post-mortem** — Tap the ✦ AI button on any journal entry to open a post-mortem sheet. Pick your engine, model, and reasoning effort, then let the AI walk through five structured sections — Why it won/lost, What Went Right, What Could Have Been Better, What You Should Have Done, and a Key Takeaway — each rendered as a styled card.

- **Candlestick chart in AI review** — The AI post-mortem sheet loads real OHLC candles from the database for the trade's pair and time period, rendered as a mini candlestick chart behind the entry/TP/SL/close level lines. Timeframe is auto-selected based on trade duration (1m → 5m → 1h → 4h).

- **Trade metrics panel** — The AI review sheet shows a live R:R ratio bar (color-coded green/yellow/red), price move in points, lot size, and trade duration alongside the price ruler.

- **Save AI report to journal** — After an AI post-mortem completes, hit Save to Journal to append the full report to the entry's notes with a timestamp. Future re-runs can reference the prior analysis automatically.

### Bug Fixes

- **Chart reset button now re-fits the Y axis** — The ↺ reset button now correctly rescales the vertical axis to show all candles in the reset window, even after manually dragging the price axis. Continuous auto-fit is restored after the reset animation completes.

- **AI review price ruler Y range** — The price ruler now includes loaded candle highs/lows in its Y range calculation so bars never overflow the ruler bounds.

---

## [v1.1] — 2026 (internal)

**Charting controls, smarter AI analysis, and more data sources.**

### New Features

- **Order Blocks indicator** — Institutional bullish/bearish order-block zones with an equilibrium midline. Toggle from the indicators menu, tune in Indicator Settings.

- **Trading Sessions indicator** — Shades the Tokyo, London, and New York sessions as per-day high/low boxes with open/close and average lines. Choose which sessions and lines to show in settings.

- **NY Open Setup** — Detects the New York 5-minute opening-range breakout with an FVG retest on the 1m and 5m charts. Marks the range, the breakout gap, and the entry/stop/target.

- **Vertical price scaling** — Drag the price axis to compress or expand the candles, TradingView-style. Double-click the axis to snap back to auto-fit.

- **Free chart panning** — Click and drag anywhere on the chart to move through time and price together.

- **Model + effort selection on the analysis page** — Click an engine icon to pick its model and reasoning effort. Opus 4.8 added; Codex models now show too.

- **Consistent reasoning trace** — The thinking stream now shows for every model, not just Sonnet.

- **Faraz for crypto** — Bitcoin, Solana, and Ethereum can now be sourced from Faraz, just like gold.

---

## [v1.0] — 2026-05-01

**Initial release.**

- Live gold price monitoring from 7 concurrent sources (HD, TGJU, Digikala, Yahoo Finance, and more).
- OHLC candlestick and line charts with bar-index X axis (no weekend gaps).
- Technical indicators: SMA, EMA, Bollinger Bands, UT Bot, RSI, MACD, Stochastic.
- AI analysis via Claude Code CLI (no API key needed) — full TA, Support/Resistance, FVG, Multi-Timeframe.
- Trading journal with P/L tracking, analytics charts, and cTrader import.
- Sidebar pair switcher, chart fullscreen mode, import from file or Go backend server.
- macOS 13+ native SwiftUI app, no App Store, no sandbox.
