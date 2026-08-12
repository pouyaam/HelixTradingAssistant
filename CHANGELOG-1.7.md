# Helix Trading App — v1.7

**Released:** 2026-08-12 · macOS 13+ · build 10

Four new Smart-Money indicators, a Smart Money Desk with its own MCP
server, and a Sentinel radar that watches every timeframe at once —
plus a set of correctness fixes in the higher-timeframe context path
that reached three separate features.

---

## New indicators

### EBP · Engulfing Bar Play

A PineScript v6 port of the Omar Agag swing model. One candle sweeps the
previous candle's extreme **with its shadow only** — the body never
trades beyond the level it took out — and closes back through that
candle's body.

Where the close lands inside the EBP candle's own range picks the plan:

| Close | Entry | Stop |
|---|---|---|
| **Strong** (within 15% of the extreme) | 25% retrace | 75% retrace — inside the candle |
| **Indecisive** | 50% retrace | behind the whole candle |
| **Already past 50%** | taken at market | behind the whole candle |

The target is 2R by default. The engine holds one trade at a time, as
the original does: a pattern that prints while an order is resting is
drawn but marked "not traded". Optional breakeven-on-new-extreme and
limit expiry are both off by default.

- **Detect on any timeframe.** Leave it on "Chart timeframe" or pin it
  to another — a 4H pattern projects onto a 15m chart at its true width,
  tagged with the timeframe it came from.
- **Its own notification toggle**, layered under the existing layer-eye
  and global strategy switches.
- **Sentinel radar tab** with the running setups / wins / losses /
  win % / total R tally.

### AMD · Accumulation / Manipulation / Distribution

Reads the phase rotation rather than a single pattern: a contracted
base, a liquidity sweep beyond one of its edges that gets reclaimed, the
displacement leg that follows, and the stall at the end of it. The fair
value gap left inside the displacement is the entry.

### SP2L + Pro BTB × Ranked OB

Two trigger engines feeding one grading engine. A displacement FVG
pullback and a pivot break that gets retested both produce setups; every
setup is then scored on Volume Profile, Ichimoku, and order-block
confluence, graded A/B/C, and only fires above the minimum grade you
choose. Order-block confluence can be a bonus or a hard gate.

Replaces the Pin Bar Combo setup, which has been removed.

### Previous Day · PDH/PDL + volume profile

The last completed session's high and low, its midpoint, its open and
close, and that session's volume profile drawn as a histogram in the
chart's right margin with POC / VAH / VAL. Every element has its own
toggle.

---

## Sentinel radar

- **Multi-timeframe scanning.** Pick a set of timeframes from the TF
  menu and the radar scans all of them at once instead of only the one
  on the chart. Each row carries the timeframe that found it, and a chip
  row filters the list down to one. The selection persists across
  launches; the default — follow the chart — is the previous behaviour.
- **Clicking a row moves the chart to that setup's timeframe**, since
  framing a 4H setup over 15m bars would put the POI off-screen.
- **Empty state explains itself per timeframe**, naming the rule
  currently blocking each one instead of showing a single blank line.
- **EBP tab** alongside the SMC radar, fed by the same computation that
  draws the chart overlay, so the two can never disagree.

---

## Smart Money Desk + MCP server

A dedicated SMC analysis workspace, plus a local MCP server exposing the
app's own market-structure engines as callable tools: ranked order
blocks, FVG detection, session ranges, previous-day levels,
multi-timeframe bias, ALGOSMART structure, a combined SMC brief, and
position sizing.

---

## Fixes

- **Higher-timeframe context was built from a broken fold.** The
  Sentinel derived its HTF read by folding the chart's own candles into
  buckets **by array index**, so every bucket boundary shifted the
  moment older history loaded through infinite scroll — enough to flip
  the structural read and with it the direction shown on the radar.
  Context now comes from real higher-timeframe bars, bucketed by wall
  clock when a fold is unavoidable.
- **HTF bars were located by multiplying a bar-count factor**, which is
  only correct when both series begin on the same bar — false for any
  independently loaded series. The two series are now matched by date.
- **Radar setups could collide onto one identity.** Alert ids came from
  a byte-XOR fold that produced the same id for any two same-length
  seeds with characters swapped 16 apart — exactly what near-identical
  zone prices look like. Ids now use a real hash, seeded on the zone's
  geometry rather than on a bar index that changes every bar.
- All three of the above also affected the Smart Money Desk and the MCP
  server, which shared the same path.
- **The timeframe ladder existed in three copies** (analysis page, MCP
  toolbox, Sentinel) and has been collapsed onto one definition.
- SMC system-prompt timeframes corrected.
- Fixed a data-loss path in candle storage.

---

## Notes

- Test suite: **281 tests, 0 failures** (was 233 at v1.6).
- The iPad target still does not build; its pre-existing break is
  unchanged by this release, so the iPad-side code for the new
  indicators is compile-unverified.
- None of this release has been visually confirmed against a running
  app — the engines are covered by unit tests, the overlays are not.
