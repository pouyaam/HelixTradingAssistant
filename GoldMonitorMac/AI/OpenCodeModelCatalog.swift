import Foundation

/// Catalog of all OpenCode Zen models the AI analysis pipeline can run
/// with. Models are grouped into Free (no cost, limited availability)
/// and Paid tiers. The model id is passed verbatim to `opencode run -m
/// <id>`.
///
/// The user's pick is persisted under the `ai.opencode.model`
/// UserDefaults key, which `OpenCodeEngine` reads when it spawns the
/// CLI.
///
/// Source: https://opencode.ai/docs/zen/
enum OpenCodeModelCatalog {
    struct Model: Identifiable, Hashable {
        let id: String
        let label: String
        let hint: String
        /// Whether this model is free to use (no billing required).
        let isFree: Bool
        /// Provider grouping for the picker UI (e.g. "OpenAI", "Anthropic").
        let provider: String
    }

    /// Default applied when the persisted key is unset. Picks a free
    /// model so the engine works out of the box without billing.
    static let defaultModelID = "mimo-v2.5-free"

    // ── Free models ────────────────────────────────────────────────

    static let freeModels: [Model] = [
        .init(id: "mimo-v2.5-free",
              label: "MiMo V2.5 Free",
              hint: "Free — Xiaomi's reasoning model. Good all-rounder for technical analysis.",
              isFree: true, provider: "OpenCode"),
        .init(id: "deepseek-v4-flash-free",
              label: "DeepSeek V4 Flash Free",
              hint: "Free — fast DeepSeek model. Good for quick lookups.",
              isFree: true, provider: "OpenCode"),
        .init(id: "north-mini-code-free",
              label: "North Mini Code Free",
              hint: "Free — Cohere's code model. Limited data retention.",
              isFree: true, provider: "OpenCode"),
        .init(id: "nemotron-3-ultra-free",
              label: "Nemotron 3 Ultra Free",
              hint: "Free — NVIDIA's reasoning model. Trial use only.",
              isFree: true, provider: "OpenCode"),
        .init(id: "big-pickle",
              label: "Big Pickle Free",
              hint: "Free — stealth model. Limited availability.",
              isFree: true, provider: "OpenCode"),
    ]

    // ── Paid models ────────────────────────────────────────────────

    static let paidModels: [Model] = [
        // OpenAI
        .init(id: "gpt-5.5",
              label: "GPT 5.5",
              hint: "$5/$30 per 1M tokens — OpenAI frontier model.",
              isFree: false, provider: "OpenAI"),
        .init(id: "gpt-5.5-pro",
              label: "GPT 5.5 Pro",
              hint: "$30/$180 per 1M tokens — Maximum capability.",
              isFree: false, provider: "OpenAI"),
        .init(id: "gpt-5.4",
              label: "GPT 5.4",
              hint: "$2.50/$15 per 1M tokens — Strong all-rounder.",
              isFree: false, provider: "OpenAI"),
        .init(id: "gpt-5.4-pro",
              label: "GPT 5.4 Pro",
              hint: "$30/$180 per 1M tokens — Pro reasoning.",
              isFree: false, provider: "OpenAI"),
        .init(id: "gpt-5.4-mini",
              label: "GPT 5.4 Mini",
              hint: "$0.75/$4.50 per 1M tokens — Fast and cheap.",
              isFree: false, provider: "OpenAI"),
        .init(id: "gpt-5.4-nano",
              label: "GPT 5.4 Nano",
              hint: "$0.20/$1.25 per 1M tokens — Ultra cheap.",
              isFree: false, provider: "OpenAI"),
        .init(id: "gpt-5.3-codex",
              label: "GPT 5.3 Codex",
              hint: "$1.75/$14 per 1M tokens — Codex-tuned variant.",
              isFree: false, provider: "OpenAI"),
        .init(id: "gpt-5.3-codex-spark",
              label: "GPT 5.3 Codex Spark",
              hint: "$1.75/$14 per 1M tokens — Lightweight codex.",
              isFree: false, provider: "OpenAI"),
        .init(id: "gpt-5.2",
              label: "GPT 5.2",
              hint: "$1.75/$14 per 1M tokens — Previous generation.",
              isFree: false, provider: "OpenAI"),
        .init(id: "gpt-5.2-codex",
              label: "GPT 5.2 Codex",
              hint: "$1.75/$14 per 1M tokens — Codex variant. Deprecated Jul 23.",
              isFree: false, provider: "OpenAI"),
        .init(id: "gpt-5.1",
              label: "GPT 5.1",
              hint: "$1.07/$8.50 per 1M tokens — Efficient generation.",
              isFree: false, provider: "OpenAI"),
        .init(id: "gpt-5.1-codex",
              label: "GPT 5.1 Codex",
              hint: "$1.07/$8.50 per 1M tokens — Code-tuned. Deprecated Jul 23.",
              isFree: false, provider: "OpenAI"),
        .init(id: "gpt-5.1-codex-max",
              label: "GPT 5.1 Codex Max",
              hint: "$1.25/$10 per 1M tokens — Max codex. Deprecated Jul 23.",
              isFree: false, provider: "OpenAI"),
        .init(id: "gpt-5.1-codex-mini",
              label: "GPT 5.1 Codex Mini",
              hint: "$0.25/$2 per 1M tokens — Cheap codex. Deprecated Jul 23.",
              isFree: false, provider: "OpenAI"),
        .init(id: "gpt-5",
              label: "GPT 5",
              hint: "$1.07/$8.50 per 1M tokens — Base GPT 5.",
              isFree: false, provider: "OpenAI"),
        .init(id: "gpt-5-codex",
              label: "GPT 5 Codex",
              hint: "$1.07/$8.50 per 1M tokens — Codex variant. Deprecated Jul 23.",
              isFree: false, provider: "OpenAI"),
        .init(id: "gpt-5-nano",
              label: "GPT 5 Nano",
              hint: "$0.05/$0.40 per 1M tokens — Cheapest OpenAI.",
              isFree: false, provider: "OpenAI"),

        // Anthropic
        .init(id: "claude-fable-5",
              label: "Claude Fable 5",
              hint: "$10/$50 per 1M tokens — Anthropic's premium creative model.",
              isFree: false, provider: "Anthropic"),
        .init(id: "claude-opus-4-8",
              label: "Claude Opus 4.8",
              hint: "$5/$25 per 1M tokens — Most capable Anthropic model.",
              isFree: false, provider: "Anthropic"),
        .init(id: "claude-opus-4-7",
              label: "Claude Opus 4.7",
              hint: "$5/$25 per 1M tokens — Previous gen Opus.",
              isFree: false, provider: "Anthropic"),
        .init(id: "claude-opus-4-6",
              label: "Claude Opus 4.6",
              hint: "$5/$25 per 1M tokens — Opus 4.6.",
              isFree: false, provider: "Anthropic"),
        .init(id: "claude-opus-4-5",
              label: "Claude Opus 4.5",
              hint: "$5/$25 per 1M tokens — Opus 4.5. Deprecated Aug 5.",
              isFree: false, provider: "Anthropic"),
        .init(id: "claude-sonnet-5",
              label: "Claude Sonnet 5",
              hint: "$2/$10 per 1M tokens — Latest Sonnet generation.",
              isFree: false, provider: "Anthropic"),
        .init(id: "claude-sonnet-4-6",
              label: "Claude Sonnet 4.6",
              hint: "$3/$15 per 1M tokens — Fast, strong all-rounder.",
              isFree: false, provider: "Anthropic"),
        .init(id: "claude-sonnet-4-5",
              label: "Claude Sonnet 4.5",
              hint: "$3/$15 per 1M tokens — Sonnet 4.5.",
              isFree: false, provider: "Anthropic"),
        .init(id: "claude-haiku-4-5",
              label: "Claude Haiku 4.5",
              hint: "$1/$5 per 1M tokens — Fastest, lowest cost Anthropic.",
              isFree: false, provider: "Anthropic"),

        // Google
        .init(id: "gemini-3.5-flash",
              label: "Gemini 3.5 Flash",
              hint: "$1.50/$9 per 1M tokens — Google's fast model.",
              isFree: false, provider: "Google"),
        .init(id: "gemini-3.1-pro",
              label: "Gemini 3.1 Pro",
              hint: "$2/$12 per 1M tokens — Google's capable model.",
              isFree: false, provider: "Google"),
        .init(id: "gemini-3-flash",
              label: "Gemini 3 Flash",
              hint: "$0.50/$3 per 1M tokens — Cheap Google model.",
              isFree: false, provider: "Google"),

        // MiMo
        .init(id: "mimo-v2.5-pro",
              label: "MiMo V2.5 Pro",
              hint: "Xiaomi's premium reasoning model.",
              isFree: false, provider: "MiMo"),
        .init(id: "mimo-v2.5",
              label: "MiMo V2.5",
              hint: "Xiaomi's reasoning model. Strong all-rounder.",
              isFree: false, provider: "MiMo"),

        // Qwen
        .init(id: "qwen3.7-max",
              label: "Qwen 3.7 Max",
              hint: "$2.50/$7.50 per 1M tokens — Alibaba's top model.",
              isFree: false, provider: "Qwen"),
        .init(id: "qwen3.7-plus",
              label: "Qwen 3.7 Plus",
              hint: "$0.40/$1.60 per 1M tokens — Good value.",
              isFree: false, provider: "Qwen"),
        .init(id: "qwen3.6-plus",
              label: "Qwen 3.6 Plus",
              hint: "$0.50/$3 per 1M tokens — Previous gen Plus.",
              isFree: false, provider: "Qwen"),
        .init(id: "qwen3.5-plus",
              label: "Qwen 3.5 Plus",
              hint: "$0.20/$1.20 per 1M tokens — Budget Qwen.",
              isFree: false, provider: "Qwen"),

        // DeepSeek
        .init(id: "deepseek-v4-pro",
              label: "DeepSeek V4 Pro",
              hint: "$1.74/$3.48 per 1M tokens — DeepSeek's flagship.",
              isFree: false, provider: "DeepSeek"),
        .init(id: "deepseek-v4-flash",
              label: "DeepSeek V4 Flash",
              hint: "$0.14/$0.28 per 1M tokens — Ultra cheap.",
              isFree: false, provider: "DeepSeek"),

        // Kimi
        .init(id: "kimi-k2.7-code",
              label: "Kimi K2.7 Code",
              hint: "$0.95/$4 per 1M tokens — Moonshot's code model.",
              isFree: false, provider: "Kimi"),
        .init(id: "kimi-k2.6",
              label: "Kimi K2.6",
              hint: "$0.95/$4 per 1M tokens — Previous gen Kimi.",
              isFree: false, provider: "Kimi"),

        // MiniMax
        .init(id: "minimax-m3",
              label: "MiniMax M3",
              hint: "$0.30/$1.20 per 1M tokens — Latest MiniMax.",
              isFree: false, provider: "MiniMax"),
        .init(id: "minimax-m2.7",
              label: "MiniMax M2.7",
              hint: "$0.30/$1.20 per 1M tokens — MiniMax gen 2.7.",
              isFree: false, provider: "MiniMax"),

        // GLM
        .init(id: "glm-5.2",
              label: "GLM 5.2",
              hint: "$1.40/$4.40 per 1M tokens — Zhipu's latest.",
              isFree: false, provider: "GLM"),
        .init(id: "glm-5.1",
              label: "GLM 5.1",
              hint: "$1.40/$4.40 per 1M tokens — Zhipu gen 5.1.",
              isFree: false, provider: "GLM"),

        // Grok
        .init(id: "grok-build-0.1",
              label: "Grok Build 0.1",
              hint: "$1/$2 per 1M tokens — xAI's coding model.",
              isFree: false, provider: "Grok"),
    ]

    /// Provider display order for the grouped picker. OpenCode
    /// (free models) comes first.
    static let providerOrder = ["OpenCode", "MiMo", "OpenAI", "Anthropic", "Google", "Qwen", "DeepSeek", "Kimi", "MiniMax", "GLM", "Grok"]

    /// Paid models grouped by provider, in display order.
    static var paidModelsByProvider: [(provider: String, models: [Model])] {
        let grouped = Dictionary(grouping: paidModels, by: \.provider)
        return providerOrder.compactMap { name in
            guard let models = grouped[name], !models.isEmpty else { return nil }
            return (provider: name, models: models)
        }
    }

    /// All models (free + paid) grouped by provider, in display
    /// order. Used by the popover and picker UIs.
    static var allModelsByProvider: [(provider: String, models: [Model])] {
        let grouped = Dictionary(grouping: allModels, by: \.provider)
        return providerOrder.compactMap { name in
            guard let models = grouped[name], !models.isEmpty else { return nil }
            return (provider: name, models: models)
        }
    }

    /// All models (free + paid), free first.
    static let allModels: [Model] = freeModels + paidModels

    static func label(forModelID id: String) -> String {
        allModels.first { $0.id == id }?.label ?? id
    }
}
