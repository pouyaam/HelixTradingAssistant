import SwiftUI
import AppKit

/// Modifier that deletes the selected drawing when the user presses
/// Backspace (keyCode 51) or Forward Delete (keyCode 117).
///
/// Follows the same `NSEvent.addLocalMonitorForEvents` pattern as
/// `ScrollZoomModifier` — a window-level key-down monitor that
/// checks whether a drawing is selected and, if so, removes it
/// from the store and clears the selection. Events are consumed
/// so the system doesn't beep.
struct DrawingDeleteKeyHandler: ViewModifier {
    @Binding var selectedDrawingID: UUID?
    let drawingStore: DrawingStore
    let pairID: String

    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear { installMonitor() }
            .onDisappear { removeMonitor() }
    }

    private func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Backspace (Delete) = 51, Forward Delete = 117
            guard event.keyCode == 51 || event.keyCode == 117 else {
                return event
            }
            guard let id = selectedDrawingID else { return event }
            drawingStore.remove(id: id, for: pairID)
            selectedDrawingID = nil
            return nil // consumed
        }
    }

    private func removeMonitor() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }
}

extension View {
    /// Delete the selected drawing on Backspace/Forward-Delete key press.
    func drawingDeleteKey(
        selectedDrawingID: Binding<UUID?>,
        drawingStore: DrawingStore,
        pairID: String
    ) -> some View {
        modifier(DrawingDeleteKeyHandler(
            selectedDrawingID: selectedDrawingID,
            drawingStore: drawingStore,
            pairID: pairID
        ))
    }
}
