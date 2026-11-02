
import SwiftUI
import UIKit

/// Shared adaptive colour system for ExpenseTracker.
/// Turquoise brand. Light mode: bright cool white with a deeper turquoise accent.
/// Dark mode: pure AMOLED black with neutral near-black surfaces and a bright turquoise accent.
enum AppTheme {

    // MARK: - Backgrounds and surfaces

    static let background = adaptive(
        light: 0xF5F8FA,
        dark: 0x000000
    )

    static let surface = adaptive(
        light: 0xFFFFFF,
        dark: 0x101010
    )

    static let elevated = adaptive(
        light: 0xFFFFFF,
        dark: 0x1A1A1A
    )

    static let border = adaptive(
        light: 0xE1E6EB,
        dark: 0x2C2C2E
    )

    // MARK: - Text

    static let primaryText = adaptive(
        light: 0x0B1116,
        dark: 0xFFFFFF
    )

    static let secondaryText = adaptive(
        light: 0x566370,
        dark: 0xA1A1A6
    )

    // MARK: - Interactive elements

    // Turquoise brand accent: deeper in light mode, brighter in dark mode.
    static let accent = adaptive(
        light: 0x087E86,
        dark: 0x55DDE0
    )

    static let onAccent = adaptive(
        light: 0xFFFFFF,
        dark: 0x000000
    )

    static let accentSoft = adaptive(
        light: 0xE3F4F5,
        dark: 0x0E2B2C
    )

    /// Accent-coloured text on accentSoft fills. Light mode needs a deeper turquoise there.
    static let accentText = adaptive(
        light: 0x076F76,
        dark: 0x55DDE0
    )

    // MARK: - Financial colours

    static let income = adaptive(
        light: 0x0E7A4B,
        dark: 0x4ADE80
    )

    static let expense = adaptive(
        light: 0xC42B4B,
        dark: 0xFF6B81
    )

    static let warning = adaptive(
        light: 0x9A6412,
        dark: 0xFBBF24
    )

    // MARK: - Chart colours

    static let chartPurple = adaptive(
        light: 0x7C3AED,
        dark: 0xA78BFA
    )

    static let chartSky = adaptive(
        light: 0x0369A1,
        dark: 0x38BDF8
    )

    static let chartAmber = adaptive(
        light: 0xB45309,
        dark: 0xFBBF24
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

