import SwiftUI
import UIKit

extension Color {
    /// Parses "#RRGGBB". Falls back to the accent colour if malformed.
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            self = AppTheme.accent
            return
        }
        self.init(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}

extension AppTheme {
    /// Text/icon colour used on top of the accent colour (readable in both modes).
    static let onAccent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .black : .white
    })
}
