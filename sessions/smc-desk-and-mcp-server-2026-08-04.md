# SMC Desk analysis kind + local MCP server (2026-08-04)

## Request

Two things:

1. An AI-engine prompt that uses Ranked OB, ALGOSMART Assist and the
   previous day's high/low/POC to produce a Smart Money Concepts analysis.
2. A local MCP server on `http://127.0.0.1:4321` exposing those same
   engines — rank OB, AlgoSmart Assist, history data, previous-day
   levels — so other AI tools can use them too.

Both landed. The connective tissue between them is `SMCEvidence`, which
is why they are one change and not two.

## What was added

### `GoldMonitorMac/AI/SMCEvidence.swift` — the shared evidence pack

One pure, `Codable` struct assembled from the engines the app already
ships: `RankedOrderBlocks.compute`, `AlgoSmartAssist.calculate`,
`VolumeProfile.computePreviousDay`, `SMCSentinelEngine.scan`. It renders
either as markdown (for the prompt) or as JSON (for MCP), from the same
computation.

This is the piece that made the rest cheap. Writing the prompt and the
MCP tools separately would have meant two serializations of the same four
engines, drifting apart on the first parameter change.

What the pack adds on top of the raw engine output is the *derived*
reading an analyst acts on, computed in Swift rather than left to the
model:

- distance from spot to each zone in **ATR units**, and nearest-first
  ordering — the model is bad at "which of these is closest" and it is
  the first question a trader asks;
- **premium / discount** classification against ALGOSMART's 0.5
  equilibrium;
- **cross-engine agreement**: when a Ranked OB and an ALGOSMART POI mark
  the same prices, the zone carries the overlapping POI's range. Two
  engines with unrelated detection rules landing on one band is the
  strongest single confluence available here.
- **unswept previous-day liquidity** — which of PDH / PDL the current
  session has not yet taken.
- a **gaps** list. When a window is too short for an engine, the pack
  says so explicitly. An empty section reads as "no structure found",
  which is a different and much more dangerous claim.

`Options` control the pack's size so the HTF pass can be cheaper than the
entry-timeframe pass.

### `AnalysisKind.smcDesk` — "Smart Money Desk"

- `PromptBuilder.systemSMCDesk` — a system prompt that fixes the
  reasoning *order* (HTF bias → liquidity → premium/discount → zone →
  trigger → execution), because SMC done in the wrong order rationalises
  a zone the trader already wanted. It emits `SCENARIO_JSON`,
  `ALT_SCENARIO_JSON`, `LEVELS_JSON` and `SUPPLY_DEMAND_JSON`, so the
  existing PlanCard / chart-overlay path lights up with no new parsing.
- `PromptBuilder.userPromptSMCDesk` — bundles the entry-TF and HTF
  evidence packs plus a trimmed OHLC table.
- `AnalysisStore.runSMCDeskAnalysis` — loads both timeframes and starts
  the session under the new kind.
- Wired into `AnalysisPage` (picker, `idleHint`, run switch) and
  `recordCompletion`.

The prompt is told to lead with the blocker when the mechanical rules
engine reports one. "No valid setup yet, waiting for a sweep" is a
complete answer; a model that fills the template anyway is the failure
mode worth designing against.

### `GoldMonitorMac/MCP/` — the local MCP server

Streamable HTTP transport, JSON-RPC 2.0 over `POST /mcp`, built on
`NWListener`. No new SPM dependency: the dependency rule is GRDB and
swift-markdown-ui only, and one route with `Content-Length` bodies
doesn't justify an exception.

| File | Role |
|---|---|
| `MCPProtocol.swift` | `JSONValue` (dynamic JSON codec), JSON-RPC types, `MCPTool`, `MCPSchema` builders |
| `MCPToolbox.swift` | The six tools, backed by the real engines + GRDB |
| `MCPHTTPServer.swift` | HTTP/1.1 parsing, routing, dispatch, security |
| `MCPServerSettings.swift` | Persisted config, lifecycle, client-config generation |

Tools: `list_symbols`, `history_data`, `rank_ob`, `algosmart_assist`,
`previous_day_levels`, `smc_brief`. The first five are the ones asked
for; `smc_brief` bundles all of them across two timeframes and returns
the desk instructions with them, which is what an agent actually wants
for a single "analyse gold" turn.

Security, in order of what actually matters:

- binds `127.0.0.1` via `requiredLocalEndpoint` — **without this
  `NWListener` accepts on every interface**, which would put the trading
  data on the local network;
- validates `Origin` against loopback (the DNS-rebinding case the MCP
  spec calls out — a web page can script the user's loopback port, and
  the browser stamps the real origin);
- optional bearer token, constant-time compared;
- read-only by construction: every tool reads candles and computes.
  None writes to the database or touches app state.

Settings live under a new **MCP server** category, with copyable
`claude mcp add` and `mcpServers` JSON blocks — getting a working client
config into the clipboard is the whole job of that screen.

## Decisions & reasoning

**Tool errors vs protocol errors.** An unknown tool is a JSON-RPC error
(`-32602`); a tool that runs and fails returns `isError: true` with the
message in the result. The spec splits these, and the split matters: the
model needs to *see* "unknown symbol dogecoin, try: ounce, btc…" to
correct itself, which it can't if the client swallows it as a transport
fault. A test pins each side.

**The server reports the port it actually bound**, not the one requested.
With port 0 the OS picks one, and a status line naming the wrong port is
worse than no status line. This also removed a real test flake — random
ports collided with sockets the previous test was still tearing down.

**The POI-overlap flag carries the POI's price range**, not a bare
boolean. The overlap check runs against every POI while the brief prints
only the top few per side, so a bare "overlaps an ALGOSMART POI" cited
something the reader often couldn't see. Verified live: a zone at
4029.68–4038.70 was flagged against a POI at 4035.06–4039.03 that was
nowhere in the printed list. A citation a model can't cross-check is the
easiest number for it to invent, which is precisely what this pack exists
to prevent.

**`smc_brief` returns the system prompt in its `instructions` field.** An
external agent gets the same reasoning discipline as the in-app kind
rather than improvising its own method over the same numbers.

## Tests

`SMCEvidenceTests` (15) and `MCPServerTests` (20). **170 tests, 0
failures**, stable across repeated runs.

The MCP suite drives a real server on a real loopback socket over HTTP
rather than calling the router directly. Everything about this feature is
invisible from inside the app — the failure mode is a client that
connects and gets nothing useful — so the tests speak actual JSON-RPC.
Covered: handshake, `tools/list` completeness, notifications getting no
body, each tool's output shape and invariants (POC inside value area,
value area inside session range, zone top ≥ bottom), the two error
classes, bearer-token enforcement, and the cross-origin rejection.

The evidence tests pin the *derived* facts — location vs distance
agreement, unswept-level detection, previous-day absence on a single
session, JSON round-trip fidelity — not the detection itself, which has
its own suites.

## Verified live

App launched with the server enabled, driven over curl against real
stored gold data: handshake, `tools/list`, and every tool returning
sensible values (spot 4063.52, ATR 12.48, PDH 4079.18 / PDL 4019.24 both
unswept, an A 4/5 bearish zone at 4081.18–4087.66 confirmed by both
engines, sentinel honestly reporting "waiting for IDM / liquidity sweep"
rather than manufacturing a setup).

## Docs

`docs/SMC_MCP_PROMPT.md` — the copy-paste prompt for external MCP
clients, with a short variant and per-style timeframe settings. It tells
the model to resolve the symbol via `list_symbols`, since gold's id is
`ounce`, not `xauusd`.

## Not done

- **The in-app Smart Money Desk kind was verified by build + tests, not
  by clicking through the UI.** The plumbing matches the existing kinds
  exactly; a visual pass is still worth doing.
- **iPad target remains broken on `main`** — the same three pre-existing
  errors from the previous session (`indicatorInstances` missing on
  `ChartViewiPad`, `enhancedSonarlabOBZones` argument, `renkoConfig` out
  of scope). None of this work touches them, and none of the new files
  appear in the errors. `MCPServerCard.swift` is excluded from the iPad
  target (it uses `NSPasteboard`); the MCP server itself compiles for iOS.
- The server runs only while the app is open. A background/login-item
  mode would need its own design.
- `UserDefaults` for the token, deliberately: it guards a loopback socket
  that is already unreachable off-machine, and the Keychain would impose
  a prompt on every launch.
