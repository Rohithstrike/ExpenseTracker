import XCTest
import SwiftUI
import SwiftData
@testable import ExpenseTracker

@MainActor
final class CategoryColorToolsTests: XCTestCase {
    private struct Env {
        let container: ModelContainer   // keeps the in-memory store alive
        let context: ModelContext
        var service: CategoryService { CategoryService(context: context) }
    }

    private func makeEnv() throws -> Env {
        let container = try AppDataStore.makeContainer(inMemory: true)
        return Env(container: container, context: ModelContext(container))
    }

    func testHexConversionForPrimaryColoursBlackAndWhite() {
        let cases: [(String, String)] = [
            ("#FF0000", "#FF0000"),
            ("#00FF00", "#00FF00"),
            ("#0000FF", "#0000FF"),
            ("#000000", "#000000"),
            ("#FFFFFF", "#FFFFFF")
        ]

        for (input, expected) in cases {
            XCTAssertEqual(
                CategoryColorHex.hex(from: Color(hex: input)),
                expected,
                "Unexpected conversion for \(input)"
            )
        }
    }

    func testHexConversionForPaletteAndCustomColours() {
        let hexes = CategoryPalette.colors.map(\.hex) + [
            "#123456",
            "#ABCDEF"
        ]

        for hex in hexes {
            XCTAssertEqual(
                CategoryColorHex.hex(from: Color(hex: hex)),
                hex,
                "Unexpected conversion for \(hex)"
            )
        }
    }

    func testDuplicateLookupFindsCaseInsensitiveMatch() throws {
        let env = try makeEnv()
        defer { withExtendedLifetime(env.container) {} }

        let category = try env.service.create(
            CategoryInput(name: "Custom One", emoji: "🧪", colorHex: "#abcdef")
        )

        let found = try env.service.activeCategory(
            usingColorHex: "#ABCDEF",
            excluding: nil
        )

        XCTAssertEqual(found?.id, category.id)
    }

    func testDuplicateLookupExcludesCurrentCategory() throws {
        let env = try makeEnv()
        defer { withExtendedLifetime(env.container) {} }

        let first = try env.service.create(
            CategoryInput(name: "Custom One", emoji: "🧪", colorHex: "#123456")
        )
        _ = try env.service.create(
            CategoryInput(name: "Custom Two", emoji: "🧪", colorHex: "#123456")
        )

        let found = try env.service.activeCategory(
            usingColorHex: "#123456",
            excluding: first.id
        )

        XCTAssertNotNil(found)
        XCTAssertNotEqual(found?.id, first.id)
    }

    func testDuplicateLookupIgnoresArchivedCategories() throws {
        let env = try makeEnv()
        defer { withExtendedLifetime(env.container) {} }

        let category = try env.service.create(
            CategoryInput(name: "Custom One", emoji: "🧪", colorHex: "#123456")
        )
        // The service never archives the last active category, so keep another one active.
        let other = try env.service.create(
            CategoryInput(name: "Custom Two", emoji: "🧪", colorHex: "#654321")
        )
        try env.service.archive(category)

        XCTAssertNil(
            try env.service.activeCategory(
                usingColorHex: "#123456",
                excluding: nil
            )
        )
        XCTAssertEqual(
            try env.service.activeCategory(
                usingColorHex: "#654321",
                excluding: nil
            )?.id,
            other.id
        )
    }

    func testDuplicateLookupReturnsNilForInvalidOrUnusedColour() throws {
        let env = try makeEnv()
        defer { withExtendedLifetime(env.container) {} }

        XCTAssertNil(
            try env.service.activeCategory(
                usingColorHex: "#123456",
                excluding: nil
            )
        )
        XCTAssertNil(
            try env.service.activeCategory(
                usingColorHex: "red",
                excluding: nil
            )
        )
        XCTAssertNil(
            try env.service.activeCategory(
                usingColorHex: "",
                excluding: nil
            )
        )
    }

    func testCreatingCategoriesWithSameColourIsAllowed() throws {
        let env = try makeEnv()
        defer { withExtendedLifetime(env.container) {} }

        let first = try env.service.create(
            CategoryInput(name: "Custom One", emoji: "🧪", colorHex: "#123456")
        )
        let second = try env.service.create(
            CategoryInput(name: "Custom Two", emoji: "🧪", colorHex: "#123456")
        )

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(try env.service.activeCategories().filter {
            $0.colorHex == "#123456"
        }.count, 2)
    }
}
