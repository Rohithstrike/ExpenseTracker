import XCTest
import SwiftData
@testable import ExpenseTracker

final class BalanceCalculatorTests: XCTestCase {
    private let w1 = UUID()
    private let w2 = UUID()

    private func entry(_ w: UUID, _ k: TransactionKind, _ a: Int64) -> LedgerEntry {
        LedgerEntry(walletID: w, kind: k, amountMinor: a)
    }

    func testIncreaseAndDecrease() throws {
        XCTAssertEqual(try BalanceCalculator.balanceMinor(openingMinor: 500_000, walletID: w1, entries: [entry(w1, .income, 10_000)]), 510_000)
        XCTAssertEqual(try BalanceCalculator.balanceMinor(openingMinor: 500_000, walletID: w1, entries: [entry(w1, .expense, 10_000)]), 490_000)
    }

    func testTransfersMoveMoneyBetweenWallets() throws {
        let entries = [entry(w1, .transferOut, 30_000), entry(w2, .transferIn, 30_000)]
        XCTAssertEqual(try BalanceCalculator.balanceMinor(openingMinor: 500_000, walletID: w1, entries: entries), 470_000)
        XCTAssertEqual(try BalanceCalculator.balanceMinor(openingMinor: 200_000, walletID: w2, entries: entries), 230_000)
    }

    func testMixedLedgerAndOtherWalletsIgnored() throws {
        let entries = [
            entry(w1, .income, 100), entry(w1, .expense, 40), entry(w1, .transferIn, 10),
            entry(w1, .transferOut, 5), entry(w2, .expense, 999_999)
        ]
        XCTAssertEqual(try BalanceCalculator.balanceMinor(openingMinor: 1_000, walletID: w1, entries: entries), 1_065)
    }

    func testNegativeBalanceIsAccurate() throws {
        XCTAssertEqual(try BalanceCalculator.balanceMinor(openingMinor: 100, walletID: w1, entries: [entry(w1, .expense, 250)]), -150)
    }

    func testInvalidAmountsAndOverflowThrow() {
        for bad: Int64 in [0, -5] {
            XCTAssertThrowsError(try BalanceCalculator.balanceMinor(openingMinor: 0, walletID: w1, entries: [entry(w1, .income, bad)])) {
                XCTAssertEqual($0 as? BalanceError, .invalidAmount)
            }
        }
        XCTAssertThrowsError(try BalanceCalculator.balanceMinor(openingMinor: .max, walletID: w1, entries: [entry(w1, .income, 1)])) {
            XCTAssertEqual($0 as? BalanceError, .overflow)
        }
        XCTAssertThrowsError(try BalanceCalculator.balanceMinor(openingMinor: .min, walletID: w1, entries: [entry(w1, .expense, 1)])) {
            XCTAssertEqual($0 as? BalanceError, .overflow)
        }
    }

    func testArchivedWalletKeepsItsBalanceAndHistory() throws {
        let container = try ModelContainer(
            for: Wallet.self, Category.self, Transaction.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let wallet = Wallet(name: "Bank 1", openingBalanceMinor: 500_000)
        context.insert(wallet)
        let inputs: [(Int64, TransactionKind)] = [(10_000, .income), (2_500, .expense)]
        for (amount, kind) in inputs {
            context.insert(try Transaction.makeValidated(amountMinor: amount, kind: kind, walletID: wallet.id))
        }
        try context.save()

        wallet.isArchived = true
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(fetched.count, 2)
        let balance = try BalanceCalculator.balance(of: wallet, transactions: fetched)
        XCTAssertEqual(balance.minorUnits, 507_500)
        XCTAssertEqual(balance.currencyCode, "INR")
    }
}
