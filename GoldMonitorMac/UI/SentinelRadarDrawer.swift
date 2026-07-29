import SwiftUI

/// Strategy Sentinel 2.0 drawer — an institutional-grade, highly interactive
/// trade radar sliding out from the chart's right edge.
/// Setups are categorized by stage (IN ZONE, PENDING, REACTION, ALL), filterable
/// by direction / HTF / volume / confidence score, and feature real-time spatial
/// price distance tracking, score breakdown accordions, and 1-click chart focus.
struct SentinelRadarDrawer: View {
    @ObservedObject var sentinel = StrategySentinel.shared
    @EnvironmentObject var app: AppState

    var livePrice: Double? = nil
    var onSelectAlert: ((RadarAlert) -> Void)?
    var onHoverAlert: ((RadarAlert?) -> Void)?
    var onFocusAlert: ((RadarAlert) -> Void)?

    @AppStorage("dashboard.sentinelDrawerExpanded") private var isExpanded: Bool = false
    @State private var selectedStage: StageTab = .all
    @State private var selectedDirection: DirectionFilter = .all
    @State private var htfOnly: Bool = false
    @State private var minVolumeFilter: Double = 0.0
    @State private var minScoreFilter: Int = 0
    @State private var hoveredAlertID: UUID?
    @State private var expandedAccordionAlertID: UUID?
    @State private var activePopoverAlertID: UUID?

    enum StageTab: String, CaseIterable {
        case inZone = "🔥 IN ZONE"
        case pending = "⏳ PENDING"
        case reaction = "🚀 REACTION"
        case all = "📊 ALL"
    }

    enum DirectionFilter: String, CaseIterable {
        case all = "ALL"
        case buy = "LONG"
        case sell = "SHORT"
    }

    private var currentPairID: String? {
        app.selectedPairID
    }

    private var symbolAlerts: [RadarAlert] {
        guard let pairID = currentPairID else { return [] }
        return sentinel.activeRadarAlerts.filter { $0.pairID == pairID }
    }

    private let confidenceThresholds: [(label: String, value: Int)] = [
        ("ALL SCORE", 0),
        ("≥ 60%", 60),
        ("≥ 70%", 70),
        ("≥ 80%", 80),
        ("≥ 90%", 90)
    ]

    private var volumeThresholds: [(label: String, value: Double)] {
        let vols = symbolAlerts.compactMap { $0.tradedVolume }.filter { $0 > 0 }.sorted()
        guard !vols.isEmpty else {
            return [("ALL VOL", 0.0)]
        }

        var thresholds: [(label: String, value: Double)] = [("ALL VOL", 0.0)]

        let p25 = vols[Int(Double(vols.count - 1) * 0.25)]
        let p50 = vols[Int(Double(vols.count - 1) * 0.50)]
        let p75 = vols[Int(Double(vols.count - 1) * 0.75)]

        if p25 > 0 { thresholds.append(("≥ \(Self.formatVolume(p25))", p25)) }
        if p50 > p25 { thresholds.append(("≥ \(Self.formatVolume(p50))", p50)) }
        if p75 > p50 { thresholds.append(("≥ \(Self.formatVolume(p75))", p75)) }

        return thresholds
    }

    private var filteredAlerts: [RadarAlert] {
        let raw = symbolAlerts.filter { alert in
            switch selectedStage {
            case .inZone: guard alert.status == .inZone else { return false }
            case .pending: guard alert.status == .pending else { return false }
            case .reaction: guard alert.status == .reaction else { return false }
            case .all: break
            }

            switch selectedDirection {
            case .all: break
            case .buy: guard alert.direction == .buy else { return false }
            case .sell: guard alert.direction == .sell else { return false }
            }

            if htfOnly {
                guard alert.isHTFNested else { return false }
            }

            if minVolumeFilter > 0 {
                guard (alert.tradedVolume ?? 0) >= minVolumeFilter - 0.001 else { return false }
            }

            if minScoreFilter > 0 {
                guard alert.confluenceScore >= minScoreFilter else { return false }
            }

            return true
        }

        if let currentPrice = livePrice, currentPrice > 0 {
            return raw.sorted { a1, a2 in
                abs(a1.entryPrice - currentPrice) < abs(a2.entryPrice - currentPrice)
            }
        } else {
            return raw.sorted { $0.confluenceScore > $1.confluenceScore }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            if isExpanded {
                panel
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            rail
        }
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }

    // MARK: - Rail

    private var rail: some View {
        Button {
            isExpanded.toggle()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.right" : "chevron.left")
                    .font(.system(size: 9, weight: .heavy))

                Text("\(symbolAlerts.count)")
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Theme.Color.accentStart.opacity(symbolAlerts.isEmpty ? 0.15 : 0.9)))
                    .foregroundStyle(symbolAlerts.isEmpty ? Theme.Color.textMuted : .white)

                Text("SENTINEL 2.0")
                    .font(.system(size: 8, weight: .heavy, design: .monospaced))
                    .rotationEffect(.degrees(-90))
                    .fixedSize()
                    .frame(width: 12)
                    .padding(.vertical, 32)
            }
            .foregroundStyle(Theme.Color.textMuted)
            .padding(.vertical, Theme.Spacing.sm)
            .frame(width: 26)
            .frame(maxHeight: .infinity)
            .background(Theme.Color.surface.opacity(0.92))
            .overlay(
                Rectangle()
                    .fill(Theme.Color.accentStart.opacity(0.35))
                    .frame(width: 1),
                alignment: .leading
            )
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Collapse Strategy Sentinel" : "Expand Strategy Sentinel")
    }

    // MARK: - Panel (300px Width)

    private var panel: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            // Header
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.Color.success)
                    .frame(width: 6, height: 6)

                Text("SENTINEL RADAR 2.0")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Theme.Color.textPrimary)

                Spacer()

                Text("\(filteredAlerts.count)/\(symbolAlerts.count)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.Color.textMuted)
            }

            // Stage Tabs Bar (🔥 IN ZONE / ⏳ PENDING / 🚀 REACTION / 📊 ALL)
            HStack(spacing: 3) {
                ForEach(StageTab.allCases, id: \.self) { stage in
                    Button {
                        selectedStage = stage
                    } label: {
                        Text(stage.rawValue)
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 3)
                            .background(selectedStage == stage ? Theme.Color.accentStart : Theme.Color.surfaceHi.opacity(0.6))
                            .foregroundStyle(selectedStage == stage ? .white : Theme.Color.textMuted)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Direction + HTF + Volume + Score Filters Row
            HStack(spacing: 4) {
                ForEach(DirectionFilter.allCases, id: \.self) { filter in
                    filterChip(filter.rawValue, isActive: selectedDirection == filter) {
                        selectedDirection = filter
                    }
                }

                filterChip("⚡ HTF", isActive: htfOnly) {
                    htfOnly.toggle()
                }

                Spacer()

                // Volume filter dropdown
                Menu {
                    ForEach(volumeThresholds, id: \.value) { threshold in
                        Button(threshold.label) {
                            minVolumeFilter = threshold.value
                        }
                    }
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chart.bar.fill")
                            .font(.system(size: 7, weight: .bold))
                        Text(volumeThresholds.first(where: { abs($0.value - minVolumeFilter) < 0.001 })?.label ?? "VOL")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(minVolumeFilter > 0 ? Theme.Color.accentStart.opacity(0.25) : Theme.Color.surfaceHi.opacity(0.6))
                    .foregroundStyle(minVolumeFilter > 0 ? Theme.Color.accentStart : Theme.Color.textMuted)
                    .cornerRadius(3)
                }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                #endif

                // Confidence Score filter dropdown
                Menu {
                    ForEach(confidenceThresholds, id: \.value) { threshold in
                        Button(threshold.label) {
                            minScoreFilter = threshold.value
                        }
                    }
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 7, weight: .bold))
                        Text(confidenceThresholds.first(where: { $0.value == minScoreFilter })?.label ?? "SCORE")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(minScoreFilter > 0 ? Theme.Color.accentStart.opacity(0.25) : Theme.Color.surfaceHi.opacity(0.6))
                    .foregroundStyle(minScoreFilter > 0 ? Theme.Color.accentStart : Theme.Color.textMuted)
                    .cornerRadius(3)
                }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                #endif
            }

            Divider()

            // Setup Card List
            if filteredAlerts.isEmpty {
                VStack(spacing: 4) {
                    Spacer()
                    Text("No setups match active stage & filters")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Color.textMuted)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredAlerts) { alert in
                            alertRow(for: alert)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(Theme.Spacing.sm)
        .frame(width: 300)
        .frame(maxHeight: .infinity)
        .background(Theme.Color.surface.opacity(0.95))
        .overlay(
            Rectangle()
                .fill(Theme.Color.accentStart.opacity(0.35))
                .frame(width: 1),
            alignment: .leading
        )
    }

    private func filterChip(_ label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(isActive ? Theme.Color.accentStart : Theme.Color.surfaceHi.opacity(0.6))
                .foregroundStyle(isActive ? .white : Theme.Color.textMuted)
                .cornerRadius(3)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Alert Row Card

    private func alertRow(for alert: RadarAlert) -> some View {
        let isBuy = alert.direction == .buy
        let dirColor = isBuy ? Theme.Color.success : Theme.Color.danger
        let rank = alert.volumeRank ?? 1
        let isHovered = hoveredAlertID == alert.id
        let isAccordionExpanded = expandedAccordionAlertID == alert.id
        let isPopoverActive = Binding<Bool>(
            get: { activePopoverAlertID == alert.id },
            set: { active in
                if active { activePopoverAlertID = alert.id }
                else if activePopoverAlertID == alert.id { activePopoverAlertID = nil }
            }
        )

        return VStack(alignment: .leading, spacing: 5) {
            // Badges Header Row
            HStack(spacing: 4) {
                Text(rankMedal(rank))
                    .font(.system(size: 8, weight: .heavy, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(rankColor(rank).opacity(0.20))
                    .foregroundStyle(rankColor(rank))
                    .cornerRadius(3)

                Text(alert.direction.rawValue)
                    .font(.system(size: 8, weight: .heavy))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
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

                Text("🎯 \(alert.confluenceScore)%")
                    .font(.system(size: 7, weight: .heavy, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(scoreColor(alert.confluenceScore).opacity(0.20))
                    .foregroundStyle(scoreColor(alert.confluenceScore))
                    .cornerRadius(3)

                Text(alert.status.rawValue)
                    .font(.system(size: 7, weight: .heavy, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(statusColor(alert.status).opacity(0.20))
                    .foregroundStyle(statusColor(alert.status))
                    .cornerRadius(3)

                Spacer()

                Button {
                    activePopoverAlertID = alert.id
                } label: {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.Color.accentStart)
                }
                .buttonStyle(.plain)
                .popover(isPresented: isPopoverActive, arrowEdge: .trailing) {
                    AlertDetailView(alert: alert) {
                        activePopoverAlertID = nil
                        onSelectAlert?(alert)
                    }
                }
            }

            // Spatial Distance Gauge Bar
            SpatialPriceBar(alert: alert, livePrice: livePrice)
                .padding(.vertical, 2)

            // Setup Meta Row (Engine, Traded Volume, R:R)
            HStack(spacing: 6) {
                Text(engineLabel(for: alert))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(Theme.Color.textMuted)
                    .lineLimit(1)

                Spacer()

                if let vol = alert.tradedVolume {
                    Text("\(Self.formatVolume(vol)) Vol")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(red: 0.15, green: 0.85, blue: 0.95))
                }

                Text("\(String(format: "%.1fx", alert.riskRewardRatio)) R:R")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.Color.accentStart)
            }

            // Accordion Score Breakdown (if expanded)
            if isAccordionExpanded {
                ConfluenceAccordionView(alert: alert)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Action Buttons Row (Focus Chart / Stage Trade / Confluence Toggle)
            HStack(spacing: 4) {
                Button {
                    onFocusAlert?(alert)
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "scope")
                        Text("FOCUS")
                    }
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Theme.Color.surfaceHi.opacity(0.8))
                    .foregroundStyle(Theme.Color.textPrimary)
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("Focus and zoom chart on this setup")

                Button {
                    onSelectAlert?(alert)
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "plus.circle.fill")
                        Text("STAGE")
                    }
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Theme.Color.accentStart)
                    .foregroundStyle(.white)
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("Stage trade position on chart")

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if isAccordionExpanded {
                            expandedAccordionAlertID = nil
                        } else {
                            expandedAccordionAlertID = alert.id
                        }
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text(isAccordionExpanded ? "▲ LESS" : "▼ SCORE")
                        Image(systemName: isAccordionExpanded ? "chevron.up" : "chevron.down")
                    }
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.Color.accentStart)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Theme.Spacing.xs)
        .background(Theme.Color.surfaceHi.opacity(isHovered ? 0.9 : 0.6))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isHovered ? Theme.Color.accentStart : Color.clear, lineWidth: 1.0)
        )
        .onHover { hovering in
            if hovering {
                hoveredAlertID = alert.id
                onHoverAlert?(alert)
            } else if hoveredAlertID == alert.id {
                hoveredAlertID = nil
                onHoverAlert?(nil)
            }
        }
    }

    private func engineLabel(for alert: RadarAlert) -> String {
        let parts = alert.rationale.components(separatedBy: " -> ")
        guard let head = parts.first else { return alert.rationale }
        let segments = head.components(separatedBy: " · ")
        return segments.last ?? head
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
        case 1:  return Color(red: 1.00, green: 0.84, blue: 0.00)
        case 2:  return Color(red: 0.75, green: 0.75, blue: 0.75)
        case 3:  return Color(red: 0.80, green: 0.50, blue: 0.20)
        default: return Color(red: 0.15, green: 0.85, blue: 0.95)
        }
    }

    private func scoreColor(_ score: Int) -> Color {
        if score >= 85 {
            return Color(red: 0.15, green: 0.85, blue: 0.95)
        } else if score >= 70 {
            return Color(red: 1.00, green: 0.84, blue: 0.00)
        } else {
            return Theme.Color.textMuted
        }
    }

    private func statusColor(_ status: RadarAlert.SetupStatus) -> Color {
        switch status {
        case .inZone:   return Color(red: 1.00, green: 0.60, blue: 0.00)
        case .reaction: return Color(red: 0.15, green: 0.85, blue: 0.95)
        case .pending:  return Theme.Color.textMuted
        }
    }

    static func formatVolume(_ vol: Double) -> String {
        if vol >= 1_000_000 {
            return String(format: "%.1fM", vol / 1_000_000)
        } else if vol >= 1_000 {
            return String(format: "%.1fk", vol / 1_000)
        } else {
            return String(format: "%.0f", vol)
        }
    }
}

// MARK: - Spatial Price Distance Bar

struct SpatialPriceBar: View {
    let alert: RadarAlert
    let livePrice: Double?

    private var currentPrice: Double {
        livePrice ?? alert.entryPrice
    }

    var body: some View {
        let sl = alert.stopLoss
        let entry = alert.entryPrice
        let tp = alert.takeProfit

        let minPrice = min(sl, entry, tp, currentPrice)
        let maxPrice = max(sl, entry, tp, currentPrice)
        let range = max(0.0001, maxPrice - minPrice)

        let entryPct = max(0, min(1, (entry - minPrice) / range))
        let livePct = max(0, min(1, (currentPrice - minPrice) / range))
        let tpPct = max(0, min(1, (tp - minPrice) / range))

        VStack(spacing: 2) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.Color.surfaceHi)
                        .frame(height: 4)

                    let startX = min(entryPct, tpPct) * w
                    let spanW = abs(tpPct - entryPct) * w
                    Capsule()
                        .fill(Theme.Color.accentStart.opacity(0.40))
                        .frame(width: max(2, spanW), height: 4)
                        .offset(x: startX)

                    Circle()
                        .fill(Theme.Color.accentStart)
                        .frame(width: 8, height: 8)
                        .shadow(color: Theme.Color.accentStart, radius: 2)
                        .offset(x: max(0, min(w - 8, livePct * w - 4)))
                }
            }
            .frame(height: 8)

            HStack {
                Text("SL \(PriceFormat.exact(sl))")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.Color.danger)

                Spacer()

                Text("ENTRY \(PriceFormat.exact(entry))")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.Color.accentStart)

                Spacer()

                Text("TP \(PriceFormat.exact(tp))")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.Color.success)
            }
        }
    }
}

// MARK: - Confluence Accordion Detail View

struct ConfluenceAccordionView: View {
    let alert: RadarAlert

    var body: some View {
        if let b = alert.breakdown {
            VStack(alignment: .leading, spacing: 3) {
                Text("CONFLUENCE SCORE BREAKDOWN (\(alert.confluenceScore)%)")
                    .font(.system(size: 7, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Theme.Color.accentStart)

                Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 2) {
                    GridRow {
                        Text(b.htfBonus > 0 ? "✓" : "✗")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(b.htfBonus > 0 ? Theme.Color.success : Theme.Color.textMuted)
                        Text("HTF Nesting (\(b.htfLabel ?? "Zone")):")
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.Color.textMuted)
                        Text("+\(b.htfBonus) pts")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(b.htfBonus > 0 ? Theme.Color.success : Theme.Color.textMuted)
                    }

                    GridRow {
                        Text("✓")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.Color.success)
                        Text("Volume Rank #\(b.volumeRank ?? 1) (\(b.volumeFormatted)):")
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.Color.textMuted)
                        Text("+\(b.rankBonus) pts")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.Color.success)
                    }

                    GridRow {
                        Text(b.isTrendAligned ? "✓" : "✗")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(b.isTrendAligned ? Theme.Color.success : Theme.Color.textMuted)
                        Text("EMA Trend Alignment:")
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.Color.textMuted)
                        Text("+\(b.trendBonus) pts")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(b.isTrendAligned ? Theme.Color.success : Theme.Color.textMuted)
                    }

                    GridRow {
                        Text(b.hasOpposingTarget ? "✓" : "✗")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(b.hasOpposingTarget ? Theme.Color.success : Theme.Color.textMuted)
                        Text("Opposing OB Target:")
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.Color.textMuted)
                        Text("+\(b.targetBonus) pts")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(b.hasOpposingTarget ? Theme.Color.success : Theme.Color.textMuted)
                    }
                }
            }
            .padding(5)
            .background(Theme.Color.surface.opacity(0.85))
            .cornerRadius(4)
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
                        Text("Setup Status:").font(.system(size: 10)).foregroundStyle(Theme.Color.textMuted)
                        Text(alert.status.rawValue).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Theme.Color.accentStart)
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
