import Foundation

/// Catalog of Claude models + reasoning-effort levels the AI analysis
/// pipeline can run with. Lives in the AI layer so the analysis-page
/// engine dropdown and `ClaudeEngine` share one source of truth instead
/// of duplicating the list in the Settings view.
///
/// The user's pick is persisted under the `ai.claude.model` /
/// `ai.claude.effort` UserDefaults keys, which `ClaudeEngine` reads when
/// it spawns the CLI. The model id is passed verbatim to `claude
/// --model <id>`; effort is folded into the system prompt as a soft hint.
enum ClaudeModelCatalog {
    struct Model: Identifiable, Hashable {
        let id: String
        let label: String
        /// One-line description shown as a menu tooltip / hint.
        let hint: String
    }

    struct Effort: Identifiable, Hashable {
        let id: String
        let label: String
        let tooltip: String
    }

    /// Defaults applied when the persisted keys are unset. Kept here so
    /// `ClaudeEngine` and the UI agree on the same fallback.
    static let defaultModelID = "claude-sonnet-4-6"
    static let defaultEffortID = "medium"

    static let models: [Model] = [
        .init(id: "claude-opus-4-8",           label: "Opus 4.8 (latest)",
              hint: "Latest and most capable. Best for full TA, Confluence Trade Scanner, multi-timeframe. Higher cost per run."),
        .init(id: "claude-opus-4-8[1m]",       label: "Opus 4.8 · 1M context",
              hint: "Opus 4.8 with 1M-token context window — useful for very long histories or multi-pair runs."),
        .init(id: "claude-opus-4-7",           label: "Opus 4.7",
              hint: "Previous Opus generation. Strong all-rounder for full TA and Confluence Trade Scanner."),
        .init(id: "claude-opus-4-7[1m]",       label: "Opus 4.7 · 1M context",
              hint: "Opus 4.7 with 1M-token context window — useful for very long histories or multi-pair runs."),
        .init(id: "claude-sonnet-4-6",         label: "Sonnet 4.6",
              hint: "Faster, lower cost. Good default for FVG / S&R / chat follow-ups."),
        .init(id: "claude-haiku-4-5-20251001", label: "Haiku 4.5",
              hint: "Fastest, lowest cost. Best for quick lookups or budget-sensitive runs."),
    ]

    static let efforts: [Effort] = [
        .init(id: "low",     label: "Low",     tooltip: "Quick, less reasoning."),
        .init(id: "medium",  label: "Medium",  tooltip: "Balanced default."),
        .init(id: "high",    label: "High",    tooltip: "Deepest reasoning."),
    ]

    /// Human-readable label for a stored model id (falls back to the raw
    /// id for anything not in the list — e.g. a value set in code).
    static func label(forModelID id: String) -> String {
        models.first { $0.id == id }?.label ?? id
    }
}

/// Codex (OpenAI CLI) counterpart to `ClaudeModelCatalog`. Reuses the
/// same `Model` / `Effort` value types. Persisted under
/// `ai.codex.model` / `ai.codex.effort` and read by `CodexEngine`.
/// Codex passes the id straight to `codex exec -m`, and its line
/// supports an extra `xhigh` reasoning level beyond Claude's three.
enum CodexModelCatalog {
    static let defaultModelID = "gpt-5.5"
    static let defaultEffortID = "high"

    static let models: [ClaudeModelCatalog.Model] = [
        .init(id: "gpt-5.5",       label: "GPT-5.5 (frontier)",
              hint: "Most capable Codex model. Best for full TA and Confluence Trade Scanner."),
        .init(id: "gpt-5.4",       label: "GPT-5.4",
              hint: "Strong all-rounder, lower cost than 5.5."),
        .init(id: "gpt-5.4-mini",  label: "GPT-5.4 Mini",
              hint: "Fast and cheap. Good for quick lookups / chat follow-ups."),
        .init(id: "gpt-5.3-codex",  label: "GPT-5.3 Codex",
              hint: "Codex-tuned variant."),
        .init(id: "gpt-5.2",       label: "GPT-5.2",
              hint: "Previous generation."),
    ]

    static let efforts: [ClaudeModelCatalog.Effort] = [
        .init(id: "low",    label: "Low",    tooltip: "Fast, lighter reasoning."),
        .init(id: "medium", label: "Medium", tooltip: "Balanced default."),
        .init(id: "high",   label: "High",   tooltip: "Deeper reasoning."),
        .init(id: "xhigh",  label: "X-High", tooltip: "Maximum reasoning depth (GPT-5.x)."),
    ]

    static func label(forModelID id: String) -> String {
        models.first { $0.id == id }?.label ?? id
    }
}
