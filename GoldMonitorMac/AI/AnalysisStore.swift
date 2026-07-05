import Foundation
import Combine

/// Holds AI analysis state at the dashboard scope so that opening or
/// closing the AnalysisSheet doesn't destroy a running task. Also keeps
/// a rolling history (persisted to UserDefaults) so the user can revisit
/// past analyses per category.
///
/// Lifecycle:
///   • `run(kind:engine:…)`    starts a task, transitions session to .running.
///   • Each streamed chunk is appended to `sessions[kind].report`.
///   • On completion the session moves to .done and an entry is pushed
///     onto `history` (which is persisted).
///   • Sheet close DOES NOT cancel the task — store survives at the
///     dashboard level. Reopening the sheet shows the in-progress
///     report wherever streaming left it.
///
/// We DO NOT persist in-flight sessions across an app launch — the task
/// dies with the process. Only completed entries become history.
@MainActor
final class AnalysisStore: ObservableObject {
    enum Phase: Equatable {
        case idle, running, done, error
    }

    /// One Q&A in the conversation tail of a Session. Drives the
    /// chat UI below the report — user types a follow-up, an
    /// engine task streams the assistant response into this
    /// turn's `assistant` field, then `isStreaming` flips off.
    /// Equatable so SwiftUI can diff cleanly on re-render.
    struct Turn: Identifiable, Equatable {
        let id: UUID
        var user: String
        var assistant: String
        var isStreaming: Bool
        var error: String?
        fileprivate var task: Task<Void, Never>?

        static func == (lhs: Turn, rhs: Turn) -> Bool {
            lhs.id == rhs.id
            && lhs.user == rhs.user
            && lhs.assistant == rhs.assistant
            && lhs.isStreaming == rhs.isStreaming
            && lhs.error == rhs.error
        }
    }

    /// Composite key — sessions are per (pair, kind) so each symbol
    /// keeps its own slot for each analysis category. Without this,
    /// switching from Gold Ounce to a Toman pair would surface the
    /// ounce's session text on the new pair (or vice-versa).
    struct SessionKey: Hashable {
        let pairID: String
        let kind: AnalysisKind
        /// Identifies a manual analysis tab. `nil` is the canonical
        /// per-(pair, kind) slot used by the auto-trader's headless
        /// runs + legacy callers. The manual analysis page passes a
        /// per-tab UUID so a symbol can run several independent
        /// scenarios concurrently (browser-tab style).
        var tabID: UUID? = nil
    }

    /// Per-(pair, kind) state. The user can start one analysis per kind
    /// on each pair and switch between them mid-stream without the
    /// picker yanking text out from under them.
    ///
    /// **Reference type (Performance Fix 7)**: was a struct; converted
    /// to a class so streaming chunk appends can mutate the live
    /// instance without re-assigning the dict subscript. The dict's
    /// `@Published` only fires on session add/remove/explicit phase
    /// transition (via `mutateAndPublish`) — the 10 Hz chunk flushes
    /// bypass the store publisher entirely. Views that need to react
    /// to streaming text (the report column) bind via
    /// `@ObservedObject` to the session directly.
    final class Session: ObservableObject {
        @Published var report: String = "" {
            didSet { renderCacheValid = false }
        }
        /// Internal reasoning trace emitted by extended-thinking
        /// models (Claude Opus / Sonnet 4.x with thinking on). The
        /// report column renders this in a collapsible section above
        /// the main answer — same UX as the Claude Code VSCode
        /// extension's "Thinking" disclosure. Empty for engines that
        /// don't surface thinking (Codex, older Claude CLIs).
        @Published var thinking: String = ""
        @Published var phase: Phase = .idle
        @Published var lastError: String?
        var startedAt: Date?
        /// Cached prompts used to kick the initial run. The
        /// follow-up flow re-uses both so the model has the same
        /// system framing + same evidence (OHLC, indicators,
        /// HTF) the original answer was built from. Empty until
        /// a run has started.
        var systemPromptUsed: String = ""
        var userPromptUsed: String = ""
        /// Conversation turns AFTER the initial report — one
        /// element per follow-up the user has asked. `isStreaming`
        /// flips true while the assistant chunk is still landing
        /// so the UI can show its own caret per turn.
        @Published var conversation: [Turn] = []
        /// Snapshot of the run context. We carry it on the session so
        /// the history entry can be created at completion time without
        /// re-reading the dashboard's "current" pair (which may have
        /// changed while the task was running).
        var pairName: String = ""
        var pairID: String = ""
        var timeframeLabel: String = ""
        var engineLabel: String = ""
        /// Byte offset into `thinking` where stage-2 (CTS Expand)
        /// content begins. nil before Expand fires. Used by the
        /// report column to split the thinking trace into two
        /// inline disclosures (one per stage) instead of one
        /// concatenated blob.
        @Published var expandThinkingOffset: Int? = nil
        fileprivate var task: Task<Void, Never>? = nil

        init() {}

        // ── Report render cache ────────────────────────────────────
        // The report column renders `report` with the structured
        // JSON blocks stripped, split into chunks at H3 boundaries
        // (so MarkdownUI only builds view trees for sections near the
        // viewport). Recomputing `stripStructuredBlocks` + the chunk
        // split on every body render — including scroll events and
        // every tab switch — was a primary source of scroll + tab lag.
        //
        // Caching the result *on the session* (not the view) means a
        // tab switch is a pure read: the report column asks
        // `renderChunks()` and gets a memoised value back without
        // re-parsing the (potentially long) report. `report.didSet`
        // invalidates the cache, so streaming still recomputes once
        // per flush. (Tab-switch Fix.)
        struct RenderChunks: Equatable {
            var clean: String = ""
            var stage1: [String] = []
            var stage2: [String] = []
            var hasStage2: Bool = false
        }

        private var renderCacheValid = false
        private var renderCacheValue = RenderChunks()
        /// Throttle for renderChunks() recomputation during streaming.
        /// The 100 ms chunk flush invalidates the cache every time,
        /// but the actual stripStructuredBlocks + chunkAtH3 work is
        /// deferred until at least `renderThrottleMS` has elapsed
        /// since the last computation. The stale cache is returned
        /// in the interim — the trailing `Text()` chunk handles the
        /// visual gap, so a 200 ms lag on the completed-chunk
        /// promotion is imperceptible. (Streaming Performance Fix.)
        private var renderLastComputedAt: Date = .distantPast
        private static let renderThrottleMS: TimeInterval = 0.2

        /// Memoised, structured-block-stripped + H3-chunked view of
        /// `report`. O(1) when the report hasn't changed since the
        /// last call; recomputes only after a `report` mutation.
        /// During streaming, recomputation is throttled to at most
        /// once per 200 ms even though `report` mutates every 100 ms.
        func renderChunks() -> RenderChunks {
            if renderCacheValid { return renderCacheValue }
            let now = Date()
            if now.timeIntervalSince(renderLastComputedAt) < Self.renderThrottleMS {
                // Too soon — return the stale cache. The trailing
                // Text() chunk covers the visual gap.
                return renderCacheValue
            }
            renderCacheValue = Self.computeRenderChunks(report)
            renderCacheValid = true
            renderLastComputedAt = now
            return renderCacheValue
        }

        private static func computeRenderChunks(_ report: String) -> RenderChunks {
            let cleaned = PromptBuilder.stripStructuredBlocks(report)
            var out = RenderChunks(clean: cleaned)
            if let range = cleaned.range(of: AnalysisStore.expandMarker) {
                let pre  = String(cleaned[..<range.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let post = String(cleaned[range.upperBound...])
                    // Strip the leading "\n\n---\n\n" separator that
                    // immediately follows the marker so stage 2 starts
                    // cleanly at the first heading.
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                out.stage1 = chunkAtH3(pre)
                out.stage2 = chunkAtH3(post)
                out.hasStage2 = true
            } else {
                out.stage1 = chunkAtH3(cleaned)
            }
            return out
        }

        /// Split a markdown report into self-contained chunks at H3
        /// (`### `) boundaries. Reports without any H3 fall through
        /// as a single chunk.
        private static func chunkAtH3(_ markdown: String) -> [String] {
            guard !markdown.isEmpty else { return [] }
            var chunks: [String] = []
            var current: [String] = []
            for line in markdown.components(separatedBy: "\n") {
                if line.hasPrefix("### ") && !current.isEmpty {
                    chunks.append(current.joined(separator: "\n"))
                    current = [line]
                } else {
                    current.append(line)
                }
            }
            if !current.isEmpty {
                chunks.append(current.joined(separator: "\n"))
            }
            return chunks
        }
    }

    /// HTML-comment marker injected at the stage 2 boundary in
    /// `session.report`. Doesn't render in MarkdownUI; the report
    /// column searches for it to split chunks + insert a second
    /// thinking disclosure right at that boundary.
    ///
    /// `nonisolated` because it's a plain constant read from
    /// `computeRenderChunks` (a nonisolated static helper) — it carries
    /// no actor state, so it doesn't need the class's `@MainActor`
    /// isolation.
    nonisolated static let expandMarker = "<!--helix-expand-mark-->"

    /// One completed analysis kept in the history list. The structured
    /// payloads (`srLevels`, `fvgZones`, `taScenario`) are extracted
    /// from the markdown at completion time and stored alongside the raw
    /// text, so reopening a past entry re-applies its chart overlays
    /// without re-parsing.
    ///
    /// All three structured fields are optional with `decodeIfPresent`
    /// fallback so older entries (saved before this feature shipped)
    /// continue to load — they'll just have nil overlays, the markdown
    /// itself opens normally.
    /// Outcome of a trade-bearing analysis entry, recorded once the
    /// activated trade hits a terminal state. The history view rolls
    /// these up into a per-kind win-rate stat; the prompt builder
    /// can later feed past outcomes back into the model so it self-
    /// corrects on systematic misses.
    enum Outcome: String, Codable, Equatable {
        case hitTP        // win
        case hitSL        // loss
        case manual       // closed by hand — neutral, doesn't count toward W/L
        case cancelled    // pending trade cancelled before fill — also neutral
    }

    struct HistoryEntry: Identifiable, Codable, Equatable {
        let id: UUID
        let kind: AnalysisKind
        let pairID: String
        let pairName: String
        let timeframeLabel: String
        let engineLabel: String
        let date: Date
        let report: String
        /// Thinking trace captured during the run. Optional + decoded
        /// via `decodeIfPresent` so older history entries (no
        /// thinking column) load cleanly. Reopening an entry restores
        /// it into the session so the user can re-read the model's
        /// reasoning, not just the final answer.
        let thinking: String?
        let srLevels: PromptBuilder.SRLevels?
        let fvgZones: [PromptBuilder.FVGZone]?
        /// Confluence Scanner / Custom Supply & Demand zones. Optional +
        /// `decodeIfPresent`-friendly so entries persisted before
        /// this feature shipped still load — they'll just lack
        /// zones, the rest of the entry opens normally.
        let supplyDemandZones: [PromptBuilder.SupplyDemandZone]?
        /// Confluence Scanner scored scenario queue. Ordered by score
        /// descending. Auto-trader iterates this list, trying
        /// each in turn on invalidation before re-running. Older
        /// entries (pre-feature) load with nil — the engine
        /// falls back to `taScenario` for single-scenario flow.
        let scoredScenarios: [PromptBuilder.ScoredScenario]?
        let taScenario: PromptBuilder.TAScenario?
        /// Optional second plan from a full-TA run. Claude is asked
        /// to emit ALT_SCENARIO_JSON only when there's a genuinely
        /// useful alternative; entries from before this feature
        /// existed (and runs where Claude omitted the block) decode
        /// this as nil via `decodeIfPresent`.
        let taAltScenario: PromptBuilder.TAScenario?
        /// Set when the user activated the scenario as a trade AND
        /// the trade reached a terminal state. `var` so the trade
        /// evaluator can mutate it post-creation via
        /// `AnalysisStore.recordOutcome`. Nil for non-activated
        /// entries (the vast majority).
        var outcome: Outcome?
        /// When `outcome` was set. Lets the UI sort / age recent
        /// closes vs ancient ones.
        var outcomeAt: Date?
        /// Realised P/L at close, in pair units. Nil for entries
        /// without an outcome or where the trade evaluator didn't
        /// capture it (older trades without the link).
        var outcomeRealisedPL: Double?

        init(
            id: UUID,
            kind: AnalysisKind,
            pairID: String,
            pairName: String,
            timeframeLabel: String,
            engineLabel: String,
            date: Date,
            report: String,
            thinking: String? = nil,
            srLevels: PromptBuilder.SRLevels? = nil,
            fvgZones: [PromptBuilder.FVGZone]? = nil,
            supplyDemandZones: [PromptBuilder.SupplyDemandZone]? = nil,
            scoredScenarios: [PromptBuilder.ScoredScenario]? = nil,
            taScenario: PromptBuilder.TAScenario? = nil,
            taAltScenario: PromptBuilder.TAScenario? = nil,
            outcome: Outcome? = nil,
            outcomeAt: Date? = nil,
            outcomeRealisedPL: Double? = nil
        ) {
            self.id = id
            self.kind = kind
            self.pairID = pairID
            self.pairName = pairName
            self.timeframeLabel = timeframeLabel
            self.engineLabel = engineLabel
            self.date = date
            self.report = report
            self.thinking = thinking
            self.srLevels = srLevels
            self.fvgZones = fvgZones
            self.supplyDemandZones = supplyDemandZones
            self.scoredScenarios = scoredScenarios
            self.taScenario = taScenario
            self.taAltScenario = taAltScenario
            self.outcome = outcome
            self.outcomeAt = outcomeAt
            self.outcomeRealisedPL = outcomeRealisedPL
        }

        /// Custom decoder so older history payloads (without the
        /// optional overlay fields) still decode cleanly.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            kind = try c.decode(AnalysisKind.self, forKey: .kind)
            pairID = try c.decode(String.self, forKey: .pairID)
            pairName = try c.decode(String.self, forKey: .pairName)
            timeframeLabel = try c.decode(String.self, forKey: .timeframeLabel)
            engineLabel = try c.decode(String.self, forKey: .engineLabel)
            date = try c.decode(Date.self, forKey: .date)
            report = try c.decode(String.self, forKey: .report)
            thinking = try c.decodeIfPresent(String.self, forKey: .thinking)
            srLevels = try c.decodeIfPresent(PromptBuilder.SRLevels.self, forKey: .srLevels)
            fvgZones = try c.decodeIfPresent([PromptBuilder.FVGZone].self, forKey: .fvgZones)
            supplyDemandZones = try c.decodeIfPresent([PromptBuilder.SupplyDemandZone].self, forKey: .supplyDemandZones)
            scoredScenarios = try c.decodeIfPresent([PromptBuilder.ScoredScenario].self, forKey: .scoredScenarios)
            taScenario = try c.decodeIfPresent(PromptBuilder.TAScenario.self, forKey: .taScenario)
            taAltScenario = try c.decodeIfPresent(PromptBuilder.TAScenario.self, forKey: .taAltScenario)
            outcome = try c.decodeIfPresent(Outcome.self, forKey: .outcome)
            outcomeAt = try c.decodeIfPresent(Date.self, forKey: .outcomeAt)
            outcomeRealisedPL = try c.decodeIfPresent(Double.self, forKey: .outcomeRealisedPL)
        }
    }

    /// Flat dictionary keyed by `SessionKey`. Views read via the
    /// `session(kind:pairID:)` helper rather than indexing directly so
    /// missing slots resolve to an idle session.
    @Published var sessions: [SessionKey: Session] = [:]
    @Published private(set) var history: [HistoryEntry] = []

    /// When the dashboard is in Replay mode this holds the replay
    /// cursor. Every analysis launched while it's set gets a leading
    /// "treat this instant as now" note prepended to the user prompt,
    /// so the model back-tests against the revealed bars instead of
    /// complaining that the data is stale. nil ⇒ live, no note. Set by
    /// DashboardView; read once at `startSession`.
    var replayAsOf: Date?

    /// Leading note injected into the user prompt during Replay. Anchors
    /// the model to the cursor as "now" so it analyses the revealed bars
    /// as a live setup rather than a historical post-mortem.
    private static func replayPreamble(_ asOf: Date?) -> String {
        guard let asOf else { return "" }
        let f = ISO8601DateFormatter()
        return """
        IMPORTANT — HISTORICAL REPLAY / BACK-TEST CONTEXT
        Treat \(f.string(from: asOf)) as the current moment ("now"). The most \
        recent candle in the data below is the latest bar available as of that \
        instant — you have NO knowledge of any price action after it. Analyse \
        the setup exactly as if you were standing at that point in time.


        """
    }

    /// Per-key chunk batching state. Claude streams text deltas
    /// at 30-100 Hz; appending to the session storage per-chunk
    /// re-publishes the dict and forces the entire report column
    /// (Markdown re-parse + 5 JSON extract+parse passes + chart
    /// re-render) to redraw at that same rate, which pegs the
    /// main thread on long reports. We coalesce into `pendingText`
    /// / `pendingThinking` buffers and flush at most 10 Hz via
    /// `flushTimers`. Net effect: ~5× fewer redraws with no
    /// visible delay (≤ 100 ms is invisible for streaming text).
    ///
    /// The buffer is keyed by `(SessionKey, target)` — `target` is
    /// either `.report` (the main streamed answer + thinking) or
    /// `.conversationTurn(UUID)` (one specific follow-up turn).
    /// Both flows funnel through the same flush so the follow-up
    /// path also gets 10 Hz batching instead of the raw 30-100 Hz
    /// republish-per-token it used to do. (Performance Fix 1.)
    private struct BufferKey: Hashable {
        let session: SessionKey
        let target: Target

        enum Target: Hashable {
            case report
            case conversationTurn(UUID)
        }
    }

    private var pendingText: [BufferKey: String] = [:]
    private var pendingThinking: [BufferKey: String] = [:]
    private var flushTimers: [BufferKey: DispatchSourceTimer] = [:]
    private static let chunkFlushIntervalMS: Int = 100

    /// Look up the session for a specific pair + kind. Returns an
    /// empty/idle session when the user hasn't run anything for that
    /// combination yet — keeps call sites null-free.
    func session(kind: AnalysisKind, pairID: String, tabID: UUID? = nil) -> Session {
        let key = SessionKey(pairID: pairID, kind: kind, tabID: tabID)
        if let existing = sessions[key] { return existing }
        let s = Session()
        sessions[key] = s
        return s
    }

    private static let historyKey = "analysis.history.v1"
    /// Cap on history size — anything older than this falls off the
    /// list. Keeps UserDefaults from ballooning forever.
    private static let historyCap = 50

    init() {
        loadHistory()
    }

    // ── Public API ──────────────────────────────────────────────────

    /// Kick off a single-timeframe analysis. Cancels any prior task
    /// for the same (pair, kind) slot. `htf` is an optional
    /// higher-timeframe snapshot the caller has already loaded so
    /// the prompt can include a one-line bigger-picture summary —
    /// the page fetches it from the dashboard's `loadCandles` before
    /// kicking the run.
    ///
    /// `customTask` is the user's first chat message for `.custom`
    /// runs — it replaces the canned task line in the user prompt
    /// so the model is answering an actual question, not a generic
    /// "produce a TA" instruction. Ignored for the other kinds.
    func run(
        kind: AnalysisKind,
        engineKind: AIEngineKind,
        pair: TradingPair,
        timeframe: Timeframe,
        candles: [Candle],
        htf: PromptBuilder.HTFContext? = nil,
        customTask: String? = nil,
        tabID: UUID? = nil
    ) {
        let user = PromptBuilder.userPrompt(
            kind: kind,
            pair: pair,
            timeframe: timeframe,
            candles: candles,
            htf: htf,
            customTask: customTask
        )
        startSession(
            key: SessionKey(pairID: pair.id, kind: kind, tabID: tabID),
            engineKind: engineKind,
            pair: pair,
            timeframeLabel: timeframe.label,
            user: user
        )
    }

    /// Multi-timeframe analysis: hands Claude OHLC for several
    /// timeframes at once and asks for the comparison table. The
    /// session's `timeframeLabel` joins the TFs (`"15m / 1h / 4h"`) so
    /// the history list reads sensibly.
    func runMultiTimeframe(
        engineKind: AIEngineKind,
        pair: TradingPair,
        candlesByTF: [(Timeframe, [Candle])],
        tabID: UUID? = nil
    ) {
        let user = PromptBuilder.userPromptMultiTimeframe(
            pair: pair,
            candlesByTF: candlesByTF
        )
        let label = candlesByTF.map { $0.0.label }.joined(separator: " / ")
        startSession(
            key: SessionKey(pairID: pair.id, kind: .multiTimeframe, tabID: tabID),
            engineKind: engineKind,
            pair: pair,
            timeframeLabel: label,
            user: user
        )
    }

    /// Combined (checklist) analysis — assembles a dynamic system +
    /// user prompt from the ticked `aspects` and runs under the
    /// `.combined` slot. `candlesByTF` is the timeframe bundle the
    /// page already loaded (trio when any aspect needs multi-TF,
    /// else just the focus TF). `freeText` folds the user's optional
    /// typed intent into the prompt.
    func runCombined(
        engineKind: AIEngineKind,
        pair: TradingPair,
        focusTimeframe: Timeframe,
        candlesByTF: [(Timeframe, [Candle])],
        aspects: Set<AnalysisAspect>,
        horizonHint: String? = nil,
        freeText: String? = nil,
        tabID: UUID? = nil
    ) {
        let system = PromptBuilder.systemCombined(aspects: aspects, horizonHint: horizonHint)
        let user = PromptBuilder.userPromptCombined(
            pair: pair,
            focusTimeframe: focusTimeframe,
            candlesByTF: candlesByTF,
            aspects: aspects,
            freeText: freeText
        )
        let label = candlesByTF.count > 1
            ? candlesByTF.map { $0.0.label }.joined(separator: " / ")
            : focusTimeframe.label
        startSession(
            key: SessionKey(pairID: pair.id, kind: .combined, tabID: tabID),
            engineKind: engineKind,
            pair: pair,
            timeframeLabel: label,
            user: user,
            systemOverride: system
        )
    }

    /// Top-Down Sniper — fixed 4H / 1H / 15m bundle routed through
    /// the top-down model prompt. Emits LEVELS / SUPPLY_DEMAND /
    /// FVG / SCENARIO blocks, so the report + every right-column
    /// card light up.
    func runTopDownSniper(
        engineKind: AIEngineKind,
        pair: TradingPair,
        candlesByTF: [(Timeframe, [Candle])],
        tabID: UUID? = nil
    ) {
        let user = PromptBuilder.userPromptTopDownSniper(
            pair: pair,
            candlesByTF: candlesByTF
        )
        // System prompt is built from the actual trio so the role
        // descriptions name the right timeframes (Swing 4H/1H/15m
        // vs Intraday 1H/15m/1m).
        let htf = candlesByTF.first?.0.label ?? "4H"
        let mtf = candlesByTF.count > 1 ? candlesByTF[1].0.label : "1H"
        let ltf = candlesByTF.last?.0.label ?? "15m"
        let system = PromptBuilder.systemTopDownSniper(htf: htf, mtf: mtf, ltf: ltf)
        let label = candlesByTF.map { $0.0.label }.joined(separator: " / ")
        startSession(
            key: SessionKey(pairID: pair.id, kind: .topDownSniper, tabID: tabID),
            engineKind: engineKind,
            pair: pair,
            timeframeLabel: label,
            user: user,
            systemOverride: system
        )
    }

    /// Confluence Trade Scanner — same multi-TF bundle as
    /// `runMultiTimeframe` but routed through the scanner's
    /// user-prompt builder and stored under the
    /// `.confluenceScanner` slot. Produces a SCENARIO_JSON plan
    /// so the PlanCard / chart-overlay path lights up just like
    /// full TA.
    func runConfluenceScanner(
        engineKind: AIEngineKind,
        pair: TradingPair,
        candlesByTF: [(Timeframe, [Candle])],
        priorRunHint: PromptBuilder.PriorRunHint? = nil,
        horizonHint: String? = nil,
        tabID: UUID? = nil
    ) {
        let user = PromptBuilder.userPromptConfluenceScanner(
            pair: pair,
            candlesByTF: candlesByTF,
            priorRunHint: priorRunHint,
            horizonHint: horizonHint
        )
        let label = candlesByTF.map { $0.0.label }.joined(separator: " / ")
        startSession(
            key: SessionKey(pairID: pair.id, kind: .confluenceScanner, tabID: tabID),
            engineKind: engineKind,
            pair: pair,
            timeframeLabel: label,
            user: user
        )
    }

    /// Confluence Trade Scanner **Expand** — user-triggered
    /// follow-up to a completed Stage 1 run. Takes the prior S&D
    /// report as context, adds raw market-structure analysis,
    /// and produces the scored `SCENARIOS_JSON` block for the
    /// auto-trader's fallback queue. Streams into the SAME
    /// `.confluenceScanner` session — appends after a separator
    /// into `session.report` — so the parsers, history entry,
    /// and chart overlays all stay on a single (pair, kind)
    /// slot rather than fragmenting into a separate session.
    func runConfluenceScannerExpand(
        engineKind: AIEngineKind,
        pair: TradingPair,
        candlesByTF: [(Timeframe, [Candle])],
        tabID: UUID? = nil
    ) {
        let key = SessionKey(pairID: pair.id, kind: .confluenceScanner, tabID: tabID)
        guard let session = sessions[key],
              session.phase == .done,
              !session.report.isEmpty
        else { return }

        let priorReport = session.report
        let user = PromptBuilder.userPromptConfluenceScannerExpand(
            pair: pair,
            candlesByTF: candlesByTF,
            priorReport: priorReport
        )
        let engine = AIEngineFactory.make(engineKind)
        let system = PromptBuilder.systemConfluenceScannerExpand

        // Mark the session running again and seed a separator so
        // the appended stage 2 output reads as a distinct section
        // in the report column. The HTML-comment marker is
        // invisible in the rendered markdown but lets the column
        // split the cleaned report at the exact boundary so it
        // can interleave a second thinking disclosure here.
        // Reset the existing task handle so a Stop kills the new
        // stream.
        //
        // mutateAndPublish forces a single store-level publish for
        // the whole prelude so the page sees the phase flip back
        // to `.running` in one pass.
        mutateAndPublish(key) {
            $0.phase = .running
            $0.startedAt = $0.startedAt ?? Date()
            $0.userPromptUsed = user
            $0.systemPromptUsed = system
            $0.expandThinkingOffset = $0.thinking.count
            $0.report.append("\n\n\(Self.expandMarker)\n\n---\n\n")
        }

        let task = Task { @MainActor [weak self] in
            do {
                for try await event in engine.run(system: system, user: user) {
                    guard let self = self else { return }
                    switch event {
                    case .text(let chunk):
                        self.bufferChunk(chunk, kind: .text, key: key)
                    case .thinking(let chunk):
                        self.bufferChunk(chunk, kind: .thinking, key: key)
                    }
                }
                guard let self = self else { return }
                self.endBatching(for: key)
                self.mutateAndPublish(key) { $0.phase = .done }
                // Re-record onto history so the latest entry
                // captures the appended SCENARIOS_JSON +
                // expanded report. Stage 1 already inserted a
                // HistoryEntry; we amend it in place rather than
                // create a sibling row.
                if let snap = self.sessions[key] {
                    self.amendLatestHistoryEntry(kind: .confluenceScanner, session: snap)
                }
            } catch is CancellationError {
                guard let self = self else { return }
                self.endBatching(for: key)
                self.mutateAndPublish(key) { $0.phase = .done }
            } catch {
                guard let self = self else { return }
                self.endBatching(for: key)
                self.mutateAndPublish(key) {
                    $0.lastError = error.localizedDescription
                    $0.phase = .error
                }
            }
        }
        sessions[key]?.task = task
    }

    /// Rewrite the most recent HistoryEntry for this (pair, kind)
    /// with re-parsed structured payloads from the now-amended
    /// session. Used by `runConfluenceScannerExpand` so the auto-trader
    /// queue sees `scoredScenarios` on the same entry the user
    /// is already viewing, instead of a second row.
    private func amendLatestHistoryEntry(kind: AnalysisKind, session: Session) {
        guard let idx = history.firstIndex(where: {
            $0.kind == kind && $0.pairID == session.pairID
        }) else {
            recordCompletion(kind: kind, session: session)
            return
        }
        let prior = history[idx]
        let sd = PromptBuilder.parseSupplyDemandZones(session.report)
        let scored = PromptBuilder.parseScoredScenarios(session.report)
        let ta = PromptBuilder.parseTAScenario(session.report)
        let alt = PromptBuilder.parseTAAltScenario(session.report)
        let trimmedThinking = session.thinking.trimmingCharacters(in: .whitespacesAndNewlines)
        let amended = HistoryEntry(
            id: prior.id,
            kind: prior.kind,
            pairID: prior.pairID,
            pairName: prior.pairName,
            timeframeLabel: prior.timeframeLabel,
            engineLabel: prior.engineLabel,
            date: prior.date,
            report: session.report,
            thinking: trimmedThinking.isEmpty ? nil : session.thinking,
            srLevels: prior.srLevels,
            fvgZones: prior.fvgZones,
            supplyDemandZones: sd.isEmpty ? prior.supplyDemandZones : sd,
            scoredScenarios: scored.isEmpty ? prior.scoredScenarios : scored,
            taScenario: ta ?? prior.taScenario,
            taAltScenario: alt ?? prior.taAltScenario
        )
        history[idx] = amended
        saveHistory()
    }

    /// Shared "spawn an engine task for this (pair, kind)" helper. Both
    /// run variants funnel through here to avoid duplicating the
    /// streaming loop / error / completion branches.
    ///
    /// `systemOverride` lets dynamic-prompt callers (the combined
    /// checklist run) supply a system message assembled at call time
    /// instead of the static `systemPrompt(for: kind)`.
    private func startSession(
        key: SessionKey,
        engineKind: AIEngineKind,
        pair: TradingPair,
        timeframeLabel: String,
        user: String,
        systemOverride: String? = nil
    ) {
        sessions[key]?.task?.cancel()

        let engine = AIEngineFactory.make(engineKind)
        let system = systemOverride ?? PromptBuilder.systemPrompt(for: key.kind)
        // Prepend the replay "as-of" note when back-testing so the model
        // anchors to the cursor instead of treating the data as stale.
        let resolvedUser = Self.replayPreamble(replayAsOf) + user

        let session = Session()
        session.phase = .running
        session.startedAt = Date()
        session.pairName = pair.name
        session.pairID = pair.id
        session.timeframeLabel = timeframeLabel
        session.engineLabel = engine.label
        session.systemPromptUsed = system
        session.userPromptUsed = resolvedUser

        let task = Task { @MainActor [weak self] in
            do {
                for try await event in engine.run(system: system, user: resolvedUser) {
                    guard let self = self else { return }
                    switch event {
                    case .text(let chunk):
                        self.bufferChunk(chunk, kind: .text, key: key)
                    case .thinking(let chunk):
                        self.bufferChunk(chunk, kind: .thinking, key: key)
                    }
                }
                guard let self = self else { return }
                self.endBatching(for: key)
                let report = self.sessions[key]?.report ?? ""
                let thinking = self.sessions[key]?.thinking ?? ""
                let hasContent = !report.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                 || !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if !hasContent {
                    self.mutateAndPublish(key) {
                        $0.lastError = "Empty response"
                        $0.phase = .error
                    }
                } else {
                    self.mutateAndPublish(key) { $0.phase = .done }
                    if let snap = self.sessions[key] {
                        self.recordCompletion(kind: key.kind, session: snap)
                    }
                }
            } catch is CancellationError {
                guard let self = self else { return }
                self.endBatching(for: key)
                let hadAny = !(self.sessions[key]?.report.isEmpty ?? true)
                self.mutateAndPublish(key) { $0.phase = hadAny ? .done : .idle }
            } catch {
                guard let self = self else { return }
                self.endBatching(for: key)
                self.mutateAndPublish(key) {
                    $0.lastError = error.localizedDescription
                    $0.phase = .error
                }
            }
        }
        session.task = task
        sessions[key] = session
    }

    /// Cooperative stop. The task's URLSession / Process responds to
    /// cancellation by terminating its underlying work. Pair-scoped so
    /// a stop on one symbol doesn't kill another symbol's parallel run.
    func stop(kind: AnalysisKind, pairID: String, tabID: UUID? = nil) {
        sessions[SessionKey(pairID: pairID, kind: kind, tabID: tabID)]?.task?.cancel()
    }

    // ── Chunk batching helpers ────────────────────────────────────

    /// Stash a streamed text or thinking chunk; the timer will
    /// flush it into the targeted destination at most ~10 Hz. First
    /// call for the buffer key also spins up the flush timer.
    ///
    /// `target` defaults to `.report` for the main streamed answer.
    /// Follow-up turns pass `.conversationTurn(turnID)` so their
    /// deltas land on the right `Turn.assistant` field — the same
    /// 100 ms coalescing as the main report. (Performance Fix 1.)
    private func bufferChunk(
        _ chunk: String,
        kind: ChunkKind,
        key: SessionKey,
        target: BufferKey.Target = .report
    ) {
        let bk = BufferKey(session: key, target: target)
        switch kind {
        case .text:     pendingText[bk, default: ""].append(chunk)
        case .thinking: pendingThinking[bk, default: ""].append(chunk)
        }
        ensureFlushTimer(for: bk)
    }

    private enum ChunkKind { case text, thinking }

    private func ensureFlushTimer(for bk: BufferKey) {
        guard flushTimers[bk] == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        let ms = Self.chunkFlushIntervalMS
        t.schedule(deadline: .now() + .milliseconds(ms), repeating: .milliseconds(ms))
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.flushPendingChunks(for: bk) }
        }
        t.resume()
        flushTimers[bk] = t
    }

    /// Drain `pendingText` / `pendingThinking` into the targeted
    /// destination — either the session's report/thinking fields
    /// or a specific conversation turn's `assistant` field.
    /// No-op when both buffers are empty (timer keeps running so
    /// the next chunk doesn't pay the timer-setup cost again).
    private func flushPendingChunks(for bk: BufferKey) {
        let text = pendingText[bk] ?? ""
        let think = pendingThinking[bk] ?? ""
        guard !text.isEmpty || !think.isEmpty else { return }
        pendingText[bk] = ""
        pendingThinking[bk] = ""

        let sessionKey = bk.session
        switch bk.target {
        case .report:
            if !text.isEmpty {
                sessions[sessionKey]?.report.append(text)
            }
            if !think.isEmpty {
                sessions[sessionKey]?.thinking.append(think)
            }
        case .conversationTurn(let turnID):
            // Follow-ups stream into a specific Turn. Thinking
            // deltas are dropped for follow-ups (the initial run
            // already burned through reasoning) but we handle the
            // case defensively in case future engines surface
            // thinking on follow-ups too.
            guard let sess = sessions[sessionKey],
                  let idx = sess.conversation.firstIndex(where: { $0.id == turnID })
            else { return }
            if !text.isEmpty {
                sess.conversation[idx].assistant.append(text)
            }
            // No `sessions[sessionKey] = sess` — Session is a class
            // so the mutation is in-place. The @Published var
            // conversation fires on the session itself; the report
            // column observes it via @ObservedObject. Re-assigning
            // the dict subscript here would trigger the store-level
            // @Published cascade (Performance Fix 7).
        }
    }

    /// Stop coalescing for this buffer key, flushing whatever's left
    /// so the final tail isn't dropped on stream completion / error /
    /// cancellation.
    private func endBatching(for bk: BufferKey) {
        flushPendingChunks(for: bk)
        flushTimers[bk]?.cancel()
        flushTimers[bk] = nil
    }

    /// Convenience overload for the main-report streaming path —
    /// keeps the existing call sites in `startSession` /
    /// `runConfluenceScannerExpand` short.
    private func endBatching(for key: SessionKey) {
        endBatching(for: BufferKey(session: key, target: .report))
    }

    /// Mutate a session in place, then re-assign the dict subscript
    /// so the store's `@Published` fires.
    ///
    /// **Why**: with Session as a class, plain `sessions[key]?.x = y`
    /// mutates the live instance but does NOT trip the dict publisher
    /// (the dict's value — the reference — is unchanged). That's the
    /// desired behaviour for streaming chunk appends (we want them to
    /// stay below the store-level publish radar). It's the WRONG
    /// behaviour for phase transitions, which page-level views
    /// observe via the store. So phase/error transitions go through
    /// here and chunk appends go directly. (Performance Fix 7.)
    private func mutateAndPublish(_ key: SessionKey, _ block: (Session) -> Void) {
        guard let s = sessions[key] else { return }
        block(s)
        // Re-assign the same reference back. Dict subscript writes
        // always invoke the @Published setter, so observers re-render.
        sessions[key] = s
    }

    /// Wipe a (pair, kind) session back to idle. Used by the "Clear"
    /// button.
    func clear(kind: AnalysisKind, pairID: String, tabID: UUID? = nil) {
        let key = SessionKey(pairID: pairID, kind: kind, tabID: tabID)
        sessions[key]?.task?.cancel()
        sessions[key] = Session()
    }

    /// Ask a follow-up question against the current session's
    /// report. Re-uses the same system framing + the original
    /// user message (with its OHLC / indicators / HTF block) so
    /// the model has full context, then layers the prior assistant
    /// answer + every previous follow-up before the new question.
    /// Streams the response into a fresh turn appended to
    /// `session.conversation`. No-op when the session hasn't run
    /// yet (nothing to follow up on).
    func askFollowUp(
        kind: AnalysisKind,
        pairID: String,
        engineKind: AIEngineKind,
        question: String,
        tabID: UUID? = nil
    ) {
        let key = SessionKey(pairID: pairID, kind: kind, tabID: tabID)
        guard let session = sessions[key],
              !session.systemPromptUsed.isEmpty,
              !session.userPromptUsed.isEmpty,
              !session.report.isEmpty
        else { return }

        let trimmedQ = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQ.isEmpty else { return }

        let turn = Turn(
            id: UUID(),
            user: trimmedQ,
            assistant: "",
            isStreaming: true,
            error: nil,
            task: nil
        )
        session.conversation.append(turn)
        sessions[key] = session

        let engine = AIEngineFactory.make(engineKind)
        let system = session.systemPromptUsed
        let followUpUser = buildFollowUpUserPrompt(
            originalUser: session.userPromptUsed,
            originalReport: session.report,
            priorTurns: session.conversation.dropLast(),
            question: trimmedQ
        )
        let turnID = turn.id

        let turnBufferKey = BufferKey(session: key, target: .conversationTurn(turnID))

        let task = Task { @MainActor [weak self] in
            do {
                for try await event in engine.run(system: system, user: followUpUser) {
                    guard let self = self else { return }
                    // Route .text through the same 100 ms chunk
                    // batcher as the main report stream. .thinking
                    // deltas are dropped — the follow-up UI doesn't
                    // surface a reasoning trace per turn.
                    if case .text(let chunk) = event {
                        self.bufferChunk(
                            chunk,
                            kind: .text,
                            key: key,
                            target: .conversationTurn(turnID)
                        )
                    }
                }
                guard let self = self else { return }
                self.endBatching(for: turnBufferKey)
                guard let sess = self.sessions[key],
                      let idx = sess.conversation.firstIndex(where: { $0.id == turnID })
                else { return }
                sess.conversation[idx].isStreaming = false
                if sess.conversation[idx].assistant
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    sess.conversation[idx].error = "Empty response"
                }
                self.sessions[key] = sess
            } catch is CancellationError {
                guard let self = self else { return }
                self.endBatching(for: turnBufferKey)
                guard let sess = self.sessions[key],
                      let idx = sess.conversation.firstIndex(where: { $0.id == turnID })
                else { return }
                sess.conversation[idx].isStreaming = false
                self.sessions[key] = sess
            } catch {
                guard let self = self else { return }
                self.endBatching(for: turnBufferKey)
                guard let sess = self.sessions[key],
                      let idx = sess.conversation.firstIndex(where: { $0.id == turnID })
                else { return }
                sess.conversation[idx].isStreaming = false
                sess.conversation[idx].error = error.localizedDescription
                self.sessions[key] = sess
            }
        }

        // Stash the task back on the turn so a future "stop
        // follow-up" affordance can cancel it.
        if let sess = sessions[key],
           let idx = sess.conversation.firstIndex(where: { $0.id == turnID })
        {
            sess.conversation[idx].task = task
            sessions[key] = sess
        }
    }

    /// Compose the follow-up user message. Recapitulates the
    /// original context block + the original answer + every prior
    /// follow-up Q/A so the model has the full conversation in
    /// view (Claude CLI doesn't surface a multi-turn message API
    /// to non-interactive `--print` mode — single stdin only).
    private func buildFollowUpUserPrompt(
        originalUser: String,
        originalReport: String,
        priorTurns: ArraySlice<Turn>,
        question: String
    ) -> String {
        var s = """
        \(originalUser)

        ---

        ## Your prior analysis

        \(originalReport)
        """
        for turn in priorTurns {
            s += """


            ---

            ## Follow-up question

            \(turn.user)

            ## Your prior answer

            \(turn.assistant)
            """
        }
        s += """


        ---

        ## Follow-up question

        \(question)

        Answer concisely — no need to repeat the full analysis,
        just address the question directly. Cite specific numbers
        from the bars above if relevant.
        """
        return s
    }

    /// Show a historical entry in the active session slot for its
    /// (pair, kind) so the panel renders it as if it were a
    /// just-finished run. Caller must already be displaying that pair
    /// (we filter history by pair in the panel) — otherwise the load
    /// lands in a slot the current view doesn't read.
    func loadFromHistory(_ entry: HistoryEntry, tabID: UUID? = nil) {
        let key = SessionKey(pairID: entry.pairID, kind: entry.kind, tabID: tabID)
        let session = sessions[key] ?? Session()
        session.task?.cancel()
        session.report = entry.report
        session.thinking = entry.thinking ?? ""
        session.phase = .done
        session.lastError = nil
        session.pairName = entry.pairName
        session.pairID = entry.pairID
        session.timeframeLabel = entry.timeframeLabel
        session.engineLabel = entry.engineLabel
        session.task = nil
        sessions[key] = session
    }

    /// Delete one history entry.
    func deleteHistory(_ entry: HistoryEntry) {
        history.removeAll { $0.id == entry.id }
        saveHistory()
    }

    /// Stamp the outcome of an activated trade back onto its source
    /// history entry. Called from DashboardView's trade-evaluator
    /// observer whenever a trade hits a terminal state; the entry's
    /// `outcome` chip + the history view's win-rate roll-up pick it
    /// up on the next render. No-op when `entryID` doesn't match
    /// (e.g. the entry was deleted, or the trade predates this
    /// feature and has no source link).
    func recordOutcome(
        entryID: UUID,
        outcome: Outcome,
        realisedPL: Double?,
        at date: Date = Date()
    ) {
        guard let idx = history.firstIndex(where: { $0.id == entryID }) else { return }
        // Skip if already recorded — terminal states only fire once
        // per trade, but defending against repeat evaluations keeps
        // the W/L counts honest if the trade store re-emits.
        guard history[idx].outcome == nil else { return }
        history[idx].outcome = outcome
        history[idx].outcomeAt = date
        history[idx].outcomeRealisedPL = realisedPL
        saveHistory()
    }

    /// Wipe the entire history list.
    func clearAllHistory() {
        history = []
        saveHistory()
    }

    // ── Internals ────────────────────────────────────────────────────

    private func recordCompletion(kind: AnalysisKind, session: Session) {
        // Parse the structured overlay payloads once at completion time
        // — same data the panel's "Add to chart" button uses, but cached
        // on the history entry so reopening the run later can re-apply
        // the chart overlay without re-running the parser.
        // Full technical analysis emits both a SCENARIO_JSON and a
        // LEVELS_JSON block now, so we parse S/R levels for both
        // dedicated S/R runs and full TA runs. History entries keep
        // them around so reopening the run still has the levels handy
        // even if Claude isn't around to re-run.
        // `.custom`, `.combined`, and `.topDownSniper` are permissive
        // — they can emit any block, so we try every parser and keep
        // whatever actually appeared.
        let multiBlock = (kind == .custom || kind == .combined || kind == .topDownSniper)
        let sr  = (kind == .supportResistance || kind == .full || multiBlock)
            ? PromptBuilder.parseSRLevels(session.report)
            : nil
        let fvg = (kind == .fvg || multiBlock)
            ? PromptBuilder.parseFVGZones(session.report)
            : nil
        // Supply / Demand zones — Confluence Trade Scanner's
        // primary structured payload + custom / combined / top-down
        // runs that emit the block. The other kinds aren't told to
        // emit it, so we skip the parse to avoid lighting up the
        // right column with a half-recognised mention.
        let sdZones: [PromptBuilder.SupplyDemandZone]? = (kind == .confluenceScanner || multiBlock)
            ? PromptBuilder.parseSupplyDemandZones(session.report)
            : nil
        // Scored multi-scenario queue — scanner-only. The auto-
        // trader iterates this list on invalidation; Full TA /
        // Custom keep the single-scenario flow via taScenario.
        let scored: [PromptBuilder.ScoredScenario]? = (kind == .confluenceScanner)
            ? PromptBuilder.parseScoredScenarios(session.report)
            : nil
        // .full, .confluenceScanner, .custom, .combined, and
        // .topDownSniper all emit SCENARIO_JSON / ALT_SCENARIO_JSON
        // blocks via the shared marker — so they share the same
        // parser + history persistence.
        let scenarioKind = (kind == .full || kind == .confluenceScanner || multiBlock)
        let ta  = scenarioKind ? PromptBuilder.parseTAScenario(session.report) : nil
        let alt = scenarioKind ? PromptBuilder.parseTAAltScenario(session.report) : nil

        let trimmedThinking = session.thinking.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = HistoryEntry(
            id: UUID(),
            kind: kind,
            pairID: session.pairID,
            pairName: session.pairName,
            timeframeLabel: session.timeframeLabel,
            engineLabel: session.engineLabel,
            date: session.startedAt ?? Date(),
            report: session.report,
            thinking: trimmedThinking.isEmpty ? nil : session.thinking,
            srLevels: (sr?.isEmpty ?? true) ? nil : sr,
            fvgZones: (fvg?.isEmpty ?? true) ? nil : fvg,
            supplyDemandZones: (sdZones?.isEmpty ?? true) ? nil : sdZones,
            scoredScenarios: (scored?.isEmpty ?? true) ? nil : scored,
            taScenario: ta,
            taAltScenario: alt
        )
        history.insert(entry, at: 0)
        if history.count > Self.historyCap {
            history = Array(history.prefix(Self.historyCap))
        }
        saveHistory()
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: Self.historyKey),
              let entries = try? JSONDecoder().decode([HistoryEntry].self, from: data)
        else { return }
        history = entries
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: Self.historyKey)
        }
    }
}
