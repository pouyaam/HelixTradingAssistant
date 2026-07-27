import SwiftUI

/// Interactive Chart Trade Box Overlay (Phase 2).
/// Displays live Entry, Stop Loss, and Take Profit levels on the chart canvas with real-time risk calculation.
struct ChartTradeBoxOverlay: View {
    @Binding var isPresented: Bool
    @Binding var entryPrice: Double
    @Binding var stopLossPrice: Double
    @Binding var takeProfitPrice: Double
    @Binding var isBuy: Bool

    var accountBalance: Double = 50_000.0
    var riskPercent: Double = 1.0

    var onPlaceOrder: ((_ lotSize: Double, _ rr: Double) -> Void)?

    private var dollarRisk: Double {
        accountBalance * (riskPercent / 100.0)
    }

    private var riskPerUnit: Double {
        abs(entryPrice - stopLossPrice)
    }

    private var rewardPerUnit: Double {
        abs(takeProfitPrice - entryPrice)
    }

    private var riskRewardRatio: Double {
        guard riskPerUnit > 0 else { return 0 }
        return rewardPerUnit / riskPerUnit
    }

    private var estimatedLotSize: Double {
        guard riskPerUnit > 0 else { return 0 }
        // 1 lot of XAU/USD = 100 oz
        return (dollarRisk / (riskPerUnit * 100.0)).rounded(toPlaces: 2)
    }

    private var potentialProfit: Double {
        dollarRisk * riskRewardRatio
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            // Header Bar
            HStack {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: isBuy ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                        .foregroundStyle(isBuy ? Theme.Color.success : Theme.Color.danger)
                        .font(.system(size: 16))

                    Text(isBuy ? "BUY ORDER TRADE BOX" : "SELL ORDER TRADE BOX")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.Color.textPrimary)
                }

                Spacer()

                Button {
                    isBuy.toggle()
                    // Swap SL and TP roughly
                    let diff = abs(entryPrice - stopLossPrice)
                    if isBuy {
                        stopLossPrice = entryPrice - diff
                        takeProfitPrice = entryPrice + (diff * 2)
                    } else {
                        stopLossPrice = entryPrice + diff
                        takeProfitPrice = entryPrice - (diff * 2)
                    }
                } label: {
                    Text("Flip Direction")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.Color.surfaceHi)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .cornerRadius(Theme.Radius.sm)
                }
                .buttonStyle(.plain)

                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.Color.textMuted)
                }
                .buttonStyle(.plain)
            }

            Divider()
                .overlay(Theme.Color.border)

            // Metrics Summary Grid
            HStack(spacing: Theme.Spacing.lg) {
                MetricTile(
                    label: "RISK ($)",
                    value: String(format: "$%.2f", dollarRisk),
                    subText: String(format: "%.1f%% Account", riskPercent),
                    color: Theme.Color.danger
                )

                MetricTile(
                    label: "ESTIMATED LOTS",
                    value: String(format: "%.2f Lots", estimatedLotSize),
                    subText: "Risk Sized",
                    color: Theme.Color.accentStart
                )

                MetricTile(
                    label: "R:R RATIO",
                    value: String(format: "1:%.2f", riskRewardRatio),
                    subText: riskRewardRatio >= 1.5 ? "Good Geometry" : "Low R:R Warning",
                    color: riskRewardRatio >= 1.5 ? Theme.Color.success : Theme.Color.warn
                )

                MetricTile(
                    label: "PROFIT TARGET ($)",
                    value: String(format: "+$%.2f", potentialProfit),
                    subText: "At TP Level",
                    color: Theme.Color.success
                )
            }

            Divider()
                .overlay(Theme.Color.border)

            // Price Steppers / Adjusters
            HStack(spacing: Theme.Spacing.md) {
                PriceInputField(
                    title: "Take Profit Target",
                    price: $takeProfitPrice,
                    color: Theme.Color.success
                )

                PriceInputField(
                    title: "Entry Level",
                    price: $entryPrice,
                    color: Theme.Color.info
                )

                PriceInputField(
                    title: "Stop Loss",
                    price: $stopLossPrice,
                    color: Theme.Color.danger
                )
            }

            // Action Button
            Button {
                onPlaceOrder?(estimatedLotSize, riskRewardRatio)
                isPresented = false
            } label: {
                HStack {
                    Image(systemName: "paperplane.fill")
                    Text("Place Paper Order (\(String(format: "%.2f", estimatedLotSize)) Lots)")
                }
                .font(.system(size: 13, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(isBuy ? Theme.Color.success : Theme.Color.danger)
                .foregroundStyle(Color.white)
                .cornerRadius(Theme.Radius.md)
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.Spacing.lg)
        .glassmorphicCard(cornerRadius: Theme.Radius.lg)
        .frame(maxWidth: 620)
    }
}

private struct MetricTile: View {
    let label: String
    let value: String
    let subText: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.Color.textMuted)

            Text(value)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(color)

            Text(subText)
                .font(.system(size: 10))
                .foregroundStyle(Theme.Color.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PriceInputField: View {
    let title: String
    @Binding var price: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(color)

            HStack(spacing: 4) {
                Button {
                    price -= 0.50
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(Theme.Color.surfaceHi)
                        .foregroundStyle(Theme.Color.textPrimary)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)

                Text(String(format: "%.2f", price))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.Color.textPrimary)
                    .frame(maxWidth: .infinity)

                Button {
                    price += 0.50
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(Theme.Color.surfaceHi)
                        .foregroundStyle(Theme.Color.textPrimary)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
            .padding(6)
            .background(Theme.Color.surfaceHi.opacity(0.5))
            .cornerRadius(Theme.Radius.sm)
        }
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
