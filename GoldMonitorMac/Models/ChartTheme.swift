import SwiftUI

/// Defines the color palette for candles and volume bars on the chart.
public enum ChartTheme: String, CaseIterable, Identifiable, Codable {
    case greenRed = "greenRed"
    case blueRed = "blueRed"
    case blackWhite = "blackWhite"

    public var id: String { rawValue }

    /// Human-readable label for UI pickers.
    public var label: String {
        switch self {
        case .greenRed:   return "Green & Red"
        case .blueRed:    return "Blue & Red"
        case .blackWhite: return "Black & White"
        }
    }

    /// Color for bullish candles (close >= open).
    public var upColor: Color {
        switch self {
        case .greenRed:
            return Theme.Color.success
        case .blueRed:
            return Color(red: 0.16, green: 0.50, blue: 0.98) // Vibrant trading blue
        case .blackWhite:
            return Color(red: 0.95, green: 0.96, blue: 0.98) // Crisp white
        }
    }

    /// Color for bearish candles (close < open).
    public var downColor: Color {
        switch self {
        case .greenRed:
            return Theme.Color.danger
        case .blueRed:
            return Theme.Color.danger
        case .blackWhite:
            return Color(red: 0.35, green: 0.38, blue: 0.45) // Dark slate for dark background contrast
        }
    }
}
