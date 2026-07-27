import SwiftUI

/// Right column of the analysis page. Composes a read-only chart
/// preview (auto-fit to the full series, no pan/zoom) on top of the
/// kind-specific structured cards: plan cards for `.full`, S/R card
/// for `.supportResistance`, FVG card for `.fvg`. Multi-timeframe
/// runs collapse the column entirely (the markdown table is the
/// artifact — a preview chart spanning 3 TFs would mislead).
struct AnalysisPlansColumn: View {
    let kind: AnalysisKind
    let pair: TradingPair
    let candles: [Candle]
    let livePrice: Double?

    let srLevels: PromptBuilder.SRLevels
    let fvgZones: [PromptBuilder.FVGZone]
    let supplyDemandZones: [PromptBuilder.SupplyDemandZone]
    /// Confluence Trade Scanner's scored multi-scenario queue (sorted high → low).
    /// Empty for non-Confluence Scanner kinds.
    let scoredScenarios: [PromptBuilder.ScoredScenario]
    let taScenario: PromptBuilder.TAScenario?
    let taAltScenario: PromptBuilder.TAScenario?

    /// Per-card apply callbacks. nil-safe so the page can omit ones
    /// that don't apply for the current kind.
    var onAddSRLevels: (() -> Void)?
    var onAddFVGZones: (() -> Void)?
    var onAddSupplyDemand: (() -> Void)?
    var onApplyMainPlan: (() -> Void)?
    var onApplyAltPlan: (() -> Void)?
    var onActivateMainPlan: (() -> Void)?
    /// Called when the user activates one of the scored
    /// scenarios from the ScoredScenariosCard. Receives the
    /// chosen ScoredScenario so the dashboard can wire the
    /// underlying TAScenario into the trade pipeline.
    var onActivateScored: ((PromptBuilder.ScoredScenario) -> Void)?
    /// "Add to journal" callbacks. Capture the plan / scenario as a
    /// journal draft (pre-filled with the position). nil-safe.
    var onJournalMainPlan: (() -> Void)?
    var onJournalAltPlan: (() -> Void)?
    var onJournalScored: ((PromptBuilder.ScoredScenario) -> Void)?

    /// Local X-domain owned by the preview. Stays at `nil` (auto-fit)
    /// for the lifetime of this view — the preview is intentionally
    /// non-interactive so the user does pan/zoom on the dashboard
    /// chart instead.
    @State private var previewDomain: ClosedRange<Double>? = nil
    /// Same story for the vertical scale — the preview always auto-fits
    /// Y; manual price-axis scaling is a dashboard-only affordance.
    @State private var previewYDomain: ClosedRange<Double>? = nil
    /// Cached oscillator config — loaded once on appear, not per body.
    @State private var cachedOscConfig: OscillatorConfig = .load()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                if kind != .multiTimeframe {
                    previewChart
                }
                cardStack
            }
            .padding(Theme.Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Color.canvas)
    }

    // ── Chart preview ──────────────────────────────────────────────
    private var previewChart: some View {
        // Mute the indicators / oscillators — the preview's job is to
        // show *where* the AI overlays sit, not to compete with the
        // dashboard's full instrumentation.
        ChartView(
            candles: candles,
            chartType: .candle,
            accent: pair.color,
            xDomain: $previewDomain,
            yDomain: $previewYDomain,
            indicators: [],
            indicatorConfig: cachedOscConfig,
            srLevels: srLevels,
            fvgZones: fvgZones,
            supplyDemandZones: supplyDemandZones,
            taScenario: taScenario,
            taAltScenario: taAltScenario,
            livePrice: livePrice,
            hoverCrosshairX: .constant(nil)
        )
        .frame(height: 320)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(Theme.Color.border, lineWidth: 1)
        )
    }

    // ── Cards ──────────────────────────────────────────────────────
    @ViewBuilder
    private var cardStack: some View {
        switch kind {
        case .full, .confluenceScanner, .custom, .combined, .topDownSniper:
            // Confluence Trade Scanner's scored scenario queue gets pole position
            // — it's the headline output now (S&D + market
            // structure + breakouts, all ranked). Falls back to
            // the legacy single-PlanCard view when the array is
            // empty (older runs / non-Confluence Scanner kinds).
            // Confluence Trade Scanner's authoritative output is the scored
            // multi-scenario queue. When it's present, the
            // ranked card covers everything the legacy PlanCards
            // would show (and the chart preview above still
            // draws the top-1 + top-2 as overlay lines from the
            // mirrored taScenario/taAltScenario).
            let hasScored = (kind == .confluenceScanner && !scoredScenarios.isEmpty)
            if hasScored {
                ScoredScenariosCard(
                    scenarios: scoredScenarios,
                    livePrice: livePrice,
                    onActivate: { s in onActivateScored?(s) },
                    onAddToJournal: onJournalScored.map { cb in { s in cb(s) } }
                )
            } else {
                if let main = taScenario {
                    PlanCard(
                        scenario: main,
                        variant: .main,
                        livePrice: livePrice,
                        onAddToChart: onApplyMainPlan,
                        onActivate: onActivateMainPlan,
                        onAddToJournal: onJournalMainPlan
                    )
                }
                if let alt = taAltScenario {
                    PlanCard(
                        scenario: alt,
                        variant: .alt,
                        livePrice: livePrice,
                        onAddToChart: onApplyAltPlan,
                        onActivate: nil,
                        onAddToJournal: onJournalAltPlan
                    )
                }
            }
            if !srLevels.isEmpty {
                LevelsCard(levels: srLevels, onAdd: onAddSRLevels)
            }
            if !supplyDemandZones.isEmpty {
                SupplyDemandCard(zones: supplyDemandZones, onAdd: onAddSupplyDemand)
            }
            let fvgEligible = (kind == .custom || kind == .combined || kind == .topDownSniper)
            if fvgEligible, !fvgZones.isEmpty {
                FVGCard(zones: fvgZones, onAdd: onAddFVGZones)
            }
            if !hasScored && taScenario == nil && taAltScenario == nil && srLevels.isEmpty
                && supplyDemandZones.isEmpty
                && (!fvgEligible || fvgZones.isEmpty)
            {
                placeholderCard(
                    icon: "scope",
                    title: "Plans appear here",
                    subtitle: placeholderSubtitle(for: kind)
                )
            }

        case .supportResistance:
            if !srLevels.isEmpty {
                LevelsCard(levels: srLevels, onAdd: onAddSRLevels)
            } else {
                placeholderCard(
                    icon: "chart.line.uptrend.xyaxis",
                    title: "Levels appear here",
                    subtitle: "Once the model emits the LEVELS_JSON block, support and resistance prices render in a compact list."
                )
            }

        case .fvg:
            if !fvgZones.isEmpty {
                FVGCard(zones: fvgZones, onAdd: onAddFVGZones)
            } else {
                placeholderCard(
                    icon: "rectangle.dashed",
                    title: "FVG zones appear here",
                    subtitle: "Once the model emits the FVG_JSON block, each zone shows its bar range, price band, and mitigated/unmitigated status."
                )
            }

        case .multiTimeframe:
            // The MTF markdown table is the artifact; nothing to render
            // on the right. Column collapses upstream (caller skips
            // rendering this view altogether for .multiTimeframe).
            EmptyView()
        }
    }

    private func placeholderSubtitle(for kind: AnalysisKind) -> String {
        switch kind {
        case .confluenceScanner:
            return "Once the model finds an impulsive breakout that left an FVG, the main and alternative plans render here with prices, R:R, and a validity badge."
        case .custom:
            return "Ask the model for `### SCENARIO_JSON`, `### LEVELS_JSON`, or `### FVG_JSON` in your prompt and the structured cards appear here when those blocks parse cleanly."
        default:
            return "Once the model emits the SCENARIO_JSON block, the main and alternative plans render with prices, R:R, and a validity badge."
        }
    }

    // ── Placeholder ────────────────────────────────────────────────
    private func placeholderCard(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(Theme.Color.textMuted)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Color.textSecondary)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Color.surface)
        )
    }
}

// ── LevelsCard ──────────────────────────────────────────────────────

/// Compact list of support / resistance prices parsed from a Claude
/// run. Single "Add to chart" CTA at the bottom so the user can push
/// them onto the dashboard chart in one click.
struct LevelsCard: View {
    let levels: PromptBuilder.SRLevels
    var onAdd: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack {
                Text("KEY LEVELS")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Color.textMuted)
                Spacer()
                Text("\(levels.support.count + levels.resistance.count) total")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textMuted)
            }
            if !levels.resistance.isEmpty {
                levelRow(title: "Resistance", values: levels.resistance.sorted(by: >), color: Theme.Color.danger)
            }
            if !levels.support.isEmpty {
                levelRow(title: "Support", values: levels.support.sorted(by: >), color: Theme.Color.success)
            }
            if let onAdd = onAdd {
                Divider().background(Theme.Color.border)
                HStack {
                    Button(action: onAdd) {
                        Label("Add to chart", systemImage: "chart.line.uptrend.xyaxis")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6).fill(Theme.Color.success)
                            )
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
        }
        .padding(Theme.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Color.surface)
        )
    }

    private func levelRow(title: String, values: [Double], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(color)
            FlowList(values: values, color: color)
        }
    }
}

/// Wraps level prices into a flexible row that wraps onto multiple
/// lines if the card is narrow. No fancy layout primitives — a simple
/// HStack-of-rows approach using a fixed bucket size, since 3–10
/// values per side is the typical count.
private struct FlowList: View {
    let values: [Double]
    let color: Color

    var body: some View {
        let buckets = stride(from: 0, to: values.count, by: 3).map {
            Array(values[$0..<min($0 + 3, values.count)])
        }
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(buckets.enumerated()), id: \.offset) { (_, row) in
                HStack(spacing: 6) {
                    ForEach(Array(row.enumerated()), id: \.offset) { (_, v) in
                        Text(fmt(v))
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(color)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(color.opacity(0.12))
                            )
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func fmt(_ v: Double) -> String {
        if v >= 10_000 { return String(format: "%.0f", v) }
        if v >= 100    { return String(format: "%.2f", v) }
        if v >= 1      { return String(format: "%.4f", v) }
        return String(format: "%.5f", v)
    }
}

// ── FVGCard ──────────────────────────────────────────────────────────

/// Compact list of Fair Value Gaps parsed from a Claude FVG run. Each
/// zone gets its bar range, price band, direction tag and a mitigated
/// badge when applicable. Single "Add to chart" CTA pushes all zones
/// onto the dashboard chart at once.
struct FVGCard: View {
    let zones: [PromptBuilder.FVGZone]
    var onAdd: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack {
                Text("FAIR VALUE GAPS")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Color.textMuted)
                Spacer()
                Text("\(zones.count) zone\(zones.count == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textMuted)
            }
            VStack(spacing: 6) {
                ForEach(zones) { zone in
                    zoneRow(zone)
                }
            }
            if let onAdd = onAdd {
                Divider().background(Theme.Color.border)
                HStack {
                    Button(action: onAdd) {
                        Label("Add to chart", systemImage: "rectangle.dashed")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6).fill(Theme.Color.success)
                            )
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
        }
        .padding(Theme.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Color.surface)
        )
    }

    private func zoneRow(_ z: PromptBuilder.FVGZone) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Circle()
                .fill(z.isBullish ? Theme.Color.success : Theme.Color.danger)
                .frame(width: 6, height: 6)
            Text(z.isBullish ? "Bullish" : "Bearish")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(z.isBullish ? Theme.Color.success : Theme.Color.danger)
                .frame(width: 60, alignment: .leading)
            Text("bars \(z.barOffsetStart)…\(z.barOffsetEnd)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Theme.Color.textMuted)
            Spacer()
            Text("\(fmt(z.low)) → \(fmt(z.high))")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.Color.textPrimary)
            if z.isMitigated {
                Text("MITIGATED")
                    .font(.system(size: 8, weight: .heavy))
                    .tracking(0.4)
                    .foregroundStyle(Theme.Color.textMuted)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(Theme.Color.textMuted.opacity(0.15))
                    )
            }
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.Color.surfaceHi)
        )
    }

    private func fmt(_ v: Double) -> String {
        if v >= 10_000 { return String(format: "%.0f", v) }
        if v >= 100    { return String(format: "%.2f", v) }
        if v >= 1      { return String(format: "%.4f", v) }
        return String(format: "%.5f", v)
    }
}

// ── SupplyDemandCard ───────────────────────────────────────────────

/// Compact list of Supply & Demand zones parsed from a Confluence Trade Scanner (or
/// custom) run. Each zone shows direction, price range, freshness,
/// strength, and how many bars ago it printed. Single "Add to chart"
/// CTA pushes all zones to the dashboard's overlay slot at once
/// (same pattern as FVGCard / LevelsCard).
struct SupplyDemandCard: View {
    let zones: [PromptBuilder.SupplyDemandZone]
    var onAdd: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack {
                Text("SUPPLY & DEMAND")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Color.textMuted)
                Spacer()
                Text("\(zones.count) zone\(zones.count == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textMuted)
            }
            VStack(spacing: 6) {
                ForEach(zones) { zone in
                    zoneRow(zone)
                }
            }
            if let onAdd = onAdd {
                Divider().background(Theme.Color.border)
                HStack {
                    Button(action: onAdd) {
                        Label("Add to chart", systemImage: "rectangle.fill.on.rectangle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6).fill(Theme.Color.success)
                            )
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
        }
        .padding(Theme.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Color.surface)
        )
    }

    private func zoneRow(_ z: PromptBuilder.SupplyDemandZone) -> some View {
        let tint: Color = z.isDemand ? Theme.Color.success : Theme.Color.danger
        return HStack(spacing: Theme.Spacing.sm) {
            // Side chip — D for Demand, S for Supply.
            Text(z.isDemand ? "D" : "S")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(tint))

            Text(z.isDemand ? "Demand" : "Supply")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 60, alignment: .leading)

            Text("bars \(z.barOffsetStart)…\(z.barOffsetEnd)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Theme.Color.textMuted)
            Spacer()

            Text("\(fmt(z.low)) → \(fmt(z.high))")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.Color.textPrimary)

            // Strength badge — weak/medium/strong, tinted by zone color.
            Text(z.strength.rawValue.uppercased())
                .font(.system(size: 8, weight: .heavy))
                .tracking(0.4)
                .foregroundStyle(tint)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    Capsule().fill(tint.opacity(0.18))
                )

            // Freshness — small dot in color for fresh, "TESTED"
            // text chip for already-revisited zones.
            if z.isFresh {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
            } else {
                Text("TESTED")
                    .font(.system(size: 8, weight: .heavy))
                    .tracking(0.4)
                    .foregroundStyle(Theme.Color.textMuted)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(Theme.Color.textMuted.opacity(0.15))
                    )
            }
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.Color.surfaceHi)
        )
    }

    private func fmt(_ v: Double) -> String {
        if v >= 10_000 { return String(format: "%.0f", v) }
        if v >= 100    { return String(format: "%.2f", v) }
        if v >= 1      { return String(format: "%.4f", v) }
        return String(format: "%.5f", v)
    }
}

// ── ScoredScenariosCard ────────────────────────────────────────────

/// Ranked list of Confluence Trade Scanner scored scenarios. The auto-trader
/// queues these by score and tries them top-down on
/// invalidation; this card exposes the same queue to the user
/// for manual activation + at-a-glance comparison.
struct ScoredScenariosCard: View {
    let scenarios: [PromptBuilder.ScoredScenario]
    let livePrice: Double?
    var onActivate: ((PromptBuilder.ScoredScenario) -> Void)?
    /// "Add to journal" for a scored scenario — captures it (with its
    /// position) as a journal draft.
    var onAddToJournal: ((PromptBuilder.ScoredScenario) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack {
                Text("SCORED SCENARIOS")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Color.textMuted)
                Spacer()
                Text("\(scenarios.count) ranked")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textMuted)
            }

            ForEach(Array(scenarios.enumerated()), id: \.element.id) { idx, scored in
                scenarioRow(scored, rank: idx + 1, isTop: idx == 0)
            }

            Text("Auto-trader stages #1 first. On invalidation it falls to #2, then #3, …. When the whole queue is exhausted it re-runs the analysis.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.Color.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Color.surface)
        )
    }

    private func scenarioRow(_ s: PromptBuilder.ScoredScenario, rank: Int, isTop: Bool) -> some View {
        let bias = s.scenario.bias
        let biasTint: Color = {
            switch bias {
            case .long:    return Theme.Color.success
            case .short:   return Theme.Color.danger
            case .neutral: return Theme.Color.info
            }
        }()
        let valid = livePrice.map { s.scenario.isValid(at: $0) } ?? true
        return VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            // Header row: rank · type · bias · score · validity.
            HStack(spacing: Theme.Spacing.sm) {
                Text("#\(rank)")
                    .font(.system(size: 12, weight: .heavy).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isTop ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.Color.textMuted))
                    )
                Text(typeLabel(s.type))
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(0.4)
                    .foregroundStyle(Theme.Color.textSecondary)
                Text(bias.rawValue.uppercased())
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(0.5)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(biasTint))
                Spacer()
                scoreBar(s.score)
                if !valid {
                    Text("INVALID")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.Color.danger))
                }
            }

            // Prices row.
            HStack(spacing: Theme.Spacing.md) {
                priceCell(label: "Entry",       value: s.scenario.entry)
                priceCell(label: "TP",          value: s.scenario.takeProfit, tint: Theme.Color.success)
                priceCell(label: "SL",          value: s.scenario.stopLoss,   tint: Theme.Color.danger)
                if let rr = riskReward(s.scenario) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("R:R").font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(Theme.Color.textMuted)
                        Text(String(format: "1 : %.2f", rr))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(rr >= 1.5 ? Theme.Color.success : Theme.Color.textPrimary)
                    }
                }
                Spacer()
                if let onJournal = onAddToJournal {
                    Button(action: { onJournal(s) }) {
                        Image(systemName: "book.closed")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.Color.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 5).fill(Theme.Color.surfaceMax)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Add to journal")
                }
                if let onAct = onActivate {
                    Button(action: { onAct(s) }) {
                        Label("Activate", systemImage: "play.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(isTop ? Theme.Color.success : Theme.Color.surfaceMax)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            if !s.rationale.isEmpty {
                Text(s.rationale)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !s.invalidatedWhen.isEmpty {
                Text("Invalidated when: \(s.invalidatedWhen)")
                    .font(.system(size: 10).italic())
                    .foregroundStyle(Theme.Color.textMuted)
            }
        }
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isTop ? Theme.Color.surfaceMax : Theme.Color.surfaceHi)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isTop ? biasTint.opacity(0.4) : Theme.Color.border,
                    lineWidth: isTop ? 1.5 : 1
                )
        )
        .opacity(valid ? 1.0 : 0.65)
    }

    private func scoreBar(_ score: Int) -> some View {
        let tint: Color = score >= 8 ? Theme.Color.success
                         : score >= 5 ? Theme.Color.warn
                         : Theme.Color.danger
        return HStack(spacing: 2) {
            Text("\(score)")
                .font(.system(size: 12, weight: .heavy).monospacedDigit())
                .foregroundStyle(tint)
            Text("/10")
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.Color.textMuted)
        }
    }

    private func priceCell(label: String, value: Double?, tint: Color = Theme.Color.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(Theme.Color.textMuted)
            Text(value.map { fmt($0) } ?? "—")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint)
        }
    }

    private func riskReward(_ s: PromptBuilder.TAScenario) -> Double? {
        guard let entry = s.entry else { return nil }
        let reward = abs(s.takeProfit - entry)
        let risk = abs(entry - s.stopLoss)
        guard risk > 0 else { return nil }
        return reward / risk
    }

    private func typeLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "supply_demand":         return "Supply / Demand"
        case "market_structure":      return "Market structure"
        case "breakout":              return "Breakout"
        case "range_bound":           return "Range fade"
        case "liquidity_grab":        return "Liquidity grab"
        case "trend_continuation":    return "Trend continuation"
        default:                       return raw.capitalized
        }
    }

    private func fmt(_ v: Double) -> String {
        if v >= 10_000 { return String(format: "%.0f", v) }
        if v >= 100    { return String(format: "%.2f", v) }
        if v >= 1      { return String(format: "%.4f", v) }
        return String(format: "%.5f", v)
    }
}
