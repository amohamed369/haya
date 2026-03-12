import SwiftUI

// MARK: - Design Tokens

/// Haya design system: "Organic Luxury Wellness"
/// Botanical greenhouse aesthetic — sage greens, warm orange, frosted glass.
enum Haya {

    // MARK: Color Palette

    enum Colors {
        // Backgrounds
        static let bgPrimaryDark = Color(hex: "4A5A3A")
        static let bgPrimaryMid = Color(hex: "5A6B4A")
        static let bgPrimaryLight = Color(hex: "6B7D5A")
        static let bgDeep = Color(hex: "3F4F32")

        // Accent
        static let accentOrange = Color(hex: "E8863A")
        static let accentOrangeDark = Color(hex: "D4753A")
        static let accentLavender = Color(hex: "B8A9D4")
        static let accentYellow = Color(hex: "E2C36B")
        static let accentTeal = Color(hex: "7DBDB4")
        static let accentRose = Color(hex: "D4A0A0")
        static let accentGreen = Color(hex: "7DD4A0")

        // Text
        static let textCream = Color(hex: "F5F0E8")
        static let textSage = Color(hex: "B5C4A0")
        static let textSageDim = Color(hex: "8A9A72")

        // Glass
        static let glassBg = Color.white.opacity(0.08)
        static let glassBgWarm = Color(hex: "FFF5E6").opacity(0.10)
        static let glassBorder = Color.white.opacity(0.12)

        // Status
        static let statusHide = Color(hex: "E85A3A")

        // Foreground on orange surfaces
        static let fgOnOrange = Color(hex: "2A3420")
        static let fgOnOrangeSoft = Color(hex: "3F4F32")
        static let tabBarBg = Color(hex: "37442A")
    }

    // MARK: Radii

    enum Radius {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 6
        static let sm: CGFloat = 12
        static let md: CGFloat = 18
        static let lg: CGFloat = 24
        static let pill: CGFloat = 100
    }

    // MARK: Spacing

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
        static let tabClearance: CGFloat = 100
    }

    // MARK: Shadows

    enum Shadows {
        static let soft = Color(hex: "1A2410").opacity(0.20)
        /// Crisp directional shadow for neobrutalist depth
        static let cardDrop = Color(hex: "1A2410").opacity(0.40)
    }

    // MARK: Animation Presets

    enum Motion {
        static let press = Animation.spring(response: 0.2, dampingFraction: 0.8)
        static let quick = Animation.spring(response: 0.25, dampingFraction: 0.8)
        static let standard = Animation.spring(response: 0.35, dampingFraction: 0.85)
        static let entrance = Animation.spring(response: 0.6, dampingFraction: 0.8)
        static let fade = Animation.easeOut(duration: 0.15)
    }

    // MARK: Gradients

    enum Gradients {
        static let sageBackground = LinearGradient(
            colors: [
                Color(hex: "4A5A3A"),
                Color(hex: "536645"),
                Color(hex: "4A5A3A"),
                Color(hex: "3F4F32")
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        static let orangeCTA = LinearGradient(
            colors: [Color(hex: "E8863A"), Color(hex: "D4753A")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        static let avatarOrange = LinearGradient(
            colors: [Color(hex: "E8863A"), Color(hex: "E2C36B")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

    }
}

// MARK: - Color Hex Initializer

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6:
            (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        case 8:
            // ARGB (alpha ignored — uses RGB from lower 24 bits)
            (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (0, 0, 0)
        }
        self.init(
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255
        )
    }
}
