import SwiftUI

/// Brand palette for Apple TV. Mirrors `lib/tv/tv_theme.dart` so the iPhone,
/// Android TV, and Apple TV apps feel like the same product.
enum Theme {
    // Brand
    static let primary = Color(red: 0.91, green: 0.12, blue: 0.39)        // #E91E63
    static let primaryLight = Color(red: 0.97, green: 0.73, blue: 0.82)   // #F8BBD0
    static let primaryDark = Color(red: 0.56, green: 0.0, blue: 0.20)     // #8F0133

    // Surfaces
    static let background = Color(red: 0.04, green: 0.04, blue: 0.04)     // #0A0A0A
    static let surface = Color(red: 0.10, green: 0.10, blue: 0.10)        // #1A1A1A
    static let surfaceVariant = Color(red: 0.15, green: 0.15, blue: 0.15) // #252525

    // Text
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.70)
    static let textTertiary = Color.white.opacity(0.50)

    // Spacing
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
    }
}
