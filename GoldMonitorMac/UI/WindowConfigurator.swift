import SwiftUI
import AppKit

/// Bridge that hands back the `NSWindow` hosting a SwiftUI view, so we
/// can run AppKit-only configuration (entering fullscreen on launch,
/// pinning min sizes, etc.) without writing an `NSApplicationDelegate`.
///
/// Use as a transparent background view; the closure fires exactly once
/// per attachment after the view's window relationship is established.
struct WindowConfigurator: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // Window isn't wired to the view until the next run-loop tick,
        // so defer to main.async (and retry once if it's still nil —
        // SwiftUI sometimes inserts the view a tick early during sheet
        // dismissals etc.).
        DispatchQueue.main.async {
            if let window = view.window {
                configure(window)
                return
            }
            DispatchQueue.main.async {
                if let window = view.window {
                    configure(window)
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
