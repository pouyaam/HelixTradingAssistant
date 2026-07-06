import SwiftUI

/// Standalone input chip for chat suggestions.
struct ChatInputChip: Hashable, Identifiable {
    let id: String
    let label: String
    let body: String
}

/// Self-contained chat input. Owns its own `draft: @State` so a
/// keystroke only invalidates this view's body — not the parent
/// AnalysisReportColumn (which renders potentially-long Markdown
/// + a chart preview + plan cards). Moving the state down here is
/// the standard SwiftUI fix for "typing into a TextField feels
/// laggy because the whole pane re-diffs on every character".
///
/// The parent passes a `chips` list (optional quick-fills), a
/// placeholder, a `isBusy` flag (disables typing + send while a
/// turn is streaming), and an `onSubmit` closure that fires on
/// Enter / send-button. Submission clears the draft; busy-state
/// just dims the controls.
struct ChatInputBar: View {
    let placeholder: String
    let chips: [ChatInputChip]
    let isBusy: Bool
    var onSubmit: (String) -> Void

    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if !chips.isEmpty {
                chipRow
            }
            inputRow
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
        .background(Theme.Color.surface)
        .overlay(
            Rectangle()
                .fill(Theme.Color.border)
                .frame(height: 1),
            alignment: .top
        )
    }

    // ── Chip row ──────────────────────────────────────────────────
    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(chips) { chip in
                    Button {
                        // Replace the draft so the user can read +
                        // edit the suggestion before sending. Skips
                        // auto-submit so accidental taps don't fire
                        // a query.
                        draft = chip.body
                    } label: {
                        Text(chip.label)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.Color.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Theme.Color.surfaceHi)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(Theme.Color.border, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(chip.body)
                }
            }
        }
    }

    // ── Input row ─────────────────────────────────────────────────
    private var inputRow: some View {
        let canSend = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Color.textMuted)
            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit { submit() }
                .disabled(isBusy)

            Button {
                submit()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(canSend && !isBusy
                                     ? Theme.Color.accentStart
                                     : Theme.Color.textMuted)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSend || isBusy)
        }
    }

    private func submit() {
        let q = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isBusy else { return }
        onSubmit(q)
        draft = ""
    }
}
