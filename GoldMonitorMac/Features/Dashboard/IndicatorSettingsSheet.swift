import SwiftUI

/// Settings sheet for the panel oscillators (RSI / MACD / Stochastic).
/// Lives over the dashboard as a popover / sheet so the user can tune
/// periods without leaving the chart context. Edits write directly to
/// the bound config; the parent persists on dismiss.
struct IndicatorSettingsSheet: View {
    @Binding var config: OscillatorConfig
    /// When set, the sheet scrolls to this section on appear so the
    /// user lands directly on the tunables for the indicator they tapped.
    var focusSection: String? = nil
    @Environment(\.dismiss) private var dismiss

    /// Locally captured snapshot — if the user hits "Cancel" we restore
    /// this so accidental drags on a Stepper don't stick.
    @State private var original: OscillatorConfig?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack {
                Text(focusSection.map { "\($0) settings" } ?? "Indicator settings")
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

            // Scrollable so the sheet stays usable on a short display as
            // the indicator list grows — the header above and the Save /
            // Restore row below stay pinned outside this region.
            ScrollViewReader { proxy in
                ScrollView {
                    settingsSections
                }
                .frame(maxHeight: 520)
                .onAppear {
                    if let section = focusSection {
                        // Slight delay so the scroll view has laid out.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation { proxy.scrollTo(section, anchor: .top) }
                        }
                    }
                }
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

    /// The scrollable body of the sheet — every indicator's tunables.
    /// Pulled out of `body` so the header and the Save / Restore row can
    /// stay pinned outside the `ScrollView`.
    @ViewBuilder
    private var settingsSections: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
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
                    checkboxLabel("Show ATR trailing-stop line")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                Toggle(isOn: $config.utUseHeikinAshi) {
                    checkboxLabel("Use Heikin Ashi for signals")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
            }

            Divider().background(Theme.Color.border)

            section(title: "Order Blocks") {
                periodStepper(label: "Run length (periods)", value: $config.obPeriods, range: 1...20)
                doubleStepper(
                    label: "Min. % move",
                    value: $config.obThreshold,
                    range: 0.0...10.0,
                    step: 0.1
                )
                Toggle(isOn: $config.obUseWicks) {
                    checkboxLabel("Use whole high/low range")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                Toggle(isOn: $config.obShowExhausted) {
                    checkboxLabel("Show exhausted blocks")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                Toggle(isOn: $config.obDetectSteroids) {
                    checkboxLabel("Filter by volume (Steroids)")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                Toggle(isOn: $config.obNotifyEvents) {
                    checkboxLabel("Notify on appear / retest / exhaust")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
            }

            Divider().background(Theme.Color.border)

            section(title: "Steroid Order Blocks") {
                periodStepper(label: "Run length (periods)", value: $config.sobPeriods, range: 1...20)
                doubleStepper(
                    label: "Min. % move",
                    value: $config.sobThreshold,
                    range: 0.0...10.0,
                    step: 0.1
                )
                Toggle(isOn: $config.sobUseWicks) {
                    checkboxLabel("Use whole high/low range")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                doubleStepper(
                    label: "Volume multiplier",
                    value: $config.sobVolumeMultiplier,
                    range: 0.5...3.0,
                    step: 0.1
                )
                Toggle(isOn: $config.sobShowExhausted) {
                    checkboxLabel("Show exhausted blocks")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                Toggle(isOn: $config.sobDetectSteroids) {
                    checkboxLabel("Filter by volume (Steroids)")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                Toggle(isOn: $config.sobNotifyEvents) {
                    checkboxLabel("Notify on appear / retest / exhaust")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
            }

            Divider().background(Theme.Color.border)

            section(title: "Fair Value Gap") {
                doubleStepper(
                    label: "Min. gap size %",
                    value: $config.fvgThreshold,
                    range: 0.0...5.0,
                    step: 0.1
                )
                Toggle(isOn: $config.fvgShowMitigated) {
                    checkboxLabel("Show mitigated gaps")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
            }

            Divider().background(Theme.Color.border)

            section(title: "Sonarlab Order Blocks") {
                doubleStepper(
                    label: "Sensitivity (ROC threshold)",
                    value: $config.sonarlabSensitivity,
                    range: 1.0...100.0,
                    step: 1.0
                )
                Text("Lower = more blocks, higher = fewer blocks. Pine default: 26.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Mitigation type", selection: $config.sonarlabMitigationType) {
                    Text("Close").tag("Close")
                    Text("Wick").tag("Wick")
                }
                .pickerStyle(.segmented)
                Text("Close: block removed when prior close crosses boundary. Wick: uses current bar's high/low.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().background(Theme.Color.border)

            // Times shown match the baked presets in `TradingSessions.catalog`
            // (regular cash hours, each in its venue's own time zone).
            section(title: "Trading Sessions") {
                Toggle(isOn: $config.sessShowTokyo) {
                    checkboxLabel("Tokyo · 09:00–15:00 JST")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                Toggle(isOn: $config.sessShowLondon) {
                    checkboxLabel("London · 08:30–16:30 UK")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                Toggle(isOn: $config.sessShowNewYork) {
                    checkboxLabel("New York · 09:30–16:00 ET")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif

                Divider().background(Theme.Color.border.opacity(0.4))

                Toggle(isOn: $config.sessShowNames) {
                    checkboxLabel("Show session names")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                Toggle(isOn: $config.sessShowOpenClose) {
                    checkboxLabel("Draw open & close lines")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                Toggle(isOn: $config.sessShowRange) {
                    checkboxLabel("Show session range")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                Toggle(isOn: $config.sessShowAverage) {
                    checkboxLabel("Show average price line")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
            }

            Divider().background(Theme.Color.border)

            // Entry (FVG 50%), stop (beyond the OR) and target (2R) are
            // fixed by design — only the breakout-strength gate and the
            // hunting window are tunable here.
            section(title: "NY Open Setup") {
                doubleStepper(
                    label: "Breakout strength (× ATR)",
                    value: $config.nyAtrMult,
                    range: 0.0...5.0,
                    step: 0.1
                )
                Toggle(isOn: $config.nyAMOnly) {
                    checkboxLabel("AM kill-zone only (09:35–11:00 ET)")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                Text("Entry at FVG 50%, stop beyond the opening range, target 2R. 1m and 5m charts.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().background(Theme.Color.border)

            section(title: "Volume Profile") {
                Toggle(isOn: $config.vpUseZigzag) {
                    checkboxLabel("ZigZag trend mode (last trend only)")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                if config.vpUseZigzag {
                    Toggle(isOn: $config.vpShowZigzag) {
                        checkboxLabel("Show ZigZag lines on chart")
                    }
                    #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                    periodStepper(label: "ZigZag depth", value: $config.vpZZDepth, range: 2...50)
                    doubleStepper(
                        label: "ZigZag min change %",
                        value: $config.vpZZMinChange,
                        range: 0.1...10,
                        step: 0.5
                    )
                }
                periodStepper(label: "Buckets per session", value: $config.vpBucketCount, range: 10...100)
                doubleStepper(
                    label: "Value Area %",
                    value: $config.vpValueAreaPct,
                    range: 50...95,
                    step: 5.0
                )
                Text(config.vpUseZigzag
                     ? "Shows a volume profile for the current ZigZag trend segment only, placed on the right side of the chart."
                     : "Computes a per-day volume profile with POC and value area (VAH/VAL). Works best on intraday timeframes with volume data.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Standard styling for a checkbox toggle's text label — shared by the
    /// UT Bot / Order Block / Trading Session boolean rows.
    private func checkboxLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.Color.textSecondary)
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder body: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.Color.textMuted)
                .id(title)  // anchor for ScrollViewReader scroll-to
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
        }
    }
}
