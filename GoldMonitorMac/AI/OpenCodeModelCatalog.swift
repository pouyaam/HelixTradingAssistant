import Foundation

/// Catalog of OpenCode Zen models the AI analysis pipeline can run
/// with. Models are grouped into Free (no cost, limited availability)
/// and Paid tiers. The model id is passed verbatim to `opencode run -m
/// <id>`.
///
/// The user's pick is persisted under the `ai.opencode.model`
/// UserDefaults key, which `OpenCodeEngine` reads when it spawns the
/// CLI.
enum OpenCodeModelCatalog {
    struct Model: Identifiable, Hashable {
        let id: String
        let label: String
        let hint: String
        /// Whether this model is free to use (no billing required).
        let isFree: Bool
    }

    /// Default applied when the persisted key is unset. Picks a free
    /// model so the engine works out of the box without billing.
    static let defaultModelID = "mimo-v2.5-free"

    // ── Free models ────────────────────────────────────────────────

    static let freeModels: [Model] = [
        .init(id: "mimo-v2.5-free",
              label: "MiMo V2.5 Free",
              hint: "Free — Xiaomi's reasoning model. Good all-rounder for technical analysis.",
              isFree: true),
        .init(id: "deepseek-v4-flash-free",
              label: "DeepSeek V4 Flash Free",
              hint: "Free — fast DeepSeek model. Good for quick lookups.",
              isFree: true),
        .init(id: "north-mini-code-free",
              label: "North Mini Code Free",
              hint: "Free — Cohere's code model. Limited data retention.",
              isFree: true),
        .init(id: "nemotron-3-ultra-free",
              label: "Nemotron 3 Ultra Free",
              hint: "Free — NVIDIA's reasoning model. Trial use only.",
              isFree: true),
        .init(id: "big-pickle",
              label: "Big Pickle Free",
              hint: "Free — stealth model. Limited availability.",
              isFree: true),
    ]

    // ── Paid models (curated selection) ────────────────────────────

    static let paidModels: [Model] = [
        // Claude family
        .init(id: "claude-opus-4-8",
              label: "Claude Opus 4.8",
              hint: "$5/$25 per 1M tokens — Most capable Anthropic model.",
              isFree: false),
        .init(id: "claude-sonnet-4-6",
              label: "Claude Sonnet 4.6",
              hint: "$3/$15 per 1M tokens — Fast, strong all-rounder.",
              isFree: false),
        .init(id: "claude-haiku-4-5",
              label: "Claude Haiku 4.5",
              hint: "$1/$5 per 1M tokens — Fastest, lowest cost Anthropic.",
              isFree: false),

        // GPT family
        .init(id: "gpt-5.5",
              label: "GPT-5.5",
              hint: "$5/$30 per 1M tokens — OpenAI frontier model.",
              isFree: false),
        .init(id: "gpt-5.4",
              label: "GPT-5.4",
              hint: "$2.50/$15 per 1M tokens — Strong all-rounder.",
              isFree: false),
        .init(id: "gpt-5.4-mini",
              label: "GPT-5.4 Mini",
              hint: "$0.75/$4.50 per 1M tokens — Fast and cheap.",
              isFree: false),
        .init(id: "gpt-5.3-codex",
              label: "GPT-5.3 Codex",
              hint: "$1.75/$14 per 1M tokens — Codex-tuned variant.",
              isFree: false),

        // Gemini
        .init(id: "gemini-3.5-flash",
              label: "Gemini 3.5 Flash",
              hint: "$1.50/$9 per 1M tokens — Google's fast model.",
              isFree: false),
        .init(id: "gemini-3.1-pro",
              label: "Gemini 3.1 Pro",
              hint: "$2/$12 per 1M tokens — Google's capable model.",
              isFree: false),

        // DeepSeek
        .init(id: "deepseek-v4-pro",
              label: "DeepSeek V4 Pro",
              hint: "$1.74/$3.48 per 1M tokens — DeepSeek's flagship.",
              isFree: false),
        .init(id: "deepseek-v4-flash",
              label: "DeepSeek V4 Flash",
              hint: "$0.14/$0.28 per 1M tokens — Ultra cheap.",
              isFree: false),

        // Qwen
        .init(id: "qwen3.7-max",
              label: "Qwen 3.7 Max",
              hint: "$2.50/$7.50 per 1M tokens — Alibaba's top model.",
              isFree: false),

        // Kimi
        .init(id: "kimi-k2.7-code",
              label: "Kimi K2.7 Code",
              hint: "$0.95/$4.00 per 1M tokens — Moonshot's code model.",
              isFree: false),
    ]

    /// All models (free + paid), free first.
    static let allModels: [Model] = freeModels + paidModels

    static func label(forModelID id: String) -> String {
        allModels.first { $0.id == id }?.label ?? id
    }
}
