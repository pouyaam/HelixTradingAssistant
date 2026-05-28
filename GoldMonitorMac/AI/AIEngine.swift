import Foundation

/// What every AI backend (Claude HTTP, Codex CLI shell-out, future LM Studio
/// localhost) implements. Returns a stream of text chunks so the UI can
/// render the report as it arrives — a 1500-token analysis takes 15-30s,
/// nobody wants to stare at a spinner that long.
///
/// Each implementation is responsible for:
///   • Building/finding its own auth (Keychain for Claude, $PATH for Codex)
///   • Honoring `Task.cancel()` to abort in-flight requests
///   • Surfacing setup problems via the throwing initializer or first chunk
protocol AIEngine {
    /// Display label for the engine selector.
    var label: String { get }

    /// True if the engine is ready to run (e.g., Claude has an API key in
    /// Keychain; Codex CLI is on $PATH). UI uses this to disable the
    /// "Analyze" button with a helpful tooltip when false.
    var isAvailable: Bool { get }

    /// Engines may be intentionally unavailable ("Coming soon") rather
    /// than misconfigured. Lets the UI distinguish "install codex" from
    /// "we haven't shipped this yet" — defaults to `.notReady` so old
    /// engines don't need to opt in.
    var availability: EngineAvailability { get }

    /// Stream the analysis. Throws once if setup is wrong; otherwise
    /// emits tagged events as they arrive — `.text` is the final
    /// assistant message being typed out, `.thinking` is the model's
    /// internal reasoning trace (extended-thinking models only). The
    /// UI can route the two to different buffers so the user sees
    /// the same "Thinking → Output" structure the Claude Code VSCode
    /// extension shows.
    ///
    /// Engines that don't surface thinking just emit `.text` events;
    /// callers iterating with a `if case .text(let s) = event` filter
    /// degrade cleanly.
    ///
    /// `system` and `user` are passed separately so engines that have
    /// distinct fields for them (e.g. Anthropic's Messages API) can
    /// wire them properly; engines without a separate system slot
    /// inline both into the prompt (Codex CLI does this).
    func run(system: String, user: String) -> AsyncThrowingStream<AIStreamEvent, Error>
}

/// Tagged delta emitted by an `AIEngine.run` stream. Lets the UI
/// distinguish the model's visible answer from its reasoning trace,
/// matching the Claude Code VSCode extension's split rendering. We
/// keep the enum deliberately small (two cases) so wiring new engines
/// stays cheap — anything that doesn't expose thinking just emits
/// `.text`.
enum AIStreamEvent: Equatable {
    /// A chunk of the final assistant text (Markdown). Concatenating
    /// every `.text` payload in order rebuilds the full response.
    case text(String)
    /// A chunk of the model's internal thinking. Extended-thinking
    /// models (Claude Opus / Sonnet 4.x with thinking on) interleave
    /// these with text deltas; non-thinking models never emit them.
    case thinking(String)
}

/// Why an engine can or can't run right now. The three cases give the
/// AnalysisPanel enough context to render the right hint — a Keychain
/// nudge, a `npm install` nudge, or a "wait for the next release" badge.
enum EngineAvailability: Equatable {
    case ready
    case notReady(hint: String)
    case comingSoon

    var canRun: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// Default implementation that derives `availability` from `isAvailable`
/// so engines built before the enum existed still slot in.
extension AIEngine {
    var availability: EngineAvailability {
        isAvailable ? .ready : .notReady(hint: "Check the engine's setup.")
    }
}

/// Engines available in this build. New ones get added here; the UI's
/// EngineSelector enumerates them.
enum AIEngineKind: String, CaseIterable, Identifiable {
    case claude
    case codex

    var id: String { rawValue }
    var label: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        }
    }
}

/// Factory — central place to map a kind onto a concrete engine. Returning
/// the protocol type means the dashboard doesn't need to import each engine
/// implementation directly.
enum AIEngineFactory {
    static func make(_ kind: AIEngineKind) -> AIEngine {
        switch kind {
        case .claude: return ClaudeEngine()
        case .codex:  return CodexEngine()
        }
    }
}
