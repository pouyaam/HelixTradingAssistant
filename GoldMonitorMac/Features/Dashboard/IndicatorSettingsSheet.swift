import SwiftUI

/// Settings sheet for the panel oscillators (RSI / MACD / Stochastic).
/// Lives over the dashboard as a popover / sheet so the user can tune
/// periods without leaving the chart context. Edits write directly to
/// the bound config; the parent persists on dismiss.
struct IndicatorSettingsSheet: View {
    @Binding var config: OscillatorConfig
    @Environment(\.dismiss) private var dismiss

    /// Locally captured snapshot — if the user hits "Cancel" we restore
    /// this so accidental drags on a Stepper don't stick.
    @State private var original: OscillatorConfig?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack {
                Text("Indicator settings")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Spacer()
                Button {
                    if let orig = original { config = orig }
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surface)
                        )
                }
                .buttonStyle(.plain)
                .help("Cancel")
            }

            section(title: "RSI") {
                periodStepper(label: "Period", value: $config.rsiPeriod, range: 2...100)
            }

            Divider().background(Theme.Color.border)

            section(title: "MACD") {
                periodStepper(label: "Fast EMA",   value: $config.macdFast,   range: 2...50)
                periodStepper(label: "Slow EMA",   value: $config.macdSlow,   range: 3...100)
                periodStepper(label: "Signal EMA", value: $config.macdSignal, range: 2...50)
            }

            Divider().background(Theme.Color.border)

            section(title: "Stochastic") {
                periodStepper(label: "%K period", value: $config.stochK, range: 2...50)
                periodStepper(label: "%D period", value: $config.stochD, range: 1...20)
            }

            Divider().background(Theme.Color.border)

            section(title: "UT Bot Alerts") {
                doubleStepper(
                    label: "Key value (sensitivity)",
                    value: $config.utKeyValue,
                    range: 0.1...10.0,
                    step: 0.1
                )
                periodStepper(label: "ATR period", value: $config.utATRPeriod, range: 1...100)
                Toggle(isOn: $config.utShowTrailingStop) {
                    Text("Show ATR trailing-stop line")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Color.textSecondary)
                }
                .toggleStyle(.checkbox)
                Toggle(isOn: $config.utUseHeikinAshi) {
                    Text("Use Heikin Ashi for signals")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Color.textSecondary)
                }
                .toggleStyle(.checkbox)
            }

            HStack {
                Button("Restore defaults") {
                    config = OscillatorConfig()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Color.textSecondary)
                Spacer()
                Button {
                    config.save()
                    dismiss()
                } label: {
                    Text("Save")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6).fill(Theme.Color.info)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(minWidth: 380, idealWidth: 420)
        .background(Theme.Color.surfaceHi)
        .onAppear { original = config }
        // MACD fast must stay below slow — clamp on the fly so the user
        // can never set fast >= slow and end up with a broken series.
        .onChange(of: config.macdFast) { _ in
            if config.macdFast >= config.macdSlow {
                config.macdSlow = config.macdFast + 1
            }
        }
        .onChange(of: config.macdSlow) { _ in
            if config.macdSlow <= config.macdFast {
                config.macdFast = max(2, config.macdSlow - 1)
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder body: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.Color.textMuted)
            body()
        }
    }

    /// Compact label-and-Stepper row. The value text is rendered in the
    /// HStack itself (not inside the Stepper's own label closure) because
    /// `.labelsHidden()` would otherwise drop it along with the implicit
    /// label, leaving just the +/- buttons.
    private func periodStepper(label: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Color.textSecondary)
            Spacer()
            Text("\(value.wrappedValue)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.Color.textPrimary)
                .frame(minWidth: 30, alignment: .trailing)
            Stepper("", value: value, in: range)
                .labelsHidden()
                .controlSize(.small)
        }
    }

    /// Same shape as `periodStepper` but for Doubles (e.g. UT Bot key
    /// value, which is a multiplier in the 0.5–3.0 range typically).
    private func doubleStepper(label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Color.textSecondary)
            Spacer()
            Text(String(format: "%.1f", value.wrappedValue))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.Color.textPrimary)
                .frame(minWidth: 36, alignment: .trailing)
            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
                .controlSize(.small)
        }
    }
}
