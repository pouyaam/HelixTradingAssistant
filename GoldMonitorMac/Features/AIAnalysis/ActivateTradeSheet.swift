import SwiftUI

/// Modal presented when the user clicks "Activate as trade" on a
/// completed full-TA analysis. Lets them pick an order type (Market
/// fills immediately at the latest tick; Pending waits for price to
/// touch the AI's entry) and a position size in lots, then hands the
/// resulting `Trade` to the dashboard's `TradeStore`.
///
/// Shows a live risk/reward preview computed from the scenario's TP
/// and SL distances so the user can see money-at-risk before
/// confirming. R:R is also surfaced — most traders won't pull the
/// trigger below 1:1.
struct ActivateTradeSheet: View {
    let scenario: PromptBuilder.TAScenario
    let pairID: String
    /// Current spot price — used to default-fill Market orders and to
    /// show the user where they'd actually fill versus the AI's
    /// proposed entry.
    let livePrice: Double?
    /// Optional ID of the HistoryEntry that produced this scenario.
    /// Threaded onto the resulting Trade so the dashboard's outcome
    /// observer can stamp wins/losses back onto the source entry —
    /// that's what feeds the win-rate stat in AnalysisHistoryView.
    /// Nil when the scenario came from a still-streaming session
    /// (history entry hasn't been recorded yet) — the trade just
    /// won't contribute to the stat.
    var sourceHistoryEntryID: UUID? = nil
    /// Called with the constructed Trade when the user clicks
    /// "Activate". The dashboard adds it to the TradeStore and
    /// dismisses the sheet.
    let onActivate: (Trade) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Local form state. Defaults to Market (the user just ran an
    /// analysis; they probably want to commit at the current price).
    /// `sizingMode` flips the lot-input between manual ("I want 0.10
    /// lots") and risk-anchored ("I want to risk 1% of my account").
    /// Risk-anchored is the default because it's what professional
    /// traders actually use — fixed-lot sizing means a wide-stop trade
    /// risks 4× as much money as a tight-stop trade, which kills
    /// long-run expectancy regardless of win rate.
    @State private var orderType: OrderType = .market
    @State private var sizingMode: SizingMode = .riskPercent
    @State private var lots: Double = 0.10
    @AppStorage("trade.accountBalance") private var accountBalance: Double = 10_000
    @AppStorage("trade.riskPercent")    private var riskPercent: Double = 1.0

    enum SizingMode: String, CaseIterable, Identifiable {
        case riskPercent, manualLots
        var id: String { rawValue }
        var label: String {
            switch self {
            case .riskPercent: return "Risk %"
            case .manualLots:  return "Lots"
            }
        }
    }

    enum OrderType: String, CaseIterable, Identifiable {
        case market, pending
        var id: String { rawValue }
        var label: String {
            switch self {
            case .market:  return "Market"
            case .pending: return "Pending"
            }
        }
        var help: String {
            switch self {
            case .market:  return "Fill immediately at the latest tick."
            case .pending: return "Wait until price touches the scenario's entry."
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            header
            scenarioSummary
            orderTypePicker
            lotSizeRow
            preview
            actions
        }
        .padding(Theme.Spacing.xl)
        .frame(minWidth: 460, idealWidth: 520)
        .background(Theme.Color.surfaceHi)
    }

    // ── Header ────────────────────────────────────────────────────
    private var header: some View {
        HStack {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.Color.success)
            Text("Activate as trade")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.Color.textPrimary)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surface))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
    }

    // ── Scenario summary ──────────────────────────────────────────
    private var scenarioSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(scenario.bias.rawValue.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(biasColor))
                if let entry = scenario.entry {
                    Text("Entry \(PriceFormat.short(entry))")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.Color.textPrimary)
                }
                Text("TP \(PriceFormat.short(scenario.takeProfit))")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.Color.success)
                Text("SL \(PriceFormat.short(scenario.stopLoss))")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.Color.danger)
                Spacer()
            }
            if let live = livePrice {
                Text("Current price: \(PriceFormat.short(live))")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Theme.Color.textMuted)
            }
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surface))
    }

    // ── Order type ────────────────────────────────────────────────
    private var orderTypePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ORDER TYPE")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)
            HStack(spacing: 6) {
                ForEach(OrderType.allCases) { type in
                    Button {
                        orderType = type
                    } label: {
                        Text(type.label)
                            .font(.system(size: 11, weight: orderType == type ? .bold : .medium))
                            .foregroundStyle(orderType == type ? .white : Theme.Color.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(orderType == type
                                          ? AnyShapeStyle(Theme.accentGradient)
                                          : AnyShapeStyle(Theme.Color.surface))
                            )
                    }
                    .buttonStyle(.plain)
                    .help(type.help)
                }
                Spacer()
            }
        }
    }

    // ── Sizing ────────────────────────────────────────────────────
    private var lotSizeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            sizingModePicker
            switch sizingMode {
            case .riskPercent: riskSizingRow
            case .manualLots:  manualLotsRow
            }
            sizingSummary
        }
    }

    private var sizingModePicker: some View {
        HStack(spacing: 6) {
            Text("SIZING")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)
            ForEach(SizingMode.allCases) { mode in
                Button {
                    sizingMode = mode
                } label: {
                    Text(mode.label)
                        .font(.system(size: 10, weight: sizingMode == mode ? .bold : .medium))
                        .foregroundStyle(sizingMode == mode ? .white : Theme.Color.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(sizingMode == mode
                                      ? AnyShapeStyle(Theme.accentGradient)
                                      : AnyShapeStyle(Theme.Color.surface))
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    /// Risk-anchored sizing: user picks account balance + risk %,
    /// lots are derived from SL distance. Empty SL distance (a
    /// degenerate scenario) collapses lots to 0 and the Activate
    /// button is disabled by `computedLots == 0`.
    private var riskSizingRow: some View {
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text("ACCOUNT")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.Color.textMuted)
                HStack(spacing: 2) {
                    Text("$")
                        .font(.system(size: 11)).foregroundStyle(Theme.Color.textMuted)
                    TextField("10000", value: $accountBalance, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .font(.system(size: 11).monospacedDigit())
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("RISK %")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.Color.textMuted)
                HStack(spacing: 2) {
                    TextField("1.0", value: $riskPercent, format: .number.precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 56)
                        .font(.system(size: 11).monospacedDigit())
                    Text("%")
                        .font(.system(size: 11)).foregroundStyle(Theme.Color.textMuted)
                }
            }
            Spacer()
        }
    }

    private var manualLotsRow: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text(String(format: "%.2f", lots))
                .font(.system(size: 14, weight: .bold).monospacedDigit())
                .foregroundStyle(Theme.Color.textPrimary)
                .frame(minWidth: 50, alignment: .leading)
            Stepper("", value: $lots, in: 0.01...100.0, step: 0.01)
                .labelsHidden()
                .controlSize(.small)
            Spacer()
        }
    }

    /// One-line "this resolves to N lots / oz, risking $X" so the
    /// user can sanity-check the math whichever sizing mode they're
    /// in. Highlighted in red when the risk amount exceeds 5% of
    /// the account — that's where blow-up risk lives.
    private var sizingSummary: some View {
        let l = effectiveLots
        let risk = riskUSDPerLot * l
        let danger = accountBalance > 0 && risk / accountBalance > 0.05
        return HStack(spacing: 8) {
            Text("→ \(String(format: "%.2f", l)) lot · \(Int((l * 100).rounded())) oz")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Theme.Color.textSecondary)
            Text("· risking $\(String(format: "%.2f", risk))")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(danger ? Theme.Color.danger : Theme.Color.textMuted)
            if danger {
                Text("⚠︎ over 5% of account")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Color.danger)
            }
            Spacer()
        }
    }

    /// SL distance × oz per lot — the dollar amount risked per lot.
    /// Reuses the Trade.riskUSD helper logic without needing a
    /// constructed Trade.
    private var riskUSDPerLot: Double {
        let entry = scenario.entry ?? livePrice ?? scenario.takeProfit
        return abs(entry - scenario.stopLoss) * 100
    }

    /// Lots that will actually be used when Activate is clicked.
    /// Risk-mode derives from (balance × risk%) / SL distance and
    /// rounds to 2dp so the lot count is broker-realistic; manual
    /// mode just hands back the stepper value.
    private var effectiveLots: Double {
        switch sizingMode {
        case .manualLots:
            return lots
        case .riskPercent:
            let perLot = riskUSDPerLot
            guard perLot > 0, accountBalance > 0, riskPercent > 0 else { return 0 }
            let target = accountBalance * (riskPercent / 100)
            let raw = target / perLot
            // Round to 2dp; clamp to a sane min so we never emit
            // 0.00 from rounding (broker would reject it).
            return max(0.01, (raw * 100).rounded() / 100)
        }
    }

    // ── Risk / reward preview ─────────────────────────────────────
    private var preview: some View {
        let l = effectiveLots
        let entryPx = scenario.entry ?? livePrice ?? scenario.takeProfit
        let risk = abs(entryPx - scenario.stopLoss) * 100 * l
        let reward = abs(scenario.takeProfit - entryPx) * 100 * l
        let rr = risk > 0 ? reward / risk : 0
        return HStack(spacing: Theme.Spacing.xl) {
            previewStat(label: "RISK", value: "−$\(String(format: "%.2f", risk))", color: Theme.Color.danger)
            previewStat(label: "REWARD", value: "+$\(String(format: "%.2f", reward))", color: Theme.Color.success)
            previewStat(label: "R:R", value: "1 : \(String(format: "%.2f", rr))", color: rr >= 1 ? Theme.Color.success : Theme.Color.warn)
            Spacer()
        }
    }

    private func previewStat(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.Color.textMuted)
            Text(value)
                .font(.system(size: 13, weight: .bold).monospacedDigit())
                .foregroundStyle(color)
        }
    }

    // ── Actions ───────────────────────────────────────────────────
    private var actions: some View {
        HStack {
            Spacer()
            SecondaryButton(title: "Cancel") { dismiss() }
            Button {
                onActivate(makeTrade())
                dismiss()
            } label: {
                Label("Activate", systemImage: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Color.success))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(scenario.entry == nil)
            .opacity(scenario.entry == nil ? 0.4 : 1)
            .help(scenario.entry == nil
                  ? "Scenario has no entry price — re-run analysis"
                  : "Activate the trade")
        }
    }

    // ── Helpers ───────────────────────────────────────────────────

    /// Build the Trade from current form state. Pending orders go
    /// out with status `.pending`; market orders go out already
    /// `.active`, filled at the live price (or the scenario's entry
    /// if no live price is available — defensive, shouldn't happen
    /// in practice).
    private func makeTrade() -> Trade {
        let side: Trade.Side = {
            switch scenario.bias {
            case .long:    return .long
            case .short:   return .short
            case .neutral: return .neutral
            }
        }()
        let entry = scenario.entry ?? livePrice ?? scenario.takeProfit
        let finalLots = effectiveLots
        switch orderType {
        case .market:
            let fill = livePrice ?? entry
            return Trade(
                id: UUID(),
                pairID: pairID,
                sourceHistoryEntryID: sourceHistoryEntryID,
                side: side,
                entry: entry,
                takeProfit: scenario.takeProfit,
                stopLoss: scenario.stopLoss,
                lots: finalLots,
                createdAt: Date(),
                status: .active,
                filledAt: Date(),
                fillPrice: fill,
                closedAt: nil,
                closePrice: nil,
                closeReason: nil,
                visible: true
            )
        case .pending:
            return Trade(
                id: UUID(),
                pairID: pairID,
                sourceHistoryEntryID: sourceHistoryEntryID,
                side: side,
                entry: entry,
                takeProfit: scenario.takeProfit,
                stopLoss: scenario.stopLoss,
                lots: finalLots,
                createdAt: Date(),
                status: .pending,
                filledAt: nil,
                fillPrice: nil,
                closedAt: nil,
                closePrice: nil,
                closeReason: nil,
                visible: true
            )
        }
    }

    private var biasColor: Color {
        switch scenario.bias {
        case .long:    return Theme.Color.success
        case .short:   return Theme.Color.danger
        case .neutral: return Theme.Color.textSecondary
        }
    }
}
