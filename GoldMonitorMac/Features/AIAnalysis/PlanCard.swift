import SwiftUI

/// Structured display of a single full-TA trade plan. Drops the wall-of-
/// JSON the model originally emits and shows the user a glanceable card:
/// bias chip, validity badge, entry / TP / SL prices with %-from-entry,
/// R:R, and per-card action buttons.
///
/// Two visual variants — `.main` for the primary plan, `.alt` for the
/// alternative plan emitted when Claude finds one. The alt variant
/// softens the styling so the user can tell at a glance which card is
/// the leading idea vs the fallback, and hides the Activate button
/// (alt plans are reference-only — to act on one, the user re-runs).
struct PlanCard: View {
    enum Variant { case main, alt }

    let scenario: PromptBuilder.TAScenario
    let variant: Variant
    /// Most recent live price for the scenario's pair, used by
    /// `scenario.isValid(at:)` to drive the VALID / INVALID badge. nil
    /// (no live tick yet) renders as "—" rather than a false-positive.
    let livePrice: Double?
    /// Click target for "Add to chart". Always shown — applies the
    /// scenario to the dashboard's overlay slot for this variant.
    var onAddToChart: (() -> Void)?
    /// Click target for "Activate". Only meaningful when there's an
    /// entry price (a bare TP/SL pair has no fill basis). Hidden for
    /// the `.alt` variant regardless.
    var onActivate: (() -> Void)?
    /// Click target for "Add to journal" — captures this plan (with
    /// its position) as a journal draft. Shown for both variants.
    var onAddToJournal: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            headerRow
            Divider().background(Theme.Color.border)
            pricesGrid
            if let rr = riskReward {
                rrRow(rr)
            }
            Divider().background(Theme.Color.border)
            actionsRow
        }
        .padding(Theme.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Color.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(borderColor, lineWidth: variant == .main ? 1.5 : 1)
        )
        .opacity(variant == .alt ? 0.85 : 1.0)
    }

    // ── Header ─────────────────────────────────────────────────────
    private var headerRow: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(variant == .main ? "MAIN PLAN" : "ALTERNATIVE PLAN")
                .font(.system(size: 11, weight: .heavy))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)
            Spacer()
            biasChip
            validityBadge
        }
    }

    private var biasChip: some View {
        Text(scenario.bias.rawValue.uppercased())
            .font(.system(size: 10, weight: .heavy))
            .tracking(0.6)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(biasColor)
            )
            .opacity(variant == .alt ? 0.7 : 1.0)
    }

    @ViewBuilder
    private var validityBadge: some View {
        if let live = livePrice {
            let valid = scenario.isValid(at: live)
            HStack(spacing: 3) {
                Image(systemName: valid ? "checkmark.seal.fill" : "xmark.seal.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(valid ? "VALID" : "INVALID")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(0.6)
            }
            .foregroundStyle(valid ? Theme.Color.success : Theme.Color.danger)
        } else {
            Text("—")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.Color.textMuted)
        }
    }

    // ── Prices ─────────────────────────────────────────────────────
    private var pricesGrid: some View {
        VStack(spacing: Theme.Spacing.sm) {
            if let entry = scenario.entry {
                priceRow(label: "Entry", value: entry, basis: nil)
            }
            priceRow(label: "Take profit", value: scenario.takeProfit, basis: scenario.entry)
            priceRow(label: "Stop loss",   value: scenario.stopLoss,   basis: scenario.entry)
        }
    }

    private func priceRow(label: String, value: Double, basis: Double?) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Color.textSecondary)
            Spacer()
            Text(fmtPrice(value))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.Color.textPrimary)
            if let basis = basis, basis > 0 {
                let pct = (value - basis) / basis * 100.0
                Text(String(format: "%+.2f%%", pct))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(pct >= 0 ? Theme.Color.success : Theme.Color.danger)
                    .frame(width: 64, alignment: .trailing)
            } else {
                Spacer().frame(width: 64)
            }
        }
    }

    // ── R:R ────────────────────────────────────────────────────────

    /// `nil` when there's no entry (R:R needs three points), or when
    /// the SL distance from entry is zero (degenerate plan).
    private var riskReward: Double? {
        guard let entry = scenario.entry else { return nil }
        let reward = abs(scenario.takeProfit - entry)
        let risk = abs(entry - scenario.stopLoss)
        guard risk > 0 else { return nil }
        return reward / risk
    }

    private func rrRow(_ rr: Double) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Text("R:R")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Color.textSecondary)
            Spacer()
            Text(String(format: "1 : %.2f", rr))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(rr >= 1.5 ? Theme.Color.success : Theme.Color.textPrimary)
            Spacer().frame(width: 64)
        }
    }

    // ── Actions ────────────────────────────────────────────────────
    private var actionsRow: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if let onAdd = onAddToChart {
                applyButton(label: "Add to chart", icon: "chart.line.uptrend.xyaxis", action: onAdd)
            }
            // Alt plans are reference-only — to act on the alt, the
            // user can re-run the analysis with the alt as the main.
            if variant == .main, scenario.entry != nil, let onActivate = onActivate {
                applyButton(label: "Activate", icon: "play.circle.fill", action: onActivate)
            }
            if let onJournal = onAddToJournal {
                journalButton(action: onJournal)
            }
            Spacer()
        }
    }

    private func applyButton(label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(Theme.Color.success)
                )
        }
        .buttonStyle(.plain)
    }

    /// Secondary-styled "Add to journal" button — surfaceMax fill so it
    /// reads as the lower-emphasis sibling of the green apply buttons.
    private func journalButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Journal", systemImage: "book.closed")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Color.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surfaceMax)
                )
        }
        .buttonStyle(.plain)
        .help("Add this plan to your trade journal")
    }

    // ── Styling helpers ────────────────────────────────────────────
    private var biasColor: Color {
        switch scenario.bias {
        case .long:    return Theme.Color.success
        case .short:   return Theme.Color.danger
        case .neutral: return Theme.Color.info
        }
    }

    private var borderColor: Color {
        variant == .main ? biasColor.opacity(0.35) : Theme.Color.border
    }

    /// Same rounding as the rest of the price tags: integers for big
    /// numbers, two decimals at $100+, four otherwise.
    private func fmtPrice(_ v: Double) -> String {
        if v >= 10_000 { return String(format: "%.0f", v) }
        if v >= 100    { return String(format: "%.2f", v) }
        if v >= 1      { return String(format: "%.4f", v) }
        return String(format: "%.5f", v)
    }
}
