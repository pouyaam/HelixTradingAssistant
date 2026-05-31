import SwiftUI

/// Placeholder shown over the chart while a timeframe's historical
/// candles are still being fetched from Yahoo. A row of grey bars with
/// a sweeping shimmer reads as "loading" without pretending to be real
/// price data. Heights follow a fixed sine-ish pattern so it looks
/// chart-like rather than random noise.
struct ChartSkeleton: View {
    var barCount: Int = 48

    @State private var shimmer: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 4
            let barWidth = max(2, (geo.size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    Capsule()
                        .fill(Theme.Color.surfaceMax)
                        .frame(width: barWidth, height: barHeight(i, in: geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .overlay {
                // Diagonal highlight that sweeps left→right on a loop.
                LinearGradient(
                    colors: [.clear, Color.white.opacity(0.08), .clear],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: geo.size.width * 0.5)
                .offset(x: shimmer * geo.size.width)
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
            }
            .clipped()
        }
        .overlay(alignment: .center) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading history…")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Theme.Color.surface))
        }
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                shimmer = 1
            }
        }
    }

    /// Deterministic, chart-like bar heights between ~25% and ~85% of
    /// the available height.
    private func barHeight(_ i: Int, in total: CGFloat) -> CGFloat {
        let t = Double(i)
        let wave = (sin(t * 0.5) + sin(t * 0.17) * 0.6 + sin(t * 0.93) * 0.3) / 1.9
        let norm = (wave + 1) / 2                      // 0…1
        return total * CGFloat(0.25 + norm * 0.60)
    }
}
