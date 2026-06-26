# Helix Trading App — Web Version · Implementation Plan

> Source of truth for the web rebuild. Each phase has a clear goal,
> an explicit file list, and a "done when" checklist so whoever picks
> this up (human or AI) knows exactly where things stand and what to
> do next.
>
> Native app lives in `../GoldMonitorMac/`. Read `../CLAUDE.md` for
> the full domain context before touching anything.

---

## Stack Decision

| Concern | Choice | Notes |
|---|---|---|
| Framework | Next.js 15 App Router | SSR, API routes, streaming, Vercel-native deploy |
| Language | TypeScript (strict) | All source files, no `.js` allowed |
| Styling | Tailwind CSS v4 + shadcn/ui | Dark theme by default. Trading platform aesthetic |
| Charts | Lightweight Charts v5 (TradingView) | Financial-grade candles, built-in pan/zoom, Series API for overlays |
| Auth | Auth.js v5 (NextAuth) | Credentials provider, JWT sessions, role middleware |
| Database | PostgreSQL via Neon + Prisma ORM | Hosted on Vercel Marketplace |
| AI | Anthropic SDK (`@anthropic-ai/sdk`) | Server-side streaming. Replaces native `claude` CLI shell-out |
| Real-time prices | Twelve Data WebSocket (server-side proxy) → SSE to browser | Same data source as native app; key stays server-side |
| Client state | Zustand | Replaces `@StateObject` / `@Published` |
| Server data | TanStack Query (React Query v5) | Cache, background refetch, stale-while-revalidate |
| Email | Resend | Price alert emails |
| Deployment | Vercel | Fluid Compute, Edge Middleware for auth |

---

## Role Permission Matrix

| Feature | admin | trader | user |
|---|---|---|---|
| View dashboard & charts | ✅ | ✅ | ✅ |
| Live price sidebar | ✅ | ✅ | ✅ read-only |
| Technical indicators (SMA/EMA/BB/RSI/MACD/Stoch/UTBot) | ✅ | ✅ | ✅ |
| AI Analysis — all kinds | ✅ | ✅ | ❌ |
| Chart overlays (S/R, FVG, S&D, Scenario) | ✅ | ✅ | ❌ |
| Trade Journal | ✅ | ✅ | ❌ |
| Portfolio / Analytics | ✅ | ✅ | ❌ |
| Auto Trader (paper mode) | ✅ | ✅ | ❌ |
| Price Alerts | ✅ | ✅ | ❌ |
| News / Economic Calendar | ✅ | ✅ | ✅ |
| Settings (API keys, intervals) | ✅ | own keys only | ❌ |
| Admin Panel (all sections) | ✅ | ❌ | ❌ |
| User management (CRUD + roles) | ✅ | ❌ | ❌ |
| System-wide data source config | ✅ | ❌ | ❌ |
| Usage analytics & audit log | ✅ | ❌ | ❌ |

---

## Project Folder Layout

```
webapp/
├── PLAN.md                        ← this file
├── package.json
├── next.config.ts
├── tailwind.config.ts
├── tsconfig.json
├── prisma/
│   └── schema.prisma              ← single source of truth for DB schema
├── app/
│   ├── layout.tsx                 ← root layout, ThemeProvider, SessionProvider
│   ├── (auth)/
│   │   ├── login/page.tsx
│   │   └── invite/[token]/page.tsx
│   ├── admin/
│   │   ├── layout.tsx             ← admin shell, admin-only guard
│   │   ├── page.tsx               ← admin dashboard (user counts, AI usage, source health)
│   │   ├── users/
│   │   │   ├── page.tsx           ← user table, search, role filter
│   │   │   ├── [id]/page.tsx      ← edit user: role, enabled, reset password
│   │   │   └── new/page.tsx       ← create user + assign role
│   │   ├── settings/page.tsx      ← global API keys, fetch intervals, proxy config
│   │   └── audit/page.tsx         ← log of logins, role changes, AI calls
│   └── app/
│       ├── layout.tsx             ← app shell: sidebar + main area
│       ├── dashboard/
│       │   └── page.tsx           ← chart + indicators + stats row
│       ├── analysis/
│       │   └── page.tsx           ← AI analysis panel (streaming + history)
│       ├── journal/
│       │   └── page.tsx           ← trade journal CRUD
│       ├── portfolio/
│       │   └── page.tsx           ← equity curve, profit factor, expectancy
│       ├── alerts/
│       │   └── page.tsx           ← price alert management
│       ├── news/
│       │   └── page.tsx           ← Forex Factory economic calendar
│       ├── auto-trader/
│       │   └── page.tsx           ← paper trading engine + strategy profiles
│       └── settings/
│           └── page.tsx           ← per-user: password, display name, own API keys
├── api/                           ← Next.js Route Handlers live under app/ but
│   │                                documented here for clarity
│   ├── auth/[...nextauth]/route.ts
│   ├── ohlc/route.ts              ← Yahoo Finance fetch + Postgres cache
│   ├── prices/
│   │   └── stream/route.ts        ← SSE endpoint: re-broadcasts WS ticks
│   ├── ai/
│   │   └── analyze/route.ts       ← Anthropic streaming analysis
│   └── alerts/
│       └── cron/route.ts          ← Vercel cron: check thresholds, fire emails
├── components/
│   ├── chart/
│   │   ├── ChartContainer.tsx     ← Lightweight Charts root, handles resize
│   │   ├── CandleSeries.tsx       ← candle / line / heikin-ashi switcher
│   │   ├── VolumeSeries.tsx
│   │   ├── IndicatorSeries.tsx    ← SMA/EMA/BB overlaid on price chart
│   │   ├── OscillatorPanel.tsx    ← sub-chart (RSI / MACD / Stoch)
│   │   ├── SRLines.tsx            ← S/R level overlay from AI
│   │   ├── FVGBoxes.tsx           ← FVG zone rectangles
│   │   ├── SDZones.tsx            ← Supply & Demand rectangles
│   │   └── ScenarioLines.tsx      ← Entry / TP / SL dashed lines + bias pill
│   ├── sidebar/
│   │   ├── Sidebar.tsx
│   │   └── PairRow.tsx
│   ├── analysis/
│   │   ├── AnalysisActionDock.tsx ← Run / Stop / Apply overlays buttons
│   │   ├── AnalysisStream.tsx     ← streaming markdown output
│   │   ├── AspectChecklist.tsx    ← Combined mode: tick aspects
│   │   ├── HistoryList.tsx        ← past analysis entries
│   │   └── KindPicker.tsx         ← analysis kind selector
│   ├── admin/
│   │   ├── UserTable.tsx
│   │   ├── UserEditForm.tsx
│   │   └── AuditTable.tsx
│   └── ui/                        ← shadcn/ui auto-generated components live here
├── lib/
│   ├── indicators/
│   │   ├── sma.ts
│   │   ├── ema.ts
│   │   ├── bollinger.ts
│   │   ├── rsi.ts
│   │   ├── macd.ts
│   │   ├── stochastic.ts
│   │   ├── utbot.ts
│   │   └── heikinAshi.ts
│   ├── prompt-builder/
│   │   ├── kinds.ts               ← AnalysisKind enum + labels
│   │   ├── aspects.ts             ← AnalysisAspect enum + instructions
│   │   ├── systemPrompts.ts       ← all system prompt strings
│   │   ├── userPrompts.ts         ← user message assemblers per kind
│   │   └── index.ts
│   ├── parsers/
│   │   ├── extractJsonBlock.ts    ← brace-walk extractor
│   │   ├── parseSRLevels.ts
│   │   ├── parseFVGZones.ts
│   │   ├── parseTAScenario.ts
│   │   └── parseSupplyDemand.ts
│   ├── auto-trader/
│   │   ├── stateMachine.ts        ← idle→staged→active→cooldown/killed
│   │   └── paperBalance.ts
│   ├── prices/
│   │   ├── twelveDataWS.ts        ← server-side WS client + reconnect backoff
│   │   └── yahooFetch.ts          ← OHLC fetch + weekend-gap filtering
│   ├── auth.ts                    ← Auth.js config, role helpers
│   ├── db.ts                      ← Prisma client singleton
│   └── pairs.ts                   ← TradingPair catalog (port of TradingPair.swift)
├── middleware.ts                   ← Edge middleware: auth + role gate per path
├── store/
│   ├── usePairStore.ts            ← selected pair, live prices (Zustand)
│   ├── useChartStore.ts           ← timeframe, chartType, xDomain, yDomain
│   ├── useIndicatorStore.ts       ← enabled indicators/oscillators, config
│   └── useOverlayStore.ts         ← srLevels, fvgZones, sdZones, scenario
└── types/
    ├── trading.ts                 ← Candle, OHLCBar, TradingPair, Timeframe
    ├── analysis.ts                ← AnalysisKind, AnalysisAspect, SRLevels, FVGZone, TAScenario
    └── user.ts                    ← User, Role, Session
```

---

## Prisma Schema (full)

```prisma
// prisma/schema.prisma

generator client {
  provider = "prisma-client-js"
}

datasource db {
  provider = "postgresql"
  url      = env("DATABASE_URL")
}

enum Role {
  admin
  trader
  user
}

model User {
  id            String    @id @default(cuid())
  email         String    @unique
  name          String?
  passwordHash  String
  role          Role      @default(user)
  enabled       Boolean   @default(true)
  createdAt     DateTime  @default(now())
  lastLoginAt   DateTime?

  // per-user settings stored as JSON blobs
  indicatorConfig   Json?   // RSI period, MACD params, UT Bot key, etc.
  claudeApiKey      String? // optional per-user override (encrypted)

  sessions        Session[]
  invites         Invite[]
  analysisHistory AnalysisEntry[]
  journalEntries  JournalEntry[]
  alerts          PriceAlert[]
  paperBalance    PaperBalance?
  paperTrades     PaperTrade[]
  auditLogs       AuditLog[]    @relation("AuditTarget")
  auditActions    AuditLog[]    @relation("AuditActor")
}

model Session {
  id        String   @id @default(cuid())
  userId    String
  token     String   @unique
  expiresAt DateTime
  createdAt DateTime @default(now())
  user      User     @relation(fields: [userId], references: [id], onDelete: Cascade)
}

model Invite {
  id        String   @id @default(cuid())
  email     String
  role      Role     @default(user)
  token     String   @unique @default(cuid())
  usedAt    DateTime?
  expiresAt DateTime
  createdBy String
  creator   User     @relation(fields: [createdBy], references: [id])
  createdAt DateTime @default(now())
}

// ── OHLC cache ────────────────────────────────────────────────────────

model OHLCBar {
  id        String   @id @default(cuid())
  pairId    String
  interval  String   // "1h", "15m", "1d", etc.
  openTime  DateTime
  open      Float
  high      Float
  low       Float
  close     Float
  volume    Float    @default(0)

  @@unique([pairId, interval, openTime])
  @@index([pairId, interval, openTime])
}

// ── AI Analysis ───────────────────────────────────────────────────────

model AnalysisEntry {
  id          String   @id @default(cuid())
  userId      String
  pairId      String
  kind        String   // AnalysisKind rawValue
  aspects     String?  // comma-separated AnalysisAspect rawValues (combined mode)
  timeframe   String
  markdownOut String   @db.Text
  // parsed structured payloads
  srLevels    Json?
  fvgZones    Json?
  sdZones     Json?
  scenario    Json?
  altScenario Json?
  createdAt   DateTime @default(now())
  user        User     @relation(fields: [userId], references: [id], onDelete: Cascade)

  @@index([userId, pairId, kind])
}

// ── Trade Journal ─────────────────────────────────────────────────────

model JournalEntry {
  id           String    @id @default(cuid())
  userId       String
  pairId       String
  direction    String    // "long" | "short"
  entryPrice   Float
  exitPrice    Float?
  size         Float
  outcome      String?   // "win" | "loss" | "breakeven"
  pnl          Float?
  notes        String?   @db.Text
  analysisId   String?   // linked AnalysisEntry
  openedAt     DateTime
  closedAt     DateTime?
  createdAt    DateTime  @default(now())
  user         User      @relation(fields: [userId], references: [id], onDelete: Cascade)

  @@index([userId, pairId])
}

// ── Price Alerts ──────────────────────────────────────────────────────

model PriceAlert {
  id          String    @id @default(cuid())
  userId      String
  pairId      String
  direction   String    // "above" | "below"
  threshold   Float
  message     String?
  triggered   Boolean   @default(false)
  triggeredAt DateTime?
  createdAt   DateTime  @default(now())
  user        User      @relation(fields: [userId], references: [id], onDelete: Cascade)

  @@index([userId, triggered])
}

// ── Paper Trading ─────────────────────────────────────────────────────

model PaperBalance {
  id        String   @id @default(cuid())
  userId    String   @unique
  balance   Float    @default(10000)
  updatedAt DateTime @updatedAt
  user      User     @relation(fields: [userId], references: [id], onDelete: Cascade)
}

model PaperTrade {
  id           String    @id @default(cuid())
  userId       String
  pairId       String
  direction    String    // "long" | "short"
  entryPrice   Float
  exitPrice    Float?
  size         Float
  tp           Float
  sl           Float
  status       String    @default("open") // "open" | "closed" | "killed"
  pnl          Float?
  scenarioId   String?   // linked AnalysisEntry id
  openedAt     DateTime  @default(now())
  closedAt     DateTime?
  user         User      @relation(fields: [userId], references: [id], onDelete: Cascade)

  @@index([userId, status])
}

// ── Audit Log ─────────────────────────────────────────────────────────

model AuditLog {
  id        String   @id @default(cuid())
  actorId   String?
  targetId  String?
  action    String   // "login" | "role_change" | "user_disabled" | "ai_call" | etc.
  meta      Json?
  createdAt DateTime @default(now())
  actor     User?    @relation("AuditActor", fields: [actorId], references: [id])
  target    User?    @relation("AuditTarget", fields: [targetId], references: [id])

  @@index([actorId, createdAt])
  @@index([action, createdAt])
}

// ── System Settings (admin-controlled) ───────────────────────────────

model SystemSetting {
  key       String @id
  value     String @db.Text
  updatedAt DateTime @updatedAt
}
```

---

## Phase 1 — Foundation, Auth & Admin Panel

**Goal:** working login system with role-based access control and a full admin panel.
No trading features yet — this is the skeleton everything else plugs into.

### Tasks

- [ ] `npx create-next-app@latest webapp --typescript --tailwind --app --src-dir=false --import-alias="@/*"`
- [ ] Install core deps: `prisma @prisma/client next-auth@beta @auth/prisma-adapter bcryptjs zod shadcn/ui @radix-ui/* lucide-react`
- [ ] Init shadcn/ui dark theme: `npx shadcn@latest init` (dark mode, CSS variables)
- [ ] Write `prisma/schema.prisma` (full schema above)
- [ ] Set up Neon database, add `DATABASE_URL` to `.env.local`
- [ ] `prisma migrate dev --name init`
- [ ] Seed script: `prisma/seed.ts` — creates default admin user (`admin@helix.local` / `changeme`)

**Auth.js config (`lib/auth.ts`)**
- [ ] Credentials provider: email + bcrypt password check
- [ ] JWT strategy, encode `{ id, email, role }` into token
- [ ] `authorized` callback: reject disabled accounts
- [ ] Session callback: expose `role` on `session.user`

**Middleware (`middleware.ts`)**
- [ ] `/admin/*` → redirect to `/login` if no session or role !== `admin`
- [ ] `/app/*` → redirect to `/login` if no session
- [ ] `/login` → redirect to `/app/dashboard` if already authenticated

**Pages**
- [ ] `/login` — branded dark UI, email + password fields, error states, "forgot password" placeholder
- [ ] `/invite/[token]` — verify token, set password form, auto-login after

**Admin pages**
- [ ] `/admin` — dashboard: stat cards (total users, users by role, AI calls today, sources online/offline)
- [ ] `/admin/users` — paginated table (name, email, role badge, enabled toggle, last login, actions)
  - Search by email/name
  - Filter by role chip
  - Bulk enable/disable
- [ ] `/admin/users/new` — form: email, name, role, "send invite email" or "set password directly"
- [ ] `/admin/users/[id]` — edit form: role dropdown, enabled toggle, reset password link, view linked audit events
- [ ] `/admin/settings` — form fields: Twelve Data API key (encrypted at rest), fetch interval (Yahoo poll ms), proxy host/port (SOCKS5), Claude API key (system fallback)
- [ ] `/admin/audit` — table of AuditLog rows, filter by action type, actor, date range

**API routes**
- [ ] `POST /api/auth/[...nextauth]` — Auth.js handler
- [ ] `POST /api/admin/users` — create user (admin only)
- [ ] `PATCH /api/admin/users/[id]` — update role/enabled (admin only)
- [ ] `DELETE /api/admin/users/[id]` — soft-delete (admin only)
- [ ] `POST /api/admin/invite` — generate invite token, send email
- [ ] `GET/PUT /api/admin/settings` — system settings CRUD

**Done when:**
- Admin can log in and land on `/admin`
- Admin can create users, assign roles, disable accounts
- Invite link flow works end-to-end
- Middleware correctly gates `/admin/*` and `/app/*`
- Non-admin hitting `/admin` gets redirected to `/app/dashboard`

---

## Phase 2 — Core Dashboard & Live Market Data

**Goal:** interactive candlestick chart with live price ticks and OHLC history.

### Tasks

**Pair catalog (`lib/pairs.ts`)**
- [ ] Port `TradingPair.catalog` from Swift: XAU (gold ounce), BTC, ETH, SOL, DJI
- [ ] `TradingPair` type: `{ id, name, symbol, colorHex, category }`
- [ ] `Category`: `forex | crypto | indices`
- [ ] Weekend-gap filter logic (same as native `MarketCalendar.swift`): drop Sat/Sun bars for `forex` and `indices`

**OHLC data pipeline**
- [ ] `lib/prices/yahooFetch.ts` — port of `YahooGoldSource.swift`:
  - Map `pairId → Yahoo symbol` (`ounce → GC=F`, `btc → BTC-USD`, etc.)
  - Fetch `https://query2.finance.yahoo.com/v8/finance/chart/{symbol}?range={r}&interval={i}`
  - Parse timestamps + OHLCV arrays
  - Filter weekend bars for forex/indices
  - Return `OHLCBar[]`
- [ ] `GET /api/ohlc?pairId=ounce&interval=1h&range=1y` route:
  - Check Postgres cache (`OHLCBar` table) for recent bars
  - If stale / missing: fetch from Yahoo, upsert into DB
  - Return JSON array
  - Cache-Control header: `s-maxage=60` (1-minute CDN cache)

**Live price streaming**
- [ ] `lib/prices/twelveDataWS.ts` — server-side singleton:
  - Connect to `wss://ws.twelvedata.com/v1/quotes/price?apikey={key}`
  - Subscribe to `XAU/USD`, `BTC/USD`, `ETH/USD`, `SOL/USD`
  - Reconnect with exponential backoff (1s → 2s → 4s → max 30s) same as `TwelveDataSpotStream.swift`
  - Emit tick events on a Node.js EventEmitter
- [ ] `GET /api/prices/stream` — SSE route:
  - Attach to the WS singleton's EventEmitter
  - Push `data: {pairId, price, change, changePercent}\n\n` on each tick
  - On client disconnect: remove listener

**Chart components**
- [ ] `components/chart/ChartContainer.tsx` — mounts `createChart()`, handles ResizeObserver, passes `IChartApi` via context
- [ ] `components/chart/CandleSeries.tsx`:
  - Mode prop: `candle | line | heikinAshi`
  - For `heikinAshi`: run `lib/indicators/heikinAshi.ts` transform on raw candles before setting data (same as native: indicators still read raw closes)
  - Bar-index X axis: map each candle to its array index so weekend gaps disappear (same design decision as native app)
- [ ] `components/chart/VolumeSeries.tsx` — histogram below price chart, volume bars colored by candle direction

**Zustand stores**
- [ ] `store/usePairStore.ts`:
  - `pairs: TradingPair[]` (seeded from catalog, prices updated by SSE)
  - `selectedPairId: string`
  - `connectSSE()` action: subscribes to `/api/prices/stream`, applies ticks to `pairs`
- [ ] `store/useChartStore.ts`:
  - `timeframe: Timeframe` (default `1h`)
  - `chartType: 'candle' | 'line' | 'heikinAshi'` (default `candle`)
  - `showVolume: boolean`
  - `xDomain: [number, number] | null`
  - Persisted in `localStorage` (Zustand persist middleware)

**Dashboard page (`app/app/dashboard/page.tsx`)**
- [ ] Pair header: live price (large), change % badge, refresh button, "last updated" timer
- [ ] Chart toolbar row: timeframe chips (1m 5m 15m 1h 4h 1D 1W), chart type toggle, volume toggle, indicators menu button, layers button, fullscreen button, AI Analyze button (trader/admin only)
- [ ] Main chart area: `ChartContainer` → `CandleSeries` + `VolumeSeries`
- [ ] Stats row: 24H high, 24H low, 24H change, volume

**Sidebar**
- [ ] `components/sidebar/Sidebar.tsx` — collapsible, same toggle-on-fullscreen behavior as native
- [ ] `components/sidebar/PairRow.tsx` — pair name, symbol, live price, change %, colored left border, online indicator dot

**Done when:**
- All 5 pairs show live ticking prices in the sidebar
- Dashboard shows candlestick chart loading real OHLC data from Yahoo
- Timeframe switching works (1m through 1W)
- Chart type switching (candle / line / heikin ashi) works
- Weekend gaps absent for XAU and DJI, present for BTC/ETH/SOL

---

## Phase 3 — Technical Indicators & Oscillators

**Goal:** full indicator toolkit rendered on chart, per-user config persisted in DB.

### Indicator math (`lib/indicators/`)

Each function signature: `(closes: number[], params) → number[]` (aligned to input array length, `NaN` for warm-up bars).

- [ ] `sma.ts` — `sma(closes, period)`
- [ ] `ema.ts` — `ema(closes, period)` (Wilder smoothing for RSI, regular for EMA20/50/200)
- [ ] `bollinger.ts` — `bollinger(closes, period, stdDev)` → `{ upper, middle, lower }[]`
- [ ] `rsi.ts` — `rsi(closes, period)` (Wilder RSI, same as TradingView)
- [ ] `macd.ts` — `macd(closes, fast, slow, signal)` → `{ macd, signal, histogram }[]`
- [ ] `stochastic.ts` — `stochastic(highs, lows, closes, kPeriod, dPeriod)` → `{ k, d }[]`
- [ ] `utbot.ts` — port of `UTBot.swift`: ATR trailing stop + buy/sell signals
- [ ] `heikinAshi.ts` — `transform(candles)` → `Candle[]` (same transform as native)

### Chart indicator overlays (`components/chart/IndicatorSeries.tsx`)

Uses Lightweight Charts `LineSeries` / `AreaSeries` for each enabled indicator overlaid on the price chart:
- [ ] SMA 20 (dashed, thin)
- [ ] SMA 50 (solid, medium)
- [ ] EMA 200 (solid, thick)
- [ ] Bollinger Bands (upper + lower as area, middle as line)
- [ ] UT Bot signals (up/down arrow markers via `setMarkers()`)

### Oscillator sub-panels (`components/chart/OscillatorPanel.tsx`)

Separate `createChart()` instances below the main chart, X-axis synced via `crosshairMove` events:
- [ ] RSI panel: line + overbought (70) / oversold (30) dashed levels
- [ ] MACD panel: histogram bars (green/red by sign) + signal line
- [ ] Stochastic panel: K line + D line + 80/20 levels

### UI

- [ ] **Indicators menu** (`components/chart/IndicatorsMenu.tsx`) — dropdown with checkboxes: SMA20, SMA50, EMA200, Bollinger Bands, UT Bot. Saves selection to `store/useIndicatorStore.ts`
- [ ] **Oscillators menu** — separate section in same dropdown: RSI, MACD, Stochastic
- [ ] **Indicator settings panel** (`components/chart/IndicatorSettingsPanel.tsx`) — slide-in sheet:
  - RSI: period (default 14)
  - MACD: fast (12), slow (26), signal (9)
  - Stochastic: K period (14), D period (3)
  - Bollinger: period (20), std dev (2)
  - UT Bot: key value (1.0), ATR period (10)
  - Save button → `PATCH /api/user/settings` (stores JSON in `User.indicatorConfig`)
- [ ] **Layers panel** (`components/chart/LayersPanel.tsx`) — popover listing every rendered layer (price series, each indicator, each oscillator, AI overlays) with eye-icon show/hide toggles
- [ ] Settings loaded from DB on session start, merged into `store/useIndicatorStore.ts`

### Zustand store

- [ ] `store/useIndicatorStore.ts`:
  - `enabledIndicators: Set<IndicatorKind>`
  - `enabledOscillators: Set<OscillatorKind>`
  - `hiddenIndicators: Set<IndicatorKind>` (Layers panel toggle)
  - `hiddenOscillators: Set<OscillatorKind>`
  - `config: IndicatorConfig` (periods, params)
  - `setIndicator(k, on)` / `setOscillator(k, on)` / `toggleHidden(...)`
  - Persist to `localStorage` + sync to DB on change

**Done when:**
- SMA, EMA, Bollinger draw correctly on price chart
- RSI, MACD, Stochastic draw in sub-panels below price, X-axis synced
- UT Bot buy/sell arrow markers appear on chart
- Indicator settings panel saves and loads correctly per user
- Layers panel hides/shows each layer independently

---

## Phase 4 — AI Analysis (trader + admin only)

**Goal:** port all AI analysis flows end-to-end: prompt assembly → Claude streaming → structured block parsing → chart overlays.

### Analysis kinds (port of `AnalysisKind` enum)

```typescript
// lib/prompt-builder/kinds.ts
export type AnalysisKind =
  | 'full'
  | 'supportResistance'
  | 'fvg'
  | 'multiTimeframe'
  | 'confluenceScanner'   // raw value "betaTSA" kept for DB back-compat
  | 'custom'
  | 'combined'
  | 'topDownSniper'
```

### Analysis aspects (port of `AnalysisAspect` enum)

```typescript
// lib/prompt-builder/aspects.ts
export type AnalysisAspect =
  | 'technical'
  | 'levels'
  | 'fvg'
  | 'supplyDemand'
  | 'multiTimeframe'
  | 'scenarios'
```

### Prompt builder (`lib/prompt-builder/`)

- [ ] `systemPrompts.ts` — direct port of all system prompt strings from `PromptBuilder.swift`:
  - `systemFullTA`
  - `systemSR`
  - `systemFVG`
  - `systemMultiTF`
  - `systemConfluenceScanner`
  - `systemCustomDefault`
  - `systemTopDownSniper(htf, mtf, ltf)`
  - `systemCombined(aspects[])` — assembles combined system prompt from selected aspects
- [ ] `userPrompts.ts` — assembles the user message:
  - OHLC table (last N candles as CSV: `time,open,high,low,close,volume`)
  - Indicator values (EMA20/50/200, RSI, MACD histogram, Stochastic K/D at last bar)
  - HTF context block for multi-TF kinds (bundles 15m + 1h + 4h tables)
  - For `confluenceScanner`: prior run hint block
- [ ] `index.ts` — `buildPrompt(kind, aspects, ohlcBars, indicatorValues, options)` → `{ system, user }`

### AI streaming route

- [ ] `POST /api/ai/analyze` — protected (trader/admin role):
  - Validate request body with Zod: `{ pairId, kind, aspects?, timeframe, customPrompt? }`
  - Load OHLC bars from Postgres (or fetch if stale)
  - Compute indicator values via `lib/indicators/*`
  - Build system + user prompt via `lib/prompt-builder`
  - Call Anthropic SDK: `anthropic.messages.stream({ model: 'claude-sonnet-4-6', system, messages: [{role:'user', content: user}], max_tokens: 8000 })`
  - Return SSE stream: pipe SDK stream chunks as `data: {delta}\n\n`
  - On stream end: parse structured blocks, save `AnalysisEntry` to DB
  - Write `AuditLog` row: `{ action: 'ai_call', meta: { pairId, kind } }`

### Structured block parsers (`lib/parsers/`)

Port of Swift parsers — brace-walk JSON extraction (same algorithm):
- [ ] `extractJsonBlock.ts` — finds the first `{...}` after a given header comment
- [ ] `parseSRLevels.ts` — extracts `LEVELS_JSON` → `{ support: number[], resistance: number[] }`
- [ ] `parseFVGZones.ts` — extracts `FVG_JSON` → `FVGZone[]`
- [ ] `parseTAScenario.ts` — extracts `SCENARIO_JSON` + `ALT_SCENARIO_JSON` → `TAScenario`
- [ ] `parseSupplyDemand.ts` — extracts `SUPPLY_DEMAND_JSON` → `SupplyDemandZone[]`

### Chart overlay components

All use Lightweight Charts Series / Primitives API:
- [ ] `components/chart/SRLines.tsx` — horizontal lines: support green dashed, resistance red dashed
- [ ] `components/chart/FVGBoxes.tsx` — rectangle primitives: bull green translucent, bear red translucent
- [ ] `components/chart/SDZones.tsx` — similar to FVG: demand green, supply red
- [ ] `components/chart/ScenarioLines.tsx` — entry (blue), TP (green), SL (red) dashed horizontal lines + bias capsule annotation. Alt scenario rendered in muted colors

### Overlay Zustand store

- [ ] `store/useOverlayStore.ts`:
  - `srLevels: SRLevels`
  - `fvgZones: FVGZone[]`
  - `sdZones: SupplyDemandZone[]`
  - `scenario: TAScenario | null`
  - `altScenario: TAScenario | null`
  - Visibility booleans for each layer
  - `applyFromEntry(entry: AnalysisEntry)` — parses and applies all JSON payloads
  - `clearForPair()` — clear on pair switch (same lifecycle as native `@State` resets)

### Analysis page (`app/app/analysis/page.tsx`)

- [ ] **Kind picker** — tab bar or dropdown: Full TA / S&R / FVG / Multi-TF / Confluence Scanner / Top-Down Sniper / Combined / Custom
- [ ] **Aspect checklist** (Combined mode) — checkboxes: Technical read, S&R, FVG, S&D, Multi-TF, Trade Scenarios
- [ ] **Custom prompt editor** — `textarea` shown only for `custom` kind, saved to DB per user
- [ ] **Action dock** — Run button, Stop button (cancels SSE), Apply Overlays button (re-parses last entry to chart)
- [ ] **Streaming output** — real-time markdown render using `react-markdown` + `remark-gfm`. Tokens stream in as they arrive
- [ ] **History panel** — list of past `AnalysisEntry` rows for selected pair/kind. Click to re-render markdown + re-apply overlays. Capped display at 50

### Integration with dashboard

- [ ] "AI Analyze" button in dashboard toolbar opens analysis panel as a right-side drawer (or navigates to `/app/analysis`)
- [ ] On analysis completion: parsed overlays automatically appear on chart
- [ ] Layers panel includes AI overlay visibility toggles
- [ ] "Delete overlay" in layers panel calls `useOverlayStore().clearX()`

**Done when:**
- All 8 analysis kinds run end-to-end and stream markdown output
- Structured JSON blocks are parsed and overlays appear on the chart
- History loads past entries and re-applies overlays on click
- `user` role gets 403 when hitting `/api/ai/analyze`
- Audit log records every AI call with pair + kind

---

## Phase 5 — Portfolio, Journal & Alerts

**Goal:** trade outcome tracking, analytics, and price notifications.

### Trade Journal (`app/app/journal/`)

- [ ] Journal entry form: pair picker, direction (Long/Short), entry price, exit price, size, notes (markdown textarea), link to analysis entry (dropdown of recent history), outcome (Win/Loss/Break-Even), opened/closed dates
- [ ] Journal list view: table of entries sortable by date/pair/outcome, P&L column, edit + delete actions
- [ ] `POST /api/journal` — create entry
- [ ] `PATCH /api/journal/[id]` — update
- [ ] `DELETE /api/journal/[id]` — delete

### Portfolio / Analytics (`app/app/portfolio/`)

Port of `AnalyticsView.swift` + `AnalysisStore` outcome data:

- [ ] **Equity curve** — Lightweight Charts `AreaSeries` of cumulative P&L over time. Filter chip: All / by AnalysisKind
- [ ] **Profit factor card** — gross wins / gross losses (ratio). Color: green if > 1.0, red if < 1.0
- [ ] **Expectancy per kind** — average P&L per closed trade, grouped by linked analysis kind
- [ ] **Win rate** — wins / total closed, shown as percentage + donut chart
- [ ] **Average R:R** — average (TP distance / SL distance) for trades linked to scenario entries
- [ ] `GET /api/portfolio/stats` — aggregates from `JournalEntry` rows for authenticated user

### Price Alerts (`app/app/alerts/`)

- [ ] Alert creation: pair picker, direction (Above / Below), threshold price, optional note
- [ ] Alert list: shows active + triggered alerts, delete action
- [ ] `GET /api/alerts` — list user's alerts
- [ ] `POST /api/alerts` — create
- [ ] `DELETE /api/alerts/[id]` — delete
- [ ] `GET /api/alerts/cron` — Vercel cron job (every 60 seconds):
  - Load all non-triggered alerts
  - Compare against latest price tick (from `OHLCBar` table, most recent close)
  - Trigger matching alerts: set `triggered=true`, `triggeredAt=now()`
  - Send email via Resend (`alert@helix.app`)
  - Push in-app notification (server → SSE `/api/prices/stream` piggybacked channel, or separate `/api/notifications/stream`)
- [ ] Notification bell in header: shows unread count, dropdown of recent triggers

### News / Economic Calendar (`app/app/news/`)

Port of `ForexFactorySource.swift`:
- [ ] `GET /api/news` — fetch Forex Factory calendar XML/JSON for the current week, parse into events: `{ date, time, currency, impact, title, forecast, actual, previous }`
- [ ] Cache in `SystemSetting` table (key `forex_factory_cache`, TTL 1 hour)
- [ ] News page: table grouped by day, color-coded impact (red=high, orange=medium, yellow=low), currency filter chips (USD, EUR, XAU, etc.)
- [ ] High-impact events flagged on chart timeline as vertical markers

**Done when:**
- Users can create journal entries and see P&L totals in portfolio
- Equity curve plots correctly from journal data
- Price alert fires email and in-app notification when threshold crossed
- Forex Factory events load and display in the news page

---

## Phase 6 — Auto Trader (Paper Mode)

**Goal:** port `AutoTraderEngine.swift` state machine for paper trading. No real broker connection.

### State machine (`lib/auto-trader/stateMachine.ts`)

Port of the Swift `AutoTraderEngine`:

```typescript
type AutoTraderState =
  | { status: 'idle' }
  | { status: 'staged'; scenarioId: string; expectingFill: boolean; rank: number; total: number }
  | { status: 'active'; scenarioId: string; tradeId: string }
  | { status: 'cooldown'; until: Date }
  | { status: 'killed'; reason: string }
```

- [ ] `stateMachine.ts` — pure transition function `(state, event) → state` (easy to test)
- [ ] Events: `STAGE_SCENARIO`, `FILL_CONFIRMED`, `TP_HIT`, `SL_HIT`, `INVALIDATED`, `KILL`, `COOLDOWN_EXPIRED`, `QUEUE_NEXT`
- [ ] Scenario queue: when Confluence Scanner emits scored scenarios, stage top one, queue rest. On invalidation, pop next from queue before re-running analysis (same as native `scenarioQueueByPair`)
- [ ] `paperBalance.ts` — P&L calculation on trade close, update `PaperBalance` in DB

### API routes

- [ ] `GET /api/auto-trader/state?pairId=ounce` — current state for pair
- [ ] `POST /api/auto-trader/kill` — force `killed` state
- [ ] `POST /api/auto-trader/stage` — manually stage a scenario
- [ ] Cron job (every 30s): check active trades against latest price; fire `TP_HIT` or `SL_HIT` events

### Strategy profiles

- [ ] `StrategyProfile` type: `{ name, positionType: 'scalp'|'swing'|'position', riskPercent, tpMultiplier, slMultiplier, maxConcurrent, pauseBeforeHighImpact }`
- [ ] Stored as JSON in `User.indicatorConfig` (reuse the settings blob)
- [ ] Strategy profile sheet: form fields, save to DB

### UI (`app/app/auto-trader/page.tsx`)

- [ ] **State pill** per pair: `IDLE` (grey), `STAGED n/m` (yellow), `ACTIVE` (green), `COOLDOWN` (orange), `KILLED` (red) — same pill colors as native
- [ ] **Auto Trader card** per pair: current state, last staged scenario entry/TP/SL, risk amount
- [ ] **Override controls**: Kill button, Force Stage button (takes current scenario from analysis store)
- [ ] **Strategy profile** section: profile selector, edit button
- [ ] **Trade log** table: all paper trades for user, status (open/closed/killed), P&L

**Done when:**
- Paper trading state machine transitions correctly on TP/SL hit events
- Paper balance updates on trade close
- Strategy profiles save and load
- Staged scenarios show entry/TP/SL lines on dashboard chart

---

## Phase 7 — Admin Panel (Advanced) & Polish

**Goal:** complete the admin experience, PWA support, and production hardening.

### Advanced admin features

- [ ] **Admin dashboard stats** — `GET /api/admin/stats`:
  - Total users by role
  - AI calls last 7 days (from AuditLog, grouped by day)
  - Active WebSocket connections (count from Twelve Data WS singleton)
  - Data source health: Twelve Data WS last event timestamp, Yahoo last successful fetch
- [ ] **Usage limits** — add `dailyAiCallLimit: Int` to `User` model. Middleware in `/api/ai/analyze` checks today's AuditLog count vs limit, returns 429 if exceeded
- [ ] **System announcements** — `POST /api/admin/announcement` saves to `SystemSetting` table, surfaced as a dismissable banner in `/app/` layout (mirrors `WhatsNewView` / `ReleaseNotes.swift`)
- [ ] **API key management** — Twelve Data key and Claude key shown in `/admin/settings` as masked inputs. Values encrypted at rest using AES-GCM with `ENCRYPTION_KEY` env var before storing in `SystemSetting`

### Progressive Web App

- [ ] `app/manifest.json` — name, icons, theme color (dark), display `standalone`
- [ ] `next-pwa` or manual service worker for offline OHLC cache
- [ ] App is installable on macOS (Chrome / Safari) and mobile

### Polish

- [ ] Dark / light theme toggle in header (dark default, same as native app aesthetic)
- [ ] Keyboard shortcuts: `1-7` for timeframes, `C` for candle type cycle, `F` for fullscreen, `A` for AI analyze
- [ ] Pair quick-switch: `G` for gold ounce, `B` for BTC, etc.
- [ ] Loading skeleton for chart while OHLC fetches
- [ ] Error boundary with "Retry" button per panel
- [ ] Empty state illustrations for journal, portfolio (no trades yet)
- [ ] `robots.txt` + `sitemap.xml` (app is behind auth, so `noindex`)

### Performance

- [ ] OHLC bars chunked: load last 500 bars immediately, lazy-load earlier history on pan-left
- [ ] React Query `staleTime: 60_000` for OHLC, `staleTime: 0` for live ticks
- [ ] `React.memo` + `useMemo` on heavy indicator computation (don't recompute EMA200 on every render)
- [ ] Lightweight Charts handles 10,000 bars natively — no virtualization needed for chart itself

**Done when:**
- Admin dashboard shows real usage numbers
- Daily AI call limit enforced per user
- App installs as PWA on macOS
- All keyboard shortcuts work
- Chart loads skeleton → data within 1 second for cached pairs

---

## Environment Variables

```bash
# .env.local (never commit)

# Database
DATABASE_URL="postgresql://..."

# Auth.js
AUTH_SECRET="..."                          # openssl rand -base64 32
AUTH_URL="http://localhost:3000"

# Anthropic
ANTHROPIC_API_KEY="sk-ant-..."

# Twelve Data
TWELVE_DATA_API_KEY="..."

# Resend (price alert emails)
RESEND_API_KEY="re_..."
FROM_EMAIL="alerts@helix.app"

# Encryption key for sensitive settings stored in DB
ENCRYPTION_KEY="..."                       # 32-byte hex

# Optional: SOCKS5 proxy for restricted regions
PROXY_HOST=""
PROXY_PORT=""
```

---

## Getting Started (once implementation begins)

```bash
cd webapp
npm install
cp .env.example .env.local   # fill in values
npx prisma migrate dev
npx prisma db seed            # creates admin@helix.local / changeme
npm run dev
```

Open `http://localhost:3000` — redirects to `/login`.
Log in as admin, then create trader/user accounts from `/admin/users`.

---

## Implementation Order

| Phase | Estimated scope | Blocks |
|---|---|---|
| 1 — Auth & Admin | ~3 days | nothing |
| 2 — Dashboard & Live Data | ~3 days | Phase 1 (auth guard) |
| 3 — Indicators | ~2 days | Phase 2 (chart exists) |
| 4 — AI Analysis | ~3 days | Phase 2 + 3 (OHLC + indicators needed for prompt) |
| 5 — Portfolio, Journal, Alerts | ~2 days | Phase 1 (DB), Phase 4 (analysis links) |
| 6 — Auto Trader | ~2 days | Phase 4 (needs scenario output), Phase 5 (journal link) |
| 7 — Admin advanced + Polish | ~2 days | all phases |

Total: ~17 focused dev days for a single developer working through phases in order.

---

## What This Web App Is NOT

- Not a broker bridge — paper trading only, no execution venues
- Not for public signup — admin creates all accounts
- Not a mobile-first app — desktop-optimized (same target as native), but responsive enough for tablet viewing
- Not a replacement for the native macOS app — they share the same data sources and concepts but are independent deployments
