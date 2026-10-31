import XCTest
@testable import ExpenseTracker

@MainActor
final class TransactionEditModelTests: XCTestCase {
    private let cash = UUID(), iob = UUID(), old = UUID(), usd = UUID()
    private let food = UUID(), retired = UUID(), other = UUID()

    private var options: EditOptions {
        EditOptions(
            wallets: [
                EditWalletOption(id: cash, name: "Cash", emoji: "💵", currencyCode: "INR", isArchived: false),
                EditWalletOption(id: iob, name: "IOB", emoji: "🏦", currencyCode: "INR", isArchived: false),
                EditWalletOption(id: old, name: "Old", emoji: "🐷", currencyCode: "INR", isArchived: true),
                EditWalletOption(id: usd, name: "Dollars", emoji: "💲", currencyCode: "USD", isArchived: false)
            ],
            categories: [
                EditCategoryOption(id: food, name: "Food", emoji: "🍔", isArchived: false),
                EditCategoryOption(id: retired, name: "Retired", emoji: "🧺", isArchived: true),
                EditCategoryOption(id: other, name: "Other", emoji: "🎁", isArchived: true)
            ])
    }

    private func row(
        _ kind: TransactionKind, category: UUID? = nil, transfer: UUID? = nil,
        counterpart: UUID? = nil, broken: Bool = false
    ) -> HistoryRow {
        HistoryRow(
            id: UUID(), kind: kind, amountMinor: 15_000,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000), note: "Lunch",
            categoryID: category, categoryName: nil, categoryEmoji: nil, categoryColorHex: nil,
            categoryIsArchived: false, transferID: transfer, counterpartWalletID: counterpart,
            counterpartWalletName: nil, isBrokenTransfer: broken)
    }

    private func make(_ row: HistoryRow, wallet: UUID) -> TransactionEditModel? {
        TransactionEditModel.make(row: row, walletID: wallet, currencyCode: "INR", options: options)
    }

    func testPrefillOfAnExpense() throws {
        let r = row(.expense, category: food)
        let m = try XCTUnwrap(make(r, wallet: cash))
        XCTAssertEqual(m.target, .ordinary(id: r.id))
        XCTAssertEqual(m.amount.money?.minorUnits, 15_000)
        XCTAssertEqual(m.walletID, cash)
        XCTAssertEqual(m.categoryID, food)
        XCTAssertEqual(m.note, "Lunch")
        XCTAssertEqual(m.kind, .expense)
        XCTAssertNil(m.validate())
    }

    func testWalletChoicesAreSameCurrencyAndKeepAnArchivedCurrentWallet() throws {
        let normal = try XCTUnwrap(make(row(.expense, category: food), wallet: cash))
        XCTAssertEqual(normal.walletChoices.map(\.id), [cash, iob])
        let inArchived = try XCTUnwrap(make(row(.expense, category: food), wallet: old))
        XCTAssertEqual(inArchived.walletChoices.map(\.id), [cash, iob, old])
        XCTAssertEqual(inArchived.walletID, old)
    }

    func testCategoryChoicesKeepOnlyTheCurrentArchivedCategory() throws {
        let m = try XCTUnwrap(make(row(.expense, category: retired), wallet: cash))
        XCTAssertEqual(m.categoryChoices.map(\.id), [food, retired])
        XCTAssertEqual(m.categoryID, retired)
    }

    func testExpenseNeedsACategoryButIncomeDoesNot() throws {
        var m = try XCTUnwrap(make(row(.expense, category: food), wallet: cash))
        m.setCategory(nil)
        XCTAssertEqual(m.validate(), .categoryRequired)
        m.setKind(.income)
        XCTAssertNil(m.validate())
    }

    func testZeroAmountIsBlocked() throws {
        var m = try XCTUnwrap(make(row(.expense, category: food), wallet: cash))
        m.amount.clear()
        XCTAssertEqual(m.validate(), .amountMissing)
        XCTAssertNil(m.transactionEdit())
    }

    func testChangesBuildTheEdit() throws {
        var m = try XCTUnwrap(make(row(.expense, category: food), wallet: cash))
        m.setWallet(iob)
        m.setWallet(usd)               // other currency: ignored
        m.setCategory(other)           // archived and not current: ignored
        m.setNote("Dinner")
        let edit = try XCTUnwrap(m.transactionEdit())
        XCTAssertEqual(edit.walletID, iob)
        XCTAssertEqual(edit.categoryID, food)
        XCTAssertEqual(edit.amountMinor, 15_000)
        XCTAssertEqual(edit.note, "Dinner")
        XCTAssertEqual(edit.kind, .expense)
        XCTAssertNil(m.transferEdit())
    }

    func testTransferDirectionFollowsTheSwipedLeg() throws {
        let id = UUID()
        let out = try XCTUnwrap(make(row(.transferOut, transfer: id, counterpart: iob), wallet: cash))
        XCTAssertEqual(out.walletID, cash)
        XCTAssertEqual(out.toWalletID, iob)
        let inn = try XCTUnwrap(make(row(.transferIn, transfer: id, counterpart: iob), wallet: cash))
        XCTAssertEqual(inn.walletID, iob)
        XCTAssertEqual(inn.toWalletID, cash)
        XCTAssertEqual(inn.target, .transfer(transferID: id))
        let edit = try XCTUnwrap(inn.transferEdit())
        XCTAssertEqual(edit.fromWalletID, iob)
        XCTAssertEqual(edit.toWalletID, cash)
        XCTAssertEqual(edit.amountMinor, 15_000)
        XCTAssertNil(inn.transactionEdit())
    }

    func testBrokenOrUnknownTransfersAreNotEditable() {
        XCTAssertNil(make(row(.transferOut, transfer: UUID(), counterpart: iob, broken: true), wallet: cash))
        XCTAssertNil(make(row(.transferOut, transfer: UUID(), counterpart: nil), wallet: cash))
    }

    func testChoosingTheDestinationAsSourceMovesTheDestination() throws {
        var m = try XCTUnwrap(make(row(.transferOut, transfer: UUID(), counterpart: iob), wallet: cash))
        m.setToWallet(cash)            // same as source: ignored
        XCTAssertEqual(m.toWalletID, iob)
        m.setWallet(iob)
        XCTAssertEqual(m.walletID, iob)
        XCTAssertEqual(m.toWalletID, cash)
        XCTAssertNil(m.validate())
        m.setKind(.income)             // transfers keep their type
        XCTAssertTrue(m.isTransfer)
    }

    func testDeleteWording() {
        let f = HistoryFormatting(calendar: Calendar(identifier: .gregorian), locale: Locale(identifier: "en_IN"))
        let expense = row(.expense)
        let title = f.deleteTitle(for: expense, currencyCode: "INR")
        XCTAssertTrue(title.hasPrefix("Delete"))
        XCTAssertTrue(title.hasSuffix("Uncategorised?"))
        XCTAssertTrue(title.contains("150"))
        XCTAssertFalse(f.deleteMessage(for: expense).contains("both sides"))
        XCTAssertTrue(f.deleteMessage(for: expense).contains("undone"))
        XCTAssertTrue(f.deleteMessage(for: row(.transferOut, transfer: UUID(), counterpart: iob)).contains("both sides"))
        XCTAssertTrue(f.deleteMessage(for: row(.transferOut, transfer: UUID(), broken: true)).contains("incomplete"))
    }
}
