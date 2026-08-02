import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Defines the color palette for candles, volume bars, and background on the chart.
public enum ChartTheme: String, CaseIterable, Identifiable, Codable {
    case greenRed = "greenRed"
    case blueRed = "blueRed"
    case blackWhite = "blackWhite"
    case custom = "custom"

    public var id: String { rawValue }

    /// Human-readable label for UI pickers.
    public var label: String {
        switch self {
        case .greenRed:   return "Green & Red"
        case .blueRed:    return "Blue & Red"
        case .blackWhite: return "Black & White"
        case .custom:     return "Custom"
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
        case .custom:
            let hex = UserDefaults.standard.string(forKey: "dashboard.customUpColorHex") ?? "#21C768"
            return Color(hex: hex) ?? Theme.Color.success
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
        case .custom:
            let hex = UserDefaults.standard.string(forKey: "dashboard.customDownColorHex") ?? "#F04545"
            return Color(hex: hex) ?? Theme.Color.danger
        }
    }

    /// Background color override for the chart container. Returns nil for default card background.
    public var effectiveBackgroundColor: Color? {
        switch self {
        case .greenRed, .blueRed:
            return nil
        case .blackWhite:
            return Color(red: 0.06, green: 0.07, blue: 0.09)
        case .custom:
            let hex = UserDefaults.standard.string(forKey: "dashboard.customBgColorHex") ?? "#12151C"
            return Color(hex: hex)
        }
    }
}

// MARK: - Color Hex Helpers

extension Color {
    public func toHex() -> String {
        #if os(macOS)
        guard let nsColor = NSColor(self).usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int(nsColor.redComponent * 255)
        let g = Int(nsColor.greenComponent * 255)
        let b = Int(nsColor.blueComponent * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
        #else
        guard let components = UIColor(self).cgColor.components, components.count >= 3 else { return "#000000" }
        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
        #endif
    }
}
