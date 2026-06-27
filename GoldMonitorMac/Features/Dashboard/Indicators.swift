import Foundation
import SwiftUI

/// Catalog of technical indicators the user can overlay on the price
/// chart. Each kind is self-describing (label, colour, computation) so
/// ChartView can iterate without a giant switch. New indicators get
/// added here and automatically show up in the menu.
enum IndicatorKind: String, CaseIterable, Identifiable, Hashable {
    case sma20
    case sma50
    case sma200
    case ema9
    case ema21
    case bollinger
    /// UT Bot Alerts — ATR-based trailing stop with buy/sell labels.
    /// Special-cased in the chart: the trailing stop renders as a
    /// stepped line and signals render as labels at the relevant bars.
    case utBot
    /// Order Block Finder — institutional order-block zones. Like UT Bot
    /// it doesn't fit the single-line `IndicatorPoint` shape: it renders
    /// as translucent rectangles (see `OrderBlocks` + ChartView's
    /// `orderBlockMarks`) and reads its run length / threshold / wick
    /// options from the indicator config.
    case orderBlock
    /// Trading Sessions — shades the Tokyo / London / New York sessions as
    /// per-day high-low boxes with open/close/average lines. Like the two
    /// above it renders as zones, not a line series (see `TradingSessions`
    /// + ChartView's `sessionMarks`); which sessions show and which lines
    /// draw come from the indicator config.
    case tradingSession
    /// NY Open Setup — the 5-minute opening-range breakout + FVG-retest
    /// strategy (see `NYOpenSetup` + ChartView's `setupMarks`). Renders
    /// the opening-range box, the breakout FVG, and the entry/SL/TP plan;
    /// on 1m and 5m charts. The dashboard also turns the live day's plan
    /// into alerts + an activate-trade affordance.
    case nyOpenSetup
    /// Fair Value Gap (FVG) detector — three-candle imbalance zones.
    /// Renders as translucent green/red rectangles extending rightward
    /// from the bar where the gap formed. Mitigated gaps (price closed
    /// back inside) are kept at lower opacity with a dashed outline.
    /// Ported from LuxAlgo's PineScript v5 FVG indicator (CC BY-NC-SA 4.0).
    case fairValueGap

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sma20:          return "SMA 20"
        case .sma50:          return "SMA 50"
        case .sma200:         return "SMA 200"
        case .ema9:           return "EMA 9"
        case .ema21:          return "EMA 21"
        case .bollinger:      return "Bollinger (20, 2)"
        case .utBot:          return "UT Bot Alerts"
        case .orderBlock:     return "Order Blocks"
        case .tradingSession: return "Trading Sessions"
        case .nyOpenSetup:    return "NY Open Setup"
        case .fairValueGap:   return "Fair Value Gap"
        }
    }

    /// Distinct hue per indicator. Chosen to stay readable on the dark
    /// surface and to not collide with the candle red/green or accent
    /// colours used for the price line.
    var color: Color {
        switch self {
        case .sma20:     return Color(red: 1.00, green: 0.78, blue: 0.20) // gold
        case .sma50:     return Color(red: 0.38, green: 0.65, blue: 1.00) // blue
        case .sma200:    return Color(red: 0.85, green: 0.35, blue: 0.95) // magenta
        case .ema9:      return Color(red: 1.00, green: 0.45, blue: 0.65) // pink
        case .ema21:     return Color(red: 0.45, green: 0.85, blue: 0.95) // teal
        case .bollinger: return Color(red: 0.55, green: 0.85, blue: 1.00) // cyan
        case .utBot:     return Color(red: 0.95, green: 0.62, blue: 0.18) // amber
        // Order blocks colour their fill green/red per direction on the
        // chart; this hue is only the Layers-popover swatch, so a neutral
        // indigo reads as "the zones layer" without implying a bias.
        case .orderBlock: return Color(red: 0.55, green: 0.50, blue: 0.95) // indigo
        // Trading sessions each carry their own hue (blue/orange/green) on
        // the chart; this single swatch is just the Layers-popover marker,
        // so a muted steel-blue reads as "the sessions layer".
        case .tradingSession: return Color(red: 0.40, green: 0.55, blue: 0.70) // steel
        // NY Open Setup colours its plan green/red by direction; the
        // Layers swatch is a neutral amber that reads as "the setup layer".
        case .nyOpenSetup: return Color(red: 0.95, green: 0.75, blue: 0.30) // amber
        // FVG fills green/red per direction on the chart; the Layers swatch
        // is a soft teal that reads as "imbalance / gap zones layer".
        case .fairValueGap: return Color(red: 0.30, green: 0.80, blue: 0.75) // teal
        }
    }
}

/// One point on an indicator series. Tuple-ish but a struct so it slots
/// into `ForEach` with a stable identity. The chart now uses bar index
/// as its X plottable so consecutive bars sit flush against each other
/// even when there are calendar gaps (weekends), so indicators emit an
/// index rather than a wall-clock date.
struct IndicatorPoint: Identifiable, Hashable {
    let index: Int
    let value: Double
    /// Composite indicators (e.g. Bollinger) emit multiple bands; this
    /// disambiguates them within a single series.
    let band: String

    var id: String { "\(index)-\(band)" }
}

/// Pure-function indicator computations. No state, no rendering — the
/// chart layer maps these into `LineMark`s.
enum Indicators {
    /// Simple moving average. Each output point is the mean close over
    /// the trailing `period` candles. The first `period - 1` candles
    /// have no SMA value (not enough history) and are skipped.
    static func sma(_ candles: [Candle], period: Int) -> [IndicatorPoint] {
        guard period > 0, candles.count >= period else { return [] }
        var out: [IndicatorPoint] = []
        out.reserveCapacity(candles.count - period + 1)
        // Rolling sum — O(n) instead of O(n·period).
        var sum: Double = 0
        for i in 0..<candles.count {
            sum += candles[i].close
            if i >= period { sum -= candles[i - period].close }
            if i >= period - 1 {
                out.append(IndicatorPoint(
                    index: i,
                    value: sum / Double(period),
                    band: "sma\(period)"
                ))
            }
        }
        return out
    }

    /// Exponential moving average. Seeds the EMA with a plain SMA over
    /// the first `period` bars so the curve doesn't lurch out of the
    /// gate, then applies the standard recurrence.
    static func ema(_ candles: [Candle], period: Int) -> [IndicatorPoint] {
        guard period > 0, candles.count >= period else { return [] }
        let alpha = 2.0 / (Double(period) + 1.0)
        var out: [IndicatorPoint] = []
        out.reserveCapacity(candles.count - period + 1)
        // Seed = SMA of the first `period` closes.
        var prev = candles.prefix(period).reduce(0.0) { $0 + $1.close } / Double(period)
        out.append(IndicatorPoint(
            index: period - 1,
            value: prev,
            band: "ema\(period)"
        ))
        for i in period..<candles.count {
            prev = alpha * candles[i].close + (1 - alpha) * prev
            out.append(IndicatorPoint(
                index: i,
                value: prev,
                band: "ema\(period)"
            ))
        }
        return out
    }

    /// Bollinger Bands: SMA(period) with upper/lower envelope at ±σ·k
    /// (population standard deviation). Returns three series tagged
    /// "bb_upper", "bb_mid", "bb_lower" so the chart can style them
    /// independently. `k` defaults to 2 — the textbook setting.
    static func bollinger(_ candles: [Candle], period: Int = 20, k: Double = 2.0)
        -> [IndicatorPoint]
    {
        guard period > 1, candles.count >= period else { return [] }
        var out: [IndicatorPoint] = []
        out.reserveCapacity((candles.count - period + 1) * 3)
        // We need both mean and stddev per window. Maintain rolling sums
        // of value and squared value for O(n) per band.
        var sum: Double = 0
        var sumSq: Double = 0
        for i in 0..<candles.count {
            let c = candles[i].close
            sum += c
            sumSq += c * c
            if i >= period {
                let old = candles[i - period].close
                sum -= old
                sumSq -= old * old
            }
            if i >= period - 1 {
                let mean = sum / Double(period)
                // Variance via E[x²] - E[x]². Clamp to 0 to dodge
                // tiny negative results from floating-point drift.
                let variance = max(0, sumSq / Double(period) - mean * mean)
                let sd = variance.squareRoot()
                out.append(.init(index: i, value: mean - k * sd, band: "bb_lower"))
                out.append(.init(index: i, value: mean,           band: "bb_mid"))
                out.append(.init(index: i, value: mean + k * sd, band: "bb_upper"))
            }
        }
        return out
    }

    /// Dispatch: compute all enabled indicators in one pass, flattened
    /// into a single (kind, points[]) list the chart can iterate.
    static func compute(_ enabled: Set<IndicatorKind>, candles: [Candle])
        -> [(kind: IndicatorKind, points: [IndicatorPoint])]
    {
        // Stable order so the legend and z-order stay consistent across
        // toggles instead of bouncing around based on Set hashing.
        IndicatorKind.allCases.compactMap { kind in
            guard enabled.contains(kind) else { return nil }
            let pts: [IndicatorPoint]
            switch kind {
            case .sma20:     pts = sma(candles, period: 20)
            case .sma50:     pts = sma(candles, period: 50)
            case .sma200:    pts = sma(candles, period: 200)
            case .ema9:      pts = ema(candles, period: 9)
            case .ema21:     pts = ema(candles, period: 21)
            case .bollinger: pts = bollinger(candles)
            // UT Bot is handled directly in ChartView's `utBotMarks` —
            // its trailing-stop line and buy/sell labels don't fit the
            // single-line `IndicatorPoint` shape and need config params
            // (key value, ATR period) that the generic compute doesn't
            // receive.
            case .utBot:     pts = []
            // Order Blocks render as zones (rectangles) in ChartView's
            // `orderBlockMarks`, not as a line series — same reason
            // UT Bot is empty here.
            case .orderBlock: pts = []
            // Trading Sessions render as per-day boxes in ChartView's
            // `sessionMarks` (see `TradingSessions`), not a line series.
            case .tradingSession: pts = []
            // NY Open Setup renders as an OR box + FVG + plan lines in
            // ChartView's `setupMarks` (see `NYOpenSetup`), not a series.
            case .nyOpenSetup: pts = []
            // FVG renders as zone rectangles in ChartView's `indicatorFvgMarks`
            // (see `FairValueGap`), not a line series.
            case .fairValueGap: pts = []
            }
            return pts.isEmpty ? nil : (kind, pts)
        }
    }
}
