import SwiftUI
import Charts

/// Per-day analytics panel shown above the journal entry list.
/// Three charts in a horizontal row:
///   1. Daily P/L bars — green wins, red losses, with a zero rule
///   2. Cumulative P/L curve — equity-curve style
///   3. Daily win-rate dots + smoothed line
struct JournalAnalyticsView: View {
    let entries: [JournalEntry]

    // ── Data model ────────────────────────────────────────────────

    struct DayStat: Identifiable {
        let day: Date
        let label: String       // "Jun 26"
        let net: Double
        let winRate: Double     // 0–1, NaN if no graded trades
        let tradeCount: Int
        let cumPL: Double       // running total up to and including this day
        var id: Date { day }
    }

    private var stats: [DayStat] {
        let cal = Calendar.current
        var map: [Date: [JournalEntry]] = [:]
        for e in entries {
            let day = cal.startOfDay(for: e.date)
            map[day, default: []].append(e)
        }
        let days = map.keys.sorted()
        var running = 0.0
        return days.map { day in
            let es = map[day]!
            let net = es.reduce(0.0) { $0 + $1.profitLoss }
            running += net
            let wins   = es.filter { $0.result == .win }.count
            let losses = es.filter { $0.result == .loss }.count
            let graded = wins + losses
            let wr = graded == 0 ? Double.nan : Double(wins) / Double(graded)
            return DayStat(
                day: day,
                label: Self.labelFmt.string(from: day),
                net: net,
                winRate: wr,
                tradeCount: es.count,
                cumPL: running
            )
        }
    }

    // ── Body ──────────────────────────────────────────────────────

    var body: some View {
        let data = stats
        guard !data.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("ANALYTICS")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Color.textMuted)
                HStack(alignment: .top, spacing: Theme.Spacing.md) {
                    dailyPLChart(data)
                    cumulativePLChart(data)
                    winRateChart(data)
                }
                .frame(height: 160)

                let zones = priceZoneStats
                if !zones.isEmpty {
                    priceZoneTable(zones)
                }
            }
        )
    }

    // ── 1 — Daily P/L bar chart ───────────────────────────────────

    private func dailyPLChart(_ data: [DayStat]) -> some View {
        chartCard(title: "Daily P/L") {
            Chart {
                RuleMark(y: .value("Zero", 0))
                    .foregroundStyle(Theme.Color.border)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                ForEach(data) { s in
                    BarMark(
                        x: .value("Day", s.label),
                        y: .value("P/L", s.net)
                    )
                    .foregroundStyle(s.net >= 0 ? Theme.Color.success : Theme.Color.danger)
                    .cornerRadius(3)
                    .annotation(position: s.net >= 0 ? .top : .bottom, spacing: 2) {
                        if data.count <= 14 {
                            Text(String(format: "%+.0f", s.net))
                                .font(.system(size: 8, weight: .semibold).monospacedDigit())
                                .foregroundStyle(s.net >= 0 ? Theme.Color.success : Theme.Color.danger)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: min(data.count, 7))) { v in
                    AxisValueLabel {
                        if let s = v.as(String.self) {
                            Text(s)
                                .font(.system(size: 8))
                                .foregroundStyle(Theme.Color.textMuted)
                        }
                    }
                }
            }
            .chartYAxis { compactYAxis() }
        }
    }

    // ── 2 — Cumulative P/L curve ──────────────────────────────────

    private func cumulativePLChart(_ data: [DayStat]) -> some View {
        let isPositive = (data.last?.cumPL ?? 0) >= 0
        return chartCard(title: "Cumulative P/L") {
            Chart {
                RuleMark(y: .value("Zero", 0))
                    .foregroundStyle(Theme.Color.border)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                // Shaded area under the curve
                ForEach(data) { s in
                    AreaMark(
                        x: .value("Day", s.label),
                        y: .value("Cum P/L", s.cumPL)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                (isPositive ? Theme.Color.success : Theme.Color.danger).opacity(0.25),
                                .clear
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.monotone)
                }
                // Line on top
                ForEach(data) { s in
                    LineMark(
                        x: .value("Day", s.label),
                        y: .value("Cum P/L", s.cumPL)
                    )
                    .foregroundStyle(isPositive ? Theme.Color.success : Theme.Color.danger)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
                }
                // Final value annotation
                if let last = data.last {
                    PointMark(
                        x: .value("Day", last.label),
                        y: .value("Cum P/L", last.cumPL)
                    )
                    .foregroundStyle(isPositive ? Theme.Color.success : Theme.Color.danger)
                    .symbolSize(30)
                    .annotation(position: last.cumPL >= 0 ? .top : .bottom, spacing: 4) {
                        Text(String(format: "%+.2f", last.cumPL))
                            .font(.system(size: 9, weight: .bold).monospacedDigit())
                            .foregroundStyle(isPositive ? Theme.Color.success : Theme.Color.danger)
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: min(data.count, 7))) { v in
                    AxisValueLabel {
                        if let s = v.as(String.self) {
                            Text(s)
                                .font(.system(size: 8))
                                .foregroundStyle(Theme.Color.textMuted)
                        }
                    }
                }
            }
            .chartYAxis { compactYAxis() }
        }
    }

    // ── 3 — Daily win rate ────────────────────────────────────────

    private func winRateChart(_ data: [DayStat]) -> some View {
        let graded = data.filter { !$0.winRate.isNaN }
        return chartCard(title: "Win Rate / Day") {
            Chart {
                // 50% reference line
                RuleMark(y: .value("50%", 0.5))
                    .foregroundStyle(Theme.Color.border)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .overlay, alignment: .leading, spacing: 4) {
                        Text("50%")
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.Color.textMuted)
                    }
                // Line through graded days
                if graded.count >= 2 {
                    ForEach(graded) { s in
                        LineMark(
                            x: .value("Day", s.label),
                            y: .value("Win rate", s.winRate)
                        )
                        .foregroundStyle(Theme.Color.info)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                    }
                }
                // Dots — colored by above/below 50%
                ForEach(graded) { s in
                    PointMark(
                        x: .value("Day", s.label),
                        y: .value("Win rate", s.winRate)
                    )
                    .foregroundStyle(s.winRate >= 0.5 ? Theme.Color.success : Theme.Color.danger)
                    .symbolSize(32)
                    .annotation(position: .top, spacing: 2) {
                        if data.count <= 14 {
                            Text(String(format: "%.0f%%", s.winRate * 100))
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(s.winRate >= 0.5 ? Theme.Color.success : Theme.Color.danger)
                        }
                    }
                }
            }
            .chartYScale(domain: 0...1)
            .chartYAxis {
                AxisMarks(values: [0, 0.25, 0.5, 0.75, 1.0]) { v in
                    AxisGridLine().foregroundStyle(Theme.Color.border.opacity(0.5))
                    AxisValueLabel {
                        if let d = v.as(Double.self) {
                            Text(String(format: "%.0f%%", d * 100))
                                .font(.system(size: 8))
                                .foregroundStyle(Theme.Color.textMuted)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: min(graded.count, 7))) { v in
                    AxisValueLabel {
                        if let s = v.as(String.self) {
                            Text(s)
                                .font(.system(size: 8))
                                .foregroundStyle(Theme.Color.textMuted)
                        }
                    }
                }
            }
        }
    }

    // ── Shared helpers ────────────────────────────────────────────

    @ViewBuilder
    private func chartCard<C: View>(title: String, @ViewBuilder chart: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.Color.textSecondary)
            chart()
                .chartBackground { _ in
                    Theme.Color.surface
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(Theme.Spacing.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.Color.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.Color.border, lineWidth: 1))
        .frame(maxWidth: .infinity)
    }

    @AxisContentBuilder
    private func compactYAxis() -> some AxisContent {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
            AxisGridLine().foregroundStyle(Theme.Color.border.opacity(0.5))
            AxisValueLabel {
                if let d = v.as(Double.self) {
                    Text(Self.compact(d))
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.Color.textMuted)
                }
            }
        }
    }

    private static func compact(_ v: Double) -> String {
        let a = abs(v)
        let sign = v < 0 ? "-" : ""
        if a >= 1_000 { return "\(sign)\(String(format: "%.1f", a / 1_000))k" }
        return "\(sign)\(String(format: "%.0f", a))"
    }

    private static let labelFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    // ── 4 — Price zone win-rate table ─────────────────────────────

    struct ZoneStat: Identifiable {
        let label: String       // e.g. "3050–3075"
        let lo: Double
        let trades: Int
        let wins: Int
        let losses: Int
        let net: Double
        var id: String { label }
        var winRate: Double { (wins + losses) == 0 ? 0 : Double(wins) / Double(wins + losses) }
    }

    /// Bucket entries by their entry price into 25-point ranges.
    /// Only entries that have an entry price are included.
    private var priceZoneStats: [ZoneStat] {
        let withPrice = entries.filter { $0.entry != nil }
        guard withPrice.count >= 3 else { return [] }

        let bucketSize: Double = 25
        var map: [Double: [JournalEntry]] = [:]
        for e in withPrice {
            guard let ep = e.entry else { continue }
            let bucket = floor(ep / bucketSize) * bucketSize
            map[bucket, default: []].append(e)
        }
        return map
            .sorted { $0.key < $1.key }
            .compactMap { (lo, es) -> ZoneStat? in
                guard es.count >= 2 else { return nil } // skip buckets with only 1 trade
                let wins   = es.filter { $0.result == .win }.count
                let losses = es.filter { $0.result == .loss }.count
                let net    = es.reduce(0.0) { $0 + $1.profitLoss }
                let label  = "\(Int(lo))–\(Int(lo + bucketSize))"
                return ZoneStat(label: label, lo: lo, trades: es.count,
                                wins: wins, losses: losses, net: net)
            }
            .sorted { $0.lo < $1.lo }
    }

    private func priceZoneTable(_ zones: [ZoneStat]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OB ZONE WIN RATE (by entry price)")
                .font(.system(size: 9, weight: .heavy))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)

            VStack(spacing: 0) {
                // Header row
                HStack {
                    Text("ZONE").frame(width: 110, alignment: .leading)
                    Text("TRADES").frame(width: 55, alignment: .trailing)
                    Text("W/L").frame(width: 55, alignment: .trailing)
                    Text("WIN%").frame(width: 55, alignment: .trailing)
                    Spacer()
                    Text("NET P/L").frame(width: 80, alignment: .trailing)
                }
                .font(.system(size: 9, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(Theme.Color.textMuted)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, 6)

                Divider().background(Theme.Color.border)

                ForEach(zones) { z in
                    HStack {
                        Text(z.label)
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.Color.textPrimary)
                            .frame(width: 110, alignment: .leading)
                        Text("\(z.trades)")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.Color.textSecondary)
                            .frame(width: 55, alignment: .trailing)
                        Text("\(z.wins)/\(z.losses)")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.Color.textSecondary)
                            .frame(width: 55, alignment: .trailing)
                        // Win rate bar
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Theme.Color.border.opacity(0.5))
                                .frame(width: 55, height: 14)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(z.winRate >= 0.5 ? Theme.Color.success : Theme.Color.danger)
                                .frame(width: 55 * CGFloat(z.winRate), height: 14)
                            Text(String(format: "%.0f%%", z.winRate * 100))
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 55)
                        }
                        .frame(width: 55, alignment: .trailing)
                        Spacer()
                        Text(String(format: "%+.2f", z.net))
                            .font(.system(size: 11, weight: .bold).monospacedDigit())
                            .foregroundStyle(z.net >= 0 ? Theme.Color.success : Theme.Color.danger)
                            .frame(width: 80, alignment: .trailing)
                    }
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, 7)
                    .background(zones.firstIndex(where: { $0.id == z.id })!.isMultiple(of: 2)
                        ? Theme.Color.surface
                        : Theme.Color.surfaceHi)
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.Color.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.Color.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        }
    }
}
