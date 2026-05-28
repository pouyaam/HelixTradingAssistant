import SwiftUI

/// Floating inspector for a single selected drawing. Sits as a chart
/// overlay (top-trailing in DashboardView) and lets the user retune
/// the drawing's colour, alpha, and line width — or delete it.
///
/// All edits go through `onChange` with the same `id`, so the store's
/// `update(_:for:)` replaces in place. The dashboard owns the
/// selection / store; this view is stateless beyond the drawing it's
/// handed.
struct DrawingInspector: View {
    /// The drawing being edited. Re-renders on each tweak so SwiftUI's
    /// `ColorPicker` binding round-trips through the store rather than
    /// keeping local state out of sync.
    let drawing: ChartDrawing

    /// Called with the modified drawing (same id, mutated fields).
    let onChange: (ChartDrawing) -> Void

    /// Called when the user clicks the trash. Dashboard removes the
    /// drawing and clears its selection state.
    let onDelete: () -> Void

    /// Closes the inspector without deleting the drawing. Same effect
    /// as clicking empty chart space.
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            kindBadge

            colorWell

            // Line width — only meaningful for line-style drawings;
            // the rectangle's border width follows the same field so
            // the inspector stays uniform.
            HStack(spacing: 6) {
                Image(systemName: "lineweight")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Color.textMuted)
                Slider(value: lineWidthBinding, in: 1...5, step: 0.5)
                    .frame(width: 90)
                Text(String(format: "%.1f", drawing.lineWidth))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(width: 24, alignment: .trailing)
            }

            Divider()
                .frame(height: 18)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Color.danger)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Theme.Color.danger.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
            .help("Delete drawing")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Color.surfaceMax.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .strokeBorder(Theme.Color.border, lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
    }

    // MARK: - Bits

    /// Tag chip showing what kind of drawing this is. Provides
    /// minimal context so the inspector doesn't read as a floating
    /// orphan UI.
    private var kindBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: kindIcon)
                .font(.system(size: 10, weight: .semibold))
            Text(kindLabel)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(Theme.Color.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Theme.Color.surface)
        )
    }

    private var kindIcon: String {
        switch drawing.kind {
        case .horizontalLine: return "minus"
        case .trendLine:      return "line.diagonal"
        case .rectangle:      return "rectangle"
        }
    }

    private var kindLabel: String {
        switch drawing.kind {
        case .horizontalLine: return "Horizontal"
        case .trendLine:      return "Trend line"
        case .rectangle:      return "Rectangle"
        }
    }

    /// SwiftUI ColorPicker bound to the drawing's stored colour. We
    /// allow opacity (the "alpha" half of requirement #4) so a single
    /// picker covers both colour and alpha. Round-tripped through
    /// `ColorRGBA(_:)` which extracts components via NSColor's sRGB
    /// space.
    private var colorWell: some View {
        ColorPicker(
            "Color",
            selection: Binding<Color>(
                get: { drawing.color.color },
                set: { newColor in
                    var copy = drawing
                    copy.color = ColorRGBA(newColor)
                    onChange(copy)
                }
            ),
            supportsOpacity: true
        )
        .labelsHidden()
        .help("Stroke color · also drives fill opacity")
    }

    /// Slider binding for the line width. Goes through the same
    /// `onChange` callback so the chart re-renders immediately.
    private var lineWidthBinding: Binding<Double> {
        Binding<Double>(
            get: { drawing.lineWidth },
            set: { newWidth in
                var copy = drawing
                copy.lineWidth = newWidth
                onChange(copy)
            }
        )
    }
}
