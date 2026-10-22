import Foundation
import SwiftData

/// Creates the first-launch Cash wallet and six categories, at most once.
/// It also does nothing if any wallet or category already exists.
enum DefaultDataSeeder {
    static let seededKey = "didSeedDefaultData.v1"

    private static let defaultCategories: [(name: String, emoji: String, colorHex: String)] = [
        ("Fuel", "⛽", "#FBBF24"),
        ("Food", "🍔", "#F97316"),
        ("Rent", "🏠", "#A78BFA"),
        ("Shopping", "🛍️", "#EC4899"),
        ("Health", "💊", "#34D399"),
        ("Entertainment", "🎮", "#60A5FA")
    ]

    static func seedIfNeeded(context: ModelContext, defaults: UserDefaults = .standard) throws {
        guard !defaults.bool(forKey: seededKey) else { return }

        let walletCount = try context.fetchCount(FetchDescriptor<Wallet>())
        let categoryCount = try context.fetchCount(FetchDescriptor<Category>())

        if walletCount == 0 && categoryCount == 0 {
            context.insert(Wallet(name: "Cash", emoji: "💵", openingBalanceMinor: 0, currencyCode: "INR"))
            for item in defaultCategories {
                context.insert(Category(name: item.name, emoji: item.emoji, colorHex: item.colorHex))
            }
            do {
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
        }
        defaults.set(true, forKey: seededKey)
    }
}
