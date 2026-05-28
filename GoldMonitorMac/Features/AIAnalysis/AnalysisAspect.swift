import Foundation

/// One selectable analysis aspect in the Claude-app-style checklist.
/// The user ticks one or many; `PromptBuilder.systemCombined` /
/// `userPromptCombined` assemble a single prompt from the chosen set,
/// and the model produces a sectioned report plus the union of the
/// structured blocks each aspect asks for.
///
/// These intentionally mirror the legacy single-`AnalysisKind` outputs
/// (LEVELS_JSON, FVG_JSON, SUPPLY_DEMAND_JSON, SCENARIO_JSON) so the
/// existing parsers + right-column cards light up unchanged.
enum AnalysisAspect: String, CaseIterable, Identifiable, Codable {
    /// Trend / momentum / indicator read — narrative, no structured block.
    case technical
    /// Support & Resistance → LEVELS_JSON.
    case levels
    /// Fair Value Gaps / iFVG → FVG_JSON.
    case fvg
    /// Supply & Demand zones → SUPPLY_DEMAND_JSON.
    case supplyDemand
    /// Cross-timeframe confluence read (15m / 1h / 4h alignment).
    case multiTimeframe
    /// Trade plans → SCENARIO_JSON (+ ALT_SCENARIO_JSON). Shows the
    /// Position/Swing/Scalp profile segment in the picker card.
    case scenarios

    var id: String { rawValue }

    var label: String {
        switch self {
        case .technical:     return "Technical read"
        case .levels:        return "Support & Resistance"
        case .fvg:           return "FVG / iFVG"
        case .supplyDemand:  return "Supply & Demand"
        case .multiTimeframe: return "Multi-timeframe confluence"
        case .scenarios:     return "Trade scenarios"
        }
    }

    var icon: String {
        switch self {
        case .technical:      return "waveform.path.ecg"
        case .levels:         return "ruler"
        case .fvg:            return "rectangle.split.2x1"
        case .supplyDemand:   return "square.stack.3d.up"
        case .multiTimeframe: return "rectangle.3.group"
        case .scenarios:      return "target"
        }
    }

    /// Whether this aspect benefits from the 15m/1h/4h bundle rather
    /// than a single timeframe. When any ticked aspect needs it, the
    /// combined run bundles the timeframe trio.
    var needsMultiTF: Bool {
        switch self {
        case .multiTimeframe, .supplyDemand, .scenarios: return true
        case .technical, .levels, .fvg:                  return false
        }
    }

    /// The per-aspect instruction injected into the combined system
    /// prompt — what to produce and which structured block to emit.
    /// Kept tight so a multi-aspect prompt doesn't balloon.
    var instruction: String {
        switch self {
        case .technical:
            return "**Technical read** — 2-3 sentences on trend direction, momentum, and what the indicators (RSI / MACD / EMA50-200 / volume) say. No JSON block."
        case .levels:
            return """
            **Support & Resistance** — the most relevant levels, then emit:
            ### LEVELS_JSON
            ```json
            {"support":[<numbers>],"resistance":[<numbers>]}
            ```
            """
        case .fvg:
            return """
            **Fair Value Gaps** — list unmitigated FVGs / iFVGs in the visible bars, then emit:
            ### FVG_JSON
            ```json
            {"fvgs":[{"barStart":<int>,"barEnd":<int>,"low":<number>,"high":<number>,"direction":"bullish|bearish","mitigated":<bool>}]}
            ```
            `barStart`/`barEnd` are NEGATIVE offsets from the latest bar (-1 = latest).
            """
        case .supplyDemand:
            return """
            **Supply & Demand** — fresh + tested zones across the timeframes, then emit:
            ### SUPPLY_DEMAND_JSON
            ```json
            {"zones":[{"barStart":<int>,"barEnd":<int>,"low":<number>,"high":<number>,"type":"demand|supply","fresh":<bool>,"strength":"weak|medium|strong"}]}
            ```
            """
        case .multiTimeframe:
            return "**Multi-timeframe confluence** — a short table or bullet list of 15m / 1h / 4h bias + key level, then one sentence on whether they agree or conflict."
        case .scenarios:
            return """
            **Trade scenarios** — a main plan and (if there's a genuine second setup) an alt, then emit:
            ### SCENARIO_JSON
            ```json
            {"bias":"long|short|neutral","entry":<number>,"tp":<number>,"sl":<number>}
            ```
            ### ALT_SCENARIO_JSON
            ```json
            {"bias":"long|short|neutral","entry":<number>,"tp":<number>,"sl":<number>}
            ```
            For long: tp > entry > sl. For short: sl > entry > tp. Omit the ALT block when there's no real second setup.
            """
        }
    }

    /// Stable display order for the checklist (top → bottom).
    static let displayOrder: [AnalysisAspect] = [
        .technical, .levels, .fvg, .supplyDemand, .multiTimeframe, .scenarios,
    ]
}

extension Set where Element == AnalysisAspect {
    /// Serialise to a comma-joined rawValue string for @AppStorage —
    /// mirrors the `enabledIndicators` pattern in DashboardView.
    var csv: String { map(\.rawValue).sorted().joined(separator: ",") }

    /// Rebuild from the @AppStorage CSV. Unknown tokens drop out.
    init(csv: String) {
        self = Set(csv.split(separator: ",").compactMap { AnalysisAspect(rawValue: String($0)) })
    }
}
