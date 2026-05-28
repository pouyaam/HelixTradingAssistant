import Foundation

/// One browser-style tab in the AI analysis page. A symbol can have
/// several open at once — each owns an independent analysis session
/// (keyed by `id` in `AnalysisStore`), so the user can run multiple
/// scenarios / agents for the same pair concurrently and flip between
/// them like browser tabs.
///
/// The tab carries the per-tab UI state (which kind is selected, the
/// ticked combined aspects, the scenario profile, which AI engine runs
/// it) so switching tabs restores exactly what that tab was doing.
struct AnalysisTab: Identifiable, Equatable {
    let id: UUID
    /// Current analysis kind for this tab. Defaults to `.combined`
    /// (the checklist flow); flips to `.confluenceScanner` when the
    /// user launches the full scanner, or to a legacy kind when they
    /// open an old history entry.
    var kind: AnalysisKind
    /// Ticked combined aspects, comma-joined rawValues.
    var aspectsCSV: String
    /// Profile for the Trade-scenarios aspect + the Confluence
    /// Scanner launch.
    var profile: StrategyProfile
    /// Which AI engine this tab runs against (Claude / Codex). Per-tab
    /// so the user can run, say, a Claude technical read and a Codex
    /// confluence scan side by side — each tab's chip shows its engine.
    var engine: AIEngineKind
    /// User-given name for the tab. `nil` ⇒ fall back to a name
    /// derived from the analysis kind (`displayName`). Set by
    /// double-clicking the tab chip and typing.
    var customTitle: String?

    /// Name shown on the tab chip. A user-typed title wins; otherwise
    /// we derive a short, meaningful label from the analysis kind so a
    /// fresh tab reads "Analysis" / "Confluence" / "Sniper" instead of
    /// a meaningless "Tab N".
    var displayName: String {
        if let t = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            return t
        }
        return kind.tabTitle
    }

    init(
        id: UUID = UUID(),
        kind: AnalysisKind = .combined,
        aspectsCSV: String = "technical,levels,scenarios",
        profile: StrategyProfile = .swing,
        engine: AIEngineKind = .claude,
        customTitle: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.aspectsCSV = aspectsCSV
        self.profile = profile
        self.engine = engine
        self.customTitle = customTitle
    }
}

extension AnalysisKind {
    /// Short label for the browser-style analysis tab chip. Kept terse
    /// (one word where possible) so several chips fit across the bar.
    var tabTitle: String {
        switch self {
        case .full:              return "Technical"
        case .supportResistance: return "S&R"
        case .fvg:               return "FVG"
        case .multiTimeframe:    return "Multi-TF"
        case .confluenceScanner: return "Confluence"
        case .custom:            return "Custom"
        case .combined:          return "Analysis"
        case .topDownSniper:     return "Sniper"
        }
    }
}
