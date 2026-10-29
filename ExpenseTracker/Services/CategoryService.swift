import Foundation
import SwiftData

enum CategoryError: Error, Equatable {
    case invalidName
    case invalidEmoji
    case invalidColor
    /// Another category already uses this name. `isArchived` tells the UI to suggest restoring it.
    case duplicateName(existing: String, isArchived: Bool)
    case categoryLimitReached
    case lastActiveCategory
    /// Transactions still use this category, so it can only be archived.
    case categoryInUse(name: String, count: Int)

    var message: String {
        switch self {
        case .invalidName:
            return "Enter a name of 1 to \(CategoryService.maxNameLength) characters."
        case .invalidEmoji:
            return "Choose a single emoji."
        case .invalidColor:
            return "Choose a valid colour."
        case .duplicateName(let existing, let isArchived):
            if isArchived {
                return "“\(existing)” already exists in your archived categories. Restore it instead."
            }
            return "You already have a category called “\(existing)”."
        case .categoryLimitReached:
            return "You can have up to \(CategoryService.maxActiveCategories) active categories. Archive one to add another."
        case .lastActiveCategory:
            return "Keep at least one active category, because expenses need one."
        case .categoryInUse(let name, let count):
            let noun = count == 1 ? "1 transaction uses" : "\(count) transactions use"
            return "\(noun) “\(name)”, so it can't be deleted. Archive it instead; past transactions keep it."
        }
    }
}

struct CategoryColor: Equatable, Identifiable {
    let name: String
    let hex: String
    var id: String { hex }
}

/// The colours a category may use. Names are for VoiceOver and menus. The first six
/// include the seeded categories' colours; Cyan is the model's original default.
enum CategoryPalette {
    static let colors: [CategoryColor] = [
        CategoryColor(name: "Amber", hex: "#FBBF24"),
        CategoryColor(name: "Orange", hex: "#F97316"),
        CategoryColor(name: "Red", hex: "#EF4444"),
        CategoryColor(name: "Pink", hex: "#EC4899"),
        CategoryColor(name: "Violet", hex: "#A78BFA"),
        CategoryColor(name: "Blue", hex: "#60A5FA"),
        CategoryColor(name: "Cyan", hex: "#00E5FF"),
        CategoryColor(name: "Teal", hex: "#14B8A6"),
        CategoryColor(name: "Green", hex: "#34D399"),
        CategoryColor(name: "Lime", hex: "#84CC16"),
        CategoryColor(name: "Brown", hex: "#B45309"),
        CategoryColor(name: "Slate", hex: "#94A3B8"),
        CategoryColor(name: "Indigo", hex: "#6366F1"),
        CategoryColor(name: "Fuchsia", hex: "#D946EF")
    ]

    /// What a new category starts with.
    static let defaultColor = colors[5]

    /// "#RRGGBB" in uppercase, or nil if the text is not that format.
    static func normalizedHex(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard trimmed.count == 7, trimmed.hasPrefix("#"),
              trimmed.dropFirst().allSatisfy({ $0.isASCII && $0.isHexDigit })
        else { return nil }
        return trimmed
    }

    static func color(forHex hex: String) -> CategoryColor? {
        guard let normalized = normalizedHex(hex) else { return nil }
        return colors.first { $0.hex == normalized }
    }
}

/// What the user types into the category form.
struct CategoryInput: Equatable {
    var name: String
    var emoji: String = CategoryService.defaultEmoji
    var colorHex: String = CategoryPalette.defaultColor.hex
}

/// All category rules live here so every screen enforces the same ones. A category that any
/// transaction uses is archived, never deleted, so history always keeps its category.
struct CategoryService {
    static let maxActiveCategories = 50
    static let maxNameLength = 30
    static let defaultEmoji = "🏷️"

    let context: ModelContext

    // MARK: Names

    static func normalizedName(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Two names with the same key count as duplicates.
    static func duplicateKey(_ text: String) -> String {
        normalizedName(text).folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Control characters and invisible format characters are not allowed in names. The
    /// zero-width joiner and non-joiner are the exception: emoji sequences such as the
    /// family emoji, and some scripts, need them.
    private static func hasDisallowedCharacters(_ name: String) -> Bool {
        name.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control:
                // Tab, newline and similar whitespace controls are allowed here because
                // normalizedName turns them into a single space.
                return !CharacterSet.whitespacesAndNewlines.contains(scalar)
            case .format:
                return scalar.value != 0x200C && scalar.value != 0x200D
            default:
                return false
            }
        }
    }

    // MARK: Create, edit, archive

    @discardableResult
    func create(_ input: CategoryInput) throws -> Category {
        let clean = try validated(input, existing: nil)
        guard try activeCount() < Self.maxActiveCategories else {
            throw CategoryError.categoryLimitReached
        }
        let category = Category(name: clean.name, emoji: clean.emoji, colorHex: clean.colorHex)
        context.insert(category)
        try commit()
        return category
    }

    func update(_ category: Category, with input: CategoryInput) throws {
        let clean = try validated(input, existing: category)
        category.name = clean.name
        category.emoji = clean.emoji
        category.colorHex = clean.colorHex
        category.updatedAt = Date()
        try commit()
    }

    func archive(_ category: Category) throws {
        guard !category.isArchived else { return }
        guard try activeCount() > 1 else { throw CategoryError.lastActiveCategory }
        category.isArchived = true
        category.updatedAt = Date()
        try commit()
    }

    func unarchive(_ category: Category) throws {
        guard category.isArchived else { return }
        guard try activeCount() < Self.maxActiveCategories else {
            throw CategoryError.categoryLimitReached
        }
        let key = Self.duplicateKey(category.name)
        let clash = try context.fetch(FetchDescriptor<Category>()).first {
            $0.id != category.id && !$0.isArchived && Self.duplicateKey($0.name) == key
        }
        if let clash { throw CategoryError.duplicateName(existing: clash.name, isArchived: false) }
        category.isArchived = false
        category.updatedAt = Date()
        try commit()
    }

    /// Why this category can't be deleted right now, or nil if it can.
    func deletionBlocker(for category: Category) throws -> CategoryError? {
        let id: UUID? = category.id
        let used = try context.fetchCount(
            FetchDescriptor<Transaction>(predicate: #Predicate { $0.categoryID == id }))
        if used > 0 { return .categoryInUse(name: category.name, count: used) }
        if !category.isArchived, try activeCount() <= 1 { return .lastActiveCategory }
        return nil
    }

    /// Re-checks every rule immediately before deleting. Never touches transactions.
    func delete(_ category: Category) throws {
        if let blocker = try deletionBlocker(for: category) { throw blocker }
        context.delete(category)
        try commit()
    }

    // MARK: Lists

    func activeCategories() throws -> [Category] {
        Self.sorted(try context.fetch(
            FetchDescriptor<Category>(predicate: #Predicate { $0.isArchived == false })))
    }

    func archivedCategories() throws -> [Category] {
        Self.sorted(try context.fetch(
            FetchDescriptor<Category>(predicate: #Predicate { $0.isArchived == true })))
    }

    /// Localised alphabetical order, with the id as a stable tie-break.
    static func sorted(_ items: [Category]) -> [Category] {
        items.sorted { a, b in
            let result = a.name.localizedStandardCompare(b.name)
            if result != .orderedSame { return result == .orderedAscending }
            return a.id.uuidString < b.id.uuidString
        }
    }

    // MARK: Private

    private func validated(_ input: CategoryInput, existing: Category?) throws -> CategoryInput {
        // Check the raw text first: normalization splits on some invisible characters
        // (such as the zero-width space) and would hide them.
        guard !Self.hasDisallowedCharacters(input.name) else { throw CategoryError.invalidName }
        let name = Self.normalizedName(input.name)
        guard !name.isEmpty, name.count <= Self.maxNameLength
        else { throw CategoryError.invalidName }

        let trimmedEmoji = input.emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        let emoji = trimmedEmoji.isEmpty ? Self.defaultEmoji : trimmedEmoji
        guard WalletService.isSingleEmoji(emoji) else { throw CategoryError.invalidEmoji }

        guard let hex = CategoryPalette.normalizedHex(input.colorHex) else {
            throw CategoryError.invalidColor
        }

        let key = Self.duplicateKey(name)
        let clashes = try context.fetch(FetchDescriptor<Category>()).filter {
            $0.id != existing?.id && Self.duplicateKey($0.name) == key
        }
        // An active clash is reported before an archived one, so the message is deterministic.
        let clash = clashes.min {
            ($0.isArchived ? 1 : 0, $0.id.uuidString) < ($1.isArchived ? 1 : 0, $1.id.uuidString)
        }
        if let clash {
            throw CategoryError.duplicateName(existing: clash.name, isArchived: clash.isArchived)
        }
        return CategoryInput(name: name, emoji: emoji, colorHex: hex)
    }

    private func activeCount() throws -> Int {
        try context.fetchCount(
            FetchDescriptor<Category>(predicate: #Predicate { $0.isArchived == false }))
    }

    private func commit() throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}
