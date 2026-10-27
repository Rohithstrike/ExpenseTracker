import XCTest
import SwiftData
@testable import ExpenseTracker

@MainActor
final class CategoryEditorSuggestionsTests: XCTestCase {
    func testEveryEmojiSuggestionPassesTheEmojiRule() {
        for item in CategoryEmojiSuggestions.all {
            XCTAssertTrue(WalletService.isSingleEmoji(item), item)
        }
    }

    func testSuggestionsAreUnique() {
        XCTAssertEqual(Set(CategoryEmojiSuggestions.all).count, CategoryEmojiSuggestions.all.count)
    }

    func testEverySuggestionCanBeSavedThroughTheService() throws {
        let container = try AppDataStore.makeContainer(inMemory: true)
        defer { withExtendedLifetime(container) {} }
        let service = CategoryService(context: ModelContext(container))
        for (index, item) in CategoryEmojiSuggestions.all.enumerated() {
            XCTAssertNoThrow(
                try service.create(CategoryInput(name: "Suggestion \(index)", emoji: item)), item)
        }
    }

    func testLegacyColourIsOnlyOfferedWhenValidButNotInThePalette() {
        XCTAssertNil(CategoryColorChoices.legacyHex(for: "#60A5FA"))
        XCTAssertNil(CategoryColorChoices.legacyHex(for: "#60a5fa"))
        XCTAssertEqual(CategoryColorChoices.legacyHex(for: "#123abc"), "#123ABC")
        XCTAssertNil(CategoryColorChoices.legacyHex(for: "not a colour"))
    }
}
