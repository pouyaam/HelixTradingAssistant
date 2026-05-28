import SwiftUI

/// Debug network-log inspector. Reached via the 🐞 button in the
/// chart header. Lists every captured request/response newest-first
/// with status/duration/preview, plus a toggle to turn capture on or
/// off and a button to wipe the buffer.
///
/// The view binds to `NetworkLog.shared` directly (not via env object)
/// — there's only ever one instance, the singleton owns its state,
/// and threading it through the env tree would just add noise.
struct DebugLogSheet: View {
    @ObservedObject private var log = NetworkLog.shared
    @Environment(\.dismiss) private var dismiss
    @State private var expandedID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.Color.border)
            controls
            Divider().background(Theme.Color.border)
            if log.entries.isEmpty {
                emptyState
            } else {
                entryList
            }
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 480, idealHeight: 640)
        .background(Theme.Color.canvas)
    }

    // ── Header ─────────────────────────────────────────────────────
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "ladybug.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.Color.warn)
            Text("Network debug")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.Color.textPrimary)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surface))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
    }

    // ── Toggle + summary + clear ──────────────────────────────────
    private var controls: some View {
        HStack(spacing: Theme.Spacing.md) {
            Toggle(isOn: $log.isEnabled) {
                Text(log.isEnabled
                     ? "Capturing requests"
                     : "Capture disabled")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Color.textPrimary)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Spacer()
            Text("\(log.entries.count) recorded")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.Color.textMuted)
            clearButton
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
    }

    /// Wipe the log without changing the enabled flag. Disabled when
    /// there's nothing to clear so the user gets visual feedback that
    /// the action would be a no-op.
    private var clearButton: some View {
        Button {
            log.clear()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text("Clear log")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.Color.danger.opacity(0.85))
            )
        }
        .buttonStyle(.plain)
        .disabled(log.entries.isEmpty)
        .opacity(log.entries.isEmpty ? 0.4 : 1)
        .help("Remove every captured request from the log")
        .keyboardShortcut(.delete, modifiers: [.command])
    }

    // ── Entry list ────────────────────────────────────────────────
    private var entryList: some View {
        ScrollView {
            LazyVStack(spacing: 6, pinnedViews: []) {
                ForEach(log.entries) { entry in
                    entryRow(entry)
                }
            }
            .padding(Theme.Spacing.md)
        }
    }

    /// Compact row with status dot + source chip + method + URL +
    /// status code + duration. Tap to expand and reveal the body.
    private func entryRow(_ entry: NetworkLog.Entry) -> some View {
        let isExpanded = expandedID == entry.id
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor(for: entry))
                    .frame(width: 7, height: 7)
                Text(entry.source)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.Color.textMuted))
                Text(entry.method)
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.Color.textSecondary)
                Text(entry.url)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let s = entry.status {
                    Text("\(s)")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(httpStatusColor(s))
                }
                Text(String(format: "%.0f ms", entry.durationMs))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Theme.Color.textMuted)
                Text(Self.timeFormat.string(from: entry.date))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Theme.Color.textMuted)
            }
            if isExpanded {
                expandedDetail(entry)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(Theme.Color.surface)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                expandedID = isExpanded ? nil : entry.id
            }
        }
    }

    /// Expanded panel with error message (if any) and the captured
    /// response body. Body is `textSelection(.enabled)` so the user
    /// can copy JSON straight out.
    private func expandedDetail(_ entry: NetworkLog.Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let err = entry.error {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Color.danger)
            }
            if !entry.responsePreview.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(entry.responsePreview)
                        .font(.system(size: 10).monospaced())
                        .foregroundStyle(Theme.Color.textPrimary)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.Color.surfaceHi)
                )
            }
        }
        .padding(.top, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 26))
                .foregroundStyle(Theme.Color.textMuted)
            Text(log.isEnabled
                 ? "No requests captured yet. Trigger a fetch and they'll appear here."
                 : "Capture is disabled. Flip the switch above to start logging.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.xl)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // ── Formatting helpers ────────────────────────────────────────
    private func dotColor(for entry: NetworkLog.Entry) -> Color {
        if entry.error != nil { return Theme.Color.danger }
        if let s = entry.status, !(200..<300).contains(s) { return Theme.Color.warn }
        return Theme.Color.success
    }

    private func httpStatusColor(_ status: Int) -> Color {
        switch status {
        case 200..<300: return Theme.Color.success
        case 300..<400: return Theme.Color.info
        case 400..<500: return Theme.Color.warn
        default:        return Theme.Color.danger
        }
    }

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
