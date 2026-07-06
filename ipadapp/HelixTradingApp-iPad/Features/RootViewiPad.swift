import SwiftUI

struct RootViewiPad: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var yahoo: YahooScheduler

    var body: some View {
        NavigationSplitView {
            List(selection: $app.selectedSidebarItem) {
                ForEach(SidebarItem.allCases) { item in
                    Label(item.label, systemImage: item.symbol)
                        .tag(item)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Helix Trading")
        } detail: {
            detailView
                .navigationBarHidden(true)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch app.selectedSidebarItem {
        case .dashboard, .none:
            DashboardViewiPad()
        case .news:
            NewsView()
        case .portfolio:
            AnalyticsView()
        case .journal:
            JournalView()
        case .inbox:
            NotificationInboxView()
        case .settings:
            SettingsViewiPad()
        }
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
