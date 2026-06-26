import Foundation

/// What the user is asking the model to do. Different kinds get different
/// system prompts and slightly different framing in the user message —
/// e.g. Support/Resistance asks for a structured JSON payload at the end
/// so the chart can parse out level numbers and draw them.
enum AnalysisKind: String, CaseIterable, Identifiable, Codable {
    /// Full technical analysis — trend / levels / indicators / outlook.
    case full
    /// Support & Resistance only, with structured level data.
    case supportResistance
    /// Fair Value Gap / Inverse Fair Value Gap detection (ICT concepts).
    case fvg
    /// Multi-timeframe comparison — runs across 15m, 1h, 4h and asks
    /// the model for a single comparison table.
    case multiTimeframe
    /// Confluence Trade Scanner — multi-TF (15m / 1h / 4h) sweep
    /// that runs Supply & Demand first (main + alt scenario), then
    /// optionally expands to market structure with scored
    /// scenarios for the auto-trader's fallback queue. Outputs a
    /// SCENARIO_JSON plan like `.full` does, so the chart / PlanCards
    /// reuse the same path. Raw value stays "betaTSA" so persisted
    /// history loads back-compat across the rename.
    case confluenceScanner = "betaTSA"
    /// User-authored prompt. The system prompt is whatever the user
    /// has typed into the page's editor (persisted via @AppStorage)
    /// — the rest of the pipeline (OHLC table, indicators, HTF
    /// context block, structured-block parsing) runs as normal so
    /// the prompt operates against real symbol data and any
    /// SCENARIO_JSON / LEVELS_JSON / FVG_JSON blocks the user asks
    /// for surface in the right column.
    case custom
    /// Multi-aspect analysis driven by the checklist card. The user
    /// ticks one or more `AnalysisAspect`s; the system + user
    /// prompts are assembled dynamically from the chosen set (see
    /// `systemCombined` / `userPromptCombined`). This is the
    /// default manual-analysis path; it can emit any of the
    /// structured blocks, so `recordCompletion` parses all of them.
    case combined
    /// Top-Down Sniper — strict top-down multi-TF model with a
    /// fixed timeframe role split: 4H sets the directional bias
    /// (trend / key levels / S&D), 1H finds the setup (breakout /
    /// pullback / order block / FVG / liquidity), 15m confirms +
    /// gives the precise entry. Emits LEVELS / SUPPLY_DEMAND / FVG
    /// / SCENARIO blocks. See `systemTopDownSniper`.
    case topDownSniper

    var id: String { rawValue }

    var label: String {
        switch self {
        case .full:              return "Technical Analysis"
        case .supportResistance: return "Support & Resistance"
        case .fvg:               return "FVG / iFVG"
        case .multiTimeframe:    return "Multi-Timeframe"
        case .confluenceScanner: return "Confluence Trade Scanner"
        case .custom:            return "Custom"
        case .combined:          return "Analysis"
        case .topDownSniper:     return "Top-Down Sniper"
        }
    }

    /// Short noun shown in the streaming pane header ("Run the …
    /// analyst").
    var noun: String {
        switch self {
        case .full:              return "technical-analysis"
        case .supportResistance: return "support/resistance"
        case .fvg:               return "FVG/iFVG"
        case .multiTimeframe:    return "multi-timeframe"
        case .confluenceScanner: return "confluence-scanner"
        case .custom:            return "custom"
        case .combined:          return "analysis"
        case .topDownSniper:     return "top-down-sniper"
        }
    }
}

/// Constructs prompts sent to AI engines. The system prompt frames the
/// model's role; the user message bundles the raw evidence. Each
/// `AnalysisKind` has its own variant so the model focuses on the
/// specific deliverable the user asked for.
enum PromptBuilder {

    // ── System prompts ────────────────────────────────────────────────

    /// Pick the right system prompt for the analysis kind. Routes are
    /// kept inline here so adding a new kind is one switch case + one
    /// constant.
    static func systemPrompt(for kind: AnalysisKind) -> String {
        switch kind {
        case .full:              return systemFullTA
        case .supportResistance: return systemSR
        case .fvg:               return systemFVG
        case .multiTimeframe:    return systemMultiTF
        case .confluenceScanner: return systemConfluenceScanner
        case .custom:            return systemCustomDefault
        case .combined:          return systemCustomDefault   // real runs override via systemCombined(...)
        case .topDownSniper:     return systemTopDownSniper(htf: "4H", mtf: "1H", ltf: "15m")  // real runs override per trio
        }
    }

    /// System framing for `.custom` chat-style runs. The user types
    /// their first message into the input bar; this prompt tells the
    /// model who it is + what data is attached + how to surface
    /// structured payloads so the right column lights up. Same
    /// pipeline (OHLC, indicators, HTF) as the canned kinds — only
    /// the system role changes.
    private static let systemCustomDefault = """
    You are a senior gold-market technical analyst answering the
    user's questions in a conversational thread. Each turn you'll
    see the pair name, timeframe, last close, 24h change, the most
    recent OHLC bars, a precomputed indicator snapshot (RSI, MACD,
    EMA50/EMA200, ATR, order blocks, volume), and a one-line
    higher-timeframe context summary.

    Answer concisely and reference specific numbers from the data
    above whenever possible. Don't pad with disclaimers — the user
    is a trader and treats your output as analysis, not advice.

    When the user asks for something that maps to a structured
    payload, emit the matching block at the END of your markdown
    so the chart can pick it up:

    - Trade plan → ### SCENARIO_JSON
      ```json
      {"bias":"long|short|neutral","entry":<number>,"tp":<number>,"sl":<number>}
      ```
      For long: tp > entry > sl. For short: sl > entry > tp.

    - Alternative plan (when relevant) → ### ALT_SCENARIO_JSON
      Same shape.

    - Key support/resistance levels → ### LEVELS_JSON
      ```json
      {"support":[<numbers>],"resistance":[<numbers>]}
      ```

    - Fair-value gaps → ### FVG_JSON
      ```json
      {"fvgs":[{"barStart":<int>,"barEnd":<int>,"low":<number>,"high":<number>,"direction":"bullish|bearish","mitigated":<bool>}]}
      ```
      `barStart` / `barEnd` are NEGATIVE offsets from the latest
      bar (-1 = latest).

    - Supply & Demand zones → ### SUPPLY_DEMAND_JSON
      ```json
      {"zones":[{"barStart":<int>,"barEnd":<int>,"low":<number>,"high":<number>,"type":"demand|supply","fresh":<bool>,"strength":"weak|medium|strong"}]}
      ```
      Demand = last bearish/neutral base candle(s) before a sharp
      UP impulse; Supply = last bullish/neutral base candle(s)
      before a sharp DOWN impulse.

    Use raw numbers (no thousands separators, no currency symbols)
    inside the JSON. Omit a block entirely when it doesn't fit the
    user's question.
    """

    private static let systemFullTA = """
    You are a senior gold-market technical analyst. The user will give you
    a trading pair, a timeframe, and the latest OHLC bars. Produce a
    concise, well-structured technical analysis in Markdown:

    1. **Trend** — direction (up / down / sideways) and momentum.
    2. **Key levels** — most relevant support and resistance.
    3. **Indicators** — what RSI / MACD / volume would say (estimate from
       the close series; flag uncertainty if data is thin).
    4. **Main trade plan** — concrete entry, take-profit, and stop-loss
       prices for the next 24h with a clear bias (long / short /
       neutral). If neutral, still provide the nearest plausible entry
       trigger and the levels that would prove it right or wrong.
    5. **Alternative trade plan** — the "if the main plan invalidates,
       then ..." plan. Usually opposite bias keyed to a break of the
       main plan's stop-loss. Same shape as the main plan: entry, TP,
       SL, bias. If the structure genuinely offers no useful alt
       (e.g. the chart is mid-range with no clear inflection beyond
       the main stop), say so in the markdown and OMIT the alternative
       JSON block entirely.
    6. **Risk note** — one sentence on what would change your view.

    After the markdown, emit EXACTLY these structured blocks so the
    chart can draw the key levels and the trade plans:

    ### LEVELS_JSON
    ```json
    {"support":[<numbers>],"resistance":[<numbers>]}
    ```

    ### SCENARIO_JSON
    ```json
    {"bias":"long|short|neutral","entry":<number>,"tp":<number>,"sl":<number>}
    ```

    ### ALT_SCENARIO_JSON
    ```json
    {"bias":"long|short|neutral","entry":<number>,"tp":<number>,"sl":<number>}
    ```

    - `support` / `resistance` are the same prices you cite in the
      "Key levels" section — output them as raw numbers. List nearby
      levels (3–5 of each) so the user can see the structure, not just
      the immediate ones.
    - `entry` is the price you'd open the position at.
    - `tp` is the take-profit (target) price.
    - `sl` is the stop-loss (invalidation) price — also the price that
      flips the whole plan from "still valid" to "invalidated" once
      it's touched.
    - For long bias, `tp > entry > sl`. For short bias, `sl > entry > tp`.
    - Use raw numbers (no thousands separators, no currency symbols).
    - `bias` must be one of "long", "short", or "neutral".
    - Same constraints apply to the ALT_SCENARIO_JSON block. Omit it
      entirely (no fence at all) if you don't have a genuinely useful
      alternative — don't emit a half-thought placeholder.

    Cite specific numbers from the bars provided. Don't hedge with
    "consult a financial advisor" boilerplate — the user is a trader.
    """

    /// S/R prompt asks for a clearly-structured markdown analysis PLUS a
    /// machine-readable JSON block at the end so the chart can parse out
    /// the levels and draw them as horizontal rules. The exact fence
    /// (`### LEVELS_JSON` followed by ```json) is checked by `parseSRLevels`.
    private static let systemSR = """
    You are a senior gold-market technical analyst focused on Support
    and Resistance. The user will give you a trading pair, a timeframe,
    and the latest OHLC bars.

    Produce Markdown with this structure:

    1. **Method** — one sentence on how you identified the levels
       (swing highs/lows, equal highs, prior breakouts, etc.).
    2. **Support** — list each support level with a short reason
       (e.g. `4,650 — prior swing low retested twice`).
    3. **Resistance** — list each resistance level with a short reason.
    4. **Key level to watch** — the single most important level right
       now and what triggers above / below it imply.

    After the markdown, emit EXACTLY this structured block so the chart
    can draw the levels:

    ### LEVELS_JSON
    ```json
    {"support":[<numbers>],"resistance":[<numbers>]}
    ```

    Use raw numbers (no thousands separators, no currency symbols).
    Cite specific numbers from the bars provided. No disclaimers.
    """

    private static let systemMultiTF = """
    You are a senior gold-market technical analyst running a multi-
    timeframe sweep. The user will give you OHLC bars for three
    timeframes — typically 15m, 1h, 4h. Output a single comparison
    table so the user can spot confluence across timeframes at a glance.

    Produce Markdown with this structure (and nothing else above it):

    ## Multi-Timeframe Snapshot

    | Timeframe | Sentiment | Support / Resistance | Scenario |
    | --- | --- | --- | --- |
    | 15m | … | … | … |
    | 1h  | … | … | … |
    | 4h  | … | … | … |

    Conventions for each cell:
    - **Sentiment** — one of "🟢 Bullish", "🔴 Bearish", or "⚪ Neutral",
      followed by ONE short reason (e.g. "🟢 Bullish — higher highs").
    - **Support / Resistance** — the two most relevant levels formatted
      as `S: 4,650 · R: 4,720`. Pick a single S and a single R per row.
    - **Scenario** — one concise trade idea, e.g.
      `Long 4,680 → 4,750, invalid 4,640` or `Wait for break of 4,720`.

    After the table, write 2–3 sentences titled **Confluence** that
    summarise whether the three timeframes agree, conflict, or are
    waiting for the same trigger. Cite the actual numbers.

    No disclaimers. No "consult a financial advisor". Numbers only — no
    currency symbols, no thousands separators inside the JSON (the
    table can keep commas for readability).
    """

    /// Confluence Trade Scanner — **Stage 1**: Supply & Demand
    /// zones only. The fast, focused first pass. Produces the
    /// main + alt scenario plus the SUPPLY_DEMAND_JSON overlay so
    /// the chart lights up immediately. After the user reviews
    /// this, they can opt-in to the heavier
    /// `systemConfluenceScannerExpand` step (market structure +
    /// scoring) without paying for it on every run.
    private static let systemConfluenceScanner = """
    You are a senior gold-market technical analyst running the
    "Confluence Trade Scanner — Supply & Demand" sweep. The user
    gives OHLC bars for 15m, 1h, 4h plus precomputed indicators
    (ATR, RSI, MACD, EMA50/200, order blocks, volume).

    Your job is **Supply & Demand only** on this pass. Identify
    zones, pick the best trade idea (and a single alt), and
    report. Other structure patterns (breakouts, range bounds,
    liquidity grabs, trend continuation) are handled in a
    follow-up step — do NOT include them here.

    ## How to find S&D zones (apply on each timeframe)

    1. **Impulsive leg**: a candle (or 2-3 candle cluster) where
       price moved sharply (body ≥ 1.5× recent ATR(14)).
    2. **Walk backward to the base**: the last 1-3 OPPOSITE-
       direction or balanced candles before the impulse —
       **Demand** (before UP impulse) or **Supply** (before
       DOWN impulse). The zone's band is `[low, high]` of those
       base candles (full wick range).
    3. **Grade each zone**: **strength** = strong (broke a
       prior S/R AND left an FVG), medium (one of the two),
       weak (momentum-only). **Fresh** = price hasn't returned
       since the impulse.

    ## Pick the main trade

    From the zones you found, pick the single best setup as the
    **main** plan and a clear runner-up as the **alt**:
    - **Entry** anchored to the zone band.
    - **TP** at the next opposing major level.
    - **SL** just beyond the zone's far edge (use ATR ≈ 0.3-1.0×
      the timeframe's ATR(14) for the buffer).
    - For LONG: `tp > entry > sl`. For SHORT: `sl > entry > tp`.

    ## Output

    Markdown report with this structure:

    ### Confluence Trade Scanner — Supply & Demand

    1. **Zones identified** — bullet list of the zones you
       found across the 3 TFs (TF, type, price band, strength,
       fresh / tested).
    2. **Main plan** — bias, entry, TP, SL, and ONE sentence
       on why this zone won (cross-TF confluence, freshness,
       indicator alignment).
    3. **Alt plan** — same shape; the runner-up. If there's
       genuinely no second viable zone, write a single line
       saying so and omit the alt JSON block.
    4. **Next step** — one short paragraph: if you'd want
       market-structure context (breakout / range / liquidity
       grab / trend continuation) before sizing in, say so
       briefly. The user can then trigger the expand step.

    Then emit the structured blocks:

    ### SUPPLY_DEMAND_JSON
    ```json
    {"zones":[{"barStart":<int>,"barEnd":<int>,"low":<number>,"high":<number>,"type":"demand|supply","fresh":<bool>,"strength":"weak|medium|strong"}]}
    ```

    List every zone you identified, most recent first.

    ### SCENARIO_JSON
    ```json
    {"bias":"long|short|neutral","entry":<number>,"tp":<number>,"sl":<number>}
    ```

    The main plan.

    ### ALT_SCENARIO_JSON
    ```json
    {"bias":"long|short|neutral","entry":<number>,"tp":<number>,"sl":<number>}
    ```

    The alt plan. Omit when there's only one viable zone.

    Use raw numbers (no thousands separators, no currency).
    No disclaimers.
    """

    /// Confluence Trade Scanner — **Stage 2 (Expand)**: user-
    /// triggered follow-up that takes the prior S&D analysis as
    /// context and adds raw market-structure analysis on top,
    /// then scores every viable scenario (S&D + structure) 1-10
    /// for the auto-trader's fallback queue. Cheaper than running
    /// both stages every time, gated behind a Continue button so
    /// the user only pays for it when they want it.
    static let systemConfluenceScannerExpand = """
    You previously did a Supply & Demand pass on this market
    (the prior report is included below). Now **expand** the
    analysis to include raw market structure, then **score every
    viable scenario** (your prior S&D ideas plus any new
    structure-based ones) so the auto-trader can queue them.

    ## Market-structure patterns to scan

    1. **Reaction at a level**: is current price tagging a
       prior swing high/low? Bounce or break? Wick / body
       relationship on the most recent 3-5 bars at the level.
    2. **Breakout in progress**: did the most recent bar close
       beyond a multi-test S/R level? Retest setup forming or
       momentum still extending?
    3. **Range-bound**: chopping between two clear levels?
       Fade the edges instead of chasing breakouts.
    4. **Liquidity grab**: price wicked beyond an equal-
       highs/lows cluster and reversed on the same bar? Classic
       stop-run.
    5. **Trend continuation**: pullback to EMA50 inside an
       active trend — bias from the EMA50 vs EMA200 alignment.

    ## Score every viable scenario (1-10)

    For each setup (S&D from the prior report + new market-
    structure ones), build:
    - **type**: `"supply_demand"`, `"market_structure"`,
      `"breakout"`, `"range_bound"`, `"liquidity_grab"`,
      `"trend_continuation"`.
    - **bias**: long / short / neutral.
    - **entry**, **tp**, **sl** (raw numbers, no commas, no
      currency).
    - **score 1-10**:
      * base 5
      * +2 cross-TF confluence (e.g. 1h zone inside 4h zone)
      * +1 strong source (strong S&D / level with 3+ touches)
      * +1 untested zone
      * +1 each: RSI / MACD aligns with bias, or price reacts at an order block
      * +1 with-trend (LONG inside 4h uptrend)
      * −1 counter-trend, −1 tested zone, −1 thin volume
      Cap 10, floor 1.
    - **rationale**: ONE sentence (≤25 words) — what + why.
    - **invalidated_when**: specific price + TF (≤15 words).

    Cap at 5 scenarios. Order by score descending. Don't pad —
    only emit a scenario you'd genuinely consider trading.

    ## Output

    Markdown:

    ### Confluence Trade Scanner — Expanded Scenarios

    | # | Type | TF | Bias | Entry | TP | SL | Score | Rationale |
    | --- | --- | --- | --- | --- | --- | --- | --- | --- |
    | 1 | … | … | … | … | … | … | … / 10 | … |

    Then a short **Strategy** paragraph (2-3 sentences) naming
    the #1 scenario and why it edged the rest.

    Then the structured block the auto-trader reads:

    ### SCENARIOS_JSON
    ```json
    {"scenarios":[
      {"type":"supply_demand","score":8,"bias":"long","entry":4680,"tp":4820,"sl":4650,"rationale":"…","invalidated_when":"close below 4650 on 1h"},
      {"type":"breakout","score":7,"bias":"long","entry":4725,"tp":4800,"sl":4690,"rationale":"…","invalidated_when":"close back below 4715 on 15m"}
    ]}
    ```

    Order by score descending. For LONG: `tp > entry > sl`.
    For SHORT: `sl > entry > tp`. Raw numbers. No disclaimers.
    """

    private static let systemFVG = """
    You are a senior gold-market technical analyst focused on
    Fair Value Gaps (FVG) and Inverse Fair Value Gaps (iFVG) as defined
    by ICT methodology. The user will give you a trading pair, a
    timeframe, and the latest OHLC bars.

    Produce Markdown with this structure:

    1. **Method recap** — one short paragraph on FVG vs iFVG definition
       so the user knows your framing.
    2. **Unmitigated FVGs (bullish / bearish)** — list each FVG you can
       identify in the visible series. For each: bar timestamp range,
       the gap's high and low, and direction (bullish if a green
       three-candle pattern leaves a gap, bearish if red).
    3. **iFVG candidates** — FVGs that have been mitigated but where the
       opposite-direction reaction makes the gap a potential reversal
       zone. Include their boundaries.
    4. **Trade premise** — one short paragraph: which FVG / iFVG matters
       right now and what the bias is.

    After the markdown, emit EXACTLY this structured block so the chart
    can draw the zones:

    ### FVG_JSON
    ```json
    {"fvgs":[{"barStart":<int>,"barEnd":<int>,"low":<number>,"high":<number>,"direction":"bullish|bearish","mitigated":<bool>}]}
    ```

    `barStart` and `barEnd` are NEGATIVE offsets from the most recent
    bar: `-1` is the latest bar, `-2` is one bar prior, etc. A standard
    three-candle FVG spans roughly `barEnd - barStart == 2`. List the
    most recent FVGs first. `mitigated: true` marks iFVG candidates.

    Use raw numbers (no thousands separators, no currency symbols).
    Cite specific numbers from the bars provided. No disclaimers.
    """

    // ── User prompt ───────────────────────────────────────────────────

    /// Higher-timeframe snapshot bundled into single-TF prompts so
    /// the model can frame its bias against the bigger picture
    /// instead of just the local window. Kept as a value type so
    /// callers can construct it once and pass it through.
    struct HTFContext {
        let timeframe: Timeframe
        let snapshot: MarketSnapshot
    }

    /// Build the user message for any analysis kind. Common structure
    /// (pair, timeframe, last close, recent OHLC table); the system
    /// prompt is what differentiates the task.
    ///
    /// `htf` is an optional higher-timeframe context the page passes in
    /// for single-TF kinds — it shows up as a one-line trend summary
    /// at the top of the prompt so the model picks bias-aligned
    /// setups instead of countertrend ones it would never take if it
    /// saw the bigger picture.
    static func userPrompt(
        kind: AnalysisKind,
        pair: TradingPair,
        timeframe: Timeframe,
        candles: [Candle],
        htf: HTFContext? = nil,
        customTask: String? = nil
    ) -> String {
        // Larger context for FVG/SR (they care about more bars) vs full
        // TA where 50 is plenty. We cap at 120 anyway to keep token
        // cost predictable.
        let cap = (kind == .full) ? 50 : 120
        let trimmed = Array(candles.suffix(cap))
        let lines = trimmed.map { ohlcLine($0) }.joined(separator: "\n")

        let snapshot = MarketSnapshot.compute(trimmed)
        let indicatorBlock = snapshot.markdownBlock()

        let htfBlock: String = {
            guard let htf = htf else { return "" }
            return """

            ## Higher-timeframe context (\(htf.timeframe.label))

            \(htf.snapshot.oneLineSummary())
            """
        }()

        let indicatorSection: String = {
            guard !indicatorBlock.isEmpty else { return "" }
            return """

            ## Indicators (precomputed from the bars above)

            \(indicatorBlock)
            """
        }()

        // For `.custom`, the user's chat message IS the task. For
        // every other kind, the per-kind canned line drives the
        // model. We bias toward customTask when it's non-empty so
        // chat-mode callers don't accidentally fall back to the
        // generic line.
        let trimmedCustomTask = customTask?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let task: String = trimmedCustomTask.isEmpty
            ? taskLine(for: kind)
            : trimmedCustomTask

        return """
        ## Context

        Pair: **\(pair.name)** (\(pair.symbol))
        Timeframe: **\(timeframe.label)**
        Last close: \(fmt(pair.price))
        24h change: \(String(format: "%+.2f", pair.changePercent))%
        \(htfBlock)\(indicatorSection)

        ## Recent OHLC (\(trimmed.count) bars, oldest first — V = volume)

        \(lines.isEmpty ? "  (no recent data)" : lines)

        ## Task

        \(task)
        """
    }

    /// Single OHLCV line — shared by every prompt builder so the
    /// shape stays consistent. Volume is included as `V=N` (skipped
    /// when zero — most Iran pairs report 0 volume).
    private static func ohlcLine(_ c: Candle) -> String {
        let ts = ISO8601DateFormatter.short.string(from: c.bucketStart)
        let base = "  \(ts)  O=\(fmt(c.open)) H=\(fmt(c.high)) L=\(fmt(c.low)) C=\(fmt(c.close))"
        if let v = c.volume, v > 0 {
            return base + " V=\(fmtVolume(v))"
        }
        return base
    }

    /// Format volume as a compact integer-with-suffix so the OHLC
    /// table doesn't explode token count on millions-of-units
    /// markets. 12,345,678 → "12.3M". Below 10k just integer.
    private static func fmtVolume(_ v: Double) -> String {
        let abs = Swift.abs(v)
        if abs >= 1_000_000_000 { return String(format: "%.1fB", v / 1_000_000_000) }
        if abs >= 1_000_000     { return String(format: "%.1fM", v / 1_000_000) }
        if abs >= 10_000        { return String(format: "%.1fK", v / 1_000) }
        return String(format: "%.0f", v)
    }

    /// Per-kind closing instruction. Kept separate so each analysis has
    /// a distinct nudge.
    private static func taskLine(for kind: AnalysisKind) -> String {
        switch kind {
        case .full:
            return "Run the analysis described in the system message. Be specific and numeric. Output Markdown only, no surrounding prose."
        case .supportResistance:
            return "Identify the current S/R levels per the system message. Output Markdown plus the LEVELS_JSON block exactly as specified."
        case .fvg:
            return "Identify FVGs and iFVGs per the system message. Output Markdown only, no surrounding prose."
        case .multiTimeframe:
            // Never actually reached — multi-TF goes through
            // `userPromptMultiTimeframe` instead — but the switch needs
            // exhaustiveness.
            return "Run the multi-timeframe sweep per the system message."
        case .confluenceScanner:
            // Same — Confluence Trade Scanner bundles three
            // timeframes and goes through `userPromptConfluenceScanner`.
            // Kept here for exhaustiveness.
            return "Run the Confluence Trade Scanner sweep per the system message."
        case .custom:
            // Fallback only — chat-mode callers pass the user's
            // typed message in via `customTask`, which replaces
            // this string. This branch fires when something kicks
            // a custom run without supplying a message (defensive).
            return "Give me a brief technical read on this pair using the data above."
        case .combined:
            // Never reached — combined goes through
            // `userPromptCombined`. Kept for exhaustiveness.
            return "Run the requested analysis aspects per the system message."
        case .topDownSniper:
            // Never reached — goes through `userPromptTopDownSniper`.
            return "Run the Top-Down Sniper model per the system message."
        }
    }

    // ── Multi-timeframe user prompt ───────────────────────────────────

    /// Build a user prompt that bundles OHLC for several timeframes at
    /// once. Used by `AnalysisKind.multiTimeframe` to give Claude
    /// enough context to fill out the comparison table.
    ///
    /// Each timeframe gets its own labelled block. Bars are trimmed to
    /// the last 40 per TF to keep total token count manageable — 3 × 40
    /// = 120 bars, similar to the single-TF FVG prompt budget.
    static func userPromptMultiTimeframe(
        pair: TradingPair,
        candlesByTF: [(Timeframe, [Candle])]
    ) -> String {
        let sections = mtfSections(candlesByTF, perTFBars: 40)

        return """
        ## Context

        Pair: **\(pair.name)** (\(pair.symbol))
        Last close: \(fmt(pair.price))
        24h change: \(String(format: "%+.2f", pair.changePercent))%

        ## OHLC + indicators by timeframe
        \(sections)

        ## Task

        Run the multi-timeframe analysis described in the system
        message. Output the table exactly in the format shown, followed
        by the Confluence paragraph.
        """
    }

    /// Shared multi-TF section builder. Each timeframe block carries
    /// its own precomputed indicator summary above the OHLC table so
    /// the model can spot momentum / EMA-alignment / volume confluence
    /// without trying to do indicator math from raw closes.
    private static func mtfSections(_ candlesByTF: [(Timeframe, [Candle])], perTFBars: Int) -> String {
        var sections = ""
        for (tf, cs) in candlesByTF {
            let trimmed = Array(cs.suffix(perTFBars))
            let lines = trimmed.map { ohlcLine($0) }.joined(separator: "\n")
            let snapshot = MarketSnapshot.compute(trimmed)
            let indicatorBlock = snapshot.markdownBlock()
            let indicators = indicatorBlock.isEmpty
                ? ""
                : "\n_Indicators (precomputed):_\n\(indicatorBlock)\n"
            sections += "\n\n### \(tf.label) — \(trimmed.count) bars\n\(indicators)\n\(lines.isEmpty ? "  (no recent data)" : lines)"
        }
        return sections
    }

    // ── Combined (checklist) analysis ─────────────────────────────

    /// Assemble the system prompt for a combined run from the ticked
    /// aspects. Only the chosen aspects' instructions are included so
    /// the prompt stays as small as the request. Always includes the
    /// CLARIFY escape hatch so the model can decline an over-broad
    /// ask rather than producing a wall of text.
    static func systemCombined(
        aspects: Set<AnalysisAspect>,
        horizonHint: String? = nil
    ) -> String {
        let ordered = AnalysisAspect.displayOrder.filter { aspects.contains($0) }
        let aspectBlock = ordered.isEmpty
            ? "Answer the user's question directly; emit any structured block (LEVELS_JSON / FVG_JSON / SUPPLY_DEMAND_JSON / SCENARIO_JSON) that fits."
            : ordered.enumerated()
                .map { "\($0.offset + 1). \($0.element.instruction)" }
                .joined(separator: "\n\n")
        let horizonLine = (horizonHint?.isEmpty == false)
            ? "\n\nTrade-plan framing: \(horizonHint!)"
            : ""
        return """
        You are a senior gold-market technical analyst. The user has
        picked specific aspects to analyze. Produce a tight, well-
        structured Markdown report with ONE `##` section per requested
        aspect — in this order — and nothing extra. Reference concrete
        numbers from the data. No disclaimers.

        Requested aspects:

        \(aspectBlock)\(horizonLine)

        Emit each structured JSON block at the END of its section, in a
        ```json fenced code block, using raw numbers (no thousands
        separators, no currency symbols).

        ## Scope guard
        If covering every requested aspect *thoroughly* would produce
        an overly long answer (many aspects across multiple
        timeframes), DON'T attempt it. Instead emit ONLY this block and
        stop:

        ### CLARIFY_JSON
        ```json
        {"question":"<one short question>","options":[{"id":"<aspect-id-or-all>","label":"<short label>"}]}
        ```
        Include one option per requested aspect (id = the aspect name)
        plus a final `{"id":"all","label":"Everything (slower)"}`.
        Only use this escape hatch when genuinely warranted.
        """
    }

    /// User prompt for a combined run. Bundles the timeframe trio via
    /// `mtfSections` when any ticked aspect needs multi-TF context;
    /// otherwise a single focus-TF block. Appends the user's optional
    /// free-text intent.
    static func userPromptCombined(
        pair: TradingPair,
        focusTimeframe: Timeframe,
        candlesByTF: [(Timeframe, [Candle])],
        aspects: Set<AnalysisAspect>,
        freeText: String? = nil
    ) -> String {
        let sections = mtfSections(candlesByTF, perTFBars: 50)
        let aspectList = AnalysisAspect.displayOrder
            .filter { aspects.contains($0) }
            .map { "- \($0.label)" }
            .joined(separator: "\n")
        let aspectBlock = aspectList.isEmpty ? "" : """

        ## Requested aspects
        \(aspectList)
        """
        let freeBlock: String = {
            let t = (freeText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return "" }
            return "\n\n## User also asks\n\(t)"
        }()
        return """
        ## Context

        Pair: **\(pair.name)** (\(pair.symbol))
        Focus timeframe: **\(focusTimeframe.label)**
        Last close: \(fmt(pair.price))
        24h change: \(String(format: "%+.2f", pair.changePercent))%
        \(aspectBlock)\(freeBlock)

        ## OHLC + indicators by timeframe
        \(sections)

        ## Task

        Produce the requested aspects per the system message, each as a
        `##` section with its structured block. Focus the read on the
        \(focusTimeframe.label) timeframe but use the others for
        confluence.
        """
    }

    // ── Top-Down Sniper ───────────────────────────────────────────

    /// Strict top-down multi-timeframe model, parameterised by the
    /// timeframe trio so it works at any speed: the HTF sets the
    /// bias, the MTF finds the setup, the LTF gives the entry. Used
    /// for both the Swing trio (4H/1H/15m) and the Intraday trio
    /// (1H/15m/1m). The higher TF always constrains the lower.
    static func systemTopDownSniper(htf: String, mtf: String, ltf: String) -> String {
        """
        You are a senior gold-market analyst running the "Top-Down
        Sniper" model — a disciplined top-down workflow on the
        \(htf) / \(mtf) / \(ltf) timeframes. Each has a specific job.
        Work them in order; the higher timeframe constrains the
        lower. Never take an entry that fights the \(htf) bias.

        ## \(htf) — Direction & map (sets the bias)
        - **Trend**: classify UP, DOWN, or NEUTRAL from the structure
          of swing highs/lows + EMA50 vs EMA200.
        - **Key levels**: the major support / resistance the market
          is respecting.
        - **Supply & Demand**: the unmitigated higher-timeframe zones
          price is likely to react at.
        This \(htf) read is the ONLY direction you may trade. If
        \(htf) is NEUTRAL, fade range edges or stand aside.

        ## \(mtf) — Setup (where the trade forms, inside the \(htf) bias)
        - **Breakout**: has price broken a \(mtf) structure level in
          the bias direction (BOS)?
        - **Pullback**: is price retracing into a discount (longs) /
          premium (shorts) area?
        - **Order Block (OB)**: the last opposite-direction candle
          before the impulsive move — treat it as a demand (long) /
          supply (short) zone.
        - **FVG**: fair-value gaps the impulse left behind (entry magnets).
        - **Liquidity**: equal highs/lows + stop pools the move is
          likely to grab or target.

        ## \(ltf) — Confirmation & entry (the trigger)
        - **Confirmation**: a \(ltf) shift validating the \(mtf)
          setup — BOS / CHoCH, a rejection wick at the zone, or an
          FVG fill.
        - **Entry**: a precise entry price (the OB / FVG / level),
          stop just beyond the invalidation, target the next
          opposing \(mtf)/\(htf) level or liquidity pool.
        - Only fire when **\(htf) bias + \(mtf) setup + \(ltf)
          confirmation align**. If they conflict, output "No trade"
          and state exactly what you'd need to see.

        ## Output — Markdown then JSON blocks

        ### Top-Down Sniper
        1. **\(htf) — Direction**: trend (UP/DOWN/NEUTRAL) + key levels + S&D, with numbers.
        2. **\(mtf) — Setup**: breakout / pullback / OB / FVG / liquidity read.
        3. **\(ltf) — Entry**: confirmation + the precise plan (entry / TP / SL), or "No trade".

        Then emit the structured blocks:

        ### LEVELS_JSON
        ```json
        {"support":[<numbers>],"resistance":[<numbers>]}
        ```
        The \(htf) key levels.

        ### SUPPLY_DEMAND_JSON
        ```json
        {"zones":[{"barStart":<int>,"barEnd":<int>,"low":<number>,"high":<number>,"type":"demand|supply","fresh":<bool>,"strength":"weak|medium|strong"}]}
        ```
        The \(htf) S&D zones plus the \(mtf) order block(s).
        `barStart`/`barEnd` are NEGATIVE offsets from the latest bar
        (-1 = latest).

        ### FVG_JSON
        ```json
        {"fvgs":[{"barStart":<int>,"barEnd":<int>,"low":<number>,"high":<number>,"direction":"bullish|bearish","mitigated":<bool>}]}
        ```
        The \(mtf) fair-value gaps.

        ### SCENARIO_JSON
        ```json
        {"bias":"long|short|neutral","entry":<number>,"tp":<number>,"sl":<number>}
        ```
        The \(ltf) entry. For long: tp > entry > sl. For short:
        sl > entry > tp. When there's no aligned trade, set bias
        "neutral" and use the nearest levels you'd watch.

        ### ALT_SCENARIO_JSON
        ```json
        {"bias":"long|short|neutral","entry":<number>,"tp":<number>,"sl":<number>}
        ```
        Optional — the "if the \(htf) bias flips" plan. Omit when
        there's no real second setup.

        Raw numbers (no thousands separators, no currency). No disclaimers.
        """
    }

    /// Build the Top-Down Sniper user prompt for any HTF→MTF→LTF
    /// trio (oldest bars first per TF). `candlesByTF` must be ordered
    /// highest timeframe first.
    static func userPromptTopDownSniper(
        pair: TradingPair,
        candlesByTF: [(Timeframe, [Candle])]
    ) -> String {
        let sections = mtfSections(candlesByTF, perTFBars: 60)
        let order = candlesByTF.map { $0.0.label }.joined(separator: " → ")
        let htf = candlesByTF.first?.0.label ?? "HTF"
        let mtf = candlesByTF.count > 1 ? candlesByTF[1].0.label : "MTF"
        let ltf = candlesByTF.last?.0.label ?? "LTF"
        return """
        ## Context

        Pair: **\(pair.name)** (\(pair.symbol))
        Last close: \(fmt(pair.price))
        24h change: \(String(format: "%+.2f", pair.changePercent))%

        ## OHLC + indicators by timeframe (\(order))
        \(sections)

        ## Task

        Run the **Top-Down Sniper** model per the system message:
        \(htf) bias first, then the \(mtf) setup inside it, then the
        \(ltf) confirmation + precise entry. Emit the report plus the
        LEVELS_JSON / SUPPLY_DEMAND_JSON / FVG_JSON / SCENARIO_JSON
        blocks. Say "No trade" when the timeframes don't align.
        """
    }

    /// Build a Confluence Trade Scanner user prompt. Same OHLC-
    /// bundle shape as `userPromptMultiTimeframe` — three timeframes
    /// side by side so the model can spot Supply & Demand zones at
    /// each scale — but the task line nudges it toward the S&D
    /// strategy rather than the table format.
    ///
    /// We give the scanner a slightly bigger bar budget per
    /// timeframe (60 vs. multi-TF's 40) because the strategy
    /// needs to see the pre-impulse structure clearly enough to
    /// locate the base candles, not just the impulse itself.
    /// Optional context block surfaced when the auto-trader is
    /// re-running the scanner after a prior scenario closed. Gives the
    /// model the prior main + alt scenarios + their outcome so it
    /// can decide whether the alt is still viable, propose a fresh
    /// take, or skip trading entirely. Without this, the model
    /// can't distinguish "first analysis of the session" from
    /// "third re-run after two losses in a row".
    struct PriorRunHint {
        let main: TAScenario
        let alt: TAScenario?
        /// What happened to the main scenario: "stopped out at SL",
        /// "hit TP", "expired without filling". Plain English so
        /// the model interprets without re-parsing structured data.
        let outcome: String
    }

    static func userPromptConfluenceScanner(
        pair: TradingPair,
        candlesByTF: [(Timeframe, [Candle])],
        priorRunHint: PriorRunHint? = nil,
        horizonHint: String? = nil
    ) -> String {
        let sections = mtfSections(candlesByTF, perTFBars: 60)

        let priorBlock: String = {
            guard let h = priorRunHint else { return "" }
            let mainLine = scenarioOneLine(h.main, label: "Main")
            let altLine  = h.alt.map { scenarioOneLine($0, label: "Alt") }
            return """

            ## Prior run (just resolved)

            - \(mainLine) → **\(h.outcome)**\(altLine.map { "\n- \($0) (was offered as fallback; never activated)" } ?? "")

            The prior alt was generated from the same market read as the prior main, so it may already be stale. Use the fresh bars + indicators below to decide: is the alt still viable, is a completely different setup forming, or is the market not actionable right now? Don't trade for the sake of trading.
            """
        }()

        // Profile-tuned horizon line so the model frames stops +
        // targets at the right scale (Scalp ≠ Position).
        let horizonLine: String = {
            guard let h = horizonHint, !h.isEmpty else { return "" }
            return "\n\n**Strategy profile:** \(h)"
        }()

        return """
        ## Context

        Pair: **\(pair.name)** (\(pair.symbol))
        Last close: \(fmt(pair.price))
        24h change: \(String(format: "%+.2f", pair.changePercent))%\(horizonLine)
        \(priorBlock)

        ## OHLC + indicators by timeframe
        \(sections)

        ## Task

        Run the **Confluence Trade Scanner — Supply & Demand**
        pass per the system message. Find zones, pick a main +
        alt, and emit the report plus the SUPPLY_DEMAND_JSON /
        SCENARIO_JSON / ALT_SCENARIO_JSON blocks.
        """
    }

    /// User prompt for the **Confluence Trade Scanner Expand**
    /// follow-up. Carries the original OHLC bundle (so the model
    /// can re-reference any bar) plus the prior stage 1 report
    /// (so it builds on the S&D analysis rather than starting
    /// over). Output is the scored SCENARIOS_JSON block.
    static func userPromptConfluenceScannerExpand(
        pair: TradingPair,
        candlesByTF: [(Timeframe, [Candle])],
        priorReport: String
    ) -> String {
        let sections = mtfSections(candlesByTF, perTFBars: 60)
        return """
        ## Context

        Pair: **\(pair.name)** (\(pair.symbol))
        Last close: \(fmt(pair.price))
        24h change: \(String(format: "%+.2f", pair.changePercent))%

        ## OHLC + indicators by timeframe
        \(sections)

        ## Prior Supply & Demand pass

        \(priorReport)

        ## Task

        Expand the analysis with raw market structure (breakout,
        range-bound, liquidity grab, trend continuation, etc.)
        per the system message. Score every viable scenario —
        the S&D ones from the prior pass AND any new structure-
        based ones — 1-10. Emit the table, the Strategy
        paragraph, and the `SCENARIOS_JSON` block.
        """
    }

    /// Compact one-line summary of a scenario for the prior-run
    /// hint block. Reads like `Main: LONG entry 4,710 tp 4,820 sl 4,655`.
    private static func scenarioOneLine(_ s: TAScenario, label: String) -> String {
        let entry = s.entry.map { fmt($0) } ?? "—"
        return "\(label): \(s.bias.rawValue.uppercased()) entry \(entry) tp \(fmt(s.takeProfit)) sl \(fmt(s.stopLoss))"
    }

    /// Round to a sensible number of decimals based on price magnitude.
    /// Mirrors the JS helper in PairListItem.tsx.
    private static func fmt(_ v: Double) -> String {
        if v >= 10_000 { return String(format: "%.0f", v) }
        if v >= 100   { return String(format: "%.2f", v) }
        if v >= 1     { return String(format: "%.4f", v) }
        return String(format: "%.5f", v)
    }

    // ── Clarify (combined scope guard) ────────────────────────────

    /// The model's "this is too broad — which aspect?" response,
    /// parsed from a CLARIFY_JSON block. Ephemeral (a question, not a
    /// saved payload) — the report column renders the options as
    /// tappable buttons that re-run a narrowed combined analysis.
    struct ClarifyRequest: Equatable {
        struct Option: Equatable, Identifiable {
            let id: String      // an AnalysisAspect rawValue, or "all"
            let label: String
        }
        let question: String
        let options: [Option]
    }

    /// Extract the CLARIFY_JSON block. Returns nil when absent /
    /// malformed (the normal case — most runs just answer).
    static func parseClarify(_ markdown: String) -> ClarifyRequest? {
        guard let slice = extractJSONBlock(markdown, marker: "CLARIFY_JSON"),
              let data = String(slice).data(using: .utf8),
              let obj  = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let question = obj["question"] as? String,
              let rawOptions = obj["options"] as? [[String: Any]]
        else { return nil }
        let options: [ClarifyRequest.Option] = rawOptions.compactMap { row in
            guard let id = row["id"] as? String,
                  let label = row["label"] as? String
            else { return nil }
            return ClarifyRequest.Option(id: id, label: label)
        }
        guard !options.isEmpty else { return nil }
        return ClarifyRequest(question: question, options: options)
    }

    // ── S/R parsing ───────────────────────────────────────────────────

    /// Parsed support / resistance levels extracted from a Claude
    /// response. Both arrays are empty when the JSON block is missing or
    /// malformed — the UI degrades to "show analysis only" rather than
    /// crashing.
    struct SRLevels: Codable, Equatable {
        var support: [Double]
        var resistance: [Double]
        var isEmpty: Bool { support.isEmpty && resistance.isEmpty }
    }

    /// Extract the LEVELS_JSON block produced by the S/R system prompt.
    /// We tolerate small drift in formatting (different fence whitespace,
    /// optional trailing periods etc.) — the shared `extractJSONBlock`
    /// helper does the brace-walking.
    static func parseSRLevels(_ markdown: String) -> SRLevels {
        guard let slice = extractJSONBlock(markdown, marker: "LEVELS_JSON"),
              let data = String(slice).data(using: .utf8),
              let obj  = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return SRLevels(support: [], resistance: []) }
        let support = (obj["support"] as? [Any] ?? []).compactMap { numerify($0) }
        let resist  = (obj["resistance"] as? [Any] ?? []).compactMap { numerify($0) }
        return SRLevels(support: support, resistance: resist)
    }

    /// Coerce a JSON value (Int, Double, NSNumber, String number) into a
    /// Double; bails when the value isn't number-shaped.
    private static func numerify(_ v: Any) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int    { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s.replacingOccurrences(of: ",", with: "")) }
        return nil
    }

    // ── FVG zones (chart overlay) ─────────────────────────────────────

    /// One Fair Value Gap entry parsed from the FVG_JSON block. The bar
    /// indices are *offsets from the latest bar* — `-1` is the latest
    /// candle, `-2` is one prior. The chart maps these onto its X axis
    /// at render time so the zone follows the bar series even as new
    /// candles arrive (well, drifts by one bar per tick — see Risks in
    /// the plan).
    struct FVGZone: Codable, Equatable, Identifiable {
        let id: UUID
        let barOffsetStart: Int
        let barOffsetEnd: Int
        let low: Double
        let high: Double
        let isBullish: Bool
        let isMitigated: Bool
    }

    /// Extract the FVG_JSON block. Tolerates the same minor drift as
    /// `parseSRLevels` — looks for the marker, walks to the first `{`,
    /// counts braces to find the matching `}`.
    static func parseFVGZones(_ markdown: String) -> [FVGZone] {
        guard let jsonSlice = extractJSONBlock(markdown, marker: "FVG_JSON"),
              let data = String(jsonSlice).data(using: .utf8),
              let obj  = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = obj["fvgs"] as? [[String: Any]]
        else { return [] }

        return rows.compactMap { row -> FVGZone? in
            guard let lo = numerify(row["low"]  ?? 0),
                  let hi = numerify(row["high"] ?? 0),
                  let start = (row["barStart"] as? Int) ?? (row["barStart"] as? NSNumber).map({ $0.intValue }),
                  let end   = (row["barEnd"]   as? Int) ?? (row["barEnd"]   as? NSNumber).map({ $0.intValue })
            else { return nil }
            let dir = (row["direction"] as? String) ?? "bullish"
            let mitigated = (row["mitigated"] as? Bool) ?? false
            // Normalize: barStart should be the earlier (more negative)
            // offset, barEnd the later. Some models flip them.
            let (s, e) = start <= end ? (start, end) : (end, start)
            return FVGZone(
                id: UUID(),
                barOffsetStart: s,
                barOffsetEnd: e,
                low: min(lo, hi),
                high: max(lo, hi),
                isBullish: dir.lowercased() == "bullish",
                isMitigated: mitigated
            )
        }
    }

    // ── Scored scenarios (Confluence Trade Scanner output) ───────────

    /// One ranked trade idea emitted by the Confluence Trade
    /// Scanner. The scanner looks at BOTH Supply & Demand zones
    /// AND raw market structure (S/R reactions, breakouts, range
    /// bounds) and outputs every viable setup with a 1-10 score.
    /// The auto-trader queues them by score and tries each in
    /// turn — if the top scenario invalidates, it falls down to the next
    /// without waiting for a fresh analysis. Only when the whole
    /// queue is exhausted does it re-run.
    ///
    /// Wraps the existing `TAScenario` so the chart overlay +
    /// PlanCard pipeline stays unchanged. `score`/`type`/`rationale`
    /// are the new surface area.
    struct ScoredScenario: Codable, Equatable, Identifiable {
        var id: String { scenario.id }
        let scenario: TAScenario
        /// 1-10 confidence/quality grade. Higher = stronger
        /// setup. The auto-trader picks the highest as "main"
        /// and falls to the next on invalidation.
        let score: Int
        /// One of: `"supply_demand"`, `"market_structure"`,
        /// `"breakout"`, `"range_bound"`, `"liquidity_grab"`.
        /// Free-form so the model can stretch but the UI
        /// renders a default badge for unknowns.
        let type: String
        /// One-line "why" — surfaced in the ranked-scenarios
        /// card so the user can compare setups at a glance
        /// without re-reading the markdown.
        let rationale: String
        /// Optional explicit invalidation condition the model
        /// wrote (e.g. "Close below 4655 on a 1h bar"). Falls
        /// back to "SL touch" when empty.
        let invalidatedWhen: String
    }

    /// Parse the SCENARIOS_JSON block — array of scored
    /// scenarios. Order by score descending so the engine + UI
    /// can iterate ranked. Bails to `[]` on any structural
    /// surprise.
    static func parseScoredScenarios(_ markdown: String) -> [ScoredScenario] {
        guard let slice = extractJSONBlock(markdown, marker: "SCENARIOS_JSON"),
              let data = String(slice).data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = obj["scenarios"] as? [[String: Any]]
        else { return [] }

        let parsed: [ScoredScenario] = rows.compactMap { row in
            let tp = numerify(row["takeProfit"] ?? row["tp"] ?? row["target"] ?? 0)
            let sl = numerify(row["stopLoss"]   ?? row["sl"] ?? row["invalidation"] ?? 0)
            guard let tpVal = tp, let slVal = sl else { return nil }
            let entry = numerify(row["entry"] ?? row["entryPrice"] ?? "")
            let biasRaw = (row["bias"] as? String)?.lowercased() ?? "neutral"
            let bias = TAScenario.Bias(rawValue: biasRaw) ?? .neutral
            let scenario = TAScenario(bias: bias, entry: entry, takeProfit: tpVal, stopLoss: slVal)
            let scoreRaw = (row["score"] as? Int)
                ?? (row["score"] as? NSNumber).map({ $0.intValue })
                ?? Int((row["score"] as? Double) ?? 5)
            let score = max(1, min(10, scoreRaw))
            let type = (row["type"] as? String) ?? "market_structure"
            let rationale = (row["rationale"] as? String) ?? ""
            let invalidatedWhen = (row["invalidated_when"] as? String)
                ?? (row["invalidatedWhen"] as? String)
                ?? ""
            return ScoredScenario(
                scenario: scenario,
                score: score,
                type: type,
                rationale: rationale,
                invalidatedWhen: invalidatedWhen
            )
        }
        return parsed.sorted { $0.score > $1.score }
    }

    // ── Supply & Demand zones (chart overlay) ─────────────────────────

    /// One Supply or Demand zone parsed from the SUPPLY_DEMAND_JSON
    /// block. Supply = the last bullish (or neutral) base candles
    /// before a sharp DOWN impulse; Demand = the last bearish (or
    /// neutral) base candles before a sharp UP impulse. The
    /// rectangle drawn on the chart spans the zone's bar range
    /// (`barOffsetStart…barOffsetEnd`, negative offsets from the
    /// latest bar) and price band (`low…high`), tinted by
    /// `isDemand` so the user can read intent at a glance.
    ///
    /// `isFresh` flips to false when price has already returned and
    /// tested the zone — those tend to be less reliable on a
    /// second visit, so the chart renders them with a dashed
    /// border / reduced opacity instead of a solid fill.
    ///
    /// `strength` is the model's confidence rating; we render
    /// strong zones with a thicker border so the user can scan
    /// for the high-quality setups without re-reading the report.
    struct SupplyDemandZone: Codable, Equatable, Identifiable {
        let id: UUID
        let barOffsetStart: Int
        let barOffsetEnd: Int
        let low: Double
        let high: Double
        let isDemand: Bool
        let isFresh: Bool
        let strength: Strength

        enum Strength: String, Codable {
            case weak, medium, strong
        }
    }

    /// Extract the SUPPLY_DEMAND_JSON block. Same tolerant brace-
    /// walking pattern as `parseFVGZones` — bails to an empty
    /// array on any structural surprise so the UI degrades to
    /// "no zones today" rather than crashing on the user's first
    /// half-formed model output.
    static func parseSupplyDemandZones(_ markdown: String) -> [SupplyDemandZone] {
        guard let jsonSlice = extractJSONBlock(markdown, marker: "SUPPLY_DEMAND_JSON"),
              let data = String(jsonSlice).data(using: .utf8),
              let obj  = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = obj["zones"] as? [[String: Any]]
        else { return [] }

        return rows.compactMap { row -> SupplyDemandZone? in
            guard let lo = numerify(row["low"]  ?? 0),
                  let hi = numerify(row["high"] ?? 0),
                  let start = (row["barStart"] as? Int) ?? (row["barStart"] as? NSNumber).map({ $0.intValue }),
                  let end   = (row["barEnd"]   as? Int) ?? (row["barEnd"]   as? NSNumber).map({ $0.intValue })
            else { return nil }
            // Accept either "type":"demand"/"supply" or
            // "isDemand":bool — models drift between conventions
            // and we shouldn't punish them for either.
            let isDemand: Bool = {
                if let s = row["type"] as? String { return s.lowercased() == "demand" }
                if let b = row["isDemand"] as? Bool { return b }
                return true
            }()
            let isFresh = (row["fresh"] as? Bool) ?? (row["isFresh"] as? Bool) ?? true
            let strRaw = (row["strength"] as? String)?.lowercased() ?? "medium"
            let strength = SupplyDemandZone.Strength(rawValue: strRaw) ?? .medium
            // Normalise bar offsets — barStart should be the
            // earlier (more negative) end of the range.
            let (s, e) = start <= end ? (start, end) : (end, start)
            return SupplyDemandZone(
                id: UUID(),
                barOffsetStart: s,
                barOffsetEnd: e,
                low: min(lo, hi),
                high: max(lo, hi),
                isDemand: isDemand,
                isFresh: isFresh,
                strength: strength
            )
        }
    }

    // ── TA scenario (chart overlay) ───────────────────────────────────

    /// Outlook payload from a full TA run. Models a concrete trade plan
    /// — entry price (where to get in), take-profit (where to exit
    /// winners), stop-loss (where the bias is invalidated). The chart
    /// projects this as three horizontal lines plus a capsule that
    /// reads e.g. `LONG · ENTRY 4,710 · TP 4,820 · SL 4,655`.
    ///
    /// `entry` is optional so that history entries saved before the
    /// "entry point" field existed still decode cleanly — the legacy
    /// `target`/`invalidation` keys map onto `takeProfit`/`stopLoss`
    /// via the custom decoder below.
    struct TAScenario: Codable, Equatable, Identifiable {
        /// Synthetic identity so the activation sheet can be presented
        /// via `.sheet(item:)`. Derived deterministically from the
        /// content fields — two parses of the same Claude response
        /// will produce equal IDs, so re-opening a history entry
        /// doesn't fragment one scenario into multiple sheet sessions.
        var id: String {
            "\(bias.rawValue)|\(entry ?? .nan)|\(takeProfit)|\(stopLoss)"
        }

        let bias: Bias
        let entry: Double?
        let takeProfit: Double
        let stopLoss: Double
        enum Bias: String, Codable { case long, short, neutral }

        init(bias: Bias, entry: Double?, takeProfit: Double, stopLoss: Double) {
            self.bias = bias
            self.entry = entry
            self.takeProfit = takeProfit
            self.stopLoss = stopLoss
        }

        /// Whether the plan is still in play at the given live price.
        /// Long plans invalidate when price drops at or below `sl`;
        /// short plans invalidate when price rises at or above `sl`.
        /// Neutral plans don't have a directional invalidation — we
        /// treat any touch of `sl` as the trigger (price equals or
        /// crosses, either direction).
        ///
        /// Pure function so callers can compute it on every render
        /// against `latestPrices`; no stored "was invalidated" state
        /// in v1 (history rows recompute against the current price
        /// when they're displayed).
        func isValid(at price: Double) -> Bool {
            switch bias {
            case .long:    return price > stopLoss
            case .short:   return price < stopLoss
            case .neutral:
                // No directional bias — we only consider the plan
                // dead once price *crosses* the SL line. Use the
                // distance from entry as the side: if entry > sl,
                // treat like long; if entry < sl, treat like short.
                if let e = entry {
                    return e > stopLoss ? price > stopLoss : price < stopLoss
                }
                return true
            }
        }

        /// Backward-compatible decoder: accepts the new (entry / tp /
        /// sl) shape and the original (target / invalidation) shape so
        /// older history entries continue to load.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let bias = (try? c.decode(Bias.self, forKey: .bias)) ?? .neutral
            let entry = try c.decodeIfPresent(Double.self, forKey: .entry)
            // Prefer the current keys; fall back to the legacy ones.
            let tp = try c.decodeIfPresent(Double.self, forKey: .takeProfit)
                ?? c.decodeIfPresent(Double.self, forKey: .target)
                ?? 0
            let sl = try c.decodeIfPresent(Double.self, forKey: .stopLoss)
                ?? c.decodeIfPresent(Double.self, forKey: .invalidation)
                ?? 0
            self.init(bias: bias, entry: entry, takeProfit: tp, stopLoss: sl)
        }

        /// Always serialize with the current key shape. Older readers
        /// don't exist (we own this whole pipeline) so we can safely
        /// drop the legacy keys on write.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(bias, forKey: .bias)
            try c.encodeIfPresent(entry, forKey: .entry)
            try c.encode(takeProfit, forKey: .takeProfit)
            try c.encode(stopLoss, forKey: .stopLoss)
        }

        enum CodingKeys: String, CodingKey {
            case bias
            case entry
            case takeProfit
            case stopLoss
            // Legacy keys preserved for decoding only.
            case target
            case invalidation
        }
    }

    /// Parse the main trade plan from `### SCENARIO_JSON`.
    static func parseTAScenario(_ markdown: String) -> TAScenario? {
        parseScenarioBlock(markdown, marker: "SCENARIO_JSON")
    }

    /// Parse the (optional) alternative trade plan from
    /// `### ALT_SCENARIO_JSON`. Claude is told to omit the block
    /// entirely when no useful alt exists, so a `nil` return is the
    /// expected outcome a lot of the time — callers treat it as
    /// "no alt, hide the Add-alt button".
    static func parseTAAltScenario(_ markdown: String) -> TAScenario? {
        parseScenarioBlock(markdown, marker: "ALT_SCENARIO_JSON")
    }

    /// Shared body — same wire format for main + alt, only the
    /// marker differs.
    private static func parseScenarioBlock(_ markdown: String, marker: String) -> TAScenario? {
        guard let slice = extractJSONBlock(markdown, marker: marker),
              let data = String(slice).data(using: .utf8),
              let obj  = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        // Accept both old (`target`/`invalidation`) and new
        // (`entry`/`tp`/`sl` or full names) key shapes — Claude
        // occasionally uses the older terms it was trained on.
        let tp = numerify(obj["takeProfit"] ?? obj["tp"] ?? obj["target"] ?? 0)
        let sl = numerify(obj["stopLoss"]   ?? obj["sl"] ?? obj["invalidation"] ?? 0)
        guard let tpVal = tp, let slVal = sl else { return nil }
        let entry = numerify(obj["entry"] ?? obj["entryPrice"] ?? "")
        let rawBias = (obj["bias"] as? String)?.lowercased() ?? "neutral"
        let bias = TAScenario.Bias(rawValue: rawBias) ?? .neutral
        return TAScenario(bias: bias, entry: entry, takeProfit: tpVal, stopLoss: slVal)
    }

    // ── Shared JSON-block extractor ───────────────────────────────────

    /// Common brace-walking helper for our `### XXX_JSON` blocks. Used
    /// by parseSRLevels / parseFVGZones / parseTAScenario.
    private static func extractJSONBlock(_ markdown: String, marker: String) -> Substring? {
        guard let markerRange = markdown.range(of: marker) else { return nil }
        let tail = markdown[markerRange.upperBound...]
        guard let openIdx = tail.firstIndex(of: "{") else { return nil }
        var depth = 0
        var endIdx: String.Index?
        for idx in tail[openIdx...].indices {
            let ch = tail[idx]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 { endIdx = idx; break }
            }
        }
        guard let close = endIdx else { return nil }
        return tail[openIdx...close]
    }
}

private extension ISO8601DateFormatter {
    static let short: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
