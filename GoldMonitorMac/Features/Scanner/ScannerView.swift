import SwiftUI

struct ScannerView: View {
    @EnvironmentObject private var app: AppState
    
    var body: some View {
        Group {
            if let store = app.scannerStore {
                ScannerMainView(store: store)
            } else {
                VStack {
                    ProgressView("Booting Scanner...")
                        .controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.Color.canvas)
            }
        }
    }
}

private struct ScannerMainView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var store: ScannerStore
    
    @State private var spinAngle: Double = 0.0
    @State private var pulse = false
    
    var body: some View {
        VStack(spacing: 0) {
            headerRow
            
            ScrollView {
                VStack(spacing: Theme.Spacing.xl) {
                    strategySettingsCard
                    
                    activeOpportunitiesSection
                    
                    historySection
                }
                .padding(Theme.Spacing.xl)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Color.canvas)
    }
    
    // ── Header Row ──────────────────────────────────────────────────
    private var headerRow: some View {
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Strategy Scanner")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.Color.textPrimary)
                
                HStack(spacing: 6) {
                    Circle()
                        .fill(store.isScanning ? Theme.Color.warn : Theme.Color.success)
                        .frame(width: 6, height: 6)
                        .shadow(color: (store.isScanning ? Theme.Color.warn : Theme.Color.success).opacity(0.5), radius: 3)
                    
                    Text(store.isScanning ? "Scanning market..." : "Active • Auto-scanning every 60s")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.Color.textMuted)
                }
            }
            
            Spacer()
            
            Button(action: {
                withAnimation(.linear(duration: 1.0)) {
                    spinAngle += 360
                }
                store.triggerManualScan()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .rotationEffect(.degrees(spinAngle))
                    Text("Scan Now")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Color.info))
            }
            .buttonStyle(.plain)
            .disabled(store.isScanning)
            .opacity(store.isScanning ? 0.6 : 1.0)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.lg)
        .background(Theme.Color.surface.opacity(0.5))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.Color.border)
                .frame(height: 1)
        }
    }
    
    // ── Strategy Toggle Card ───────────────────────────────────────
    private var strategySettingsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack(spacing: Theme.Spacing.xxl) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Scanner Modules")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.Color.textPrimary)
                        Text("Toggle scanning sub-systems. Discovered setups will trigger system alarms and notifications.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Color.textMuted)
                    }
                    
                    Spacer()
                    
                    HStack(spacing: Theme.Spacing.xl) {
                        Toggle(isOn: $store.enableSwingScan) {
                            Text("Swing (4H/1H/15M)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.Color.textSecondary)
                        }
                        .toggleStyle(.checkbox)
                        
                        Toggle(isOn: $store.enableScalpScan) {
                            Text("Scalping (15M/5M/1M)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.Color.textSecondary)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                
                Divider().background(Theme.Color.border.opacity(0.5))
                
                // Pairs selection section
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("Instruments to Scan")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.Color.textSecondary)
                    
                    HStack(spacing: Theme.Spacing.md) {
                        ForEach(store.pairs) { pair in
                            Button(action: {
                                store.togglePairScan(pairID: pair.id)
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: store.scannedPairIDs.contains(pair.id) ? "checkmark.square.fill" : "square")
                                        .font(.system(size: 12))
                                        .foregroundStyle(store.scannedPairIDs.contains(pair.id) ? pair.color : Theme.Color.textMuted)
                                    Text(pair.name)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(store.scannedPairIDs.contains(pair.id) ? Theme.Color.textPrimary : Theme.Color.textSecondary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 6).fill(store.scannedPairIDs.contains(pair.id) ? pair.color.opacity(0.15) : Theme.Color.surfaceHi))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(store.scannedPairIDs.contains(pair.id) ? pair.color.opacity(0.3) : Theme.Color.border, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
    
    // ── Discovered Opportunities ───────────────────────────────────
    private var activeOpportunitiesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Active Setups (\(store.activeSetups.count))")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.Color.textMuted)
            
            if store.isScanning && store.activeSetups.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Spacing.lg), GridItem(.flexible(), spacing: Theme.Spacing.lg)], spacing: Theme.Spacing.lg) {
                    skeletonCard
                    skeletonCard
                }
            } else if store.activeSetups.isEmpty {
                emptyStateCard(message: "No setups spotted yet. Hit 'Scan Now' to run manual check.")
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Spacing.lg), GridItem(.flexible(), spacing: Theme.Spacing.lg)], spacing: Theme.Spacing.lg) {
                    ForEach(store.activeSetups) { setup in
                        opportunityCard(for: setup)
                    }
                }
            }
        }
    }
    
    private func opportunityCard(for setup: ScannerSetup) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                // Header: Pair and Strategy
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(setup.pairName)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Theme.Color.textPrimary)
                        
                        Text(setup.strategy.rawValue)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.Color.textMuted)
                    }
                    
                    Spacer()
                    
                    // Direction badge
                    HStack(spacing: 4) {
                        Text(setup.direction.rawValue.uppercased())
                        Text(setup.direction.arrow)
                    }
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 4).fill(setup.direction.color))
                }
                
                Divider().background(Theme.Color.border.opacity(0.5))
                
                // Targets grid
                HStack(spacing: Theme.Spacing.xl) {
                    targetColumn(label: "ENTRY", price: setup.entry, color: Theme.Color.textPrimary)
                    targetColumn(label: "STOP LOSS", price: setup.stopLoss, color: Theme.Color.danger)
                    targetColumn(label: "TAKE PROFIT", price: setup.takeProfit, color: Theme.Color.success)
                }
                
                Divider().background(Theme.Color.border.opacity(0.5))
                
                // Risk reward and CTA
                HStack {
                    HStack(spacing: 4) {
                        Text("Risk/Reward:")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Color.textMuted)
                        Text(String(format: "1:%.1f", setup.riskReward))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.Color.textPrimary)
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        app.selectedPairID = setup.pairID
                        app.selectedSidebarItem = .dashboard
                    }) {
                        Text("Trade on Chart")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.Color.info))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Theme.Spacing.lg)
        }
    }
    
    private func targetColumn(label: String, price: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.Color.textMuted)
                .tracking(0.5)
            
            Text(ScannerStore.formatPrice(price))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    // ── Opportunities History Log ──────────────────────────────────
    private var historySection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack {
                Text("Opportunites Log (\(store.opportunityHistory.count))")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.Color.textMuted)
                
                Spacer()
                
                if !store.opportunityHistory.isEmpty {
                    Button(action: { store.clearHistory() }) {
                        Text("Clear History")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.Color.danger)
                    }
                    .buttonStyle(.plain)
                }
            }
            
            if store.opportunityHistory.isEmpty {
                emptyStateCard(message: "Setup logs is empty.")
            } else {
                VStack(spacing: 1) {
                    // Table Header
                    HStack {
                        headerCell("Time", width: 120)
                        headerCell("Symbol", width: 100)
                        headerCell("Strategy", width: 140)
                        headerCell("Direction", width: 80)
                        headerCell("Entry", width: 100)
                        headerCell("SL", width: 100)
                        headerCell("TP", width: 100)
                        Spacer()
                    }
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, 8)
                    .background(Theme.Color.surface.opacity(0.3))
                    
                    // Table Rows
                    ForEach(store.opportunityHistory) { log in
                        HStack {
                            valueCell(formatDate(log.timestamp), width: 120, color: Theme.Color.textMuted)
                            valueCell(log.pairName, width: 100, color: Theme.Color.textPrimary, weight: .semibold)
                            valueCell(log.strategy, width: 140, color: Theme.Color.textSecondary)
                            
                            // Direction badge in row
                            HStack(spacing: 3) {
                                Text(log.direction)
                                Text(log.direction == "Long" ? "↑" : "↓")
                            }
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(log.direction == "Long" ? Theme.Color.success : Theme.Color.danger)
                            .frame(width: 80, alignment: .leading)
                            
                            valueCell(ScannerStore.formatPrice(log.entry), width: 100, color: Theme.Color.textPrimary)
                            valueCell(ScannerStore.formatPrice(log.stopLoss), width: 100, color: Theme.Color.danger)
                            valueCell(ScannerStore.formatPrice(log.takeProfit), width: 100, color: Theme.Color.success)
                            
                            Spacer()
                            
                            Button(action: {
                                app.selectedPairID = log.pairID
                                app.selectedSidebarItem = .dashboard
                            }) {
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(Theme.Color.textMuted)
                                    .padding(.horizontal, 8)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, 10)
                        .background(Theme.Color.surface.opacity(0.1))
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(Theme.Color.border.opacity(0.3))
                                .frame(height: 1)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surface.opacity(0.2)))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Theme.Color.border, lineWidth: 1)
                )
            }
        }
    }
    
    private func headerCell(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Theme.Color.textMuted)
            .tracking(0.5)
            .frame(width: width, alignment: .leading)
    }
    
    private func valueCell(_ text: String, width: CGFloat, color: Color, weight: Font.Weight = .regular) -> some View {
        Text(text)
            .font(.system(size: 12, weight: weight).monospacedDigit())
            .foregroundStyle(color)
            .frame(width: width, alignment: .leading)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss dd MMM"
        return formatter.string(from: date)
    }
    
    // ── Helper Views ────────────────────────────────────────────────
    private func emptyStateCard(message: String) -> some View {
        Card {
            VStack {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Color.textMuted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(Theme.Spacing.xl)
        }
    }
    
    private var skeletonCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.Color.surfaceHi)
                            .frame(width: 80, height: 16)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.Color.surfaceHi)
                            .frame(width: 120, height: 10)
                    }
                    Spacer()
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.Color.surfaceHi)
                        .frame(width: 50, height: 18)
                }
                Divider().background(Theme.Color.border.opacity(0.3))
                HStack(spacing: Theme.Spacing.xl) {
                    ForEach(0..<3) { _ in
                        VStack(alignment: .leading, spacing: 4) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Theme.Color.surfaceHi)
                                .frame(width: 45, height: 8)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Theme.Color.surfaceHi)
                                .frame(width: 60, height: 12)
                        }
                    }
                }
            }
            .padding(Theme.Spacing.lg)
            .opacity(pulse ? 0.35 : 0.7)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
        }
    }
}
