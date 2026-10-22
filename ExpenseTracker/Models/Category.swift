import Foundation
import SwiftData

/// colorHex format: "#RRGGBB" (uppercase hex, sRGB). Archived categories stay
/// readable so historical transactions never lose their category.
@Model
final class Category {
    var id: UUID = UUID()
    var name: String = ""
    var emoji: String = "🏷️"
    var colorHex: String = "#00E5FF"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var isArchived: Bool = false

    init(
        id: UUID = UUID(),
        name: String,
        emoji: String = "🏷️",
        colorHex: String = "#00E5FF",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isArchived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.colorHex = colorHex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isArchived = isArchived
    }
}
