import SwiftUI

/// iPad network debug inspector. Shows captured HTTP requests with
/// status, duration, and response preview. Includes a "Copy as cURL"
/// button on each expanded entry.
struct DebugLogSheetiPad: View {
    @ObservedObject private var log = NetworkLog.shared
    @Environment(\.dismiss) private var dismiss
    @State private var expandedID: UUID?
    @State private var copiedID: UUID?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                Divider().background(Theme.Color.border)
                if log.entries.isEmpty {
                    emptyState
                } else {
                    entryList
                }
            }
            .background(Theme.Color.canvas)
            .navigationTitle("Network debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // ── Toggle + summary + clear ──────────────────────────────────
    private var controls: some View {
        HStack(spacing: ThemeiPad.Spacing.md) {
            Toggle(isOn: $log.isEnabled) {
                Text(log.isEnabled
                     ? "Capturing requests"
                     : "Capture disabled")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Color.textPrimary)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Spacer()
            Text("\(log.entries.count) recorded")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.Color.textMuted)
            Button {
                log.clear()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Clear")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.Color.danger.opacity(0.85))
                )
            }
            .buttonStyle(.plain)
            .disabled(log.entries.isEmpty)
            .opacity(log.entries.isEmpty ? 0.4 : 1)
        }
        .padding(.horizontal, ThemeiPad.Spacing.xl)
        .padding(.vertical, ThemeiPad.Spacing.md)
    }

    // ── Entry list ────────────────────────────────────────────────
    private var entryList: some View {
        ScrollView {
            LazyVStack(spacing: 8, pinnedViews: []) {
                ForEach(log.entries) { entry in
                    entryRow(entry)
                }
            }
            .padding(ThemeiPad.Spacing.md)
        }
    }

    /// Compact row with status dot + source chip + method + URL +
    /// status code + duration. Tap to expand and reveal the body.
    private func entryRow(_ entry: NetworkLog.Entry) -> some View {
        let isExpanded = expandedID == entry.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor(for: entry))
                    .frame(width: 8, height: 8)
                Text(entry.source)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.Color.textMuted))
                Text(entry.method)
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.Color.textSecondary)
                Text(entry.url)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let s = entry.status {
                    Text("\(s)")
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(httpStatusColor(s))
                }
                Text(String(format: "%.0f ms", entry.durationMs))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.Color.textMuted)
                Text(Self.timeFormat.string(from: entry.date))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.Color.textMuted)
            }
            if isExpanded {
                expandedDetail(entry)
            }
        }
        .padding(.horizontal, ThemeiPad.Spacing.md)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: ThemeiPad.Radius.sm)
                .fill(Theme.Color.surface)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                expandedID = isExpanded ? nil : entry.id
            }
        }
    }

    /// Expanded panel with cURL copy button, error message, and
    /// response body preview.
    private func expandedDetail(_ entry: NetworkLog.Entry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let err = entry.error {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Color.danger)
            }

            // Copy as cURL
            HStack(spacing: 6) {
                Button {
                    let curl = Self.curlCommand(for: entry)
                    UIPasteboard.general.string = curl
                    copiedID = entry.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        if copiedID == entry.id { copiedID = nil }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: copiedID == entry.id ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                        Text(copiedID == entry.id ? "Copied" : "Copy as cURL")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(copiedID == entry.id ? Theme.Color.success : Theme.Color.accentStart)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Theme.Color.surface)
                    )
                }
                .buttonStyle(.plain)
                Spacer()
            }

            if !entry.responsePreview.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(entry.responsePreview)
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(Theme.Color.textPrimary)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.Color.surfaceHi)
                )
            }
        }
        .padding(.top, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundStyle(Theme.Color.textMuted)
            Text(log.isEnabled
                 ? "No requests captured yet. Trigger a fetch and they'll appear here."
                 : "Capture is disabled. Flip the switch above to start logging.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.Color.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, ThemeiPad.Spacing.xl)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // ── Helpers ───────────────────────────────────────────────────

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

    private static func curlCommand(for entry: NetworkLog.Entry) -> String {
        var parts = ["curl"]
        if entry.method != "GET" {
            parts.append("-X \(entry.method)")
        }
        if let headers = entry.headers {
            for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
                let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
                parts.append("-H '\(key): \(escaped)'")
            }
        }
        let escaped = entry.url
            .replacingOccurrences(of: "'", with: "'\\''")
        parts.append("'\(escaped)'")
        return parts.joined(separator: " \\\n  ")
    }

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
