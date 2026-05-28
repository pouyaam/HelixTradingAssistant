import SwiftUI
import Charts

/// Analytics dashboard built from the outcome data the AnalysisStore
/// has been collecting. Lives under the sidebar's Portfolio entry
/// (replaces the post-MVP placeholder there). Surfaces the three
/// metrics that actually decide whether a strategy has edge:
///
///   • **Equity curve** — cumulative realised P/L over time, by
///     analysis kind. A flat line = no edge; a rising one = real
///     skill (or luck — needs enough samples to tell).
///   • **Profit factor** — gross wins / gross losses. Anything
///     under 1.0 is a losing strategy; 1.5+ is professional-grade.
///   • **Expectancy per kind** — average $ won per trade. Lets the
///     user compare Full TA vs Confluence Trade Scanner on the dimension that
///     compounds (a 60% win rate at 0.5R is worse than 40% at 2R).
struct AnalyticsView: View {
    @EnvironmentObject private var analysisStore: AnalysisStore

    /// Filter chip — Portfolio / All / per-kind. Lets the user drill
    /// in on Confluence Trade Scanner specifically vs the noise of every Full TA
    /// they've ever run.
    @State private var kindFilter: KindFilter = .all

    enum KindFilter: Hashable, Identifiable {
        case all
        case kind(AnalysisKind)
        var id: String {
            switch self {
            case .all:           return "all"
            case .kind(let k):   return k.rawValue
            }
        }
        var label: String {
            switch self {
            case .all:           return "All kinds"
            case .kind(let k):   return k.label
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                header
                if gradedEntries.isEmpty {
                    emptyState
                } else {
                    summaryCards
                    kindFilterRow
                    equityCurveCard
                    perKindBreakdownCard
                    recentTradesCard
                }
            }
            .padding(Theme.Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Color.canvas)
    }

    // ── Header ─────────────────────────────────────────────────────
    private var header: some View {
        HStack {
            Label("Analytics", systemImage: "chart.line.uptrend.xyaxis")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.Color.textPrimary)
            Spacer()
        }
    }

    // ── Filter chips ───────────────────────────────────────────────
    private var availableKindFilters: [KindFilter] {
        let kindsInUse = Array(Set(allGradedEntries.map(\.kind))).sorted { $0.rawValue < $1.rawValue }
        return [.all] + kindsInUse.map { .kind($0) }
    }

    private var kindFilterRow: some View {
        HStack(spacing: 6) {
            Text("FILTER")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)
            ForEach(availableKindFilters) { f in
                Button {
                    kindFilter = f
                } label: {
                    Text(f.label)
                        .font(.system(size: 11, weight: kindFilter == f ? .bold : .medium))
                        .foregroundStyle(kindFilter == f ? .white : Theme.Color.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(kindFilter == f
                                      ? AnyShapeStyle(Theme.accentGradient)
                                      : AnyShapeStyle(Theme.Color.surface))
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // ── Data slices ────────────────────────────────────────────────

    /// All entries that have a TP/SL outcome (manual + cancelled
    /// don't reflect whether the analysis was right). The "all"
    /// slice ignores the kind filter so the chip row knows which
    /// chips to even show.
    private var allGradedEntries: [AnalysisStore.HistoryEntry] {
        analysisStore.history.filter {
            $0.outcome == .hitTP || $0.outcome == .hitSL
        }
    }

    private var gradedEntries: [AnalysisStore.HistoryEntry] {
        switch kindFilter {
        case .all:
            return allGradedEntries
        case .kind(let k):
            return allGradedEntries.filter { $0.kind == k }
        }
    }

    /// Aggregate stats for the currently-filtered slice.
    private struct Stats {
        var wins: Int = 0
        var losses: Int = 0
        var grossProfit: Double = 0      // sum of winning P/L
        var grossLoss: Double = 0        // abs(sum of losing P/L)
        var totalGraded: Int { wins + losses }
        var net: Double { grossProfit - grossLoss }
        var winRate: Double { totalGraded == 0 ? 0 : Double(wins) / Double(totalGraded) }
        var profitFactor: Double {
            grossLoss == 0 ? (grossProfit > 0 ? .infinity : 0) : grossProfit / grossLoss
        }
        /// Expected $ per trade = average net P/L across all
        /// graded trades. Negative = losing strategy.
        var expectancy: Double {
            totalGraded == 0 ? 0 : net / Double(totalGraded)
        }
    }

    private var stats: Stats {
        statsFor(gradedEntries)
    }

    private func statsFor(_ entries: [AnalysisStore.HistoryEntry]) -> Stats {
        var s = Stats()
        for e in entries {
            let pl = e.outcomeRealisedPL ?? 0
            switch e.outcome {
            case .hitTP:
                s.wins += 1
                s.grossProfit += max(0, pl)
            case .hitSL:
                s.losses += 1
                s.grossLoss += abs(min(0, pl))
            default: continue
            }
        }
        return s
    }

    // ── Summary cards ──────────────────────────────────────────────

    private var summaryCards: some View {
        let s = stats
        return HStack(spacing: Theme.Spacing.md) {
            statCard(label: "TRADES",
                     value: "\(s.totalGraded)",
                     subtitle: "\(s.wins)W / \(s.losses)L",
                     tint: Theme.Color.textPrimary)
            statCard(label: "WIN RATE",
                     value: String(format: "%.0f%%", s.winRate * 100),
                     subtitle: "of graded trades",
                     tint: s.winRate >= 0.5 ? Theme.Color.success : Theme.Color.danger)
            statCard(label: "PROFIT FACTOR",
                     value: s.profitFactor.isInfinite ? "∞" : String(format: "%.2f", s.profitFactor),
                     subtitle: "gross wins / gross losses",
                     tint: s.profitFactor >= 1.5 ? Theme.Color.success
                           : (s.profitFactor >= 1.0 ? Theme.Color.warn : Theme.Color.danger))
            statCard(label: "EXPECTANCY",
                     value: String(format: "%+.2f", s.expectancy),
                     subtitle: "avg P/L per trade",
                     tint: s.expectancy >= 0 ? Theme.Color.success : Theme.Color.danger)
            statCard(label: "NET P/L",
                     value: String(format: "%+.2f", s.net),
                     subtitle: "realised, all trades",
                     tint: s.net >= 0 ? Theme.Color.success : Theme.Color.danger)
        }
    }

    private func statCard(label: String, value: String, subtitle: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(Theme.Color.textMuted)
            Text(value)
                .font(.system(size: 22, weight: .bold).monospacedDigit())
                .foregroundStyle(tint)
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(Theme.Color.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Color.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(Theme.Color.border, lineWidth: 1)
        )
    }

    // ── Equity curve ───────────────────────────────────────────────

    /// Cumulative net P/L plotted against trade index (1, 2, 3…).
    /// Index-based rather than date-based so a long flat period
    /// between trades doesn't make the curve look like a cliff.
    private struct EquityPoint: Identifiable {
        let id: Int
        let cumulative: Double
        let date: Date
    }

    private var equityPoints: [EquityPoint] {
        let sorted = gradedEntries.sorted {
            ($0.outcomeAt ?? $0.date) < ($1.outcomeAt ?? $1.date)
        }
        var running = 0.0
        return sorted.enumerated().map { (idx, e) in
            running += e.outcomeRealisedPL ?? 0
            return EquityPoint(id: idx + 1, cumulative: running, date: e.outcomeAt ?? e.date)
        }
    }

    private var equityCurveCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("EQUITY CURVE")
                .font(.system(size: 10, weight: .heavy))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)
            Chart {
                ForEach(equityPoints) { p in
                    LineMark(
                        x: .value("Trade", p.id),
                        y: .value("Cumulative P/L", p.cumulative)
                    )
                    .foregroundStyle(Theme.Color.accentStart)
                    .interpolationMethod(.monotone)
                    AreaMark(
                        x: .value("Trade", p.id),
                        y: .value("Cumulative P/L", p.cumulative)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Theme.Color.accentStart.opacity(0.25), .clear],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.monotone)
                }
                RuleMark(y: .value("Break-even", 0))
                    .foregroundStyle(Theme.Color.textMuted.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .frame(height: 240)
            Text("X axis = trade index · Y axis = cumulative realised P/L")
                .font(.system(size: 10))
                .foregroundStyle(Theme.Color.textMuted)
        }
        .padding(Theme.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Color.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(Theme.Color.border, lineWidth: 1)
        )
    }

    // ── Per-kind breakdown ────────────────────────────────────────

    private var perKindBreakdownCard: some View {
        let groups: [(AnalysisKind, Stats)] = AnalysisKind.allCases.compactMap { k in
            let subset = allGradedEntries.filter { $0.kind == k }
            guard !subset.isEmpty else { return nil }
            return (k, statsFor(subset))
        }
        return VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("BY ANALYSIS KIND")
                .font(.system(size: 10, weight: .heavy))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)
            // Column headers.
            HStack(spacing: Theme.Spacing.md) {
                Text("Kind")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Trades").frame(width: 60, alignment: .trailing)
                Text("Win %").frame(width: 60, alignment: .trailing)
                Text("PF").frame(width: 60, alignment: .trailing)
                Text("Expectancy").frame(width: 100, alignment: .trailing)
                Text("Net").frame(width: 80, alignment: .trailing)
            }
            .font(.system(size: 9, weight: .heavy))
            .tracking(0.4)
            .foregroundStyle(Theme.Color.textMuted)

            ForEach(groups, id: \.0) { kind, s in
                HStack(spacing: Theme.Spacing.md) {
                    Text(kind.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Color.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(s.totalGraded)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.Color.textSecondary)
                        .frame(width: 60, alignment: .trailing)
                    Text(String(format: "%.0f%%", s.winRate * 100))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(s.winRate >= 0.5 ? Theme.Color.success : Theme.Color.danger)
                        .frame(width: 60, alignment: .trailing)
                    Text(s.profitFactor.isInfinite ? "∞" : String(format: "%.2f", s.profitFactor))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(s.profitFactor >= 1.0 ? Theme.Color.success : Theme.Color.danger)
                        .frame(width: 60, alignment: .trailing)
                    Text(String(format: "%+.2f", s.expectancy))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(s.expectancy >= 0 ? Theme.Color.success : Theme.Color.danger)
                        .frame(width: 100, alignment: .trailing)
                    Text(String(format: "%+.2f", s.net))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(s.net >= 0 ? Theme.Color.success : Theme.Color.danger)
                        .frame(width: 80, alignment: .trailing)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(Theme.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Color.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(Theme.Color.border, lineWidth: 1)
        )
    }

    // ── Recent trades list ────────────────────────────────────────

    private var recentTradesCard: some View {
        let recent = Array(gradedEntries.sorted {
            ($0.outcomeAt ?? $0.date) > ($1.outcomeAt ?? $1.date)
        }.prefix(10))
        return VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("RECENT GRADED TRADES")
                .font(.system(size: 10, weight: .heavy))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)
            ForEach(recent) { entry in
                HStack(spacing: Theme.Spacing.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.pairName) · \(entry.kind.label)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.Color.textPrimary)
                        Text(Self.dateFmt.string(from: entry.outcomeAt ?? entry.date))
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.Color.textMuted)
                    }
                    Spacer()
                    if let outcome = entry.outcome {
                        Text(outcome == .hitTP ? "WIN" : "LOSS")
                            .font(.system(size: 10, weight: .heavy))
                            .tracking(0.5)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(outcome == .hitTP ? Theme.Color.success : Theme.Color.danger)
                            )
                    }
                    if let pl = entry.outcomeRealisedPL {
                        Text(String(format: "%+.2f", pl))
                            .font(.system(size: 12, weight: .bold).monospacedDigit())
                            .foregroundStyle(pl >= 0 ? Theme.Color.success : Theme.Color.danger)
                            .frame(width: 80, alignment: .trailing)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, Theme.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.Color.surfaceHi)
                )
            }
        }
        .padding(Theme.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Color.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(Theme.Color.border, lineWidth: 1)
        )
    }

    // ── Empty state ────────────────────────────────────────────────

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Spacer().frame(height: 40)
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 32))
                .foregroundStyle(Theme.Color.textMuted)
            Text("No graded trades yet.")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Color.textSecondary)
            Text("Activate an AI scenario as a paper trade and analytics appear here once it hits TP or SL.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d · HH:mm"
        return f
    }()
}
