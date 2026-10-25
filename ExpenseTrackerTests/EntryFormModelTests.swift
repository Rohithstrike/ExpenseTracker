// ExpenseTrackerTests/EntryFormModelTests.swift  (new file)
import XCTest
@testable import ExpenseTracker

private func fixedID(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
}

@MainActor
final class EntryFormModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let cash = EntryWallet(id: fixedID(1), name: "Cash", emoji: "💵", currencyCode: "INR", balanceMinor: 50_000)
    private let bank = EntryWallet(id: fixedID(2), name: "Bank", emoji: "🏦", currencyCode: "INR", balanceMinor: 20_000)
    private let usd = EntryWallet(id: fixedID(3), name: "Dollars", emoji: "💳", currencyCode: "USD", balanceMinor: 10_000)
    private let savings = EntryWallet(id: fixedID(4), name: "Savings", emoji: "🐷", currencyCode: "INR", balanceMinor: 0)
    private let food = EntryCategory(id: fixedID(101), name: "Food", emoji: "🍔", colorHex: "#F97316")
    private let fuel = EntryCategory(id: fixedID(102), name: "Fuel", emoji: "⛽", colorHex: "#FBBF24")

    private func base() -> EntrySnapshot {
        EntrySnapshot(wallets: [cash, bank, usd], categories: [food, fuel])
    }

    /// Presses keypad keys: digits and "."
    private func typed(_ keys: String, into model: EntryFormModel) -> EntryFormModel {
        var copy = model
        for key in keys {
            if key == "." {
                copy.amount.appendDecimal()
            } else if let digit = key.wholeNumberValue {
                copy.amount.appendDigit(digit)
            }
        }
        return copy
    }

    func testInitialState() {
        let m = EntryFormModel(snapshot: base())
        XCTAssertEqual(m.mode, .expense)
        XCTAssertEqual(m.fromWalletID, cash.id)
        XCTAssertEqual(m.toWalletID, bank.id)
        XCTAssertTrue(m.amount.isEmpty)
        XCTAssertNil(m.date)
        XCTAssertNil(m.categoryID)
        XCTAssertEqual(m.currencyCode, "INR")
        XCTAssertFalse(m.currencySymbol.isEmpty)
        XCTAssertEqual(m.validate(now: now), .blocked(.amountMissing))
    }

    func testNoWalletIsBlocked() {
        var m = EntryFormModel(snapshot: EntrySnapshot(wallets: [], categories: []))
        XCTAssertNil(m.fromWallet)
        XCTAssertEqual(m.validate(now: now), .blocked(.noWallet))
        XCTAssertNil(m.contextLine)
        XCTAssertEqual(m.buttonTitle, "Save Expense")
        m.setMode(.transfer)
        XCTAssertEqual(m.validate(now: now), .blocked(.noWallet))
    }

    func testModeFlagsAndLabels() {
        var m = EntryFormModel(snapshot: base())
        XCTAssertTrue(m.showsCategory)
        XCTAssertTrue(m.categoryIsRequired)
        XCTAssertFalse(m.showsDestination)
        XCTAssertEqual(m.mode.walletLabel, "Paid from")
        m.setMode(.income)
        XCTAssertTrue(m.showsCategory)
        XCTAssertFalse(m.categoryIsRequired)
        XCTAssertEqual(m.mode.walletLabel, "Deposit to")
        m.setMode(.transfer)
        XCTAssertFalse(m.showsCategory)
        XCTAssertTrue(m.showsDestination)
        XCTAssertEqual(m.mode.walletLabel, "From")
        XCTAssertEqual(EntryMode.allCases.map(\.title), ["Expense", "Income", "Transfer"])
    }

    func testSwitchingModeKeepsAmountAndRemembersCategory() {
        var m = typed("12.5", into: EntryFormModel(snapshot: base()))
        m.setCategory(food.id)
        m.setMode(.income)
        XCTAssertEqual(m.categoryID, food.id)
        XCTAssertEqual(m.amount.text, "12.5")
        m.setMode(.transfer)
        XCTAssertEqual(m.categoryID, food.id)
        XCTAssertNil(m.effectiveCategoryID)
        XCTAssertEqual(m.amount.text, "12.5")
        m.setMode(.expense)
        XCTAssertEqual(m.categoryID, food.id)
        XCTAssertEqual(m.effectiveCategoryID, food.id)
        XCTAssertEqual(m.amount.text, "12.5")
    }

    func testCategoryRules() {
        var m = EntryFormModel(snapshot: base())
        m.setCategory(UUID())
        XCTAssertNil(m.categoryID)
        m.setCategory(food.id)
        XCTAssertEqual(m.category?.name, "Food")
        m.setCategory(nil)
        XCTAssertNil(m.categoryID)
        m.setMode(.transfer)
        m.setCategory(food.id)
        XCTAssertNil(m.categoryID)
    }

    func testDestinationDefaultsAndRepicks() {
        let snap = EntrySnapshot(wallets: [cash, bank, usd, savings], categories: [food])
        var m = EntryFormModel(snapshot: snap)
        XCTAssertEqual(m.destinationOptions.map(\.id), [bank.id, savings.id])
        XCTAssertEqual(m.toWalletID, bank.id)
        m.setToWallet(usd.id)
        XCTAssertEqual(m.toWalletID, bank.id)
        m.setToWallet(savings.id)
        XCTAssertEqual(m.toWalletID, savings.id)
        m.setToWallet(cash.id)
        XCTAssertEqual(m.toWalletID, savings.id)
        m.setFromWallet(savings.id)
        XCTAssertEqual(m.toWalletID, cash.id)
        XCTAssertEqual(m.destinationOptions.map(\.id), [cash.id, bank.id])
    }

    func testSourceInAnotherCurrencyClearsAmountAndFiltersDestinations() {
        var m = typed("5", into: EntryFormModel(snapshot: base()))
        XCTAssertFalse(m.amount.isEmpty)
        m.setFromWallet(usd.id)
        XCTAssertEqual(m.currencyCode, "USD")
        XCTAssertEqual(m.amount.currencyCode, "USD")
        XCTAssertTrue(m.amount.isEmpty)
        XCTAssertTrue(m.destinationOptions.isEmpty)
        XCTAssertNil(m.toWalletID)
        XCTAssertEqual(m.transferAvailability, .noWalletInSameCurrency("USD"))
    }

    func testTransferNeedsASecondWallet() {
        var m = EntryFormModel(snapshot: EntrySnapshot(wallets: [cash], categories: [food]))
        XCTAssertEqual(m.transferAvailability, .needsSecondWallet)
        m.setMode(.transfer)
        m = typed("5", into: m)
        XCTAssertNil(m.toWalletID)
        XCTAssertEqual(m.validate(now: now), .blocked(.needsSecondWallet))
    }

    func testValidationOrder() {
        var m = EntryFormModel(snapshot: base())
        XCTAssertEqual(m.validate(now: now), .blocked(.amountMissing))
        m = typed("5", into: m)
        XCTAssertEqual(m.validate(now: now), .blocked(.categoryRequired))
        m.setCategory(food.id)
        XCTAssertEqual(m.validate(now: now), .ready)

        // Transfer: funds are checked before the note, and the note before the date.
        var t = EntryFormModel(snapshot: base())
        t.setMode(.transfer)
        t = typed("600", into: t)
        t.note = String(repeating: "a", count: Transaction.maxNoteLength + 1)
        t.date = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(t.validate(now: now), .blocked(.insufficientFunds(
            availableMinor: 50_000, currencyCode: "INR", walletName: "Cash")))
        t.amount.clear()
        t = typed("100", into: t)
        XCTAssertEqual(t.validate(now: now), .blocked(.noteTooLong))
        t.note = "ok"
        XCTAssertEqual(t.validate(now: now), .blocked(.dateOutOfRange))
        t.date = nil
        XCTAssertEqual(t.validate(now: now), .ready)
    }

    func testExpensesAndIncomeMayExceedTheBalance() {
        var expense = typed("600", into: EntryFormModel(snapshot: base()))
        expense.setCategory(food.id)
        XCTAssertEqual(expense.validate(now: now), .ready)

        var income = EntryFormModel(snapshot: base())
        income.setMode(.income)
        income = typed("99999", into: income)
        XCTAssertEqual(income.validate(now: now), .ready)
    }

    func testTransferFundsBoundary() {
        var m = EntryFormModel(snapshot: base())
        m.setMode(.transfer)
        XCTAssertEqual(typed("500", into: m).validate(now: now), .ready)
        XCTAssertEqual(typed("500.01", into: m).validate(now: now), .blocked(.insufficientFunds(
            availableMinor: 50_000, currencyCode: "INR", walletName: "Cash")))

        var empty = EntryFormModel(snapshot: EntrySnapshot(wallets: [savings, cash], categories: []))
        empty.setMode(.transfer)
        XCTAssertEqual(typed("0.01", into: empty).validate(now: now), .blocked(.insufficientFunds(
            availableMinor: 0, currencyCode: "INR", walletName: "Savings")))

        let overdrawn = EntryWallet(id: fixedID(5), name: "Overdrawn", emoji: "💳",
                                    currencyCode: "INR", balanceMinor: -1_000)
        var negative = EntryFormModel(snapshot: EntrySnapshot(wallets: [overdrawn, cash], categories: []))
        negative.setMode(.transfer)
        XCTAssertEqual(typed("0.01", into: negative).validate(now: now), .blocked(.insufficientFunds(
            availableMinor: -1_000, currencyCode: "INR", walletName: "Overdrawn")))
    }

    func testButtonTitles() {
        var m = EntryFormModel(snapshot: base())
        XCTAssertEqual(m.buttonTitle, "Save Expense")
        m.setMode(.income)
        XCTAssertEqual(m.buttonTitle, "Save Income")
        m.setMode(.transfer)
        XCTAssertEqual(m.buttonTitle, "Transfer")
        m = typed("800", into: m)
        let formatted = Money(minorUnits: 80_000, currencyCode: "INR").formatted()
        XCTAssertEqual(m.buttonTitle, "Transfer \(formatted)")
    }

    func testContextLine() {
        var m = EntryFormModel(snapshot: base())
        let formatted = Money(minorUnits: 50_000, currencyCode: "INR").formatted()
        XCTAssertEqual(m.contextLine, "Cash balance: \(formatted)")
        m.setMode(.transfer)
        XCTAssertEqual(m.contextLine, "\(formatted) available in Cash")
        var zero = EntryFormModel(snapshot: EntrySnapshot(wallets: [savings, cash], categories: []))
        zero.setMode(.transfer)
        XCTAssertEqual(zero.contextLine, "No money available in Savings")
    }

    func testNoteAndDateLimits() {
        var m = typed("5", into: EntryFormModel(snapshot: base()))
        m.setCategory(food.id)
        m.note = String(repeating: "a", count: Transaction.maxNoteLength)
        XCTAssertEqual(m.validate(now: now), .ready)
        m.note = "  " + String(repeating: "a", count: Transaction.maxNoteLength) + "  "
        XCTAssertEqual(m.validate(now: now), .ready)
        m.note = String(repeating: "a", count: Transaction.maxNoteLength + 1)
        XCTAssertEqual(m.validate(now: now), .blocked(.noteTooLong))
        m.note = ""

        m.date = Date(timeIntervalSince1970: 946_684_799)
        XCTAssertEqual(m.validate(now: now), .blocked(.dateOutOfRange))
        m.date = now.addingTimeInterval(TransactionService.futureTolerance + 1)
        XCTAssertEqual(m.validate(now: now), .blocked(.dateOutOfRange))
        m.date = now.addingTimeInterval(TransactionService.futureTolerance)
        XCTAssertEqual(m.validate(now: now), .ready)
        m.date = TransactionService.earliestDate
        XCTAssertEqual(m.validate(now: now), .ready)
    }

    func testApplySnapshotRepairsSelectionsAndRefreshesBalances() {
        var m = EntryFormModel(snapshot: base())
        m.setFromWallet(bank.id)
        m.setCategory(fuel.id)
        m.apply(snapshot: EntrySnapshot(wallets: [cash, usd], categories: [food]))
        XCTAssertEqual(m.fromWalletID, cash.id)
        XCTAssertNil(m.categoryID)
        XCTAssertNil(m.toWalletID)

        var poorCash = cash
        poorCash.balanceMinor = 100
        m.setMode(.transfer)
        m.apply(snapshot: EntrySnapshot(wallets: [poorCash, bank], categories: [food]))
        XCTAssertEqual(m.toWalletID, bank.id)
        m = typed("5", into: m)
        XCTAssertEqual(m.validate(now: now), .blocked(.insufficientFunds(
            availableMinor: 100, currencyCode: "INR", walletName: "Cash")))
    }

    func testResetAfterSaveKeepsModeAndWallets() {
        var m = typed("12.5", into: EntryFormModel(snapshot: base()))
        m.setMode(.income)
        m.setFromWallet(bank.id)
        m.setCategory(fuel.id)
        m.note = "salary"
        m.date = now
        let oldID = m.submissionID
        m.resetAfterSave()
        XCTAssertTrue(m.amount.isEmpty)
        XCTAssertEqual(m.note, "")
        XCTAssertEqual(m.categoryID, fuel.id)
        XCTAssertNil(m.date)
        XCTAssertNotEqual(m.submissionID, oldID)
        XCTAssertEqual(m.mode, .income)
        XCTAssertEqual(m.fromWalletID, bank.id)
    }

    func testNoteIsClampedByTheModel() {
        var m = EntryFormModel(snapshot: base())
        m.setNote(String(repeating: "a", count: Transaction.maxNoteLength + 100))
        XCTAssertEqual(m.note.count, Transaction.maxNoteLength)
        m.setNote("short")
        XCTAssertEqual(m.note, "short")
    }

    func testTransferNeverCarriesARememberedCategory() {
        var m = EntryFormModel(snapshot: base())
        m.setCategory(fuel.id)
        XCTAssertEqual(m.effectiveCategoryID, fuel.id)
        m.setMode(.transfer)
        XCTAssertNil(m.effectiveCategoryID)
        XCTAssertEqual(m.categoryID, fuel.id)
        m.apply(snapshot: EntrySnapshot(wallets: [cash, bank], categories: [food]))
        XCTAssertNil(m.categoryID)
        XCTAssertNil(m.effectiveCategoryID)
    }

    func testIssueMessages() {
        let issues: [EntryIssue] = [
            .noWallet, .amountMissing, .categoryRequired, .needsSecondWallet,
            .noWalletInSameCurrency("USD"),
            .insufficientFunds(availableMinor: 50_000, currencyCode: "INR", walletName: "Cash"),
            .insufficientFunds(availableMinor: 0, currencyCode: "INR", walletName: "Cash"),
            .noteTooLong, .dateOutOfRange
        ]
        for issue in issues { XCTAssertFalse(issue.message.isEmpty) }

        let some = EntryIssue.insufficientFunds(
            availableMinor: 50_000, currencyCode: "INR", walletName: "Cash").message
        XCTAssertTrue(some.contains("Cash"))
        XCTAssertTrue(some.contains(Money(minorUnits: 50_000, currencyCode: "INR").formatted()))
        let none = EntryIssue.insufficientFunds(
            availableMinor: -5, currencyCode: "INR", walletName: "Cash").message
        XCTAssertTrue(none.contains("no money"))
        XCTAssertTrue(EntryIssue.noWalletInSameCurrency("USD").message.contains("USD"))
    }
}
