import SwiftUI

/// Popover / sheet panel allowing users to customize candle colors and chart background color,
/// along with one-tap preset palettes.
struct CustomThemeSheet: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("dashboard.chartTheme")          private var chartThemeRaw: String = ChartTheme.greenRed.rawValue
    @AppStorage("dashboard.customUpColorHex")   private var customUpHex: String = "#21C768"
    @AppStorage("dashboard.customDownColorHex") private var customDownHex: String = "#F04545"
    @AppStorage("dashboard.customBgColorHex")   private var customBgHex: String = "#12151C"

    private var customUpBinding: Binding<Color> {
        Binding(
            get: { Color(hex: customUpHex) ?? Theme.Color.success },
            set: {
                customUpHex = $0.toHex()
                chartThemeRaw = ChartTheme.custom.rawValue
            }
        )
    }

    private var customDownBinding: Binding<Color> {
        Binding(
            get: { Color(hex: customDownHex) ?? Theme.Color.danger },
            set: {
                customDownHex = $0.toHex()
                chartThemeRaw = ChartTheme.custom.rawValue
            }
        )
    }

    private var customBgBinding: Binding<Color> {
        Binding(
            get: { Color(hex: customBgHex) ?? Color(red: 0.07, green: 0.08, blue: 0.11) },
            set: {
                customBgHex = $0.toHex()
                chartThemeRaw = ChartTheme.custom.rawValue
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "paintpalette.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.Color.accentStart)
                    Text("Custom Chart Colors")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.Color.textPrimary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.Color.textMuted)
                }
                .buttonStyle(.plain)
            }

            Divider().background(Theme.Color.border)

            // Pickers
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("COLOR PALETTE")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Color.textMuted)

                HStack(spacing: Theme.Spacing.lg) {
                    ColorPicker("Bullish (Up)", selection: customUpBinding)
                        .font(.system(size: 12, weight: .medium))

                    ColorPicker("Bearish (Down)", selection: customDownBinding)
                        .font(.system(size: 12, weight: .medium))

                    ColorPicker("Chart Background", selection: customBgBinding)
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(Theme.Spacing.md)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.Color.surfaceHi))
            }

            // Quick Presets
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("QUICK PRESETS")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Color.textMuted)

                HStack(spacing: Theme.Spacing.sm) {
                    presetButton(title: "Classic", up: "#21C768", down: "#F04545", bg: "#12151C")
                    presetButton(title: "TradingView", up: "#2962FF", down: "#F04545", bg: "#131722")
                    presetButton(title: "Institutional", up: "#F2F5FA", down: "#596173", bg: "#0D0E12")
                    presetButton(title: "Cyberpunk", up: "#00F5D4", down: "#FF007F", bg: "#0D0221")
                    presetButton(title: "Gold", up: "#FFD700", down: "#FF4500", bg: "#0F0E17")
                }
            }

            Spacer()

            // Footer
            HStack {
                Button("Reset Defaults") {
                    customUpHex = "#21C768"
                    customDownHex = "#F04545"
                    customBgHex = "#12151C"
                    chartThemeRaw = ChartTheme.custom.rawValue
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textMuted)

                Spacer()

                Button("Done") {
                    chartThemeRaw = ChartTheme.custom.rawValue
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Theme.Color.accentStart)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 440, height: 280)
        .background(Theme.Color.canvas)
    }

    private func presetButton(title: String, up: String, down: String, bg: String) -> some View {
        Button {
            customUpHex = up
            customDownHex = down
            customBgHex = bg
            chartThemeRaw = ChartTheme.custom.rawValue
        } label: {
            HStack(spacing: 4) {
                Circle().fill(Color(hex: up) ?? .green).frame(width: 8, height: 8)
                Circle().fill(Color(hex: down) ?? .red).frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Color.textPrimary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(hex: bg) ?? Theme.Color.surfaceHi)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.Color.border, lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
    }
}
