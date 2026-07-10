import SwiftUI

/// Renders a monospaced reasoning trace without re-laying out the
/// entire string on every chunk.
///
/// A single growing `Text(thinking)` view forces AppKit to re-wrap and
/// re-render the whole trace each time a token arrives. On long
/// extended-thinking runs this becomes O(n²) and the UI falls behind
/// the stream. This view splits the trace into paragraphs, keeps the
/// split result in local state, and renders only the paragraphs near
/// the viewport inside a `LazyVStack`.
struct ThinkingTraceView: View {
    let text: String

    /// Paragraphs are recomputed only when `text` changes, not on
    /// every body render. We keep empty strings so the offset-based
    /// identity is stable while the last paragraph grows.
    @State private var paragraphs: [String] = []

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.Color.textMuted)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { refreshParagraphs(text) }
        .onChange(of: text) { refreshParagraphs($0) }
    }

    private func refreshParagraphs(_ t: String) {
        paragraphs = t.components(separatedBy: "\n\n")
    }
}
