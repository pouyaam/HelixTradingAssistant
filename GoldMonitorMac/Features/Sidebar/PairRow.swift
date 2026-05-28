import SwiftUI

/// A single pair entry in the sidebar list. Layout:
///   [color icon]  Pair name              ↑X.XX%
///                 last price             24h hi/lo
///
/// Compact two-line layout matches CleanMyMac's "memory" / "drives" rows.
struct PairRow: View {
    let pair: TradingPair
    let isSelected: Bool
    let action: () -> Void
    @State private var hovered = false
    @EnvironmentObject private var yahoo: YahooScheduler

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.md) {
                // Circle badge with the pair's accent color and the
                // 2-letter symbol.
                ZStack {
                    Circle()
                        .fill(pair.color.opacity(0.18))
                    Circle()
                        .strokeBorder(pair.color.opacity(0.55), lineWidth: 1.5)
                    Text(String(pair.symbol.prefix(2)))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(pair.color)
                }
                .frame(width: 30, height: 30)
                .overlay(alignment: .bottomTrailing) {
                    // Online dot — visible when source reported a price
                    // in the last snapshot.
                    Circle()
                        .fill(rowIsOnline ? Theme.Color.success : Theme.Color.danger)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().strokeBorder(Theme.Color.surface, lineWidth: 1))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(pair.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Color.textPrimary)
                        .lineLimit(1)
                    Text(pair.symbol)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Color.textMuted)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 1) {
                    Text(rowPrice)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Color.textPrimary)
                        .monospacedDigit()
                    if rowIsOnline {
                        Text(Self.formatChange(pair.changePercent))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(pair.changePercent >= 0
                                              ? Theme.Color.success
                                              : Theme.Color.danger)
                            .monospacedDigit()
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, 7)
            .background(background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    @ViewBuilder
    private var background: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(pair.color.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .strokeBorder(pair.color.opacity(0.45), lineWidth: 1)
                )
        } else if hovered {
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(Theme.Color.surfaceHi)
        }
    }

    // ── Live-stream override ───────────────────────────────────────
    //
    // Metal (ounce) and Crypto (BTC/SOL/ETH) pairs don't flow through
    // the snapshot pipeline, so `pair.price` / `pair.isOnline` would
    // be zero/false for them. We sub in the YahooScheduler's
    // `latestPrices` map instead. Iran pairs continue to read straight
    // from the snapshot-derived TradingPair.
    private var rowPrice: String {
        if pair.usesLiveStream, let live = yahoo.latestPrices[pair.id] {
            return Self.formatPrice(live)
        }
        return pair.isOnline ? Self.formatPrice(pair.price) : "—"
    }

    private var rowIsOnline: Bool {
        if pair.usesLiveStream {
            return yahoo.latestPrices[pair.id] != nil
        }
        return pair.isOnline
    }

    // ── Formatting ─────────────────────────────────────────────────
    /// Mirror of the web app's PairListItem `formatPrice`. Different
    /// magnitudes get different precision so 1234567 doesn't drown out
    /// 0.05 in the same column.
    private static func formatPrice(_ p: Double) -> String {
        if p >= 10_000 {
            return p.formatted(.number.grouping(.automatic).precision(.fractionLength(0)))
        }
        if p >= 100 {
            return p.formatted(.number.precision(.fractionLength(2)))
        }
        if p >= 1 {
            return p.formatted(.number.precision(.fractionLength(4)))
        }
        return String(format: "%.5f", p)
    }

    private static func formatChange(_ pct: Double) -> String {
        let sign = pct >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", pct))%"
    }
}
