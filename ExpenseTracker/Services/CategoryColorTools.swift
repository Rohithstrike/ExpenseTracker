import SwiftUI
import SwiftData
import UIKit

enum CategoryColorHex {
    /// Converts a picker colour to "#RRGGBB" in sRGB.
    static func hex(from color: Color) -> String? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = UIColor(color).cgColor.converted(
                to: space,
                intent: .defaultIntent,
                options: nil
              ),
              let components = converted.components,
              components.count >= 3 else {
            return nil
        }

        func byte(_ value: CGFloat) -> Int {
            Int((min(max(value, 0), 1) * 255).rounded())
        }

        return String(
            format: "#%02X%02X%02X",
            byte(components[0]),
            byte(components[1]),
            byte(components[2])
        )
    }
}

extension CategoryService {
    /// Finds an active category using this colour, excluding an optional category ID.
    func activeCategory(
        usingColorHex hex: String,
        excluding id: UUID?
    ) throws -> Category? {
        guard let key = CategoryPalette.normalizedHex(hex) else {
            return nil
        }

        return try activeCategories().first {
            $0.id != id &&
            CategoryPalette.normalizedHex($0.colorHex) == key
        }
    }
}
