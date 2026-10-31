import XCTest
@testable import ExpenseTracker

final class ProgressCalculatorTests: XCTestCase {
    private let inr = UUID(), usd = UUID(), ghost = UUID()
    private let food = UUID(), fuel = UUID(), retired = UUID()

    private var currencies: [UUID: String] { [inr: "INR", usd: "USD"] }

    private func category(_ id: UUID, _ name: String, hex: String = "#FBBF24", archived: Bool = false) -> ProgressCategory {
        ProgressCategory(id: id, name: name, emoji: "🏷️", colorHex: hex, isArchived: archived)
    }

    private var categories: [UUID: ProgressCategory] {
        [food: category(food, "Food"), fuel: category(fuel, "Fuel"),
         retired: category(retired, "Retired", archived: true)]
    }

    private func txn(_ kind: TransactionKind, _ amount: Int64, wallet: UUID? = nil, category: UUID? = nil) -> ProgressTransaction {
        ProgressTransaction(kind: kind, amountMinor: amount, walletID: wallet ?? inr, categoryID: category)
    }

    private func summaries(_ items: [ProgressTransaction], cats: [UUID: ProgressCategory]? = nil) throws -> [CurrencySummary] {
        try ProgressCalculator.summaries(
            transactions: items, walletCurrencies: currencies, categories: cats ?? categories)
    }

    func testTotalsNetAndTransfersAreExcluded() throws {
        let result = try summaries([
            txn(.income, 60_000),
            txn(.expense, 35_000, category: food),
            txn(.expense, 10_000, category: fuel),
            txn(.transferOut, 20_000),
            txn(.transferIn, 20_000)
        ])
        XCTAssertEqual(result.count, 1)
        let inrSummary = try XCTUnwrap(result.first)
        XCTAssertEqual(inrSummary.currencyCode, "INR")
        XCTAssertEqual(inrSummary.incomeMinor, 60_000)
        XCTAssertEqual(inrSummary.expenseMinor, 45_000)
        XCTAssertEqual(inrSummary.netMinor, 15_000)
        XCTAssertEqual(inrSummary.categories.map(\.amountMinor), [35_000, 10_000])
    }

    func testNetCanBeNegative() throws {
        let result = try summaries([txn(.income, 1_000), txn(.expense, 5_000, category: food)])
        XCTAssertEqual(try XCTUnwrap(result.first).netMinor, -4_000)
    }

    func testCategoriesAreGroupedByIdAndIncomeIsNotSpending() throws {
        let result = try summaries([
            txn(.expense, 300, category: food),
            txn(.expense, 200, category: food),
            txn(.expense, 400, category: fuel),
            txn(.income, 9_999, category: food)
        ])
        let list = try XCTUnwrap(result.first).categories
        XCTAssertEqual(list.map(\.name), ["Food", "Fuel"])
        XCTAssertEqual(list.map(\.amountMinor), [500, 400])
        XCTAssertEqual(list.compactMap(\.categoryID), [food, fuel])
    }

    func testUncategorisedAndUnknownCategoryShareOneRow() throws {
        let result = try summaries([
            txn(.expense, 100),
            txn(.expense, 250, category: UUID())
        ])
        let list = try XCTUnwrap(result.first).categories
        XCTAssertEqual(list.count, 1)
        XCTAssertNil(list[0].categoryID)
        XCTAssertEqual(list[0].name, CategorySpend.uncategorisedName)
        XCTAssertEqual(list[0].amountMinor, 350)
    }

    func testArchivedCategoriesStillCount() throws {
        let result = try summaries([txn(.expense, 700, category: retired)])
        let row = try XCTUnwrap(result.first?.categories.first)
        XCTAssertTrue(row.isArchived)
        XCTAssertEqual(row.amountMinor, 700)
    }

    func testRecolouringOrRenamingChangesNoAmounts() throws {
        let items = [txn(.expense, 300, category: food), txn(.expense, 400, category: fuel)]
        let before = try summaries(items)
        var changed = categories
        changed[food] = category(food, "Groceries", hex: "#123456")
        let after = try summaries(items, cats: changed)
        XCTAssertEqual(before.first?.categories.map(\.amountMinor), after.first?.categories.map(\.amountMinor))
        XCTAssertEqual(before.first?.categories.compactMap(\.categoryID), after.first?.categories.compactMap(\.categoryID))
        XCTAssertEqual(after.first?.categories.last?.colorHex ?? "", "#123456")
    }

    func testCurrenciesAreNeverMixed() throws {
        let result = try summaries([
            txn(.expense, 1_000, wallet: inr, category: food),
            txn(.expense, 2_000, wallet: usd, category: food),
            txn(.income, 500, wallet: usd),
            txn(.expense, 7, wallet: ghost)
        ])
        XCTAssertEqual(result.map(\.currencyCode), ["INR", "USD", ""])
        XCTAssertEqual(result[0].expenseMinor, 1_000)
        XCTAssertEqual(result[1].expenseMinor, 2_000)
        XCTAssertEqual(result[1].incomeMinor, 500)
        XCTAssertEqual(result[2].expenseMinor, 7)
    }

    func testTiesAreOrderedByName() throws {
        let result = try summaries([txn(.expense, 100, category: fuel), txn(.expense, 100, category: food)])
        XCTAssertEqual(try XCTUnwrap(result.first).categories.map(\.name), ["Food", "Fuel"])
    }

    func testEmptyInputGivesNoSummaries() throws {
        XCTAssertEqual(try summaries([]), [])
    }

    func testOverflowIsReportedNotWrapped() {
        let half = Int64.max / 2 + 1
        XCTAssertThrowsError(try summaries([txn(.expense, half), txn(.expense, half)])) {
            XCTAssertEqual($0 as? ProgressError, .overflow)
        }
    }
}
