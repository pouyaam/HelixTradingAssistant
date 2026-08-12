import SwiftUI

/// SMC Sentinel drawer — the trade radar sliding out from the chart's right
/// edge. Every setup listed here comes from `SMCSentinelEngine`, which reads
/// the ALGOSMART ASSIST v2 indicator only: HTF context → liquidity grab → POI
/// mitigation in discount/premium → SCOB or LTF CHoCH trigger.
///
/// Setups are grouped by the strategy's own lifecycle (WAITING POI, IN POI,
/// ACTIVE), filterable by direction / trigger / confluence score, and feature
/// real-time spatial price tracking, score breakdown accordions, and 1-click
/// chart focus.
struct SentinelRadarDrawer: View {
    @ObservedObject var sentinel = StrategySentinel.shared
    @EnvironmentObject var app: AppState

    /// The timeframe on the chart. Always scanned, and the one the header's
    /// context line falls back to.
    var chartTimeframe: Timeframe = .h1
    var livePrice: Double? = nil
    var onSelectAlert: ((RadarAlert) -> Void)?
    var onHoverAlert: ((RadarAlert?) -> Void)?
    var onFocusAlert: ((RadarAlert) -> Void)?

    @AppStorage("dashboard.sentinelDrawerExpanded") private var isExpanded: Bool = false
    @State private var selectedStage: StageTab = .all
    @State private var selectedDirection: DirectionFilter = .all
    @State private var triggeredOnly: Bool = false
    @State private var minScoreFilter: Int = 0
    @State private var hoveredAlertID: UUID?
    @State private var expandedAccordionAlertID: UUID?
    @State private var activePopoverAlertID: UUID?
    @State private var selectedSource: SourceTab = .smc
    /// Which scanned timeframe the list is narrowed to. `nil` = all of them.
    @State private var timeframeFilter: Timeframe?

    /// Which engine the drawer is showing. The two are different animals
    /// — SMC produces scored, filterable setup queues; EBP produces one
    /// trade at a time plus a running tally — so they get separate
    /// panels rather than a merged list with half the columns empty.
    enum SourceTab: String, CaseIterable {
        case smc = "SMC"
        case ebp = "EBP"
    }

    enum StageTab: String, CaseIterable {
        case active = "🚀 ACTIVE"
        case inPOI = "🔥 IN POI"
        case waiting = "⏳ WAITING"
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
        return sentinel.activeRadarAlerts.filter { alert in
            guard alert.pairID == pairID else { return false }
            guard let only = timeframeFilter else { return true }
            return alert.timeframe == only.rawValue
        }
    }

    /// Every timeframe currently on the radar for this pair, smallest first.
    /// Drives the filter row, which only appears once there is more than one.
    private var scannedTimeframes: [Timeframe] {
        let live = sentinel.scanTimeframes.union([chartTimeframe])
        return live.sorted { $0.seconds < $1.seconds }
    }

    private let confidenceThresholds: [(label: String, value: Int)] = [
        ("ALL SCORE", 0),
        ("≥ 60%", 60),
        ("≥ 70%", 70),
        ("≥ 80%", 80),
        ("≥ 90%", 90)
    ]

    /// The EBP engine's read for this symbol, or `nil` when the
    /// indicator isn't on the chart.
    private var ebp: EBPRadarSnapshot? {
        guard let pairID = currentPairID else { return nil }
        return sentinel.ebpSnapshots[pairID]
    }

    /// Count shown on the rail and in the header for the active tab.
    private var badgeCount: Int {
        switch selectedSource {
        case .smc: return symbolAlerts.count
        case .ebp: return ebp?.working.count ?? 0
        }
    }

    /// The engine's market read for this symbol — shown even when no setup
    /// qualifies, so an empty radar explains which rule is blocking.
    /// There is one context per scanned timeframe now, so the header shows
    /// the filtered one — falling back to the chart's, which is always
    /// scanned. Any other choice goes incoherent the moment the user filters.
    private var context: StrategySentinel.MarketContext? {
        guard let pairID = currentPairID else { return nil }
        let tf = timeframeFilter ?? chartTimeframe
        return sentinel.marketContext(pairID: pairID, timeframe: tf.rawValue)
    }

    /// The timeframe whose context the header is showing.
    private var contextTimeframe: Timeframe { timeframeFilter ?? chartTimeframe }

    /// One blocking-rule line per scanned timeframe, for the empty state.
    /// Honours the TF filter so filtering to 4h explains only 4h.
    private var blockers: [(timeframe: String, blocker: String)] {
        guard let pairID = currentPairID else { return [] }
        let scope = timeframeFilter.map { [$0] } ?? scannedTimeframes
        return scope.compactMap { tf in
            guard let blocker = sentinel.marketContext(pairID: pairID,
                                                      timeframe: tf.rawValue)?.blocker,
                  !blocker.isEmpty else { return nil }
            return (tf.rawValue, blocker)
        }
    }

    /// Multi-select scan-timeframe picker. A `Menu` rather than a pill row for
    /// the same reason `TimeframeSelector` is one: pills devour the 300pt
    /// panel's horizontal space. The chart's own timeframe is always scanned,
    /// so its row is shown pinned and non-interactive.
    private var timeframeMenu: some View {
        Menu {
            Button {
                sentinel.scanTimeframes = []
                timeframeFilter = nil
                pruneToSelection()
            } label: {
                Text("Follow chart only")
            }

            Divider()

            ForEach(Timeframe.allCases, id: \.self) { tf in
                if tf == chartTimeframe {
                    Text("✓ \(tf.rawValue.uppercased())  (chart)")
                } else {
                    Button {
                        toggleScan(tf)
                    } label: {
                        Text("\(sentinel.scanTimeframes.contains(tf) ? "✓ " : "")\(tf.rawValue.uppercased())")
                    }
                }
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "clock.fill")
                    .font(.system(size: 7, weight: .bold))
                Text(scannedTimeframes.count > 1 ? "TF · \(scannedTimeframes.count)" : "TF · CHART")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(scannedTimeframes.count > 1
                        ? Theme.Color.accentStart.opacity(0.25)
                        : Theme.Color.surfaceHi.opacity(0.6))
            .foregroundStyle(scannedTimeframes.count > 1
                             ? Theme.Color.accentStart
                             : Theme.Color.textMuted)
            .cornerRadius(3)
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
    }

    /// Add or remove an auxiliary timeframe. Removing the one the list is
    /// filtered to would leave the list empty with no way back, so clear it.
    private func toggleScan(_ tf: Timeframe) {
        var next = sentinel.scanTimeframes
        if next.contains(tf) {
            next.remove(tf)
            if timeframeFilter == tf { timeframeFilter = nil }
        } else {
            next.insert(tf)
        }
        sentinel.scanTimeframes = next
        pruneToSelection()
    }

    /// Drop rows for timeframes that are no longer selected. Without this the
    /// deselected timeframe's setups sit in the list until something else
    /// prunes them, which reads as the toggle not working.
    private func pruneToSelection() {
        sentinel.prune(pairID: currentPairID,
                       keeping: sentinel.scanTimeframes.union([chartTimeframe]))
    }

    private var filteredAlerts: [RadarAlert] {
        let raw = symbolAlerts.filter { alert in
            switch selectedStage {
            case .active: guard alert.status == .active else { return false }
            case .inPOI: guard alert.status == .mitigating else { return false }
            case .waiting: guard alert.status == .waitingForPOI else { return false }
            case .all: break
            }

            switch selectedDirection {
            case .all: break
            case .buy: guard alert.direction == .buy else { return false }
            case .sell: guard alert.direction == .sell else { return false }
            }

            if triggeredOnly {
                guard alert.breakdown?.hasTrigger == true else { return false }
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
        .onChange(of: chartTimeframe) { _ in
            // The chart's timeframe is always scanned, so moving it can strand
            // the filter on a timeframe that just left the set — which would
            // show an empty list with no obvious way back.
            if let only = timeframeFilter, !scannedTimeframes.contains(only) {
                timeframeFilter = nil
            }
        }
    }

    // MARK: - Rail

    private var rail: some View {
        Button {
            isExpanded.toggle()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.right" : "chevron.left")
                    .font(.system(size: 9, weight: .heavy))

                Text("\(badgeCount)")
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Theme.Color.accentStart.opacity(badgeCount == 0 ? 0.15 : 0.9)))
                    .foregroundStyle(badgeCount == 0 ? Theme.Color.textMuted : .white)

                Text(selectedSource == .ebp ? "EBP SENTINEL" : "SMC SENTINEL")
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

                Text("SENTINEL")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Theme.Color.textPrimary)

                Spacer()

                if selectedSource == .smc {
                    Text("\(filteredAlerts.count)/\(symbolAlerts.count)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.Color.textMuted)
                } else if let ebp {
                    Text(ebp.timeframe.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.Color.textMuted)
                }
            }

            // Engine tabs (SMC / EBP)
            HStack(spacing: 3) {
                ForEach(SourceTab.allCases, id: \.self) { source in
                    Button {
                        selectedSource = source
                    } label: {
                        Text(source.rawValue)
                            .font(.system(size: 8, weight: .heavy, design: .monospaced))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 3)
                            .background(selectedSource == source
                                        ? Theme.Color.accentStart
                                        : Theme.Color.surfaceHi.opacity(0.6))
                            .foregroundStyle(selectedSource == source ? .white : Theme.Color.textMuted)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
            }

            if selectedSource == .ebp {
                ebpPanel
            } else {
                smcPanel
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

    // MARK: - SMC panel

    @ViewBuilder
    private var smcPanel: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            // Market context read (HTF structure + premium/discount state)
            if let ctx = context {
                HStack(spacing: 4) {
                    // Which timeframe's read this is — the header shows one
                    // context, so it has to say which.
                    Text(contextTimeframe.rawValue.uppercased())
                        .font(.system(size: 7, weight: .heavy, design: .monospaced))
                        .padding(.horizontal, 3)
                        .padding(.vertical, 0.5)
                        .background(Theme.Color.surfaceHi.opacity(0.8))
                        .foregroundStyle(Theme.Color.textMuted)
                        .cornerRadius(3)

                    Text("\(ctx.htfLabel) \(ctx.contextLabel)")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(ctx.contextLabel.hasPrefix("Bullish")
                                         ? Theme.Color.success
                                         : (ctx.contextLabel.hasPrefix("Bearish") ? Theme.Color.danger : Theme.Color.textMuted))

                    if let eq = ctx.equilibrium {
                        Text("· 0.5 \(PriceFormat.exact(eq))")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.Color.textMuted)

                        Text(ctx.equilibriumState.uppercased())
                            .font(.system(size: 7, weight: .heavy, design: .monospaced))
                            .padding(.horizontal, 3)
                            .padding(.vertical, 0.5)
                            .background((ctx.equilibriumState == "Discount" ? Theme.Color.success : Theme.Color.danger).opacity(0.20))
                            .foregroundStyle(ctx.equilibriumState == "Discount" ? Theme.Color.success : Theme.Color.danger)
                            .cornerRadius(3)
                    }

                    Spacer()
                }
            }

            // Stage Tabs Bar (🚀 ACTIVE / 🔥 IN POI / ⏳ WAITING / 📊 ALL)
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

                filterChip("⚡ TRIGGERED", isActive: triggeredOnly) {
                    triggeredOnly.toggle()
                }

                Spacer()

                timeframeMenu

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

            // Per-timeframe filter. Pointless with a single timeframe on the
            // radar, so it only shows up once the scan set widens.
            if scannedTimeframes.count > 1 {
                HStack(spacing: 3) {
                    filterChip("ALL", isActive: timeframeFilter == nil) {
                        timeframeFilter = nil
                    }

                    ForEach(scannedTimeframes, id: \.self) { tf in
                        filterChip(tf.rawValue.uppercased(),
                                   isActive: timeframeFilter == tf) {
                            timeframeFilter = (timeframeFilter == tf) ? nil : tf
                        }
                    }

                    Spacer()
                }
            }

            Divider()

            // Setup Card List
            if filteredAlerts.isEmpty {
                VStack(spacing: 4) {
                    Spacer()
                    Text(symbolAlerts.isEmpty ? "No SMC setup yet" : "No setups match active stage & filters")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Color.textMuted)

                    // When the engine produced nothing, name the rule that
                    // blocked — once per scanned timeframe, so an empty radar
                    // still says what every timeframe is waiting on.
                    if symbolAlerts.isEmpty {
                        ForEach(blockers, id: \.timeframe) { row in
                            Text("\(row.timeframe.uppercased()) · \(row.blocker)")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Theme.Color.accentStart)
                                .multilineTextAlignment(.center)
                        }
                    }
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
    }

    // MARK: - EBP panel

    /// The Engulfing Bar Play read: the running tally the original drew
    /// as an info table, then the setups newest-first. There are no
    /// filters here — the engine holds one trade at a time, so the list
    /// is short by construction.
    @ViewBuilder
    private var ebpPanel: some View {
        if let ebp, !ebp.setups.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                ebpStatsRow(ebp.stats)
                Divider()
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(ebp.setups) { setup in
                            ebpRow(setup)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        } else {
            VStack(spacing: 4) {
                Spacer()
                Text(ebp == nil ? "EBP is not on the chart" : "No EBP pattern yet")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Color.textMuted)
                if ebp == nil {
                    Text("Add the EBP indicator to start tracking")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.Color.accentStart)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func ebpStatsRow(_ stats: EngulfingBarPlay.Stats) -> some View {
        HStack(spacing: 6) {
            ebpStat("SETUPS", "\(stats.setups)", Theme.Color.textPrimary)
            ebpStat("W/L", "\(stats.wins)/\(stats.losses)", Theme.Color.textPrimary)
            ebpStat(
                "WIN",
                stats.winRate.map { String(format: "%.0f%%", $0) } ?? "–",
                (stats.winRate ?? 0) >= 50 ? Theme.Color.success : Theme.Color.textMuted
            )
            ebpStat(
                "R",
                String(format: "%+.2f", stats.totalR),
                stats.totalR >= 0 ? Theme.Color.success : Theme.Color.danger
            )
            Spacer()
        }
    }

    private func ebpStat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.system(size: 7, weight: .heavy, design: .monospaced))
                .foregroundStyle(Theme.Color.textMuted)
            Text(value)
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    private func ebpRow(_ setup: EngulfingBarPlay.Setup) -> some View {
        let isLong = setup.direction.isLong
        let dirColor = isLong ? Theme.Color.success : Theme.Color.danger
        let statusColor = ebpStatusColor(setup.status)

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(isLong ? "BULLISH" : "BEARISH")
                    .font(.system(size: 8, weight: .heavy))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(dirColor.opacity(0.20))
                    .foregroundStyle(dirColor)
                    .cornerRadius(3)

                Text(setup.closeQuality.label.uppercased())
                    .font(.system(size: 7, weight: .heavy, design: .monospaced))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 0.5)
                    .background(Theme.Color.surfaceHi.opacity(0.8))
                    .foregroundStyle(Theme.Color.textMuted)
                    .cornerRadius(3)

                if setup.status != .skipped {
                    Text(setup.entryKind.label.uppercased())
                        .font(.system(size: 7, weight: .heavy, design: .monospaced))
                        .padding(.horizontal, 3)
                        .padding(.vertical, 0.5)
                        .background(Theme.Color.surfaceHi.opacity(0.8))
                        .foregroundStyle(Theme.Color.textMuted)
                        .cornerRadius(3)
                }

                Spacer()

                Text(ebpStatusLabel(setup.status))
                    .font(.system(size: 7, weight: .heavy, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(statusColor.opacity(0.20))
                    .foregroundStyle(statusColor)
                    .cornerRadius(3)
            }

            // The plan. A skipped pattern never had one.
            if let stop = setup.stopLoss, let target = setup.takeProfit {
                HStack(spacing: 6) {
                    Text("E \(PriceFormat.exact(setup.entryLevel))")
                        .foregroundStyle(Theme.Color.textPrimary)
                    Text("SL \(PriceFormat.exact(stop))")
                        .foregroundStyle(Theme.Color.danger.opacity(0.85))
                    Text("TP \(PriceFormat.exact(target))")
                        .foregroundStyle(Theme.Color.success.opacity(0.85))
                    Spacer()
                    if let r = setup.rMultiple {
                        Text(String(format: "%+.1fR", r))
                            .foregroundStyle(r >= 0 ? Theme.Color.success : Theme.Color.danger)
                    }
                }
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .lineLimit(1)
            } else {
                Text("Printed while another setup was working — not traded")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(Theme.Color.textMuted)
                    .lineLimit(2)
            }

            if setup.movedToBreakeven {
                Text("Stop moved to breakeven")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.Color.warn)
            }
        }
        .padding(6)
        .background(Theme.Color.surfaceHi.opacity(0.35))
        .cornerRadius(5)
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(dirColor.opacity(setup.status.isUntriggered ? 0.15 : 0.35), lineWidth: 1)
        )
    }

    private func ebpStatusLabel(_ status: EngulfingBarPlay.Status) -> String {
        switch status {
        case .pending:   return "⏳ WAITING"
        case .triggered: return "🚀 LIVE"
        case .hitTP:     return "TP"
        case .hitSL:     return "SL"
        case .breakeven: return "BE"
        case .cancelled: return "EXPIRED"
        case .skipped:   return "SKIPPED"
        }
    }

    private func ebpStatusColor(_ status: EngulfingBarPlay.Status) -> Color {
        switch status {
        case .triggered: return Color(red: 0.15, green: 0.85, blue: 0.95)
        case .pending:   return Color(red: 1.00, green: 0.60, blue: 0.00)
        case .hitTP:     return Theme.Color.success
        case .hitSL:     return Theme.Color.danger
        case .breakeven: return Theme.Color.warn
        case .cancelled, .skipped: return Theme.Color.textMuted
        }
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
                Text(alert.direction.rawValue)
                    .font(.system(size: 8, weight: .heavy))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(dirColor.opacity(0.20))
                    .foregroundStyle(dirColor)
                    .cornerRadius(3)

                // Which timeframe found this setup. The list is a flat mix of
                // every scanned timeframe, so the row has to say.
                Text(alert.timeframe.uppercased())
                    .font(.system(size: 7, weight: .heavy, design: .monospaced))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 0.5)
                    .background(alert.timeframe == chartTimeframe.rawValue
                                ? Theme.Color.surfaceHi.opacity(0.8)
                                : Theme.Color.accentStart.opacity(0.20))
                    .foregroundStyle(alert.timeframe == chartTimeframe.rawValue
                                     ? Theme.Color.textMuted
                                     : Theme.Color.accentStart)
                    .cornerRadius(3)

                if alert.breakdown?.hasTrigger == true {
                    Text("⚡\(alert.breakdown?.triggerKind ?? "")")
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

            // Setup Meta Row (POI band, TP2, R:R)
            HStack(spacing: 6) {
                Text("POI \(PriceFormat.exact(alert.zoneBottom))–\(PriceFormat.exact(alert.zoneTop))")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.Color.textMuted)
                    .lineLimit(1)

                Spacer()

                Text("TP2 \(PriceFormat.exact(alert.takeProfit2))")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.Color.success.opacity(0.75))

                Text("\(String(format: "%.1fx", alert.riskRewardRatio)) R:R")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.Color.accentStart)
            }

            // Strategy read (HTF context · liquidity grab · POI freshness)
            Text(engineLabel(for: alert))
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(Theme.Color.textMuted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

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

    /// The rationale's context half — everything before the " -> " execution
    /// clause the row already renders as entry/SL/TP.
    private func engineLabel(for alert: RadarAlert) -> String {
        alert.rationale.components(separatedBy: " -> ").first ?? alert.rationale
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
        case .mitigating:    return Color(red: 1.00, green: 0.60, blue: 0.00)
        case .active:        return Color(red: 0.15, green: 0.85, blue: 0.95)
        case .waitingForPOI: return Theme.Color.textMuted
        case .invalidated:   return Theme.Color.danger
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
        let tp2 = alert.takeProfit2

        let minPrice = min(sl, entry, tp, tp2, currentPrice)
        let maxPrice = max(sl, entry, tp, tp2, currentPrice)
        let range = max(0.0001, maxPrice - minPrice)

        let entryPct = max(0, min(1, (entry - minPrice) / range))
        let livePct = max(0, min(1, (currentPrice - minPrice) / range))
        let tpPct = max(0, min(1, (tp - minPrice) / range))
        let tp2Pct = max(0, min(1, (tp2 - minPrice) / range))

        VStack(spacing: 2) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.Color.surfaceHi)
                        .frame(height: 4)

                    // Entry → TP2 run, with the TP1 leg drawn brighter on top.
                    let runStart = min(entryPct, tp2Pct) * w
                    let runWidth = abs(tp2Pct - entryPct) * w
                    Capsule()
                        .fill(Theme.Color.success.opacity(0.20))
                        .frame(width: max(2, runWidth), height: 4)
                        .offset(x: runStart)

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

                Text("TP1 \(PriceFormat.exact(tp))")
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
                Text("SMC CONFLUENCE (\(alert.confluenceScore)%)")
                    .font(.system(size: 7, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Theme.Color.accentStart)

                // The HTF context is a hard precondition, so it is reported
                // rather than scored.
                Text("Context: \(b.contextEvent) on \(b.htfLabel ?? "HTF") · base \(b.baseScore) pts")
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.Color.textMuted)

                Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 2) {
                    scoreRow(hit: b.idmSweepBonus > 0, label: "IDM sweep @ \(PriceFormat.exact(b.grabLevel))", pts: b.idmSweepBonus)
                    scoreRow(hit: b.liquiditySweepBonus > 0, label: "Liquidity sweep (X)", pts: b.liquiditySweepBonus)
                    scoreRow(hit: b.equilibriumBonus > 0, label: "POI in \(b.equilibriumState)", pts: b.equilibriumBonus)
                    scoreRow(hit: b.hasTrigger, label: "Trigger: \(b.triggerKind)", pts: b.triggerBonus)
                    scoreRow(hit: b.isFreshZone, label: "Fresh (unmitigated) POI", pts: b.freshZoneBonus)
                    scoreRow(hit: b.isLTFAligned, label: "LTF structure aligned", pts: b.ltfAlignBonus)
                }
            }
            .padding(5)
            .background(Theme.Color.surface.opacity(0.85))
            .cornerRadius(4)
        }
    }

    @ViewBuilder
    private func scoreRow(hit: Bool, label: String, pts: Int) -> some View {
        GridRow {
            Text(hit ? "✓" : "✗")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(hit ? Theme.Color.success : Theme.Color.textMuted)
            Text("\(label):")
                .font(.system(size: 8))
                .foregroundStyle(Theme.Color.textMuted)
            Text("+\(pts) pts")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(hit ? Theme.Color.success : Theme.Color.textMuted)
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

                Text(alert.status.rawValue)
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
                Text("WHY THIS SETUP QUALIFIED")
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
                        Text("HTF Context:").font(.system(size: 10)).foregroundStyle(Theme.Color.textMuted)
                        Text("\(alert.breakdown?.contextEvent ?? "—") on \(alert.htfLabel ?? "—")").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.Color.textPrimary)
                    }
                    GridRow {
                        Text("Liquidity Grab:").font(.system(size: 10)).foregroundStyle(Theme.Color.textMuted)
                        Text("\(alert.breakdown?.grabKind ?? "—") @ \(PriceFormat.exact(alert.breakdown?.grabLevel ?? 0))").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Color(red: 0.15, green: 0.85, blue: 0.95))
                    }
                    GridRow {
                        Text("Entry Zone (POI):").font(.system(size: 10)).foregroundStyle(Theme.Color.textMuted)
                        Text("\(PriceFormat.exact(alert.zoneBottom)) – \(PriceFormat.exact(alert.zoneTop))").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Theme.Color.textPrimary)
                    }
                    GridRow {
                        Text("Equilibrium (0.5):").font(.system(size: 10)).foregroundStyle(Theme.Color.textMuted)
                        Text("\(PriceFormat.exact(alert.equilibrium)) · \(alert.breakdown?.equilibriumState ?? "—")").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Theme.Color.textPrimary)
                    }
                    GridRow {
                        Text("Trigger:").font(.system(size: 10)).foregroundStyle(Theme.Color.textMuted)
                        Text(alert.breakdown?.triggerKind ?? "—").font(.system(size: 10, weight: .bold)).foregroundStyle(alert.breakdown?.hasTrigger == true ? Theme.Color.success : Theme.Color.textMuted)
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
                        Text("Take Profit 1:").font(.system(size: 10)).foregroundStyle(Theme.Color.textMuted)
                        Text(PriceFormat.exact(alert.takeProfit)).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Theme.Color.success)
                    }
                    GridRow {
                        Text("Take Profit 2:").font(.system(size: 10)).foregroundStyle(Theme.Color.textMuted)
                        Text(PriceFormat.exact(alert.takeProfit2)).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Theme.Color.success)
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
}
