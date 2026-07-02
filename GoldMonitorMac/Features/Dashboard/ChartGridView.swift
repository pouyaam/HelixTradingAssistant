import SwiftUI

/// Renders the multi-chart split-screen grid: 2 or 4 independent
/// `ChartPaneView`s arranged per `layoutStore.layout`. Swapped in by
/// `DashboardView.body` in place of the single-chart `chartCard` when
/// the layout isn't `.single` — see `DashboardView`'s `multiChart`
/// state and the layout picker in its pair header.
struct ChartGridView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var layoutStore: MultiChartLayoutStore
    let indicatorConfig: OscillatorConfig
    /// Same store the primary single chart uses — drawings are a
    /// property of the pair, not of which view mode you're looking at
    /// it in, so a line drawn in a grid pane shows up on the primary
    /// chart for that pair too, and vice versa.
    @ObservedObject var drawingStore: DrawingStore

    /// Which pane (if any) a user has expanded to fullscreen. Only one
    /// pane can be fullscreen at a time — going fullscreen hides every
    /// sibling pane (and, via `app.isChartFullscreen`, the sidebar and
    /// pair header too) so exactly one chart fills the window.
    @State private var fullscreenPaneID: UUID?

    var body: some View {
        let panes = layoutStore.panes
        VStack(spacing: Theme.Spacing.sm) {
            // Lives above the grid itself (not in `DashboardView`'s
            // `pairHeader`, which hides in fullscreen) so it's the one
            // control that's always reachable — both to enter grid-wide
            // fullscreen and to get back out of it. Hidden while a
            // single pane is fullscreen since that pane's own header
            // already owns the exit control then.
            if fullscreenPaneID == nil {
                gridToolbar
            }
            Group {
                if let fsID = fullscreenPaneID, let fullscreenPane = panes.first(where: { $0.id == fsID }) {
                    pane(fullscreenPane)
                } else {
                    VStack(spacing: Theme.Spacing.md) {
                        switch layoutStore.layout {
                        case .single:
                            if let first = panes.first { pane(first) }

                        case .twoColumn:
                            HStack(spacing: Theme.Spacing.md) {
                                ForEach(panes.prefix(2)) { pane($0) }
                            }

                        case .twoRow:
                            ForEach(panes.prefix(2)) { pane($0) }

                        case .grid2x2:
                            HStack(spacing: Theme.Spacing.md) {
                                ForEach(Array(panes.prefix(2))) { pane($0) }
                            }
                            HStack(spacing: Theme.Spacing.md) {
                                ForEach(Array(panes.dropFirst(2).prefix(2))) { pane($0) }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Keep the sidebar-collapse behavior in sync with pane
        // fullscreen the same way the primary chart's own maximise
        // button drives it (see `DashboardView.isChartFull` /
        // `RootView`).
        .onChange(of: fullscreenPaneID) { id in
            app.isChartFullscreen = id != nil
        }
        // A layout change (e.g. 2×2 → 2 columns) can drop the
        // fullscreen pane entirely — always land back in the grid
        // rather than showing a stale, now-nonexistent pane.
        .onChange(of: layoutStore.layout) { _ in
            fullscreenPaneID = nil
        }
    }

    /// Whole-grid fullscreen toggle — distinct from a single pane's own
    /// fullscreen (`fullscreenPaneID`): this hides the sidebar and pair
    /// header while leaving every pane visible, so the full 2×2 (or
    /// 2-up) layout gets the extra room instead of just one chart.
    private var gridToolbar: some View {
        HStack {
            Spacer()
            Button {
                app.isChartFullscreen.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: app.isChartFullscreen
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                    Text(app.isChartFullscreen ? "Exit Fullscreen" : "Fullscreen Grid")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Color.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Theme.Color.surfaceHi))
                .overlay(Capsule().strokeBorder(Theme.Color.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help(app.isChartFullscreen ? "Exit fullscreen" : "Fullscreen the whole grid")
        }
    }

    @ViewBuilder
    private func pane(_ p: ChartPane) -> some View {
        ChartPaneView(
            pane: p,
            indicatorConfig: indicatorConfig,
            drawingStore: drawingStore,
            isFullscreen: Binding(
                get: { fullscreenPaneID == p.id },
                set: { fullscreenPaneID = $0 ? p.id : nil }
            )
        ) { updated in
            layoutStore.updatePane(updated)
        }
    }
}
