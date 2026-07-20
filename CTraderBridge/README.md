# Helix Trading · cTrader Bridge

This directory holds the companion **cTrader cBot** that streams
XAU/USD ticks and bar closes to the Helix Trading macOS app.

```
cTrader desktop                       Helix Trading.app
┌───────────────────────┐    JSON     ┌─────────────────────────┐
│  HelixBridgeBot.cs    │ ──TCP─────▶ │  CTraderWSReceiver       │
│  (this directory)     │  loopback   │  Settings → cTrader      │
│                       │  port 7878  │                          │
└───────────────────────┘             └─────────────────────────┘
```

When the bridge is connected and delivering fresh ticks, Helix uses
it as the **authoritative** XAU/USD price source. TwelveData and the
gold-api fallback remain wired in and step back in automatically if
the bridge goes quiet (>10s without a tick). Other symbols (BTC,
SOL, ETH) are unaffected.

---

## Prerequisites

- **cTrader Desktop** installed and signed into a trading account
  with XAU/USD available (most brokers list it).
- **Helix Trading.app** running, with Settings → cTrader → "Bridge
  enabled" toggled on. The card will say "Listening on 127.0.0.1:7878
  (waiting for cBot)" until the cBot dials in.

## Install (~3 minutes)

1. Open cTrader → click **Automate** in the left rail.
2. Click **New cBot** → name it `HelixBridgeBot` → click Create.
3. cTrader opens a code editor with a stub class. Replace **all** of
   its contents with the body of [`HelixBridgeBot.cs`](./HelixBridgeBot.cs)
   from this directory.
4. Click **Build** in the editor's toolbar. You should see
   "Build succeeded" at the bottom.
5. Back in the Automate pane, expand **My cBots → HelixBridgeBot**.
6. Drag the cBot onto an **XAU/USD** chart of any timeframe — the
   timeframe of the chart you attach it to determines which bar
   close events get streamed (M1 → 1-minute bars, M5 → 5-minute,
   etc.). Attach a second instance to a different timeframe if you
   want multiple resolutions; the Mac side merges them by `tf`.
7. In the right panel (the bot's parameters), confirm:
   - **Helix host**: `127.0.0.1` (default)
   - **Helix port**: `7878` (must match Settings → cTrader on the Mac)
   - **Send ticks**: on
   - **Send bars**: on
8. Click **Start**.

The Mac app's Settings card should flip from "Listening" to
"Connected" within a second or two, and a "Last tick Ns ago" chip
should start counting up — see the screenshot in this directory's
parent docs.

## Verifying it's working

In Helix Trading, open the **ounce** pair's chart. The price tag in
the top-right and the live tick on the latest candle should update
in real time on every quote change. The Settings → cTrader card
shows a green dot when a tick was received within the last 10s.

You can also confirm at the cBot side: the cTrader **Log** tab
prints `[Helix] Connected to 127.0.0.1:7878` on startup and silent
output thereafter. Any send failure prints
`[Helix] Send failed, will reconnect: <reason>`.

## Troubleshooting

| Symptom                            | Likely cause                                  | Fix                                       |
|-----------------------------------|-----------------------------------------------|-------------------------------------------|
| Settings card stuck on "Listening" | cBot not started / wrong port                 | Click Start on the bot; check parameters  |
| "Connection refused" in cTrader log| Helix bridge disabled                         | Toggle on Settings → cTrader → Bridge     |
| "Connected" but no ticks displayed | Bot attached, but Send ticks off              | Flip the toggle in cTrader parameters     |
| Last-tick chip stops counting up   | cBot crashed (check cTrader Log)              | Click Stop then Start in cTrader          |

## Customising

- **Different symbol**: change the Mac side's `symbolToPairID` map
  in `CTraderScheduler.swift` and drop a new internal pair into
  `TradingPair.catalog`.
- **Different port**: edit both `HelixPort` (cTrader parameter) and
  the Mac's Settings → cTrader → Loopback port; they must match.
- **LAN instead of loopback**: change `HelixHost` to the Mac's LAN
  IP and edit `CTraderWSReceiver.start(...)` to bind to `.any`
  instead of `.loopback`. Add a shared-secret check in the hello
  message before doing this — there's no auth on the bridge today.

## Message schema (for reference)

All messages are UTF-8 JSON, one per line. Schema versioned by the
`bot` field in the hello frame.

```
{"type":"hello","symbol":"XAUUSD","tf":"M1","account":"Pepperstone/12345","bot":"0.1"}
{"type":"tick","symbol":"XAUUSD","bid":2340.55,"ask":2340.62,"ts":"2026-05-15T10:23:45.123Z"}
{"type":"bar","symbol":"XAUUSD","tf":"M1","o":2340.10,"h":2340.65,"l":2339.90,"c":2340.55,"v":182,"ts":"2026-05-15T10:23:00Z"}
{"type":"ping","ts":"2026-05-15T10:23:50.000Z"}
```
