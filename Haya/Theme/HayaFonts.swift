import SwiftUI

/// Typography system using Fraunces (headings) and DM Sans (body).
/// Falls back to system serif/sans-serif if custom fonts aren't loaded.
enum HayaFont {

    // MARK: - Font Names

    private static let serifFamily = "Fraunces"
    private static let sansFamily = "DM Sans"

    // MARK: - Heading (Fraunces serif)

    static func heading(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        if isFontAvailable(serifFamily) {
            return .custom(frauncesFontName(for: weight), size: size)
        }
        return .system(size: size, weight: weight, design: .serif)
    }

    // MARK: - Body (DM Sans)

    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if isFontAvailable(sansFamily) {
            return .custom(dmSansFontName(for: weight), size: size)
        }
        return .system(size: size, weight: weight, design: .default)
    }

    // MARK: - Presets

    static let largeTitle = heading(30, weight: .semibold)
    static let title = heading(24, weight: .semibold)
    static let title2 = heading(20, weight: .semibold)
    static let title3 = heading(18, weight: .medium)
    static let headline = heading(16, weight: .semibold)
    static let subheadline = body(14, weight: .medium)
    static let bodyText = body(15, weight: .regular)
    static let caption = body(12, weight: .regular)
    static let caption2 = body(11, weight: .medium)
    static let label = body(13, weight: .medium)
    static let pill = body(13, weight: .semibold)

    // MARK: - Font Name Resolution

    private static func frauncesFontName(for weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black:
            return "Fraunces-Bold"
        case .semibold:
            return "Fraunces-SemiBold"
        case .medium:
            return "Fraunces-Medium"
        default:
            return "Fraunces-Regular"
        }
    }

    private static func dmSansFontName(for weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black:
            return "DMSans-Bold"
        case .semibold:
            return "DMSans-SemiBold"
        case .medium:
            return "DMSans-Medium"
        default:
            return "DMSans-Regular"
        }
    }

    private static func isFontAvailable(_ family: String) -> Bool {
        UIFont.familyNames.contains(where: { $0.contains(family) })
    }

    /// Call once at startup to verify font registration.
    static func logAvailableFonts() {
        #if DEBUG
        for family in UIFont.familyNames.sorted() {
            if family.contains("Fraun") || family.contains("DM") {
                print("Font family: \(family)")
                for name in UIFont.fontNames(forFamilyName: family) {
                    print("  → \(name)")
                }
            }
        }
        #endif
    }
}
