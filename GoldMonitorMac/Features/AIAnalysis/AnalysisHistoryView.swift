import SwiftUI

/// Full-width history list shown when the user hits the "History" button
/// in the analysis page header. Slides over the report + plans columns;
/// the page's bottom action dock goes inactive while it's up.
///
/// Entries are scoped to the currently-selected pair + kind so the list
/// stays relevant ("show me past Gold Ounce technical analyses") without
/// forcing the user to dig through unrelated runs.
struct AnalysisHistoryView: View {
    let pair: TradingPair
    let kind: AnalysisKind
    @EnvironmentObject private var store: AnalysisStore

    /// Called when the user picks an entry. The page reloads the
    /// session for the entry's kind, fires the restore callbacks for
    /// any chart overlays the entry carried, and dismisses the
    /// history view back to the live layout.
    var onOpen: (AnalysisStore.HistoryEntry) -> Void
    /// Called when the user hits "Back to live".
    var onDismiss: () -> Void

    private var entries: [AnalysisStore.HistoryEntry] {
        store.history.filter { $0.kind == kind && $0.pairID == pair.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            Divider().background(Theme.Color.border)
            if entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        if winRateStats.totalGraded > 0 {
                            winRateCard
                        }
                        ForEach(entries) { entry in
                            row(entry)
                        }
                    }
                    .padding(Theme.Spacing.xl)
                }
            }
            if !entries.isEmpty {
                footerRow
            }
        }
        .background(Theme.Color.canvas)
    }

    // ── Win-rate roll-up ──────────────────────────────────────────

    /// Aggregate W/L statistics for the entries currently in view.
    /// Manual closes and cancellations are excluded from the
    /// denominator — they don't represent the analysis being
    /// "right" or "wrong" about direction.
    private struct WinRateStats {
        var wins: Int = 0
        var losses: Int = 0
        var manual: Int = 0
        var realisedPLSum: Double = 0
        var totalGraded: Int { wins + losses }
        var winRate: Double {
            totalGraded == 0 ? 0 : Double(wins) / Double(totalGraded)
        }
    }

    private var winRateStats: WinRateStats {
        var s = WinRateStats()
        for entry in entries {
            switch entry.outcome {
            case .hitTP:     s.wins += 1
            case .hitSL:     s.losses += 1
            case .manual:    s.manual += 1
            case .cancelled, .none: continue
            }
            if let pl = entry.outcomeRealisedPL { s.realisedPLSum += pl }
        }
        return s
    }

    private var winRateCard: some View {
        let s = winRateStats
        let rate = s.winRate * 100
        let plColor: Color = s.realisedPLSum >= 0 ? Theme.Color.success : Theme.Color.danger
        return HStack(spacing: Theme.Spacing.lg) {
            statBlock(
                label: "WIN RATE",
                value: String(format: "%.0f%%", rate),
                tint: rate >= 50 ? Theme.Color.success : Theme.Color.danger
            )
            Divider().background(Theme.Color.border).frame(height: 32)
            statBlock(label: "WINS",   value: "\(s.wins)",   tint: Theme.Color.success)
            statBlock(label: "LOSSES", value: "\(s.losses)", tint: Theme.Color.danger)
            if s.manual > 0 {
                statBlock(label: "MANUAL", value: "\(s.manual)", tint: Theme.Color.textSecondary)
            }
            Divider().background(Theme.Color.border).frame(height: 32)
            statBlock(
                label: "REALISED P/L",
                value: String(format: "%+.2f", s.realisedPLSum),
                tint: plColor
            )
            Spacer()
        }
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Color.surfaceHi)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(Theme.Color.border, lineWidth: 1)
        )
    }

    private func statBlock(label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(Theme.Color.textMuted)
            Text(value)
                .font(.system(size: 16, weight: .bold).monospacedDigit())
                .foregroundStyle(tint)
        }
    }

    // ── Header ─────────────────────────────────────────────────────
    private var headerRow: some View {
        HStack(spacing: Theme.Spacing.md) {
            Button(action: onDismiss) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Back to live")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Theme.Color.textSecondary)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surface)
                )
            }
            .buttonStyle(.plain)

            Text("History · \(kind.label) · \(pair.name)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Color.textPrimary)
            Spacer()
            Text("\(entries.count) entr\(entries.count == 1 ? "y" : "ies")")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textMuted)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
    }

    // ── Row ────────────────────────────────────────────────────────
    private func row(_ entry: AnalysisStore.HistoryEntry) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.dateFmt.string(from: entry.date))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                HStack(spacing: 8) {
                    Text(entry.timeframeLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.Color.textSecondary)
                    Text("·")
                        .foregroundStyle(Theme.Color.textMuted)
                    Text(entry.engineLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.Color.textSecondary)
                    Text("·")
                        .foregroundStyle(Theme.Color.textMuted)
                    Text("\(entry.report.count) chars")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Color.textMuted)
                    overlayTags(entry)
                }
            }
            Spacer()
            outcomeChip(entry)
            Button("Open") {
                onOpen(entry)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(Theme.Color.info)
            )

            Button {
                store.deleteHistory(entry)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Color.textMuted)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("Delete this entry")
        }
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Color.surface)
        )
    }

    /// Small badges showing which overlay payloads the entry carried,
    /// so the user can spot at a glance which runs produced full plans
    /// vs bare prose.
    @ViewBuilder
    private func overlayTags(_ entry: AnalysisStore.HistoryEntry) -> some View {
        if let sr = entry.srLevels, !sr.isEmpty {
            tag(text: "S/R", color: Theme.Color.info)
        }
        if let fvg = entry.fvgZones, !fvg.isEmpty {
            tag(text: "FVG", color: Theme.Color.warn)
        }
        if entry.taScenario != nil {
            tag(text: "PLAN", color: Theme.Color.success)
        }
        if entry.taAltScenario != nil {
            tag(text: "ALT", color: Theme.Color.textSecondary)
        }
    }

    /// Per-entry outcome chip — WIN / LOSS / MANUAL / CANCELLED /
    /// blank (for entries the user never activated). Includes the
    /// realised P/L when available so the row reads at a glance.
    @ViewBuilder
    private func outcomeChip(_ entry: AnalysisStore.HistoryEntry) -> some View {
        if let outcome = entry.outcome {
            let (label, color): (String, Color) = {
                switch outcome {
                case .hitTP:     return ("WIN",       Theme.Color.success)
                case .hitSL:     return ("LOSS",      Theme.Color.danger)
                case .manual:    return ("MANUAL",    Theme.Color.textSecondary)
                case .cancelled: return ("CANCELLED", Theme.Color.textMuted)
                }
            }()
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(0.5)
                if let pl = entry.outcomeRealisedPL {
                    Text(String(format: "%+.2f", pl))
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .opacity(0.85)
                }
            }
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(color.opacity(0.18))
            )
        }
    }

    private func tag(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .heavy))
            .tracking(0.4)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(color.opacity(0.18))
            )
    }

    // ── Footer ─────────────────────────────────────────────────────
    private var footerRow: some View {
        HStack {
            Spacer()
            Button("Clear all history") {
                store.clearAllHistory()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.Color.textMuted)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundStyle(Theme.Color.textMuted)
            Text("No saved \(kind.label) runs yet for \(pair.name).")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Color.textMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy · HH:mm"
        return f
    }()
}
