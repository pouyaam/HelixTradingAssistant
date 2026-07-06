import Foundation

/// Shared price formatting utilities. Extracted from ChartView so both
/// macOS and iPad targets can use them without coupling to a specific
/// chart view type.
enum PriceFormat {
    /// Compact price label: 19,634,000 → "19.6M"; 4,675 → "4,675";
    /// 0.0234 → "0.0234". K/M/B suffixes once values exceed 4 digits.
    static func short(_ v: Double) -> String {
        let abs = Swift.abs(v)
        if abs >= 1_000_000_000 { return String(format: "%.2fB", v / 1_000_000_000) }
        if abs >= 1_000_000     { return String(format: "%.2fM", v / 1_000_000) }
        if abs >= 10_000        { return String(format: "%.0fK", v / 1_000) }
        if abs >= 100           { return v.formatted(.number.precision(.fractionLength(0))) }
        if abs >= 1             { return v.formatted(.number.precision(.fractionLength(2))) }
        return String(format: "%.4f", v)
    }

    /// Exact price with thousands separators and up to 4 decimals.
    static func exact(_ v: Double) -> String {
        let abs = Swift.abs(v)
        let digits: Int
        if abs >= 1_000_000 { digits = 0 }
        else if abs >= 100  { digits = 2 }
        else if abs >= 1    { digits = 4 }
        else                { digits = 5 }
        return v.formatted(.number.precision(.fractionLength(digits)))
    }
}
