import SwiftUI
import UIKit

/// Shared adaptive colour system for ExpenseTracker.
enum AppTheme {

    static let background = adaptive(
        dark: UIColor(
            red: 5 / 255,
            green: 6 / 255,
            blue: 7 / 255,
            alpha: 1
        ),
        light: UIColor.systemGroupedBackground
    )

    static let surface = adaptive(
        dark: UIColor(
            red: 17 / 255,
            green: 21 / 255,
            blue: 25 / 255,
            alpha: 1
        ),
        light: UIColor.secondarySystemGroupedBackground
    )

    static let accent = adaptive(
        dark: UIColor(
            red: 0,
            green: 229 / 255,
            blue: 1,
            alpha: 1
        ),
        light: UIColor(
            red: 0,
            green: 130 / 255,
            blue: 150 / 255,
            alpha: 1
        )
    )

    static let expense = Color(
        red: 251 / 255,
        green: 113 / 255,
        blue: 133 / 255
    )

    static let primaryText = Color.primary
    static let secondaryText = Color.secondary

    private static func adaptive(
        dark: UIColor,
        light: UIColor
    ) -> Color {
        Color(
            uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? dark
                    : light
            }
        )
    }
}
