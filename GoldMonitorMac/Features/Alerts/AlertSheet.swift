import SwiftUI

/// Alerts manager for the current pair. Single sheet with two
/// sections:
///   • **Current alerts** — every alert on this pair, with
///     per-row enable/disable toggle, re-arm (for fired alerts),
///     and delete.
///   • **Create alert** — form for adding a new price-cross or
///     RSI-cross alert. RSI threshold defaults to 70 / 30
///     (overbought / oversold canonical levels).
///
/// Scenario-derived alerts (entry / SL auto-created when an AI
/// scenario lands on the chart) show in the list with their
/// origin badged so the user knows they were auto-installed.
struct AlertSheet: View {
    let pairID: String
    let pairName: String
    let livePrice: Double?
    var onCreate: (PriceAlert) -> Void

    @EnvironmentObject private var store: AlertStore
    @Environment(\.dismiss) private var dismiss

    @State private var kind: NewKind = .priceCross
    @State private var direction: Direction = .crossUp
    @State private var level: Double = 0
    @State private var rsiSide: RSISide = .above
    @State private var rsiLevel: Double = 70

    enum NewKind: String, CaseIterable, Identifiable {
        case priceCross, rsi
        var id: String { rawValue }
        var label: String {
            switch self {
            case .priceCross: return "Price cross"
            case .rsi:        return "RSI"
            }
        }
    }

    enum Direction: String, CaseIterable, Identifiable {
        case crossUp, crossDown
        var id: String { rawValue }
        var label: String { self == .crossUp ? "Cross UP" : "Cross DOWN" }
        var kind: PriceAlert.Kind { self == .crossUp ? .crossUp : .crossDown }
    }

    enum RSISide: String, CaseIterable, Identifiable {
        case above, below
        var id: String { rawValue }
        var label: String { self == .above ? "RSI above" : "RSI below" }
        var kind: PriceAlert.Kind { self == .above ? .rsiCrossAbove : .rsiCrossBelow }
    }

    private var alerts: [PriceAlert] {
        store.alerts(for: pairID).sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Theme.Color.border)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    currentAlertsSection
                    createSection
                }
                .padding(Theme.Spacing.xl)
            }
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 480, idealHeight: 560)
        .background(Theme.Color.surfaceHi)
        .onAppear {
            if level == 0, let live = livePrice { level = live }
        }
    }

    // ── Header ────────────────────────────────────────────────────
    private var header: some View {
        HStack {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.Color.warn)
            Text("Alerts · \(pairName)")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.Color.textPrimary)
            if let live = livePrice {
                Text("· \(PriceFormat.exact(live))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.Color.textMuted)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surface))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
    }

    // ── Current alerts list ──────────────────────────────────────
    private var currentAlertsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text("CURRENT ALERTS")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Color.textMuted)
                Spacer()
                Text("\(alerts.count) total")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textMuted)
            }
            if alerts.isEmpty {
                Text("No alerts on this pair yet. Add one below.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textMuted)
                    .padding(.vertical, Theme.Spacing.sm)
            } else {
                ForEach(alerts) { alert in
                    alertRow(alert)
                }
            }
        }
    }

    private func alertRow(_ alert: PriceAlert) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            // Kind chip — single letter for compactness.
            Text(kindGlyph(alert.kind))
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(kindTint(alert.kind)))

            VStack(alignment: .leading, spacing: 2) {
                Text(alertSummary(alert))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.Color.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(alertStatusText(alert))
                        .font(.system(size: 9, weight: .heavy))
                        .tracking(0.4)
                        .foregroundStyle(alertStatusTint(alert))
                    if alert.sourceScenarioID != nil {
                        Text("· auto from scenario")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.Color.textMuted)
                    }
                }
            }

            Spacer()

            // Re-arm — only meaningful for fired alerts.
            if alert.firedAt != nil {
                Button {
                    store.reArm(id: alert.id)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Color.accentStart)
                        .frame(width: 24, height: 24)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.Color.surface))
                }
                .buttonStyle(.plain)
                .help("Re-arm so it fires again on the next cross.")
            }

            // Enable / disable.
            Toggle("", isOn: Binding(
                get: { alert.enabled },
                set: { store.setEnabled($0, id: alert.id) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(Theme.Color.accentStart)
            .labelsHidden()

            // Delete.
            Button {
                store.remove(id: alert.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textMuted)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.Color.surface))
            }
            .buttonStyle(.plain)
            .help("Delete this alert.")
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surface)
        )
    }

    private func kindGlyph(_ k: PriceAlert.Kind) -> String {
        switch k {
        case .crossUp:        return "↑"
        case .crossDown:      return "↓"
        case .scenarioEntry:  return "E"
        case .scenarioSL:     return "SL"
        case .rsiCrossAbove:  return "R↑"
        case .rsiCrossBelow:  return "R↓"
        }
    }

    private func kindTint(_ k: PriceAlert.Kind) -> Color {
        switch k {
        case .crossUp, .scenarioEntry:        return Theme.Color.success
        case .crossDown, .scenarioSL:         return Theme.Color.danger
        case .rsiCrossAbove:                  return Theme.Color.warn
        case .rsiCrossBelow:                  return Theme.Color.info
        }
    }

    private func alertSummary(_ a: PriceAlert) -> String {
        switch a.kind {
        case .crossUp:        return "Cross UP @ \(PriceFormat.exact(a.level))"
        case .crossDown:      return "Cross DOWN @ \(PriceFormat.exact(a.level))"
        case .scenarioEntry:  return "Entry @ \(PriceFormat.exact(a.level))"
        case .scenarioSL:     return "Stop loss @ \(PriceFormat.exact(a.level))"
        case .rsiCrossAbove:  return "RSI crosses above \(String(format: "%.0f", a.level))"
        case .rsiCrossBelow:  return "RSI crosses below \(String(format: "%.0f", a.level))"
        }
    }

    private func alertStatusText(_ a: PriceAlert) -> String {
        if !a.enabled                  { return "DISABLED" }
        if a.firedAt != nil            { return "FIRED" }
        return "ARMED"
    }

    private func alertStatusTint(_ a: PriceAlert) -> Color {
        if !a.enabled                  { return Theme.Color.textMuted }
        if a.firedAt != nil            { return Theme.Color.textSecondary }
        return Theme.Color.warn
    }

    // ── Create section ───────────────────────────────────────────
    private var createSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("CREATE NEW ALERT")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)

            kindPicker

            switch kind {
            case .priceCross: priceCrossForm
            case .rsi:        rsiForm
            }

            HStack {
                Spacer()
                Button {
                    if let alert = composeAlert() {
                        onCreate(alert)
                        // Reset draft so the sheet is ready for
                        // another alert if the user wants to add
                        // multiple in one sitting.
                        level = livePrice ?? 0
                    }
                } label: {
                    Label("Add alert", systemImage: "bell.badge.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Color.warn))
                }
                .buttonStyle(.plain)
                .disabled(!canCompose)
                .opacity(canCompose ? 1 : 0.4)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var kindPicker: some View {
        HStack(spacing: 6) {
            ForEach(NewKind.allCases) { k in
                Button {
                    kind = k
                } label: {
                    Text(k.label)
                        .font(.system(size: 11, weight: kind == k ? .bold : .medium))
                        .foregroundStyle(kind == k ? .white : Theme.Color.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(kind == k
                                      ? AnyShapeStyle(Theme.accentGradient)
                                      : AnyShapeStyle(Theme.Color.surface))
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private var priceCrossForm: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: 6) {
                ForEach(Direction.allCases) { d in
                    Button { direction = d } label: {
                        Text(d.label)
                            .font(.system(size: 11, weight: direction == d ? .bold : .medium))
                            .foregroundStyle(direction == d ? .white : Theme.Color.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(direction == d
                                          ? AnyShapeStyle(d == .crossUp ? Theme.Color.success : Theme.Color.danger)
                                          : AnyShapeStyle(Theme.Color.surface))
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("LEVEL")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Color.textMuted)
                TextField("Price", value: $level, format: .number.precision(.fractionLength(0...4)))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 160)
                    .font(.system(size: 14, weight: .bold).monospacedDigit())
            }
        }
    }

    private var rsiForm: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: 6) {
                ForEach(RSISide.allCases) { s in
                    Button {
                        rsiSide = s
                        // Snap to the canonical level for the side
                        // the first time the user flips it.
                        if s == .above && rsiLevel < 50 { rsiLevel = 70 }
                        if s == .below && rsiLevel > 50 { rsiLevel = 30 }
                    } label: {
                        Text(s.label)
                            .font(.system(size: 11, weight: rsiSide == s ? .bold : .medium))
                            .foregroundStyle(rsiSide == s ? .white : Theme.Color.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(rsiSide == s
                                          ? AnyShapeStyle(s == .above ? Theme.Color.warn : Theme.Color.info)
                                          : AnyShapeStyle(Theme.Color.surface))
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("RSI THRESHOLD (0–100)")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Color.textMuted)
                HStack {
                    Slider(value: $rsiLevel, in: 1...99, step: 1)
                        .tint(rsiSide == .above ? Theme.Color.warn : Theme.Color.info)
                    Text("\(Int(rsiLevel))")
                        .font(.system(size: 14, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.Color.textPrimary)
                        .frame(width: 32, alignment: .trailing)
                }
                Text(rsiSide == .above
                     ? "Canonical overbought level is 70. Cross above this means momentum is reaching extreme upside."
                     : "Canonical oversold level is 30. Cross below this means momentum is reaching extreme downside.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var canCompose: Bool {
        switch kind {
        case .priceCross: return level > 0
        case .rsi:        return rsiLevel >= 1 && rsiLevel <= 99
        }
    }

    private func composeAlert() -> PriceAlert? {
        switch kind {
        case .priceCross:
            guard level > 0 else { return nil }
            return PriceAlert(
                id: UUID(),
                pairID: pairID,
                kind: direction.kind,
                level: level,
                title: "\(pairName) — \(direction.label.lowercased()) \(PriceFormat.exact(level))",
                body: "Price \(direction == .crossUp ? "rose through" : "fell through") \(PriceFormat.exact(level)).",
                createdAt: Date(),
                firedAt: nil,
                enabled: true,
                sourceScenarioID: nil
            )
        case .rsi:
            let threshold = Int(rsiLevel)
            return PriceAlert(
                id: UUID(),
                pairID: pairID,
                kind: rsiSide.kind,
                level: Double(threshold),
                title: "\(pairName) — RSI \(rsiSide == .above ? "above" : "below") \(threshold)",
                body: "RSI(14) crossed \(rsiSide == .above ? "above" : "below") \(threshold) on the dashboard's analysis timeframe.",
                createdAt: Date(),
                firedAt: nil,
                enabled: true,
                sourceScenarioID: nil
            )
        }
    }
}
