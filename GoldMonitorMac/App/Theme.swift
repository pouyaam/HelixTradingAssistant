import SwiftUI

// CleanMyMac X-inspired design tokens. Centralized here so a future "light
// theme polish" pass touches one file, not 30. Read via `Theme.spacing.lg`
// from any view.
enum Theme {
    enum Color {
        // Surface tones — match the dark CleanMyMac panels.
        // sRGB hex: #0E1116, #14171F, #1B1F2A, #232838
        static let canvas      = SwiftUI.Color(red: 0.055, green: 0.067, blue: 0.086)
        static let surface     = SwiftUI.Color(red: 0.078, green: 0.090, blue: 0.122)
        static let surfaceHi   = SwiftUI.Color(red: 0.106, green: 0.122, blue: 0.165)
        static let surfaceMax  = SwiftUI.Color(red: 0.137, green: 0.157, blue: 0.220)

        // Text
        static let textPrimary   = SwiftUI.Color(red: 0.95,  green: 0.96, blue: 0.98)
        static let textSecondary = SwiftUI.Color(red: 0.62,  green: 0.66, blue: 0.74)
        static let textMuted     = SwiftUI.Color(red: 0.42,  green: 0.46, blue: 0.54)

        // Accent gradient (CleanMyMac X uses gold→orange for the brand).
        static let accentStart = SwiftUI.Color(red: 1.00, green: 0.78, blue: 0.20)
        static let accentEnd   = SwiftUI.Color(red: 1.00, green: 0.52, blue: 0.10)

        // Status colors
        static let success = SwiftUI.Color(red: 0.13, green: 0.78, blue: 0.41)
        static let danger  = SwiftUI.Color(red: 0.94, green: 0.27, blue: 0.27)
        static let warn    = SwiftUI.Color(red: 0.96, green: 0.62, blue: 0.04)
        static let info    = SwiftUI.Color(red: 0.23, green: 0.51, blue: 0.96)

        // Subtle borders
        static let border = SwiftUI.Color.white.opacity(0.06)
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 16
        static let xl: CGFloat = 22
    }

    enum Shadow {
        // Soft drop shadow used on every card. Subtle so it doesn't
        // muddy the dark surface, but enough to give the lift CleanMyMac
        // is known for.
        static let card = ShadowStyle(
            color: SwiftUI.Color.black.opacity(0.35),
            radius: 14,
            x: 0,
            y: 6
        )
    }

    /// The brand gradient — used on primary buttons, the accent badge in the
    /// sidebar header, and progress rings.
    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [Color.accentStart, Color.accentEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// Plain shadow descriptor — SwiftUI's `.shadow()` doesn't take a struct so
/// we apply the fields manually. Keeps the call site terse.
struct ShadowStyle {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
}

extension View {
    /// Apply the standard card shadow.
    func cardShadow() -> some View {
        let s = Theme.Shadow.card
        return self.shadow(color: s.color, radius: s.radius, x: s.x, y: s.y)
    }
}
