import SwiftUI

struct AnalysisPageiPad: View {
    let pair: TradingPair
    let timeframe: Timeframe
    let candles: [Candle]
    let livePrice: Double?
    var loadCandles: ((Timeframe) async -> [Candle])?
    var onApplySRLevels: ((PromptBuilder.SRLevels) -> Void)?
    var onApplyFVGZones: (([PromptBuilder.FVGZone]) -> Void)?
    var onApplySupplyDemand: (([PromptBuilder.SupplyDemandZone]) -> Void)?
    var onApplyTAScenario: ((PromptBuilder.TAScenario) -> Void)?
    var onApplyTAAltScenario: ((PromptBuilder.TAScenario) -> Void)?
    var onActivateTradeFromScenario: ((PromptBuilder.TAScenario, UUID?) -> Void)?
    /// Dismisses the analysis overlay. The iPad dashboard shows this page via
    /// its own local state, so dismissal must route back through here rather
    /// than the macOS-only `AppState.showAnalysisFullPage` flag.
    var onClose: (() -> Void)?

    @EnvironmentObject private var store: AnalysisStore

    @State private var selectedKind: AnalysisKind = .combined
    @State private var isRunning: Bool = false
    @State private var showHistory: Bool = false

    private let engineKind: AIEngineKind = .opencode

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerBar

            Divider().background(Theme.Color.border)

            // Analysis kind picker
            kindPicker

            Divider().background(Theme.Color.border)

            // Report area with chart preview
            let session = store.session(kind: selectedKind, pairID: pair.id)

            if session.phase == .idle && session.report.isEmpty {
                readyState
            } else {
                GeometryReader { geo in
                    if geo.size.width > 600 {
                        // Regular width: two-column layout
                        HStack(spacing: 0) {
                            reportColumn(session: session)
                                .frame(width: geo.size.width * 0.55)
                            Divider().background(Theme.Color.border)
                            plansColumn(session: session)
                                .frame(width: geo.size.width * 0.45)
                        }
                    } else {
                        // Compact width: stacked
                        VStack(spacing: 0) {
                            reportColumn(session: session)
                            Divider().background(Theme.Color.border)
                            plansColumn(session: session)
                        }
                    }
                }
            }

            Divider().background(Theme.Color.border)

            // Phase 2: Chat input bar (follow-up questions)
            if session.phase == .done && !session.report.isEmpty {
                ChatInputBar(
                    placeholder: "Ask a follow-up...",
                    chips: [],
                    isBusy: false
                ) { question in
                    store.askFollowUp(
                        kind: selectedKind,
                        pairID: pair.id,
                        engineKind: engineKind,
                        question: question
                    )
                }
            }

            // Bottom action dock
            actionDock(session: session)
        }
        .background(Theme.Color.canvas)
        .sheet(isPresented: $showHistory) {
            historySheet
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: Theme.Spacing.md) {
            Button {
                onClose?()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.Color.textSecondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("AI Analysis")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text("\(pair.name) · \(timeframe.label)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Color.textMuted)
            }

            Spacer()

            let modelID = UserDefaults.standard.string(forKey: "ai.opencode.model") ?? OpenCodeModelCatalog.defaultModelID
            Text(OpenCodeModelCatalog.label(forModelID: modelID))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.Color.textMuted)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Theme.Color.surface))

            Button {
                showHistory = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
    }

    // MARK: - Kind picker

    private var kindPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(AnalysisKind.allCases, id: \.self) { kind in
                    let isSelected = selectedKind == kind
                    Button {
                        selectedKind = kind
                    } label: {
                        Text(kind.tabTitle)
                            .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                            .foregroundStyle(isSelected ? .white : Theme.Color.textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                isSelected
                                    ? AnyShapeStyle(Theme.accentGradient)
                                    : AnyShapeStyle(Color.clear)
                            )
                            .overlay(
                                Capsule().strokeBorder(
                                    isSelected ? Color.clear : Theme.Color.border,
                                    lineWidth: 1
                                )
                            )
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.md)
        }
    }

    // MARK: - Ready state

    private var readyState: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(Theme.Color.accentStart)
            Text("Ready to analyze")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.Color.textSecondary)
            Text("Tap Analyze to run \(selectedKind.noun) on \(pair.name)")
                .font(.system(size: 13))
                .foregroundStyle(Theme.Color.textMuted)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Report column

    private func reportColumn(session: AnalysisStore.Session) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                if session.phase == .running {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text("Analyzing...")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.Color.textMuted)
                    }
                    .padding(.horizontal, Theme.Spacing.xl)
                }

                // Thinking trace
                if !session.thinking.isEmpty {
                    DisclosureGroup("Thinking") {
                        Text(session.thinking)
                            .font(.system(size: 11).monospaced())
                            .foregroundStyle(Theme.Color.textMuted)
                    }
                    .padding(.horizontal, Theme.Spacing.xl)
                }

                let chunks = session.renderChunks()
                if !chunks.clean.isEmpty {
                    ForEach(Array(chunks.stage1.enumerated()), id: \.offset) { _, chunk in
                        Text(LocalizedStringKey(chunk))
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.Color.textPrimary)
                            .padding(.horizontal, Theme.Spacing.xl)
                    }
                } else if !session.report.isEmpty {
                    Text(LocalizedStringKey(session.report))
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.Color.textPrimary)
                        .padding(.horizontal, Theme.Spacing.xl)
                }

                if let error = session.lastError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Color.danger)
                        .padding(.horizontal, Theme.Spacing.xl)
                }

                // Follow-up conversation
                ForEach(session.conversation) { turn in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(turn.user)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.Color.textSecondary)
                            .padding(.horizontal, Theme.Spacing.xl)
                        Text(LocalizedStringKey(turn.assistant))
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.Color.textPrimary)
                            .padding(.horizontal, Theme.Spacing.xl)
                    }
                    Divider().background(Theme.Color.border)
                }
            }
            .padding(.vertical, Theme.Spacing.lg)
        }
    }

    // MARK: - Plans column (Phase 2: PlanCards)

    private func plansColumn(session: AnalysisStore.Session) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                // PlanCards
                let scenario = PromptBuilder.parseTAScenario(session.report)
                let altScenario = PromptBuilder.parseTAAltScenario(session.report)

                if let s = scenario {
                    PlanCard(
                        scenario: s,
                        variant: .main,
                        livePrice: livePrice,
                        onAddToChart: {
                            onApplyTAScenario?(s)
                            onClose?()
                        },
                        onActivate: {
                            onActivateTradeFromScenario?(s, nil)
                        }
                    )
                    .padding(.horizontal, Theme.Spacing.lg)
                }

                if let s = altScenario {
                    PlanCard(
                        scenario: s,
                        variant: .alt,
                        livePrice: livePrice,
                        onAddToChart: {
                            onApplyTAAltScenario?(s)
                            onClose?()
                        }
                    )
                    .padding(.horizontal, Theme.Spacing.lg)
                }

                // S/R levels card
                let sr = PromptBuilder.parseSRLevels(session.report)
                if !sr.isEmpty {
                    srLevelsCard(sr)
                        .padding(.horizontal, Theme.Spacing.lg)
                }

                // FVG zones card
                let fvgs = PromptBuilder.parseFVGZones(session.report)
                if !fvgs.isEmpty {
                    fvgCard(fvgs)
                        .padding(.horizontal, Theme.Spacing.lg)
                }

                // Supply & Demand zones
                let sd = PromptBuilder.parseSupplyDemandZones(session.report)
                if !sd.isEmpty {
                    supplyDemandCard(sd)
                        .padding(.horizontal, Theme.Spacing.lg)
                }

                Spacer(minLength: 20)
            }
            .padding(.vertical, Theme.Spacing.lg)
        }
    }

    // MARK: - Overlay cards

    private func srLevelsCard(_ sr: PromptBuilder.SRLevels) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("S/R LEVELS")
                .font(.system(size: 10, weight: .heavy))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)
            HStack(spacing: Theme.Spacing.md) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Support").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.Color.success)
                    ForEach(sr.support, id: \.self) { level in
                        Text(formatPrice(level))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.Color.textPrimary)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Resistance").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.Color.danger)
                    ForEach(sr.resistance, id: \.self) { level in
                        Text(formatPrice(level))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.Color.textPrimary)
                    }
                }
                Spacer()
            }
            Button {
                onApplySRLevels?(sr)
                onClose?()
            } label: {
                Label("Add to chart", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Color.success))
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.Spacing.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.Color.surface))
    }

    private func fvgCard(_ fvgs: [PromptBuilder.FVGZone]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text("FVG ZONES")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Color.textMuted)
                Spacer()
                Text("\(fvgs.count) zones")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textMuted)
            }
            Button {
                onApplyFVGZones?(fvgs)
                onClose?()
            } label: {
                Label("Add to chart", systemImage: "rectangle.dashed")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Color.info))
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.Spacing.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.Color.surface))
    }

    private func supplyDemandCard(_ zones: [PromptBuilder.SupplyDemandZone]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text("SUPPLY & DEMAND")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Color.textMuted)
                Spacer()
                Text("\(zones.count) zones")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textMuted)
            }
            Button {
                onApplySupplyDemand?(zones)
                onClose?()
            } label: {
                Label("Add to chart", systemImage: "rectangle.righthalf.filled")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Color.warn))
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.Spacing.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.Color.surface))
    }

    // MARK: - Action dock

    private func actionDock(session: AnalysisStore.Session) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            if session.phase == .running {
                Button {
                    store.stop(kind: selectedKind, pairID: pair.id)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text("Stop")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Theme.Color.danger))
                }
            } else {
                Button {
                    runAnalysis()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12, weight: .bold))
                        Text("Analyze")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Theme.accentGradient))
                }
            }

            Spacer()

            if !session.report.isEmpty && session.phase != .running {
                Button {
                    store.clear(kind: selectedKind, pairID: pair.id)
                } label: {
                    Text("Clear")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().strokeBorder(Theme.Color.border, lineWidth: 1)
                        )
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
    }

    // MARK: - Run analysis

    private func runAnalysis() {
        store.run(
            kind: selectedKind,
            engineKind: engineKind,
            pair: pair,
            timeframe: timeframe,
            candles: candles
        )
    }

    // MARK: - History sheet

    private var historySheet: some View {
        NavigationStack {
            List {
                let entries = store.history.filter { $0.pairID == pair.id }
                if entries.isEmpty {
                    Text("No analysis history yet")
                        .foregroundStyle(Theme.Color.textMuted)
                } else {
                    ForEach(entries) { entry in
                        Button {
                            store.loadFromHistory(entry)
                            showHistory = false
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(entry.kind.label)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Theme.Color.textPrimary)
                                    Spacer()
                                    Text(entry.date, style: .relative)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.Color.textMuted)
                                }
                                HStack(spacing: 8) {
                                    Text(entry.timeframeLabel)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.Color.textSecondary)
                                    Text("·")
                                        .foregroundStyle(Theme.Color.textMuted)
                                    Text(entry.engineLabel)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.Color.textSecondary)
                                    Text("·")
                                        .foregroundStyle(Theme.Color.textMuted)
                                    Text("\(entry.report.count) chars")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.Color.textMuted)
                                }
                                // Outcome chip
                                if let outcome = entry.outcome {
                                    Text(outcomeLabel(outcome))
                                        .font(.system(size: 9, weight: .heavy))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(outcomeColor(outcome)))
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        let entries = store.history.filter { $0.pairID == pair.id }
                        for idx in offsets {
                            store.deleteHistory(entries[idx])
                        }
                    }
                }
            }
            .navigationTitle("Analysis History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showHistory = false }
                }
            }
        }
    }

    private func formatPrice(_ v: Double) -> String {
        if v >= 10_000 { return String(format: "%.0f", v) }
        if v >= 100 { return String(format: "%.2f", v) }
        if v >= 1 { return String(format: "%.4f", v) }
        return String(format: "%.5f", v)
    }

    private func outcomeLabel(_ outcome: AnalysisStore.Outcome) -> String {
        switch outcome {
        case .hitTP:     return "WIN"
        case .hitSL:     return "LOSS"
        case .manual:    return "MANUAL"
        case .cancelled: return "CANCELLED"
        }
    }

    private func outcomeColor(_ outcome: AnalysisStore.Outcome) -> Color {
        switch outcome {
        case .hitTP:     return Theme.Color.success
        case .hitSL:     return Theme.Color.danger
        case .manual:    return Theme.Color.textSecondary
        case .cancelled: return Theme.Color.textMuted
        }
    }
}
