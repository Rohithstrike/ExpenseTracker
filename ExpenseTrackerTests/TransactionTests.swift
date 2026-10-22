import XCTest
@testable import ExpenseTracker

final class TransactionTests: XCTestCase {
    private let wallet = UUID()

    func testValidExpenseAndIncome() throws {
        let e = try Transaction.makeValidated(amountMinor: 100, kind: .expense, walletID: wallet, note: "  tea  ")
        XCTAssertEqual(e.kind, .expense)
        XCTAssertEqual(e.note, "tea")
        let i = try Transaction.makeValidated(amountMinor: 100, kind: .income, walletID: wallet)
        XCTAssertEqual(i.kind, .income)
    }

    func testRejectsZeroNegativeAndHugeAmounts() {
        for amount: Int64 in [0, -1, .min] {
            XCTAssertThrowsError(try Transaction.makeValidated(amountMinor: amount, kind: .expense, walletID: wallet)) {
                XCTAssertEqual($0 as? TransactionValidationError, .nonPositiveAmount)
            }
        }
        XCTAssertThrowsError(try Transaction.makeValidated(amountMinor: Money.maxInputMinorUnits + 1, kind: .income, walletID: wallet)) {
            XCTAssertEqual($0 as? TransactionValidationError, .amountTooLarge)
        }
        XCTAssertNoThrow(try Transaction.makeValidated(amountMinor: Money.maxInputMinorUnits, kind: .income, walletID: wallet))
    }

    func testTransferRules() throws {
        let tid = UUID()
        XCTAssertNoThrow(try Transaction.makeValidated(amountMinor: 5, kind: .transferOut, walletID: wallet, transferID: tid))
        XCTAssertThrowsError(try Transaction.makeValidated(amountMinor: 5, kind: .transferIn, walletID: wallet)) {
            XCTAssertEqual($0 as? TransactionValidationError, .missingTransferID)
        }
        XCTAssertThrowsError(try Transaction.makeValidated(amountMinor: 5, kind: .expense, walletID: wallet, transferID: tid)) {
            XCTAssertEqual($0 as? TransactionValidationError, .unexpectedTransferID)
        }
        XCTAssertThrowsError(try Transaction.makeValidated(amountMinor: 5, kind: .transferOut, walletID: wallet, categoryID: UUID(), transferID: tid)) {
            XCTAssertEqual($0 as? TransactionValidationError, .transferCannotHaveCategory)
        }
    }

    func testNoteLengthLimit() {
        let long = String(repeating: "a", count: Transaction.maxNoteLength + 1)
        XCTAssertThrowsError(try Transaction.makeValidated(amountMinor: 5, kind: .expense, walletID: wallet, note: long)) {
            XCTAssertEqual($0 as? TransactionValidationError, .noteTooLong)
        }
        XCTAssertNoThrow(try Transaction.makeValidated(amountMinor: 5, kind: .expense, walletID: wallet, note: "😀 café 日本"))
    }

    func testUnknownKindIsDetected() {
        let t = Transaction(amountMinor: 5, kind: .expense, walletID: wallet)
        t.kindRaw = "futureKind"
        XCTAssertNil(t.kind)
        XCTAssertThrowsError(try t.ledgerEntry()) { XCTAssertEqual($0 as? BalanceError, .unknownKind) }
    }
}
