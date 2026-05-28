import SwiftUI

/// Dropdown timeframe picker. Used to be a row of pills (1m 5m 15m
/// 30m 1h 4h 1d) which devoured horizontal space — collapsed to a Menu
/// matching the style of `ChartTypeToggle` so the toolbar stays tidy.
struct TimeframeSelector: View {
    @Binding var selected: Timeframe

    var body: some View {
        Menu {
            ForEach(Timeframe.allCases) { tf in
                Button {
                    selected = tf
                } label: {
                    Label(tf.label,
                          systemImage: selected == tf
                                       ? "checkmark.circle.fill"
                                       : "clock")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 11, weight: .semibold))
                Text(selected.rawValue)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Theme.Color.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surface)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// Two-button toggle for chart type (line vs candle). Disabled on 1m
/// because candlesticks at minute granularity are visually meaningless.
struct ChartTypeToggle: View {
    @Binding var selected: ChartType
    let isDisabled: Bool

    var body: some View {
        Menu {
            ForEach(ChartType.allCases) { type in
                Button {
                    selected = type
                } label: {
                    Label(type.label, systemImage: selected == type
                          ? "checkmark.circle.fill" : icon(for: type))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon(for: selected))
                    .font(.system(size: 11, weight: .semibold))
                Text(selected.label)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Theme.Color.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surface)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(isDisabled ? 0.4 : 1)
        .disabled(isDisabled)
    }

    /// SF Symbol per chart type. Reused for both the toggle button glyph
    /// and the per-row icon in the menu (when that row isn't selected).
    private func icon(for type: ChartType) -> String {
        switch type {
        case .line:       return "chart.xyaxis.line"
        case .candle:     return "chart.bar.fill"
        case .heikinAshi: return "rectangle.stack.fill"
        }
    }
}
