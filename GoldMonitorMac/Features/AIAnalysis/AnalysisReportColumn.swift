import SwiftUI
import MarkdownUI

/// Left column of the analysis page. Renders the streamed markdown
/// report with the JSON structured blocks stripped out — the parsed
/// payloads already drive the right column's chart preview + plan
/// cards, so the raw `### LEVELS_JSON` / ```json ... ``` fences are
/// implementation detail the user shouldn't see.
///
/// Above the report, a collapsible "Thinking" disclosure surfaces the
/// model's reasoning trace (extended-thinking models — Claude Opus /
/// Sonnet 4.x with thinking on) as it streams, matching the Claude
/// Code VSCode extension's two-pane UX. Default expanded while a run
/// is live so the user sees something happen immediately; collapses
/// to a one-line summary once the answer arrives.
struct AnalysisReportColumn: View {
    /// Observed directly so streaming chunk appends to `session.report`
    /// / `session.thinking` re-render *only this column*, not the
    /// entire page. Previously this was a `let`; the page passed a
    /// struct snapshot, which forced a parent-driven re-diff for
    /// every chunk. With Session as a class (Performance Fix 7),
    /// observation is per-view. (Performance Fix 7.)
    @ObservedObject var session: AnalysisStore.Session
    /// Idle-state hint shown when there's no report yet. Composed by
    /// the page since it knows the selected kind + engine names.
    let idleHint: String
    /// Engine-not-ready warning shown under the idle CTA, or nil when
    /// the engine is reachable. Same string the panel used to show.
    let unavailableHint: String?
    let engineReady: Bool
    var onAnalyze: () -> Void
    /// Optional follow-up callback. When non-nil and the session is
    /// in `.done` state, the report column shows a chat input below
    /// the report so the user can ask the model questions about
    /// what it just produced. Nil ⇒ chat disabled.
    var onAskFollowUp: ((String) -> Void)? = nil
    /// Optional "submit my first chat message" callback. When
    /// non-nil, the input bar is also shown while the session is
    /// `.idle` (instead of only after a run completes). The chat
    /// .custom kind uses this so the very first message in the
    /// thread doubles as the initial run trigger — no separate
    /// "Analyze" button. Nil ⇒ idle-state input is hidden.
    var onSubmitInitial: ((String) -> Void)? = nil
    /// Optional quick-fill chips rendered above the input. Click
    /// populates the input draft (doesn't auto-send) so the user
    /// can edit before submitting. Empty ⇒ no chip row.
    var inputChips: [InputChip] = []
    /// Placeholder text for the input field. Lets the page tailor
    /// the prompt per kind ("Ask Claude about this analysis…" vs
    /// "Start a chat about \(pair)…").
    var inputPlaceholder: String = "Ask a follow-up about this analysis…"
    /// Optional view rendered in the idle state above the input bar
    /// — the combined analysis page passes its checklist card here
    /// so the user picks aspects right in the chat flow.
    var idleAccessory: AnyView? = nil
    /// Model-emitted "narrow the scope" question, parsed from a
    /// CLARIFY_JSON block. When set, the report column renders the
    /// options as tappable buttons wired to `onClarifyPick`.
    var clarify: PromptBuilder.ClarifyRequest? = nil
    var onClarifyPick: ((String) -> Void)? = nil

    struct InputChip: Hashable, Identifiable {
        let label: String
        let body: String
        var id: String { label }
    }

    /// Disclosure state for the Thinking section. Defaults to nil so
    /// the view can pick a sensible auto-expansion (open while
    /// streaming, closed once done) — `userToggled` flips to true on
    /// the first manual click so we stop overriding the user's
    /// preference mid-run.
    /// Memoised version of the structured-block-stripped report.
    /// Recomputing `stripStructuredBlocks` on every body render
    /// (which SwiftUI calls liberally — including in response to
    /// scroll events on long reports) was the main source of
    /// scroll lag. We refresh this cache only when
    /// `session.report` actually changes.
    @State private var cleanReportCache: String = ""
    /// Stage 1 (Confluence Scanner — S&D) chunks of
    /// `cleanReportCache`, split at H3 boundaries. Rendered
    /// through a `LazyVStack` so MarkdownUI only builds view
    /// trees for sections near the viewport.
    @State private var stage1Chunks: [ReportChunk] = []
    /// Stage 2 (Expand) chunks. Empty until the user clicks
    /// Continue and the engine appends past the expand marker.
    @State private var stage2Chunks: [ReportChunk] = []
    /// True once the expand marker is detected in the report —
    /// drives the second inline thinking disclosure.
    @State private var hasStage2: Bool = false

    private struct ReportChunk: Identifiable, Equatable {
        let id: Int
        let text: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch session.phase {
            case .idle:
                // Combined mode passes a checklist card as the idle
                // accessory — that's the entry point. Chat-only
                // kinds fall back to the sparkles placeholder; the
                // canned kinds keep the big Analyze button.
                if let accessory = idleAccessory {
                    ScrollView { accessory }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if onSubmitInitial != nil {
                    chatModeIdlePlaceholder
                } else {
                    idleView
                }
            case .running, .done:
                reportScroll
            case .error:
                errorView
            }
            // Chat input — visible whenever the page has wired a
            // submit handler for the current phase: `.idle` runs go
            // through onSubmitInitial (chat-mode .custom), `.done`
            // runs go through onAskFollowUp. Both can be set
            // simultaneously (chat-mode supports both).
            if shouldShowInputBar {
                ChatInputBar(
                    placeholder: inputPlaceholder,
                    chips: inputChips,
                    // Disable typing while a turn is in flight so
                    // the user doesn't queue a half-formed thought
                    // mid-stream.
                    isBusy: session.phase == .running
                        || session.conversation.contains { $0.isStreaming },
                    onSubmit: { text in routeSubmit(text) }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Color.canvas)
    }

    private var chatModeIdlePlaceholder: some View {
        VStack(spacing: Theme.Spacing.md) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 28))
                .foregroundStyle(Theme.Color.textMuted)
            Text(.init(idleHint))
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.Color.textSecondary)
                .padding(.horizontal, Theme.Spacing.xxl)
            if let hint = unavailableHint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.warn)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Spacing.xl)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Input bar visibility: shown when there's a submit target
    /// for the current phase. Chat-mode .custom wires both
    /// onSubmitInitial AND onAskFollowUp, so the bar is visible
    /// across idle / running / done; the other kinds only wire
    /// onAskFollowUp so the bar appears once the run completes.
    private var shouldShowInputBar: Bool {
        switch session.phase {
        case .idle:    return onSubmitInitial != nil
        case .running: return onSubmitInitial != nil || onAskFollowUp != nil
        case .done:    return onAskFollowUp != nil || onSubmitInitial != nil
        case .error:   return false
        }
    }

    // ── Idle ───────────────────────────────────────────────────────
    private var idleView: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundStyle(Theme.Color.accentStart)
            Text(.init(idleHint))
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.Color.textSecondary)
                .padding(.horizontal, Theme.Spacing.xxl)
            PrimaryButton("Analyze", systemImage: "play.fill", action: onAnalyze)
                .disabled(!engineReady)
                .opacity(engineReady ? 1 : 0.5)
            if let hint = unavailableHint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.warn)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Spacing.xl)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // ── Clarify card ───────────────────────────────────────────────
    private func clarifyCard(
        _ clarify: PromptBuilder.ClarifyRequest,
        onPick: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Color.accentStart)
                Text(clarify.question)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            FlowOptions(options: clarify.options, onPick: onPick)
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Color.accentStart.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(Theme.Color.accentStart.opacity(0.3), lineWidth: 1)
        )
    }

    /// Simple wrapping row of option buttons for the clarify card.
    private struct FlowOptions: View {
        let options: [PromptBuilder.ClarifyRequest.Option]
        let onPick: (String) -> Void
        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(options) { opt in
                    Button { onPick(opt.id) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: opt.id == "all" ? "square.stack.3d.up.fill" : "arrow.right.circle")
                                .font(.system(size: 11, weight: .semibold))
                            Text(opt.label)
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                        }
                        .foregroundStyle(Theme.Color.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surface)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // ── Running / done ─────────────────────────────────────────────

    private var reportScroll: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    // Stage 1 — first session: thinking on top,
                    // then the markdown chunks below it.
                    if showThinking {
                        ThinkingDisclosure(
                            stageLabel: hasStage2 ? "Thought (Stage 1)" : "Thought",
                            streamingLabel: hasStage2 ? "Thinking (Stage 1)…" : "Thinking…",
                            text: stage1Thinking,
                            isRunning: session.phase == .running && !hasStage2,
                            hasFollowingContent: !stage1Chunks.isEmpty,
                            initiallyExpanded: session.phase == .running && !hasStage2
                        )
                    }
                    if !stage1Chunks.isEmpty {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(stage1Chunks.enumerated()), id: \.element.id) { idx, chunk in
                                chunkView(
                                    chunk,
                                    isStreamingTail: idx == stage1Chunks.count - 1
                                        && !hasStage2
                                        && session.phase == .running
                                )
                            }
                        }
                    } else if cleanReportCache.isEmpty {
                        // Pre-content placeholder while Claude warms up.
                        if session.phase == .running && !showThinking {
                            workingPlaceholder
                        } else if !showThinking {
                            Text("…")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.Color.textSecondary)
                        }
                    }

                    // Stage 2 — opt-in Expand session: its own
                    // thinking disclosure right above its report
                    // chunks, mirroring the stage 1 layout.
                    if hasStage2 {
                        Divider()
                            .background(Theme.Color.border)
                            .padding(.vertical, Theme.Spacing.sm)
                        ThinkingDisclosure(
                            stageLabel: "Thought (Stage 2 · Expand)",
                            streamingLabel: "Thinking (Stage 2 · Expand)…",
                            text: stage2Thinking,
                            isRunning: session.phase == .running,
                            hasFollowingContent: !stage2Chunks.isEmpty,
                            initiallyExpanded: session.phase == .running
                        )
                        if !stage2Chunks.isEmpty {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(stage2Chunks.enumerated()), id: \.element.id) { idx, chunk in
                                    chunkView(
                                        chunk,
                                        isStreamingTail: idx == stage2Chunks.count - 1
                                            && session.phase == .running
                                    )
                                }
                            }
                        }
                    }

                    // Clarify options — the model decided the
                    // request was too broad and asked the user to
                    // narrow it. Render the choices as buttons.
                    if let clarify = clarify, let pick = onClarifyPick {
                        clarifyCard(clarify, onPick: pick)
                    }

                    // Streaming caret pinned to the bottom whenever
                    // the run is still live, regardless of which
                    // buffer was the last to receive a delta.
                    if session.phase == .running {
                        StreamingCaret()
                    }

                    // Conversation tail — every follow-up Q&A the
                    // user has asked since the initial report.
                    if !session.conversation.isEmpty {
                        Divider()
                            .background(Theme.Color.border)
                            .padding(.vertical, Theme.Spacing.md)
                        ForEach(session.conversation) { turn in
                            conversationTurn(turn)
                        }
                    }
                }
                .id("report-end")
                .padding(Theme.Spacing.xl)
            }
            // Scroll on either the report OR the thinking growing so
            // the streaming caret stays in view even while the model
            // is still in its thinking phase.
            //
            // No `withAnimation` here: the chunk batcher flushes at
            // 10 Hz and the previous 200 ms animation was *twice*
            // the flush interval, so animations stacked / cancelled
            // into jitter. Unanimated `scrollTo` keeps up cleanly
            // and is essentially free. (Performance Fix 2.)
            .onChange(of: session.report) { newValue in
                refreshReportCache(from: newValue)
                scroll.scrollTo("report-end", anchor: .bottom)
            }
            .onChange(of: session.thinking) { _ in
                scroll.scrollTo("report-end", anchor: .bottom)
            }
            .onAppear { refreshReportCache(from: session.report) }
        }
    }

    /// Render one report chunk. The trailing chunk of a still-running
    /// run is rendered as plain `Text` instead of `MarkdownUI.Markdown`
    /// — markdown re-parses the whole input each time `chunk.text`
    /// changes, which used to be the dominant cost during streaming
    /// (every 100 ms flush re-tokenised + re-laid out the entire
    /// active chunk). Once a new H3 lands and the chunk is no longer
    /// the tail, it promotes to Markdown on the next render. Visual
    /// tint slightly muted while still streaming so it reads as
    /// "in-flight" content. (Performance Fix 5.)
    @ViewBuilder
    private func chunkView(_ chunk: ReportChunk, isStreamingTail: Bool) -> some View {
        if isStreamingTail {
            Text(chunk.text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.Color.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Markdown(chunk.text)
                .markdownTheme(Theme.goldMarkdown)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Rebuild the cleaned report + chunk lists. Called only when
    /// `session.report` actually changes (or on first appear), not
    /// on every body render — which is what made scrolling laggy
    /// on long CTS reports. Also splits at the engine-injected
    /// expand marker so the column can render two inline thinking
    /// disclosures (one per stage).
    private func refreshReportCache(from report: String) {
        let cleaned = PromptBuilder.stripStructuredBlocks(report)
        guard cleaned != cleanReportCache else { return }
        cleanReportCache = cleaned

        let marker = AnalysisStore.expandMarker
        if let range = cleaned.range(of: marker) {
            let pre  = String(cleaned[..<range.lowerBound])
            let post = String(cleaned[range.upperBound...])
                // Strip the leading "\n\n---\n\n" separator that
                // immediately follows the marker so the stage 2
                // chunks start cleanly at the first heading.
                .trimmingCharacters(in: .whitespacesAndNewlines)
            stage1Chunks = Self.chunk(pre.trimmingCharacters(in: .whitespacesAndNewlines))
            stage2Chunks = Self.chunk(post)
            hasStage2 = true
        } else {
            stage1Chunks = Self.chunk(cleaned)
            stage2Chunks = []
            hasStage2 = false
        }
    }

    private var stage1Thinking: String {
        guard let offset = session.expandThinkingOffset, offset > 0 else {
            return session.thinking
        }
        let safe = min(offset, session.thinking.count)
        return String(session.thinking.prefix(safe))
    }

    private var stage2Thinking: String {
        guard let offset = session.expandThinkingOffset,
              session.thinking.count > offset
        else { return "" }
        return String(session.thinking.dropFirst(offset))
    }

    /// Split a long markdown report into self-contained chunks at
    /// H3 (`### `) boundaries. Each chunk renders as its own
    /// MarkdownUI subview inside a `LazyVStack` so SwiftUI can
    /// skip building view trees for sections outside the
    /// viewport. Reports without any H3 headers fall through as a
    /// single chunk (the lazy split is a no-op for short content).
    private static func chunk(_ markdown: String) -> [ReportChunk] {
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
        return chunks.enumerated().map { ReportChunk(id: $0.offset, text: $0.element) }
    }

    /// Whether to render the stage-1 thinking disclosure at all.
    /// We show it any time there's any thinking content OR while
    /// stage 1 is still in flight (so the "Thinking…" header
    /// appears immediately, before the first delta lands).
    private var showThinking: Bool {
        !stage1Thinking.isEmpty || (session.phase == .running && !hasStage2)
    }

    /// Inline thinking disclosure used for both Stage 1 and
    /// Stage 2. Owns its own expansion state so the user can
    /// collapse one without affecting the other.
    private struct ThinkingDisclosure: View {
        let stageLabel: String
        let streamingLabel: String
        let text: String
        let isRunning: Bool
        let hasFollowingContent: Bool
        let initiallyExpanded: Bool

        @State private var userToggled: Bool = false
        @State private var manualExpanded: Bool = false

        /// Pre-split paragraph windows for streaming rendering.
        /// A single growing `Text(text)` was the dominant cost during
        /// thinking phase — AppKit re-laid out the entire trace on
        /// every 100 ms chunk flush. Splitting on `\n\n` and rendering
        /// each paragraph as its own Text inside a LazyVStack lets
        /// SwiftUI's Equatable diff skip everything but the growing
        /// last paragraph. (Performance Fix 6.)
        @State private var paragraphs: [String] = []

        var body: some View {
            let expanded = currentlyExpanded
            VStack(alignment: .leading, spacing: 0) {
                header(expanded: expanded)
                if expanded {
                    body(expanded: true)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(Theme.Color.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .strokeBorder(Theme.Color.border, lineWidth: 1)
            )
            .onAppear { refreshParagraphs(text) }
            .onChange(of: text) { refreshParagraphs($0) }
        }

        /// Resplit on every text change. `components(separatedBy:)` is
        /// O(n) but n is small (<10 KB typical) and we're already on
        /// the main thread for a state update. The win is downstream:
        /// SwiftUI sees identical leading paragraphs and skips them.
        private func refreshParagraphs(_ t: String) {
            let next = t.components(separatedBy: "\n\n")
            if next != paragraphs { paragraphs = next }
        }

        /// Auto-open while streaming; auto-collapse once the
        /// stage has produced report content (so the answer is
        /// the visible focus). The first manual click pins the
        /// preference for the rest of the session.
        private var currentlyExpanded: Bool {
            if userToggled { return manualExpanded }
            return initiallyExpanded
        }

        private func header(expanded: Bool) -> some View {
            Button {
                manualExpanded = !expanded
                userToggled = true
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Color.textMuted)
                    Image(systemName: "brain")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Color.accentStart)
                    Text(labelText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Color.textSecondary)
                    Spacer()
                    if isRunning && !hasFollowingContent {
                        Circle()
                            .fill(Theme.Color.accentStart)
                            .frame(width: 6, height: 6)
                            .modifier(PulseModifier())
                    }
                    if !text.isEmpty {
                        Text("\(text.count) chars")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(Theme.Color.textMuted)
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        private var labelText: String {
            if isRunning && !hasFollowingContent { return streamingLabel }
            return stageLabel
        }

        @ViewBuilder
        private func body(expanded: Bool) -> some View {
            VStack(alignment: .leading, spacing: 0) {
                Divider().background(Theme.Color.border)
                if text.isEmpty {
                    Text("Waiting for the model to start reasoning…")
                        .font(.system(size: 11))
                        .italic()
                        .foregroundStyle(Theme.Color.textMuted)
                        .padding(Theme.Spacing.md)
                } else {
                    // Per-paragraph Text views in a LazyVStack: only
                    // the trailing paragraph relays out as new tokens
                    // arrive; earlier paragraphs short-circuit via
                    // SwiftUI's Equatable diff because their String
                    // identity is stable across flushes.
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, p in
                            Text(p)
                                .font(.system(size: 11).italic())
                                .foregroundStyle(Theme.Color.textSecondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(Theme.Spacing.md)
                }
            }
        }
    }

    // ── "Working…" placeholder (no thinking, no text yet) ──────────
    private var workingPlaceholder: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ProgressView()
                .scaleEffect(0.7)
            Text("Working…")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Color.textSecondary)
            Spacer()
        }
    }

    // ── Conversation tail ──────────────────────────────────────────

    private func conversationTurn(_ turn: AnalysisStore.Turn) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            // User question — small bubble aligned right.
            HStack {
                Spacer(minLength: 60)
                Text(turn.user)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Color.textPrimary)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.md)
                            .fill(Theme.Color.accentStart.opacity(0.18))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.md)
                            .strokeBorder(Theme.Color.accentStart.opacity(0.35), lineWidth: 1)
                    )
                    .frame(maxWidth: 520, alignment: .trailing)
                    .textSelection(.enabled)
            }
            // Assistant reply — Markdown-rendered, left-aligned.
            VStack(alignment: .leading, spacing: 0) {
                if let err = turn.error {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.Color.danger)
                            .font(.system(size: 11, weight: .semibold))
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Color.danger)
                    }
                } else if turn.assistant.isEmpty && turn.isStreaming {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.6)
                        Text("Thinking…")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Color.textMuted)
                    }
                } else {
                    Markdown(turn.assistant)
                        .markdownTheme(Theme.goldMarkdown)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if turn.isStreaming {
                        StreamingCaret()
                    }
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, Theme.Spacing.sm)
    }

    // ── Follow-up input ────────────────────────────────────────────

    /// Route the typed message to either the initial-run handler
    /// or the follow-up handler depending on session phase. Both
    /// callbacks are optional so this gracefully no-ops when
    /// nothing's wired.
    private func routeSubmit(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        switch session.phase {
        case .idle:
            onSubmitInitial?(q)
        case .done, .running:
            if let onFollow = onAskFollowUp {
                onFollow(q)
            } else {
                onSubmitInitial?(q)
            }
        case .error:
            onSubmitInitial?(q)
        }
    }

    // ── Error ──────────────────────────────────────────────────────
    private var errorView: some View {
        VStack(spacing: Theme.Spacing.md) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(Theme.Color.danger)
            Text(session.lastError ?? "Unknown error")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.Color.textPrimary)
                .padding(.horizontal, Theme.Spacing.xl)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Subtle pulsing block-caret that signals "still streaming" when
/// chunks arrive in bursts. Lifted verbatim from the old AnalysisPanel.
private struct StreamingCaret: View {
    @State private var alpha: Double = 0.3
    var body: some View {
        Text("▍")
            .font(.system(size: 13, weight: .bold).monospacedDigit())
            .foregroundStyle(Theme.Color.textPrimary.opacity(alpha))
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    alpha = 1.0
                }
            }
    }
}

/// Auto-pulsing opacity modifier — used by the thinking header's
/// "still working" dot. Lives as a ViewModifier so the pulse animation
/// is attached at .onAppear rather than racing with View identity
/// changes.
private struct PulseModifier: ViewModifier {
    @State private var pulsing = false
    func body(content: Content) -> some View {
        content
            .opacity(pulsing ? 1.0 : 0.35)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
    }
}
