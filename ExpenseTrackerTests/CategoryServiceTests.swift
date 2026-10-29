import XCTest
import SwiftData
@testable import ExpenseTracker

@MainActor
final class CategoryServiceTests: XCTestCase {
    private struct Env {
        let container: ModelContainer   // keeps the in-memory store alive
        let context: ModelContext
        var service: CategoryService { CategoryService(context: context) }
    }

    private func makeEnv() throws -> Env {
        let container = try AppDataStore.makeContainer(inMemory: true)
        return Env(container: container, context: ModelContext(container))
    }

    private func input(_ name: String, emoji: String = "🧪", hex: String = "#60A5FA") -> CategoryInput {
        CategoryInput(name: name, emoji: emoji, colorHex: hex)
    }

    private func assertThrows(
        _ expected: CategoryError, file: StaticString = #filePath, line: UInt = #line,
        _ body: () throws -> Void
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual($0 as? CategoryError, expected, file: file, line: line)
        }
    }

    // MARK: Names, colours, emoji

    func testNameNormalisation() {
        XCTAssertEqual(CategoryService.normalizedName("  Bike   Wash \n"), "Bike Wash")
        XCTAssertEqual(CategoryService.normalizedName("\tFuel\t"), "Fuel")
        XCTAssertEqual(CategoryService.normalizedName("a\n\nb"), "a b")
        XCTAssertEqual(CategoryService.normalizedName("   "), "")
    }


    func testDuplicateKeyIgnoresCaseDiacriticsAndWidth() {
        XCTAssertEqual(CategoryService.duplicateKey("Café"), CategoryService.duplicateKey("  cafe "))
        XCTAssertEqual(CategoryService.duplicateKey("ＦＵＥＬ"), CategoryService.duplicateKey("fuel"))
        XCTAssertEqual(CategoryService.duplicateKey("Bike  Wash"), CategoryService.duplicateKey("bike wash"))
        XCTAssertNotEqual(CategoryService.duplicateKey("Fuel"), CategoryService.duplicateKey("Fuels"))
    }

    func testPaletteIncludesSeededColoursAndTheOldDefault() {
        let hexes = CategoryPalette.colors.map(\.hex)
        for seeded in ["#FBBF24", "#F97316", "#A78BFA", "#EC4899", "#34D399", "#60A5FA", "#00E5FF"] {
            XCTAssertTrue(hexes.contains(seeded), seeded)
        }
        XCTAssertEqual(Set(hexes).count, hexes.count)
        XCTAssertEqual(Set(CategoryPalette.colors.map(\.name)).count, hexes.count)
        XCTAssertTrue(CategoryPalette.colors.allSatisfy { !$0.name.isEmpty })
        XCTAssertTrue(hexes.contains(CategoryPalette.defaultColor.hex))
        XCTAssertEqual(CategoryPalette.colors.count, 14)
        XCTAssertEqual(CategoryPalette.color(forHex: "#6366F1")?.name, "Indigo")
        XCTAssertEqual(CategoryPalette.color(forHex: "#D946EF")?.name, "Fuchsia")
        XCTAssertEqual(CategoryPalette.defaultColor.name, "Blue")
    }

    func testHexNormalisation() {
        XCTAssertEqual(CategoryPalette.normalizedHex(" #f97316 "), "#F97316")
        XCTAssertNil(CategoryPalette.normalizedHex("F97316"))
        XCTAssertNil(CategoryPalette.normalizedHex("#F9731"))
        XCTAssertNil(CategoryPalette.normalizedHex("#GGGGGG"))
        XCTAssertNil(CategoryPalette.normalizedHex(""))
        XCTAssertEqual(CategoryPalette.color(forHex: "#fbbf24")?.name, "Amber")
        XCTAssertNil(CategoryPalette.color(forHex: "#123456"))
    }

    func testSeededCategoriesPassTheNewRules() throws {
        let env = try makeEnv()
        let suite = "CategoryServiceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        try DefaultDataSeeder.seedIfNeeded(context: env.context, defaults: defaults)

        let seeded = try env.context.fetch(FetchDescriptor<ExpenseTracker.Category>())
        XCTAssertEqual(seeded.count, 6)
        for category in seeded {
            XCTAssertEqual(CategoryService.normalizedName(category.name), category.name)
            XCTAssertTrue(WalletService.isSingleEmoji(category.emoji), category.emoji)
            XCTAssertNotNil(CategoryPalette.color(forHex: category.colorHex), category.colorHex)
        }
        // Editing a seeded category without changing anything is allowed.
        let first = try XCTUnwrap(seeded.first)
        XCTAssertNoThrow(try env.service.update(
            first, with: CategoryInput(name: first.name, emoji: first.emoji, colorHex: first.colorHex)))
    }

    func testEmojiValidation() throws {
        let env = try makeEnv()
        for good in ["⛽", "🍔", "🏠", "🛍️", "💊", "🎮", "🏷️", "👨‍👩‍👧"] {
            XCTAssertNoThrow(try env.service.create(input("Cat \(good)", emoji: good)), good)
        }
        for bad in ["a", "ab", "⛽⛽", "1", "Fuel"] {
            assertThrows(.invalidEmoji) { try env.service.create(input("Bad \(bad)", emoji: bad)) }
        }
        let blank = try env.service.create(input("Blank emoji", emoji: "  "))
        XCTAssertEqual(blank.emoji, CategoryService.defaultEmoji)
    }

    // MARK: Create

    func testCreateStoresCleanValues() throws {
        let env = try makeEnv()
        let made = try env.service.create(input("  Bike   Wash ", emoji: " 🧼 ", hex: "#f97316"))
        XCTAssertEqual(made.name, "Bike Wash")
        XCTAssertEqual(made.emoji, "🧼")
        XCTAssertEqual(made.colorHex, "#F97316")
        XCTAssertFalse(made.isArchived)
        XCTAssertEqual(try env.context.fetchCount(FetchDescriptor<ExpenseTracker.Category>()), 1)
    }

    func testColourAcceptsAnyValidHexButRejectsMalformed() throws {
        let env = try makeEnv()
        XCTAssertEqual(try env.service.create(input("A", hex: "#123456")).colorHex, "#123456")
        XCTAssertEqual(try env.service.create(input("B", hex: "#abcdef")).colorHex, "#ABCDEF")
        XCTAssertEqual(try env.service.create(input("D", hex: "#00e5ff")).colorHex, "#00E5FF")
        assertThrows(.invalidColor) { try env.service.create(input("E", hex: "red")) }
        assertThrows(.invalidColor) { try env.service.create(input("F", hex: "")) }
        assertThrows(.invalidColor) { try env.service.create(input("G", hex: "#12345")) }
        assertThrows(.invalidColor) { try env.service.create(input("H", hex: "#GGGGGG")) }
        XCTAssertEqual(try env.context.fetchCount(FetchDescriptor<ExpenseTracker.Category>()), 3)
    }

    func testDuplicateNamesRejectedIncludingArchived() throws {
        let env = try makeEnv()
        let fuel = try env.service.create(input("Fuel"))
        try env.service.create(input("Food"))
        assertThrows(.duplicateName(existing: "Fuel", isArchived: false)) {
            try env.service.create(input("  fuel "))
        }
        try env.service.archive(fuel)
        assertThrows(.duplicateName(existing: "Fuel", isArchived: true)) {
            try env.service.create(input("FUEL"))
        }
        assertThrows(.duplicateName(existing: "Fuel", isArchived: true)) {
            try env.service.create(input("Fuél"))
        }
        XCTAssertTrue(CategoryError.duplicateName(existing: "Fuel", isArchived: true).message.contains("Restore"))
    }

    func testFiftyActiveLimitWithArchiveAndRestore() throws {
        let env = try makeEnv()
        var made: [ExpenseTracker.Category] = []
        for number in 1...CategoryService.maxActiveCategories {
            made.append(try env.service.create(input("Cat \(number)")))
        }
        assertThrows(.categoryLimitReached) { try env.service.create(input("One too many")) }

        try env.service.archive(made[0])                       // frees a slot
        let replacement = try env.service.create(input("Replacement"))
        XCTAssertEqual(try env.service.activeCategories().count, CategoryService.maxActiveCategories)
        assertThrows(.categoryLimitReached) { try env.service.unarchive(made[0]) }   // limit re-checked

        try env.service.archive(replacement)
        XCTAssertNoThrow(try env.service.unarchive(made[0]))
        XCTAssertFalse(made[0].isArchived)
    }

    // MARK: Update, archive, restore

    func testUpdateChangesFieldsAndKeepsIdentity() throws {
        let env = try makeEnv()
        let made = try env.service.create(input("Fuel", emoji: "⛽", hex: "#FBBF24"))
        let id = made.id
        let created = made.createdAt
        try env.service.update(made, with: input("FUEL", emoji: "🚗", hex: "#14B8A6"))
        XCTAssertEqual(made.id, id)
        XCTAssertEqual(made.name, "FUEL")            // changing only the case of its own name is allowed
        XCTAssertEqual(made.emoji, "🚗")
        XCTAssertEqual(made.colorHex, "#14B8A6")
        XCTAssertEqual(made.createdAt, created)
        XCTAssertGreaterThanOrEqual(made.updatedAt, created)
    }

    func testUpdateRejectsAnotherCategorysName() throws {
        let env = try makeEnv()
        try env.service.create(input("Fuel"))
        let food = try env.service.create(input("Food"))
        assertThrows(.duplicateName(existing: "Fuel", isArchived: false)) {
            try env.service.update(food, with: input("fuel"))
        }
        XCTAssertEqual(food.name, "Food")
    }

    func testUpdateAcceptsCustomColoursAndRejectsMalformedOnes() throws {
        let env = try makeEnv()
        let made = try env.service.create(input("Old"))
        try env.service.update(made, with: input("Old", hex: "#123456"))
        XCTAssertEqual(made.colorHex, "#123456")
        try env.service.update(made, with: input("Old", hex: "#654321"))
        XCTAssertEqual(made.colorHex, "#654321")
        assertThrows(.invalidColor) { try env.service.update(made, with: input("Old", hex: "nope")) }
        XCTAssertEqual(made.colorHex, "#654321")
    }

    func testCannotArchiveTheLastActiveCategory() throws {
        let env = try makeEnv()
        let only = try env.service.create(input("Only"))
        assertThrows(.lastActiveCategory) { try env.service.archive(only) }
        XCTAssertFalse(only.isArchived)
        let second = try env.service.create(input("Second"))
        XCTAssertNoThrow(try env.service.archive(only))
        assertThrows(.lastActiveCategory) { try env.service.archive(second) }
    }

    func testArchiveAndUnarchiveAreIdempotent() throws {
        let env = try makeEnv()
        let a = try env.service.create(input("A"))
        try env.service.create(input("B"))
        try env.service.archive(a)
        XCTAssertNoThrow(try env.service.archive(a))
        XCTAssertTrue(a.isArchived)
        try env.service.unarchive(a)
        XCTAssertNoThrow(try env.service.unarchive(a))
        XCTAssertFalse(a.isArchived)
    }


    // MARK: Lists, history, messages

    func testListsAreLocalisedAndSeparated() throws {
        let env = try makeEnv()
        for name in ["Éclair", "banana", "Eagle", "Apple"] { try env.service.create(input(name)) }
        let zed = try env.service.create(input("Zed"))
        try env.service.archive(zed)
        XCTAssertEqual(try env.service.activeCategories().map(\.name), ["Apple", "banana", "Eagle", "Éclair"])
        XCTAssertEqual(try env.service.archivedCategories().map(\.name), ["Zed"])
    }

    func testHistorySurvivesRenameAndArchive() throws {
        let env = try makeEnv()
        let fuel = try env.service.create(input("Fuel", emoji: "⛽", hex: "#FBBF24"))
        try env.service.create(input("Food"))
        let wallet = try WalletService(context: env.context)
            .create(WalletInput(name: "IOB", openingBalanceMinor: 100_000))
        let draft = TransactionDraft(
            kind: .expense, amountMinor: 500, walletID: wallet.id, categoryID: fuel.id)
        try TransactionService(context: env.context).save(draft)

        func historyRow() throws -> HistoryRow {
            let now = Date()
            let days = try TransactionQueryService(context: env.context).history(
                in: now.addingTimeInterval(-172_800)..<now.addingTimeInterval(172_800))
            return try XCTUnwrap(days.flatMap(\.wallets).flatMap(\.rows).first)
        }

        XCTAssertEqual(try historyRow().categoryName, "Fuel")
        try env.service.update(fuel, with: input("Petrol", emoji: "⛽", hex: "#FBBF24"))
        var row = try historyRow()
        XCTAssertEqual(row.categoryName, "Petrol")
        XCTAssertEqual(row.categoryID, fuel.id)

        try env.service.archive(fuel)
        row = try historyRow()
        XCTAssertEqual(row.categoryName, "Petrol")
        XCTAssertTrue(row.categoryIsArchived)
        // New entries can't use it, but old ones keep it.
        XCTAssertThrowsError(try TransactionService(context: env.context).save(
            TransactionDraft(kind: .expense, amountMinor: 100, walletID: wallet.id, categoryID: fuel.id))) {
            XCTAssertEqual($0 as? TransactionServiceError, .categoryArchived)
        }
    }

    func testErrorMessages() {
        let all: [CategoryError] = [
            .invalidName, .invalidEmoji, .invalidColor,
            .duplicateName(existing: "Fuel", isArchived: false),
            .duplicateName(existing: "Fuel", isArchived: true),
            .categoryLimitReached, .lastActiveCategory
        ]
        for error in all { XCTAssertFalse(error.message.isEmpty) }
        XCTAssertTrue(CategoryError.duplicateName(existing: "Fuel", isArchived: false).message.contains("Fuel"))
        XCTAssertTrue(CategoryError.categoryLimitReached.message.contains("50"))
    }




    func testNameLengthAndCharacterRules() throws {
        let env = try makeEnv()
        assertThrows(.invalidName) { try env.service.create(input("")) }
        assertThrows(.invalidName) { try env.service.create(input("   \n ")) }
        assertThrows(.invalidName) { try env.service.create(input("A\u{0007}B")) }
        assertThrows(.invalidName) {
            try env.service.create(input(String(repeating: "a", count: CategoryService.maxNameLength + 1)))
        }
        XCTAssertNoThrow(try env.service.create(input("a")))
        XCTAssertNoThrow(try env.service.create(input(String(repeating: "b", count: CategoryService.maxNameLength))))
        XCTAssertNoThrow(try env.service.create(input("Fuel ⛽")))
        // Emoji sequences and some scripts need the zero-width joiner and non-joiner.
        XCTAssertNoThrow(try env.service.create(input("Family 👨‍👩‍👧")))
        XCTAssertNoThrow(try env.service.create(input("a\u{200C}b")))
        // Invisible or direction-changing characters are still refused.
        assertThrows(.invalidName) { try env.service.create(input("Zero\u{200B}width")) }
        assertThrows(.invalidName) { try env.service.create(input("A\u{202E}B")) }
    }

    func testTabsAndNewlinesNormalizeToSingleSpace() throws {
        let env = try makeEnv()
        XCTAssertEqual(try env.service.create(input("Bike\tWash")).name, "Bike Wash")
        XCTAssertEqual(try env.service.create(input("Car\nService")).name, "Car Service")
    }

    func testUnarchiveRejectsNameClash() throws {
        let env = try makeEnv()
        // Inserted directly: the service itself would refuse to create "fuel" next to "Fuel".
        let retired = ExpenseTracker.Category(name: "Fuel", emoji: "⛽", colorHex: "#FBBF24", isArchived: true)
        let active = ExpenseTracker.Category(name: "fuel", emoji: "⛽", colorHex: "#FBBF24")
        env.context.insert(retired)
        env.context.insert(active)
        try env.context.save()
        assertThrows(.duplicateName(existing: "fuel", isArchived: false)) {
            try env.service.unarchive(retired)
        }
        XCTAssertTrue(retired.isArchived)
    }

    func testActiveClashIsReportedBeforeAnArchivedOne() throws {
        let env = try makeEnv()
        env.context.insert(ExpenseTracker.Category(name: "Fuel", emoji: "⛽", colorHex: "#FBBF24", isArchived: true))
        env.context.insert(ExpenseTracker.Category(name: "fuel", emoji: "⛽", colorHex: "#FBBF24"))
        try env.context.save()
        for _ in 0..<5 {
            assertThrows(.duplicateName(existing: "fuel", isArchived: false)) {
                try env.service.create(input("FUEL"))
            }
        }
    }

    // MARK: Delete

    private func makeUsedCategory(_ env: Env) throws -> (category: ExpenseTracker.Category, walletID: UUID) {
        let category = try env.service.create(input("Used"))
        let wallet = try WalletService(context: env.context)
            .create(WalletInput(name: "IOB", openingBalanceMinor: 100_000))
        try TransactionService(context: env.context).save(
            TransactionDraft(kind: .expense, amountMinor: 500, walletID: wallet.id, categoryID: category.id))
        return (category, wallet.id)
    }

    func testDeleteRemovesUnusedCategory() throws {
        let env = try makeEnv()
        let keep = try env.service.create(input("Keep"))
        let gone = try env.service.create(input("Gone"))
        try env.service.delete(gone)
        let names = try env.context.fetch(FetchDescriptor<ExpenseTracker.Category>()).map(\.name)
        XCTAssertEqual(names, [keep.name])
    }

    func testDeleteRefusesCategoryUsedByTransaction() throws {
        let env = try makeEnv()
        try env.service.create(input("Other"))
        let used = try makeUsedCategory(env).category
        assertThrows(.categoryInUse(name: "Used", count: 1)) { try env.service.delete(used) }
        XCTAssertEqual(try env.context.fetchCount(FetchDescriptor<ExpenseTracker.Category>()), 2)
        XCTAssertEqual(try env.context.fetchCount(FetchDescriptor<Transaction>()), 1)
    }

    func testDeleteRefusesArchivedCategoryThatIsStillUsed() throws {
        let env = try makeEnv()
        try env.service.create(input("Other"))
        let used = try makeUsedCategory(env).category
        try env.service.archive(used)
        assertThrows(.categoryInUse(name: "Used", count: 1)) { try env.service.delete(used) }
        XCTAssertEqual(try env.context.fetchCount(FetchDescriptor<Transaction>()), 1)
    }

    func testDeleteRefusesLastActiveCategory() throws {
        let env = try makeEnv()
        let only = try env.service.create(input("Only"))
        assertThrows(.lastActiveCategory) { try env.service.delete(only) }
        XCTAssertEqual(try env.context.fetchCount(FetchDescriptor<ExpenseTracker.Category>()), 1)
    }

    func testDeleteArchivedUnusedCategoryIsAllowedWhenOnlyOneIsActive() throws {
        let env = try makeEnv()
        let active = try env.service.create(input("Active"))
        let retired = try env.service.create(input("Retired"))
        try env.service.archive(retired)
        XCTAssertNoThrow(try env.service.delete(retired))
        let names = try env.context.fetch(FetchDescriptor<ExpenseTracker.Category>()).map(\.name)
        XCTAssertEqual(names, [active.name])
    }

    func testCategoryInUseMessageSuggestsArchiving() {
        let one = CategoryError.categoryInUse(name: "Fuel", count: 1).message
        let many = CategoryError.categoryInUse(name: "Fuel", count: 3).message
        XCTAssertTrue(one.contains("1 transaction uses"))
        XCTAssertTrue(many.contains("3 transactions use"))
        XCTAssertTrue(one.contains("Archive") && many.contains("Fuel"))
    }
}
