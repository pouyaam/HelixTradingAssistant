import SwiftUI

/// First-class searchable watchlist. Replaces the old pattern where pair
/// selection was buried in a dropdown in the chart header. Selecting a pair
/// sets `AppState.selectedPairID`; on compact (iPhone) it also routes back
/// to the chart tab via `onPick`.
struct MarketsView: View {
    @EnvironmentObject private var app: AppState
    var onPick: (() -> Void)? = nil

    @State private var query: String = ""
    @Environment(\.metrics) private var metrics

    private var filtered: [TradingPair] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return app.pairs }
        return app.pairs.filter {
            $0.name.lowercased().contains(q) || $0.symbol.lowercased().contains(q)
        }
    }

    private var grouped: [(TradingPair.Category, [TradingPair])] {
        TradingPair.Category.allCases.compactMap { cat in
            let items = filtered.filter { $0.category == cat }
            return items.isEmpty ? nil : (cat, items)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: metrics.sectionGap, pinnedViews: [.sectionHeaders]) {
                ForEach(grouped, id: \.0) { cat, items in
                    Section {
                        VStack(spacing: 0) {
                            ForEach(items) { pair in
                                Button {
                                    Haptics.select()
                                    app.selectedPairID = pair.id
                                    onPick?()
                                } label: {
                                    PairRowiPad(
                                        pair: pair,
                                        isSelected: pair.id == app.selectedPairID,
                                        livePrice: nil
                                    )
                                    .padding(.horizontal, metrics.cardPadding)
                                    .frame(minHeight: metrics.tap + 8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(RowHighlightStyle(isSelected: pair.id == app.selectedPairID))
                                if pair.id != items.last?.id {
                                    Divider().background(Theme.Color.border)
                                        .padding(.leading, metrics.cardPadding)
                                }
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: metrics.cardRadius, style: .continuous)
                                .fill(Theme.Color.surfaceHi)
                        )
                    } header: {
                        SectionLabel(text: cat.label)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.Color.canvas)
                    }
                }
            }
            .padding(metrics.screenPadding)
        }
        .background(Theme.Color.canvas)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search markets")
        .navigationTitle("Markets")
    }
}

/// Row background that lifts on press and stays tinted when selected.
private struct RowHighlightStyle: ButtonStyle {
    let isSelected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                (configuration.isPressed || isSelected)
                    ? Theme.Color.surfaceMax.opacity(isSelected ? 0.6 : 0.35)
                    : Color.clear
            )
    }
}
