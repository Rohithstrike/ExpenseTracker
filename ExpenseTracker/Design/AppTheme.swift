
import SwiftUI
import UIKit

/// Shared adaptive colour system for ExpenseTracker.
/// Light mode stays unchanged. Dark mode uses a neutral AMOLED palette.
enum AppTheme {

    // MARK: - Backgrounds and surfaces

    static let background = adaptive(
        light: 0xF4F5F9,
        dark: 0x000000
    )

    static let surface = adaptive(
        light: 0xFFFFFF,
        dark: 0x101010
    )

    static let elevated = adaptive(
        light: 0xFFFFFF,
        dark: 0x191919
    )

    static let border = adaptive(
        light: 0xDFE2EC,
        dark: 0x303030
    )

    // MARK: - Text

    static let primaryText = adaptive(
        light: 0x11142B,
        dark: 0xF5F5F5
    )

    static let secondaryText = adaptive(
        light: 0x565C75,
        dark: 0xA6A6A6
    )

    // MARK: - Interactive elements

    // Preserve the approved light accent.
    // Use a restrained lavender accent in dark mode.
    static let accent = adaptive(
        light: 0x3B47B8,
        dark: 0xA0A8FF
    )

    static let onAccent = adaptive(
        light: 0xFFFFFF,
        dark: 0x000000
    )

    static let accentSoft = adaptive(
        light: 0xE9EBF8,
        dark: 0x242433
    )

    // MARK: - Financial colours

    static let income = adaptive(
        light: 0x17704A,
        dark: 0x4CCB8A
    )

    static let expense = adaptive(
        light: 0xB83A32,
        dark: 0xFF7770
    )

    static let warning = adaptive(
        light: 0x9A6412,
        dark: 0xE8BB58
    )

    // MARK: - Adaptive colour helper

    private static func adaptive(
        light: UInt32,
        dark: UInt32
    ) -> Color {
        Color(
            uiColor: UIColor { traits in
                UIColor(
                    hex: traits.userInterfaceStyle == .dark
                        ? dark
                        : light
                )
            }
        )
    }
}

