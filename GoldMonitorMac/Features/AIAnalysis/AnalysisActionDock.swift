import SwiftUI

/// Bottom toolbar for the AI analysis page. Left side carries the
/// non-card overlay applies (S/R levels, FVG zones) — the per-plan
/// "Add to chart" / "Activate" buttons live on the PlanCards themselves
/// because they're more naturally read in the context of the prices.
///
/// Right side carries the always-present phase controls (Stop while
/// running; Clear + Run again once done or errored). The dock collapses
/// to just the phase controls when there's no overlay payload to apply
/// (e.g. multi-timeframe runs or kinds with their CTA on a card).
struct AnalysisActionDock: View {
    let phase: AnalysisStore.Phase
    /// Engine ready — gates "Run again". Mirrors the same gate the
    /// idle "Analyze" CTA used to apply.
    let engineReady: Bool

    /// Optional levels payload — when non-empty, the dock shows an
    /// "Add S/R levels (N)" button. Used by both .full and .supportResistance
    /// kinds (S/R card on .supportResistance owns its own button, so
    /// caller can omit this if the card variant is preferred).
    let srLevels: PromptBuilder.SRLevels?
    /// Optional FVG zones — same shape as srLevels.
    let fvgZones: [PromptBuilder.FVGZone]?

    var onAddSRLevels: (() -> Void)?
    var onAddFVGZones: (() -> Void)?
    /// "Add to journal" — captures the finished analysis (and its top
    /// scenario, when present) as a journal draft. Shown once done.
    var onAddToJournal: (() -> Void)?
    var onStop: () -> Void
    var onClear: () -> Void
    var onRunAgain: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            leftSide
            Spacer()
            rightSide
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
        .background(Theme.Color.surface)
        .overlay(
            Rectangle()
                .fill(Theme.Color.border)
                .frame(height: 1),
            alignment: .top
        )
    }

    // ── Left: overlay applies ──────────────────────────────────────
    @ViewBuilder
    private var leftSide: some View {
        if phase == .done {
            if let sr = srLevels, !sr.isEmpty, let onAdd = onAddSRLevels {
                applyButton(
                    label: "Add S/R levels (\(sr.support.count + sr.resistance.count))",
                    icon: "chart.line.uptrend.xyaxis",
                    action: onAdd
                )
            }
            if let zones = fvgZones, !zones.isEmpty, let onAdd = onAddFVGZones {
                applyButton(
                    label: "Add FVG zones (\(zones.count))",
                    icon: "rectangle.dashed",
                    action: onAdd
                )
            }
            if let onJournal = onAddToJournal {
                journalButton(action: onJournal)
            }
        }
    }

    // ── Right: phase controls ──────────────────────────────────────
    @ViewBuilder
    private var rightSide: some View {
        switch phase {
        case .running:
            SecondaryButton(title: "Stop", action: onStop)
        case .done, .error:
            SecondaryButton(title: "Clear", action: onClear)
            PrimaryButton("Run again", systemImage: "arrow.clockwise", action: onRunAgain)
                .disabled(!engineReady)
                .opacity(engineReady ? 1 : 0.5)
        case .idle:
            EmptyView()
        }
    }

    private func applyButton(label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8).fill(Theme.Color.success)
                )
        }
        .buttonStyle(.plain)
    }

    /// Secondary-styled "Add to journal" button — surfaceMax fill so it
    /// sits below the green overlay-apply buttons in emphasis.
    private func journalButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Add to journal", systemImage: "book.closed")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Color.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8).fill(Theme.Color.surfaceMax)
                )
        }
        .buttonStyle(.plain)
        .help("Save this analysis to your trade journal")
    }
}
