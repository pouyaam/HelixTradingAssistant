import SwiftUI

/// Browsable history of saved AI day/week/month reviews
/// (`DayReviewStore`) — the "so I can see the history" counterpart to
/// `JournalDayAISheet`'s "Save Review" button. Per-trade AI
/// post-mortems already live inside their `JournalEntry.notes`, so
/// this view only covers the day/week/month reviews, which have
/// nowhere else to persist.
struct DayReviewHistoryView: View {
    @EnvironmentObject private var dayReviewStore: DayReviewStore
    @Environment(\.dismiss) private var dismiss

    @State private var selected: DayReviewEntry? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.Color.border)
            if dayReviewStore.sorted.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(width: 640, height: 620)
        .background(Theme.Color.canvas)
        .sheet(item: $selected) { review in
            DayReviewDetailView(review: review)
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Label("AI Review History", systemImage: "clock.arrow.circlepath")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.Color.textPrimary)
            Spacer()
            if !dayReviewStore.reviews.isEmpty {
                Button {
                    dayReviewStore.clearAll()
                } label: {
                    Text("Clear all")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Color.danger)
                }
                .buttonStyle(.plain)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.Color.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.Spacing.lg)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Spacing.sm) {
                ForEach(dayReviewStore.sorted) { review in
                    row(review)
                        .onTapGesture { selected = review }
                }
            }
            .padding(Theme.Spacing.lg)
        }
    }

    private func row(_ review: DayReviewEntry) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(review.periodTitle)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.Color.textPrimary)
                HStack(spacing: 6) {
                    Text("\(review.tradeCount) trades")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Color.textMuted)
                    Text("· \(review.engineLabel) · \(review.modelLabel)")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Color.textMuted)
                    Text("· \(Self.dateFmt.string(from: review.createdAt))")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Color.textMuted)
                }
            }
            Spacer()
            Text(String(format: "%+.2f", review.netPL))
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundStyle(review.netPL >= 0 ? Theme.Color.success : Theme.Color.danger)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.Color.textMuted)
        }
        .padding(Theme.Spacing.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.Color.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.Color.border, lineWidth: 1))
        .contentShape(Rectangle())
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40))
                .foregroundStyle(Theme.Color.textMuted)
            Text("No saved reviews yet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Color.textSecondary)
            Text("Run an AI day/week/month review and tap \"Save Review\" to keep it here.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d, yyyy · HH:mm"; return f
    }()
}

/// Read-only viewer for one saved review — same "## " section parsing
/// `JournalDayAISheet` uses for the live result, kept as a small local
/// copy since the original is private to that view.
private struct DayReviewDetailView: View {
    let review: DayReviewEntry
    @Environment(\.dismiss) private var dismiss

    private struct Section: Identifiable {
        let id: String
        let title: String
        let body: String
    }

    private var sections: [Section] {
        let lines = review.report.components(separatedBy: "\n")
        var buckets: [(header: String, lines: [String])] = []
        var current: (header: String, lines: [String])?
        for line in lines {
            if line.hasPrefix("## ") {
                if let c = current { buckets.append(c) }
                current = (String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), [])
            } else if current != nil {
                current!.lines.append(line)
            }
        }
        if let c = current { buckets.append(c) }
        return buckets.enumerated().map { i, bucket in
            Section(id: "\(i)", title: bucket.header,
                     body: bucket.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.sm) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(review.periodTitle)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.Color.textPrimary)
                    Text("\(review.tradeCount) trades · \(review.engineLabel) \(review.modelLabel)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Color.textMuted)
                }
                Spacer()
                Button {
                    #if os(iOS)
                    UIPasteboard.general.string = review.report
                    #else
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(review.report, forType: .string)
                    #endif
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.Color.surface))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.Color.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.Color.textMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(Theme.Spacing.lg)
            Divider().background(Theme.Color.border)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    if sections.isEmpty {
                        Text(review.report)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Color.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(sections) { section in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(section.title)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Theme.Color.textPrimary)
                                AIMarkdownLines(bodyText: section.body,
                                    accentColor: Theme.Color.info,
                                    bodyColor: Theme.Color.textSecondary)
                            }
                            .padding(Theme.Spacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.Color.surface))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.Color.border, lineWidth: 1))
                        }
                    }
                }
                .padding(Theme.Spacing.lg)
            }
        }
        .frame(width: 680, height: 640)
        .background(Theme.Color.canvas)
    }
}
