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
        case .renko:      return "rectangle.3.group.fill"
        }
    }
}

/// Settings panel popover content for Renko chart configuration.
struct RenkoSettingsView: View {
    @Binding var config: RenkoConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Renko Settings")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Color.textPrimary)

            Divider()

            HStack {
                Text("Box Size Mode")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textSecondary)
                Spacer()
                Picker("Mode", selection: $config.mode) {
                    ForEach(RenkoConfig.Mode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
            }

            if config.mode == .atr {
                HStack {
                    Text("ATR Period")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Color.textSecondary)
                    Spacer()
                    HStack(spacing: 6) {
                        Button {
                            if config.atrPeriod > 1 { config.atrPeriod -= 1 }
                        } label: {
                            Image(systemName: "minus")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .buttonStyle(.borderless)
                        Text("\(config.atrPeriod)")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .frame(width: 24, alignment: .center)
                        Button {
                            if config.atrPeriod < 100 { config.atrPeriod += 1 }
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } else {
                HStack {
                    Text("Fixed Box Size")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Color.textSecondary)
                    Spacer()
                    TextField("1.0", value: $config.fixedBoxSize, format: .number)
                        .font(.system(size: 11).monospacedDigit())
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                }
            }
            // No "Show Wicks" toggle: a Renko brick is a pure box. It
            // represents a fixed price move rather than a time period, so
            // there's no intrabar excursion for a shadow to describe.
        }
        .padding(12)
        .frame(width: 220)
    }
}
