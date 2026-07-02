# Helix Trading App v1.3

**Steroid Order Blocks, Volume Profile, multi-chart grid, AI-reviewed journal days, and a real notification inbox.**

## New Features

- **Steroid Order Blocks** — a volume-validated take on Order Blocks. A zone only survives if its originating candle's volume is ≥1.2x (adjustable 0.5x–3x) the 20-period volume average, or its price range overlaps a High Volume Node from an internally computed Volume Profile — filtering structural-looking-but-thin order blocks down to the ones with real trading activity behind them. Toggle it as its own indicator ("Steroid OB," coral accent) with its own settings section (run length, min % move, wick mode, show-exhausted, notify-on-events, volume multiplier).

- **Order Blocks exhaustion lifecycle** — every Order Block / Steroid Order Block zone now tracks `fresh → tested → exhausted` as price interacts with it, with a retest counter and a "Show exhausted blocks" toggle so old, dead zones don't clutter the chart. Optional push notifications on appear / retest / exhaust, routed through the new Inbox.

- **Volume Profile drawing tool** — a new manual drawing (alongside horizontal line / trend line / rectangle): drag a box over any price/time range and the chart renders a horizontal volume histogram along its right edge, 30 buckets, Point of Control highlighted in red. Resizes and repositions like a rectangle; shows up in the Drawing Inspector as "Vol Profile."

- **Multi-chart grid** — a layout picker in the pair header switches between a single chart and 2-column / 2-row / 2×2 split layouts. Each pane has its own pair, timeframe, chart type, and indicators (drawings are shared per-pair with the main chart); new panes seed at a useful timeframe spread (15m/1h/4h/1d). An optional "Sync symbol across panes" toggle propagates a pair change to every pane. Any pane can go fullscreen on its own, or the whole grid can go fullscreen together. Layout and per-pane settings persist across relaunches.

- **AI review for a whole journal day, week, or month** — beyond the existing per-trade AI post-mortem, a new "Analyse Day" button on each day-group header (and a dynamic "AI Today / This Week / This Month / Custom" toolbar button tied to the journal's date filter) runs a full-session AI review across every trade in the period: session overview, what drove the result, order-block quality per trade, discipline patterns, and concrete rules to carry forward. Reviews can now be saved and browsed later from **AI Review History** in the Journal's overflow menu — previously the report vanished the moment the sheet closed.

- **Notification Inbox** — a new sidebar section collecting every notification the app sends (order-block lifecycle events, price/RSI alerts, Scanner opportunities) into one persisted, filterable history with unread badges, instead of relying on macOS Notification Center. Each entry now also shows the timeframe the condition fired on.

- **Strategy Scanner** — new sidebar section that continuously scans every enabled pair for Swing (4H/1H/15M) and Scalp (15M/5M/1M) confluence setups, surfacing long/short opportunities with entry/stop/take-profit/R:R, a running opportunity log, and a push notification the moment a new setup appears.

- **Risk Calculator** — a new toolbar popover in the Journal view: enter account balance, risk % (0.5/1/2/3% presets), entry, and stop loss to get a suggested lot size.

- **OB Zone Win Rate analytics** — the Journal's analytics section gained a table bucketing trades into 25-point price zones (min 2 trades to show) with win/loss counts, a win-rate bar, and net P/L per zone, to spot which price levels have actually been profitable.

- **Live Faraz streaming** — the Faraz gold/BTC/SOL/ETH feed now uses a real-time WebSocket stream for spot ticks and 1m/1D candles instead of pure HTTP polling, with polling kept only as a fallback (socket stale >20s, or to backfill 5m/1h/1d bars the socket doesn't push). The Faraz API base URL is also now configurable in Settings for pointing at a custom host.

- **Sonnet 4.6 set as the default AI model** across the Analysis panel, per-trade AI sheet, and the new day-review sheet.

## Bug Fixes

- **Order-block notifications no longer flood the Inbox** — zone identity was keyed on the zone's position in whatever candle window happened to be recomputed, which shifted on every live-tick refresh or history backfill and made existing zones look "new" again. Zones are now identified by their stable price range, so a zone only notifies once per real lifecycle transition.
- **Scanner opportunities no longer re-notify hourly** — a setup that stayed valid for more than an hour used to fall outside the old dedup window and get re-announced roughly every hour it stayed open; it now only notifies once, when it first becomes active.
- **Sunday reopening respected** — COMEX's actual Sunday 6pm ET reopen is no longer blanked out for the whole day, fixing missing Sunday-evening bars for users in timezones ahead of ET.
- **Smoother panning/zooming on long histories** — indicator and oscillator recomputation (Order Blocks, FVG, NY Open Setup, MACD, etc.) now runs off the main thread, so charts with years of 1-minute data no longer stutter while panning or zooming.
- **Re-importing a cTrader CSV statement is fully idempotent** — duplicate-detection now also matches on pair, closing the small gap where two different pairs could theoretically collide on entry price + side + timestamp.

---

Full history: see [CHANGELOG.md](./CHANGELOG.md).
