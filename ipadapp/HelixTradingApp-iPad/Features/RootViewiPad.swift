import SwiftUI

/// Adaptive root. Picks the navigation shell by horizontal size class:
/// - **regular** (iPad, big iPhone landscape) → `SplitRootView`
///   (`NavigationSplitView`: sidebar with nav + live watchlist, detail pane).
/// - **compact** (iPhone portrait) → `TabRootView` (bottom `TabView`).
///
/// Both drive the same `AppState.selectedSidebarItem` / `selectedPairID`,
/// so no screen logic is duplicated.
struct RootViewiPad: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if sizeClass == .compact {
                TabRootView()
            } else {
                SplitRootView()
            }
        }
        .provideAdaptiveMetrics()
    }
}

// MARK: - Shared detail routing

/// Maps a `SidebarItem` to its screen. Shared by both shells.
@ViewBuilder
func destinationView(for item: SidebarItem?) -> some View {
    switch item {
    case .dashboard, .none: DashboardViewiPad()
    case .news:             NewsView()
    case .portfolio:        AnalyticsView()
    case .journal:          JournalView()
    case .inbox:            NotificationInboxView()
    case .settings:         SettingsViewiPad()
    }
}

// MARK: - Regular (iPad) shell

private struct SplitRootView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        NavigationSplitView {
            List(selection: $app.selectedSidebarItem) {
                Section {
                    ForEach(SidebarItem.allCases) { item in
                        Label(item.label, systemImage: item.symbol)
                            .tag(item)
                    }
                } header: {
                    Text("Navigate")
                }

                Section {
                    ForEach(app.pairs) { pair in
                        Button {
                            app.selectedPairID = pair.id
                            app.selectedSidebarItem = .dashboard
                        } label: {
                            PairRowiPad(
                                pair: pair,
                                isSelected: pair.id == app.selectedPairID,
                                livePrice: nil
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            pair.id == app.selectedPairID
                                ? Theme.Color.surfaceMax.opacity(0.4)
                                : Color.clear
                        )
                    }
                } header: {
                    Text("Watchlist")
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Helix Trading")
        } detail: {
            destinationView(for: app.selectedSidebarItem)
                .navigationBarHidden(true)
        }
    }
}

// MARK: - Compact (iPhone) shell

private struct TabRootView: View {
    @EnvironmentObject private var app: AppState
    @State private var tab: Tab = .chart

    private enum Tab: Hashable { case chart, markets, journal, inbox, more }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                DashboardViewiPad()
                    .navigationBarHidden(true)
            }
            .tabItem { Label("Chart", systemImage: "chart.line.uptrend.xyaxis") }
            .tag(Tab.chart)

            NavigationStack {
                MarketsView(onPick: { tab = .chart })
            }
            .tabItem { Label("Markets", systemImage: "list.bullet") }
            .tag(Tab.markets)

            NavigationStack { JournalView() }
                .tabItem { Label("Journal", systemImage: "book.closed.fill") }
                .tag(Tab.journal)

            NavigationStack { NotificationInboxView() }
                .tabItem { Label("Inbox", systemImage: "bell.fill") }
                .tag(Tab.inbox)

            NavigationStack { MoreView() }
                .tabItem { Label("More", systemImage: "ellipsis.circle.fill") }
                .tag(Tab.more)
        }
        .tint(Theme.Color.accentStart)
    }
}

/// Compact-only overflow list for the secondary destinations that don't
/// earn a first-class tab.
private struct MoreView: View {
    var body: some View {
        List {
            NavigationLink { NewsView() } label: {
                Label("News", systemImage: "newspaper.fill")
            }
            NavigationLink { AnalyticsView() } label: {
                Label("Portfolio", systemImage: "briefcase.fill")
            }
            NavigationLink { SettingsViewiPad() } label: {
                Label("Settings", systemImage: "gearshape.fill")
            }
        }
        .navigationTitle("More")
    }
}

struct PairRowiPad: View {
    let pair: TradingPair
    let isSelected: Bool
    let livePrice: Double?

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(pair.color)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(pair.name)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(pair.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textMuted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                let price = livePrice ?? pair.price
                if price > 0 {
                    Text(formatPrice(price))
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.Color.textPrimary)
                    let pct = pair.changePercent
                    Text(String(format: "%+.2f%%", pct))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(pct >= 0 ? Theme.Color.success : Theme.Color.danger)
                } else {
                    Text("—")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.Color.textMuted)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func formatPrice(_ v: Double) -> String {
        if v >= 10_000 { return String(format: "%.0f", v) }
        if v >= 100 { return String(format: "%.2f", v) }
        if v >= 1 { return String(format: "%.4f", v) }
        return String(format: "%.5f", v)
    }
}
