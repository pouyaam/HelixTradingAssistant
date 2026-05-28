import SwiftUI

/// Floating "controls" puck that lives in the bottom-right corner of
/// the chart. Tap the main button and the four chart controls (zoom in,
/// zoom out, reset zoom, maximise) fan out in a quarter-arc going
/// up-and-to-the-left.
///
/// Used to live in the top toolbar as a row of buttons but that crowded
/// the header with controls the user only reaches for occasionally.
/// Folding them into a FAB keeps the toolbar focused on selection
/// (indicators / tools / timeframe) and tucks navigation onto the
/// chart itself where it's contextual.
struct ChartControlsFAB: View {
    /// Bound to AppState's fullscreen flag so the maximise icon flips
    /// to "restore" when already in fullscreen.
    @Binding var isFullscreen: Bool

    let onZoomIn: () -> Void
    let onZoomOut: () -> Void
    let onReset: () -> Void

    @State private var expanded: Bool = false

    /// Distance from main-button centre to each fan-out child. ~58pt
    /// keeps the 32pt children clear of the 40pt main button.
    private let radius: CGFloat = 58
    private let mainSize: CGFloat = 40
    private let actionSize: CGFloat = 32

    var body: some View {
        ZStack {
            // Translucent backdrop swallows clicks outside the FAB
            // while it's open so a tap elsewhere collapses it. Sized
            // generously so the entire chart area dismisses on tap.
            if expanded {
                Color.black.opacity(0.001)
                    .frame(width: 4000, height: 4000)
                    .contentShape(Rectangle())
                    .onTapGesture { collapse() }
                    .transition(.opacity)
            }

            // Children. Each ForEach pass renders one fan-out button at
            // its precomputed angle around the main FAB.
            ForEach(Array(actions.enumerated()), id: \.offset) { idx, action in
                let angle = arcAngle(for: idx, count: actions.count)
                actionButton(action)
                    .offset(
                        x: expanded ? radius * cos(angle) : 0,
                        y: expanded ? -radius * sin(angle) : 0
                    )
                    .opacity(expanded ? 1 : 0)
                    .scaleEffect(expanded ? 1 : 0.3)
            }

            // Main puck. Spins the icon when toggling so the change
            // from "menu" to "close" reads as motion, not a swap.
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    expanded.toggle()
                }
            } label: {
                Image(systemName: expanded ? "xmark" : "slider.horizontal.3")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: mainSize, height: mainSize)
                    .background(Circle().fill(Theme.accentGradient))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide controls" : "Chart controls")
        }
        // The fan-out children offset away from the main button — give
        // the ZStack enough room so they aren't clipped by the chart's
        // bounds. Aligns the visible main button to the bottom-right
        // anchor while the children animate into the empty space above.
        .frame(width: mainSize, height: mainSize)
    }

    private func collapse() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            expanded = false
        }
    }

    // ── Actions ────────────────────────────────────────────────────

    /// Bundles the four controls into a single ordered list so the
    /// arc-angle math has one source of truth (`actions.count`) and
    /// adding a new control is a one-line append.
    private struct Action {
        let icon: String
        let help: String
        let perform: () -> Void
    }

    private var actions: [Action] {
        [
            Action(icon: "plus",
                   help: "Zoom in",
                   perform: onZoomIn),
            Action(icon: "minus",
                   help: "Zoom out",
                   perform: onZoomOut),
            Action(icon: "arrow.counterclockwise",
                   help: "Reset zoom",
                   perform: onReset),
            Action(icon: isFullscreen
                   ? "arrow.down.right.and.arrow.up.left"
                   : "arrow.up.left.and.arrow.down.right",
                   help: isFullscreen ? "Restore" : "Maximise chart",
                   perform: { isFullscreen.toggle() }),
        ]
    }

    /// Even angular spacing across the up-and-left quarter arc (90°→
    /// 180°). Degrees converted to radians for `cos` / `sin`.
    /// SwiftUI's Y axis points down, so we use `-sin(angle)` to send
    /// the up-quadrant children upward visually.
    private func arcAngle(for index: Int, count: Int) -> Double {
        let startDeg = 90.0   // straight up
        let endDeg   = 180.0  // straight left
        let step = (endDeg - startDeg) / Double(max(count - 1, 1))
        let deg = startDeg + step * Double(index)
        return deg * .pi / 180
    }

    @ViewBuilder
    private func actionButton(_ action: Action) -> some View {
        Button {
            action.perform()
            // Deliberately do NOT auto-collapse — users typically tap
            // zoom-in several times in a row. Re-tap the main button
            // (or anywhere off the FAB) to dismiss.
        } label: {
            Image(systemName: action.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Color.textPrimary)
                .frame(width: actionSize, height: actionSize)
                .background(Circle().fill(Theme.Color.surfaceHi))
                .overlay(Circle().strokeBorder(Theme.Color.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.28), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .help(action.help)
    }
}
