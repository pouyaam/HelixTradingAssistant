import SwiftUI

/// Claude-app-style inline checklist for the analysis page. The user
/// ticks one or more `AnalysisAspect`s; ticking "Trade scenarios"
/// reveals a Position/Swing/Scalp profile segment. Run fires the
/// combined analysis. At 3+ ticked aspects the footer swaps to a
/// "this may be slow" confirm (the client-side half of the dual
/// scope guard; the model can still emit a CLARIFY block).
struct AnalysisAspectCard: View {
    @Binding var selected: Set<AnalysisAspect>
    @Binding var profile: StrategyProfile
    let engineReady: Bool
    let onRun: () -> Void
    /// Launches the dedicated Confluence Trade Scanner — the full
    /// scored-scenario workflow (S&D + market structure, ranked
    /// 1-10, with the opt-in Expand step), distinct from the
    /// combined à-la-carte report. Uses the picked `profile`.
    let onRunConfluenceScanner: () -> Void
    /// Launches the Top-Down Sniper (Swing) — 4H bias → 1H setup →
    /// 15m entry.
    let onRunTopDownSniperSwing: () -> Void
    /// Launches the Top-Down Sniper (Intraday) — 1H bias → 15m setup
    /// → 1m entry.
    let onRunTopDownSniperIntraday: () -> Void

    /// Two-step confirm state when ≥3 aspects are ticked.
    @State private var awaitingConfirm = false

    private var hasScenarios: Bool { selected.contains(.scenarios) }
    private var isHeavy: Bool { selected.count >= 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("What should I analyze?")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.Color.textPrimary)
            Text("Pick one or several — I'll produce a section for each.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textSecondary)

            VStack(spacing: 6) {
                ForEach(AnalysisAspect.displayOrder) { aspect in
                    aspectRow(aspect)
                }
            }

            if hasScenarios {
                profileSegment
            }

            footer

            confluenceSection
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: 520, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Color.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(Theme.Color.border, lineWidth: 1)
        )
        .padding(Theme.Spacing.xl)
    }

    private func aspectRow(_ aspect: AnalysisAspect) -> some View {
        let isOn = selected.contains(aspect)
        return Button {
            if isOn { selected.remove(aspect) } else { selected.insert(aspect) }
            awaitingConfirm = false
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isOn ? Theme.Color.accentStart : Theme.Color.textMuted)
                Image(systemName: aspect.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(width: 18)
                Text(aspect.label)
                    .font(.system(size: 13, weight: isOn ? .semibold : .medium))
                    .foregroundStyle(Theme.Color.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isOn ? Theme.Color.accentStart.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var profileSegment: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PROFILE (trade horizon)")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)
            HStack(spacing: 6) {
                ForEach(StrategyProfile.allCases) { p in
                    let isOn = profile == p
                    Button { profile = p } label: {
                        HStack(spacing: 4) {
                            Image(systemName: p.meta.icon)
                                .font(.system(size: 10, weight: .semibold))
                            Text(p.meta.label)
                                .font(.system(size: 11, weight: isOn ? .bold : .semibold))
                        }
                        .foregroundStyle(isOn ? .white : Theme.Color.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isOn
                                      ? AnyShapeStyle(Theme.accentGradient)
                                      : AnyShapeStyle(Theme.Color.canvas))
                        )
                    }
                    .buttonStyle(.plain)
                    .help(p.meta.description)
                }
                Spacer()
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var footer: some View {
        if awaitingConfirm {
            VStack(alignment: .leading, spacing: 6) {
                Text("You picked \(selected.count) analyses — this may take a while.")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Color.warn)
                HStack(spacing: 8) {
                    Button("Narrow down") { awaitingConfirm = false }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Color.canvas))
                    Button("Run full anyway") { fire() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accentGradient))
                }
            }
        } else {
            HStack {
                Text(selected.isEmpty ? "Select at least one"
                                       : "\(selected.count) selected")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textMuted)
                Spacer()
                Button {
                    if isHeavy { awaitingConfirm = true } else { fire() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill").font(.system(size: 11, weight: .bold))
                        Text("Run analysis").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accentGradient))
                }
                .buttonStyle(.plain)
                .disabled(selected.isEmpty || !engineReady)
                .opacity(selected.isEmpty || !engineReady ? 0.5 : 1)
            }
        }
    }

    // ── Confluence Trade Scanner (full scored strategy) ───────────
    private var confluenceSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Divider().background(Theme.Color.border)
            Text("OR RUN A FULL STRATEGY")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)
            strategyButton(
                icon: "scope",
                title: "Confluence Trade Scanner",
                subtitle: "S&D + market structure, ranked 1-10 · \(profile.meta.label)",
                action: onRunConfluenceScanner
            )
            strategyButton(
                icon: "arrow.down.right.and.arrow.up.left",
                title: "Top-Down Sniper · Swing",
                subtitle: "4H bias → 1H setup (OB / FVG / liquidity) → 15m entry",
                action: onRunTopDownSniperSwing
            )
            strategyButton(
                icon: "bolt.horizontal",
                title: "Top-Down Sniper · Intraday",
                subtitle: "1H bias → 15m setup (OB / FVG / liquidity) → 1m entry",
                action: onRunTopDownSniperIntraday
            )
            // Profile picker (drives the Confluence Scanner horizon)
            // when "Trade scenarios" isn't ticked — so it's always
            // reachable for the scanner.
            if !hasScenarios {
                profileSegment
            }
        }
    }

    private func strategyButton(
        icon: String,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Color.accentStart)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Color.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(engineReady ? Theme.Color.accentStart : Theme.Color.textMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.Color.accentStart.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.Color.accentStart.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!engineReady)
        .opacity(engineReady ? 1 : 0.5)
    }

    private func fire() {
        awaitingConfirm = false
        onRun()
    }
}
