import Foundation
import SwiftData

/// A place money lives. Balance is NEVER stored here; see BalanceCalculator.
/// CloudKit-safe: no unique attributes, defaults on every property.
@Model
final class Wallet {
    var id: UUID = UUID()
    var name: String = ""
    var emoji: String = "👛"
    var openingBalanceMinor: Int64 = 0
    var currencyCode: String = "INR"
    var createdAt: Date = Date()
    var isArchived: Bool = false

    init(
        id: UUID = UUID(),
        name: String,
        emoji: String = "👛",
        openingBalanceMinor: Int64 = 0,
        currencyCode: String = "INR",
        createdAt: Date = Date(),
        isArchived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.openingBalanceMinor = openingBalanceMinor
        self.currencyCode = currencyCode.uppercased()
        self.createdAt = createdAt
        self.isArchived = isArchived
    }
}
