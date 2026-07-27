import SwiftUI

/// Institutional Strategy Sentinel Radar HUD Component.
/// Provides real-time ranked signal monitoring across Order Block engines
/// with interactive direction filters, R:R thresholds, volume rank medals,
/// visual confluence score breakdowns, interactive Guide Wizard, and prominent per-card Info Detail Popovers.
struct StrategyRadarHUDView: View {
    @ObservedObject var sentinel = StrategySentinel.shared
    @EnvironmentObject var app: AppState

    var livePrice: Double? = nil
    var onSelectAlert: ((RadarAlert) -> Void)?
    var onHoverAlert: ((RadarAlert?) -> Void)?

    @State private var selectedDirection: SetupDirectionFilter = .all
    @State private var minRRFilter: Double = 0.0
    @State private var minVolumeFilter: Double = 0.0
    @AppStorage("dashboard.sentinelCollapsed") private var isCollapsed: Bool = true
    @State private var hoveredAlertID: UUID?
    @State private var isPulseAnimating: Bool = false
    @State private var showGuidePopover: Bool = false
    @State private var activePopoverAlertID: UUID?

    enum SetupDirectionFilter: String, CaseIterable {
        case all = "ALL"
        case buy = "LONGS"
        case sell = "SHORTS"
        case htf = "⚡ HTF NESTED"
    }

    private var currentPairID: String? {
        app.selectedPairID
    }

    private var symbolAlerts: [RadarAlert] {
        guard let pairID = currentPairID else { return [] }
        return sentinel.activeRadarAlerts.filter { $0.pairID == pairID }
    }

    /// Dynamically calculated volume threshold steps based on current active signal volume distribution
    private var volumeThresholds: [(label: String, value: Double)] {
        let vols = symbolAlerts.compactMap { $0.tradedVolume }.filter { $0 > 0 }.sorted()
        guard !vols.isEmpty else {
            return [("ALL VOL", 0.0)]
        }

        var thresholds: [(label: String, value: Double)] = [("ALL VOL", 0.0)]

        let p25 = vols[Int(Double(vols.count - 1) * 0.25)]
        let p50 = vols[Int(Double(vols.count - 1) * 0.50)]
        let p75 = vols[Int(Double(vols.count - 1) * 0.75)]

        if p25 > 0 {
            thresholds.append(("≥ \(formatVolume(p25))", p25))
        }
        if p50 > p25 {
            thresholds.append(("≥ \(formatVolume(p50))", p50))
        }
        if p75 > p50 {
            thresholds.append(("≥ \(formatVolume(p75))", p75))
        }

        return thresholds
    }

    private func formatVolume(_ vol: Double) -> String {
        if vol >= 1_000_000 {
            return String(format: "%.1fM", vol / 1_000_000)
        } else if vol >= 1_000 {
            return String(format: "%.1fk", vol / 1_000)
        } else {
            return String(format: "%.0f", vol)
        }
    }

    /// Filter & rank alerts for the active symbol, sorted by entry price proximity to live chart price
    private var filteredAlerts: [RadarAlert] {
        guard let pairID = currentPairID else { return [] }
        let raw = sentinel.activeRadarAlerts.filter { alert in
            guard alert.pairID == pairID else { return false }

            // Direction & HTF Filter
            switch selectedDirection {
            case .all: break
            case .buy: guard alert.direction == .buy else { return false }
            case .sell: guard alert.direction == .sell else { return false }
            case .htf: guard alert.isHTFNested else { return false }
            }

            // Min R:R Filter
            if minRRFilter > 0 {
                guard alert.riskRewardRatio >= minRRFilter else { return false }
            }

            // Min Volume Filter
            if minVolumeFilter > 0 {
                guard (alert.tradedVolume ?? 0) >= minVolumeFilter - 0.001 else { return false }
            }

            return true
        }

        // Sort by nearest entry price to live market price (if available)
        if let currentPrice = livePrice, currentPrice > 0 {
            return raw.sorted { a1, a2 in
                abs(a1.entryPrice - currentPrice) < abs(a2.entryPrice - currentPrice)
            }
        } else {
            return raw.sorted { $0.confluenceScore > $1.confluenceScore }
        }
    }

    var body: some View {
        if !sentinel.activeRadarAlerts.filter({ $0.pairID == currentPairID }).isEmpty {
            HStack(spacing: Theme.Spacing.sm) {
                // Live Sentinel Pulse Indicator
                HStack(spacing: 4) {
                    Circle()
                        .fill(Theme.Color.success)
                        .frame(width: 5, height: 5)

                    Text("SENTINEL")
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .foregroundStyle(Theme.Color.textPrimary)
                }

                Divider()
                    .frame(height: 12)

                if isCollapsed {
                    // Collapsed View: Quick summary text
                    Text("\(filteredAlerts.count) SETUPS RANKED")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.Color.textMuted)
                    Spacer()
                } else {
                    // Direction Filter Chips
                    HStack(spacing: 2) {
                        ForEach(SetupDirectionFilter.allCases, id: \.self) { filter in
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selectedDirection = filter
                                }
                            } label: {
                                Text(filter.rawValue)
                                    .font(.system(size: 8, weight: .bold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(selectedDirection == filter ? Theme.Color.accentStart : Theme.Color.surfaceHi.opacity(0.6))
                                    .foregroundStyle(selectedDirection == filter ? .white : Theme.Color.textMuted)
                                    .cornerRadius(3)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Divider()
                        .frame(height: 12)

                    // Scrollable Cards Carousel inline in the EXACT same 28px row!
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(filteredAlerts) { alert in
                                sentinelCard(for: alert)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    .contentShape(Rectangle())
                }

                // Guide Button
                Button {
                    showGuidePopover.toggle()
                } label: {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.Color.accentStart)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showGuidePopover, arrowEdge: .bottom) {
                    SentinelGuideView()
                }

                // Collapse/Expand Toggle
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isCollapsed.toggle()
                    }
                } label: {
                    HStack(spacing: 3) {
                        if isCollapsed {
                            Text("\(filteredAlerts.count)")
                                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                        }
                        Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Theme.Color.surfaceHi)
                    .foregroundStyle(Theme.Color.textMuted)
                    .cornerRadius(3)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .frame(height: 28)
            .background(Theme.Color.surface.opacity(0.92))
            .cornerRadius(Theme.Radius.md)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .strokeBorder(Theme.Color.accentStart.opacity(0.35), lineWidth: 1)
            )
        }
    }

    // MARK: - Redesigned Single-Row Micro Sentinel Card
    private func sentinelCard(for alert: RadarAlert) -> some View {
        let isBuy = alert.direction == .buy
        let dirColor = isBuy ? Theme.Color.success : Theme.Color.danger
        let rank = alert.volumeRank ?? 1
        let isHovered = hoveredAlertID == alert.id
        let isPopoverActive = Binding<Bool>(
            get: { activePopoverAlertID == alert.id },
            set: { active -> Void in
                if active { activePopoverAlertID = alert.id }
                else if activePopoverAlertID == alert.id { activePopoverAlertID = nil }
            }
        )

        return HStack(spacing: 4) {
            Text(rankMedal(rank))
                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(rankColor(rank).opacity(0.20))
                .foregroundStyle(rankColor(rank))
                .cornerRadius(3)

            Text(alert.symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.Color.textPrimary)

            Text(alert.direction.rawValue)
                .font(.system(size: 8, weight: .heavy))
                .padding(.horizontal, 3)
                .padding(.vertical, 0.5)
                .background(dirColor.opacity(0.20))
                .foregroundStyle(dirColor)
                .cornerRadius(3)

            if alert.isHTFNested {
                Text("⚡HTF")
                    .font(.system(size: 7, weight: .heavy, design: .monospaced))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 0.5)
                    .background(Color(red: 1.00, green: 0.84, blue: 0.00).opacity(0.25))
                    .foregroundStyle(Color(red: 1.00, green: 0.84, blue: 0.00))
                    .cornerRadius(3)
            }

            Text(PriceFormat.exact(alert.entryPrice))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.Color.textPrimary)

            Text("(\(String(format: "%.1fx", alert.riskRewardRatio)))")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.Color.accentStart)

            Button {
                activePopoverAlertID = alert.id
            } label: {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.Color.accentStart)
            }
            .buttonStyle(.plain)
            .popover(isPresented: isPopoverActive, arrowEdge: .bottom) {
                AlertDetailView(alert: alert) {
                    activePopoverAlertID = nil
                    onSelectAlert?(alert)
                }
            }

            Button {
                onSelectAlert?(alert)
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.Color.accentStart)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Theme.Color.surfaceHi.opacity(0.7))
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isHovered ? Theme.Color.accentStart : Color.clear, lineWidth: 1.0)
        )
        .onHover { isHovered in
            if isHovered {
                hoveredAlertID = alert.id
                onHoverAlert?(alert)
            } else if hoveredAlertID == alert.id {
                hoveredAlertID = nil
                onHoverAlert?(nil)
            }
        }
    }

    private func rankMedal(_ rank: Int) -> String {
        switch rank {
        case 1:  return "🥇 #1"
        case 2:  return "🥈 #2"
        case 3:  return "🥉 #3"
        default: return "🏅 #\(rank)"
        }
    }

    private func rankColor(_ rank: Int) -> Color {
        switch rank {
        case 1:  return Color(red: 1.00, green: 0.84, blue: 0.00) // Gold
        case 2:  return Color(red: 0.75, green: 0.75, blue: 0.75) // Silver
        case 3:  return Color(red: 0.80, green: 0.50, blue: 0.20) // Bronze
        default: return Color(red: 0.15, green: 0.85, blue: 0.95) // Cyan
        }
    }
}

// MARK: - Per-Alert Info Detail View

struct AlertDetailView: View {
    let alert: RadarAlert
    var onStageTrade: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // Header
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.Color.accentStart)

                Text("\(alert.symbol) \(alert.direction.rawValue) Setup Details")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.Color.textPrimary)

                Spacer()

                Text("Rank #\(alert.volumeRank ?? 1)")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(red: 1.00, green: 0.84, blue: 0.00).opacity(0.20))
                    .foregroundStyle(Color(red: 1.00, green: 0.84, blue: 0.00))
                    .cornerRadius(4)
            }

            Divider()

            // Why it was selected Rationale Box
            VStack(alignment: .leading, spacing: 4) {
                Text("WHY THIS POSITION WAS SELECTED")
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Theme.Color.accentStart)

                Text(alert.rationale)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Spacing.sm)
            .glassmorphicCard(cornerRadius: Theme.Radius.sm)

            // Setup Properties Grid
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("SETUP METRICS & PROPERTIES")
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Theme.Color.textMuted)

                Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.lg, verticalSpacing: 6) {
                    GridRow {
                        Text("Pair / Symbol:").font(.system(size: 10)).foregroundStyle(Theme.Color.textMuted)
                        Text("\(alert.symbol) (\(alert.timeframe))").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.Color.textPrimary)
                    }
                    GridRow {
                        Text("Traded Volume:").font(.system(size: 10)).foregroundStyle(Theme.Color.textMuted)
                        Text(formatVol(alert.tradedVolume)).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Color(red: 0.15, green: 0.85, blue: 0.95))
                    }
                    GridRow {
                        Text("Confluence Score:").font(.system(size: 10)).foregroundStyle(Theme.Color.textMuted)
                        Text("\(alert.confluenceScore)%").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Theme.Color.accentStart)
                    }
                    GridRow {
                        Text("Entry Price:").font(.system(size: 10)).foregroundStyle(Theme.Color.textMuted)
                        Text(PriceFormat.exact(alert.entryPrice)).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Theme.Color.textPrimary)
                    }
                    GridRow {
                        Text("Stop Loss:").font(.system(size: 10)).foregroundStyle(Theme.Color.textMuted)
                        Text(PriceFormat.exact(alert.stopLoss)).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Theme.Color.danger)
                    }
                    GridRow {
                        Text("Take Profit:").font(.system(size: 10)).foregroundStyle(Theme.Color.textMuted)
                        Text(PriceFormat.exact(alert.takeProfit)).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Theme.Color.success)
                    }
                    GridRow {
                        Text("Risk-to-Reward:").font(.system(size: 10)).foregroundStyle(Theme.Color.textMuted)
                        Text(String(format: "%.2fx R:R", alert.riskRewardRatio)).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Theme.Color.success)
                    }
                }
            }

            Divider()

            // Stage Trade Action Button
            Button {
                onStageTrade()
            } label: {
                HStack {
                    Spacer()
                    Image(systemName: "plus.circle.fill")
                    Text("STAGE POSITION ON CHART")
                        .font(.system(size: 11, weight: .bold))
                    Spacer()
                }
                .padding(.vertical, Theme.Spacing.sm)
                .background(Theme.Color.accentStart)
                .foregroundStyle(.white)
                .cornerRadius(Theme.Radius.sm)
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.Spacing.md)
        .frame(width: 380)
        .background(Theme.Color.surface)
    }

    private func formatVol(_ vol: Double?) -> String {
        guard let v = vol else { return "N/A" }
        if v >= 1_000_000 {
            return String(format: "%.1fM accumulated", v / 1_000_000)
        } else if v >= 1_000 {
            return String(format: "%.1fk accumulated", v / 1_000)
        } else {
            return String(format: "%.0f accumulated", v)
        }
    }
}

// MARK: - Sentinel Guide Wizard View

struct SentinelGuideView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // Header
            HStack {
                Image(systemName: "book.fill")
                    .foregroundStyle(Theme.Color.accentStart)
                Text("Sentinel Signal Guide & Color Legend")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.Color.textPrimary)
            }

            Divider()

            // 1. Sample Annotated Card
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("SAMPLE SENTINEL RADAR CARD")
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Theme.Color.textMuted)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text("🥇 #1")
                            .font(.system(size: 9, weight: .heavy, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color(red: 1.00, green: 0.84, blue: 0.00).opacity(0.20))
                            .foregroundStyle(Color(red: 1.00, green: 0.84, blue: 0.00))
                            .cornerRadius(3)

                        Text("XAU/USD")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.Color.textPrimary)

                        Text("BUY")
                            .font(.system(size: 9, weight: .heavy))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Theme.Color.success.opacity(0.20))
                            .foregroundStyle(Theme.Color.success)
                            .cornerRadius(3)

                        Spacer()

                        HStack(spacing: 2) {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 11, weight: .bold))
                            Text("INFO")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(Theme.Color.accentStart.opacity(0.25))
                        .foregroundStyle(Theme.Color.accentStart)
                        .cornerRadius(3)

                        Text("95% Confluence")
                            .font(.system(size: 10, weight: .heavy, design: .monospaced))
                            .foregroundStyle(Theme.Color.accentStart)
                    }

                    // Score breakdown
                    HStack(spacing: 2) {
                        Rectangle().fill(Color(red: 0.15, green: 0.85, blue: 0.95)).frame(height: 3)
                        Rectangle().fill(Color(red: 0.75, green: 0.35, blue: 0.95)).frame(height: 3)
                        Rectangle().fill(Theme.Color.success).frame(height: 3)
                    }
                    .cornerRadius(1.5)

                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("ENTRY").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.Color.textMuted)
                            Text("2650.10").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.Color.textPrimary)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text("TARGET").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.Color.textMuted)
                            Text("2668.50").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.Color.success)
                        }
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("R:R").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.Color.textMuted)
                            Text("2.45x").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Theme.Color.accentStart)
                        }

                        Spacer()

                        HStack(spacing: 3) {
                            Image(systemName: "plus.circle.fill").font(.system(size: 13, weight: .bold))
                            Text("STAGE").font(.system(size: 9, weight: .heavy))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Theme.Color.accentStart)
                        .foregroundStyle(.white)
                        .cornerRadius(4)
                    }
                }
                .padding(Theme.Spacing.sm)
                .glassmorphicCard(cornerRadius: Theme.Radius.sm)
            }

            // 2. Color & Rank Legend
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("RANK MEDALS & COLORS")
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Theme.Color.textMuted)

                Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.md, verticalSpacing: 6) {
                    GridRow {
                        HStack(spacing: 4) {
                            Text("🥇 Gold").font(.system(size: 10, weight: .bold)).foregroundStyle(Color(red: 1.00, green: 0.84, blue: 0.00))
                        }
                        Text("Rank #1 — Highest traded volume in the market structure.").font(.system(size: 10)).foregroundStyle(Theme.Color.textMuted)
                    }
                    GridRow {
                        HStack(spacing: 4) {
                            Text("🥈 Silver").font(.system(size: 10, weight: .bold)).foregroundStyle(Color(red: 0.75, green: 0.75, blue: 0.75))
                        }
                        Text("Rank #2 — 2nd highest traded volume zone.").font(.system(size: 10)).foregroundStyle(Theme.Color.textMuted)
                    }
                    GridRow {
                        HStack(spacing: 4) {
                            Text("🥉 Bronze").font(.system(size: 10, weight: .bold)).foregroundStyle(Color(red: 0.80, green: 0.50, blue: 0.20))
                        }
                        Text("Rank #3 — 3rd highest traded volume zone.").font(.system(size: 10)).foregroundStyle(Theme.Color.textMuted)
                    }
                    GridRow {
                        HStack(spacing: 4) {
                            Text("🩵 Cyan").font(.system(size: 10, weight: .bold)).foregroundStyle(Color(red: 0.15, green: 0.85, blue: 0.95))
                        }
                        Text("Volume Profile Node & Volume-Ranked OB.").font(.system(size: 10)).foregroundStyle(Theme.Color.textMuted)
                    }
                    GridRow {
                        HStack(spacing: 4) {
                            Text("💜 Purple").font(.system(size: 10, weight: .bold)).foregroundStyle(Color(red: 0.75, green: 0.35, blue: 0.95))
                        }
                        Text("RVOL Impulse Volume Spike (>1.2x SMA).").font(.system(size: 10)).foregroundStyle(Theme.Color.textMuted)
                    }
                    GridRow {
                        HStack(spacing: 4) {
                            Text("💚 Green").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.Color.success)
                        }
                        Text("BUY (Long) Direction / Support Zone.").font(.system(size: 10)).foregroundStyle(Theme.Color.textMuted)
                    }
                    GridRow {
                        HStack(spacing: 4) {
                            Text("❤️ Red").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.Color.danger)
                        }
                        Text("SELL (Short) Direction / Resistance Zone.").font(.system(size: 10)).foregroundStyle(Theme.Color.textMuted)
                    }
                }
            }

            // 3. Quick How-To
            VStack(alignment: .leading, spacing: 2) {
                Text("HOW TO USE")
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Theme.Color.textMuted)
                Text("• Click the cyan (i) INFO button on any card to see why it was selected and its volume stats.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text("• Click STAGE or anywhere on the card to stage the position tool and open the 1% risk trade box.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textPrimary)
            }
        }
        .padding(Theme.Spacing.md)
        .frame(width: 440)
        .background(Theme.Color.surface)
    }
}
