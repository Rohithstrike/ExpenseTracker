// ExpenseTrackerTests/LedgerEditingTests.swift  (new file)
import XCTest
import SwiftData
@testable import ExpenseTracker

@MainActor
final class TransactionEditingTests: XCTestCase {
    private struct Env {
        let container: ModelContainer   // keeps the in-memory store alive
        let context: ModelContext
        let cash: Wallet                // INR, opening 100_000
        let bank: Wallet                // INR, opening 50_000
        let food: ExpenseTracker.Category
        let fuel: ExpenseTracker.Category
        var service: TransactionService { TransactionService(context: context) }
        var balances: WalletBalanceService { WalletBalanceService(context: context) }
    }

    private func makeEnv() throws -> Env {
        let container = try AppDataStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let walletService = WalletService(context: context)
        let cash = try walletService.create(WalletInput(name: "Cash", openingBalanceMinor: 100_000))
        let bank = try walletService.create(WalletInput(name: "Bank", openingBalanceMinor: 50_000))
        let food = ExpenseTracker.Category(name: "Food")
        let fuel = ExpenseTracker.Category(name: "Fuel")
        context.insert(food)
        context.insert(fuel)
        try context.save()
        return Env(container: container, context: context, cash: cash, bank: bank, food: food, fuel: fuel)
    }

    /// Saves one transaction through the service and returns its id.
    private func saved(
        _ env: Env,
        kind: TransactionKind = .expense,
        amount: Int64 = 2_500,
        wallet: Wallet? = nil,
        category: ExpenseTracker.Category? = nil
    ) throws -> UUID {
        let categoryID: UUID? = kind == .expense ? (category ?? env.food).id : category?.id
        let draft = TransactionDraft(
            kind: kind, amountMinor: amount,
            walletID: (wallet ?? env.cash).id, categoryID: categoryID)
        try env.service.save(draft)
        return draft.id
    }

    private func find(_ env: Env, _ id: UUID) throws -> Transaction? {
        try env.context.fetch(FetchDescriptor<Transaction>(predicate: #Predicate { $0.id == id })).first
    }

    private func currentEdit(_ env: Env, _ id: UUID) throws -> TransactionEdit {
        let row = try XCTUnwrap(try find(env, id))
        return TransactionEdit(
            kind: try XCTUnwrap(row.kind), amountMinor: row.amountMinor, walletID: row.walletID,
            categoryID: row.categoryID, note: row.note, timestamp: row.timestamp)
    }

    private func balance(_ env: Env, _ wallet: Wallet) throws -> Int64 {
        try env.balances.balance(of: wallet).minorUnits
    }

    private func count(_ env: Env) throws -> Int {
        try env.context.fetchCount(FetchDescriptor<Transaction>())
    }

    func testEditAmountChangesBalance() throws {
        let env = try makeEnv()
        let id = try saved(env, amount: 2_500)
        XCTAssertEqual(try balance(env, env.cash), 97_500)

        var edit = try currentEdit(env, id)
        edit.amountMinor = 4_000
        try env.service.update(id: id, to: edit)
        XCTAssertEqual(try balance(env, env.cash), 96_000)
    }

    func testFlippingKindReversesEffect() throws {
        let env = try makeEnv()
        let id = try saved(env, amount: 2_500)
        var edit = try currentEdit(env, id)
        edit.kind = .income
        try env.service.update(id: id, to: edit)
        XCTAssertEqual(try balance(env, env.cash), 102_500)
    }

    func testMovingToAnotherWalletMovesTheBalance() throws {
        let env = try makeEnv()
        let id = try saved(env, amount: 2_500)
        var edit = try currentEdit(env, id)
        edit.walletID = env.bank.id
        try env.service.update(id: id, to: edit)
        XCTAssertEqual(try balance(env, env.cash), 100_000)
        XCTAssertEqual(try balance(env, env.bank), 47_500)
    }

    func testMoveToDifferentCurrencyWalletIsRejected() throws {
        let env = try makeEnv()
        let dollars = try WalletService(context: env.context)
            .create(WalletInput(name: "Dollars", currencyCode: "USD"))
        let id = try saved(env)
        var edit = try currentEdit(env, id)
        edit.walletID = dollars.id
        XCTAssertThrowsError(try env.service.update(id: id, to: edit)) {
            XCTAssertEqual($0 as? TransactionServiceError, .walletCurrencyMismatch)
        }
        XCTAssertEqual(try find(env, id)?.walletID, env.cash.id)
    }

    func testMoveToArchivedWalletIsRejected() throws {
        let env = try makeEnv()
        let id = try saved(env)
        try WalletService(context: env.context).archive(env.bank)
        var edit = try currentEdit(env, id)
        edit.walletID = env.bank.id
        XCTAssertThrowsError(try env.service.update(id: id, to: edit)) {
            XCTAssertEqual($0 as? TransactionServiceError, .walletArchived)
        }
        XCTAssertEqual(try find(env, id)?.walletID, env.cash.id)
    }

    func testHistoryInArchivedWalletCanStillBeEdited() throws {
        let env = try makeEnv()
        let id = try saved(env, amount: 2_500, wallet: env.bank)
        try WalletService(context: env.context).archive(env.bank)
        var edit = try currentEdit(env, id)
        edit.amountMinor = 1_000
        XCTAssertNoThrow(try env.service.update(id: id, to: edit))
        XCTAssertEqual(try balance(env, env.bank), 49_000)
    }

    func testCategoryRules() throws {
        let env = try makeEnv()
        let id = try saved(env, category: env.fuel)

        env.fuel.isArchived = true       // keeping an archived category is fine
        env.food.isArchived = true       // choosing an archived one is not
        try env.context.save()

        var edit = try currentEdit(env, id)
        edit.amountMinor = 3_000
        XCTAssertNoThrow(try env.service.update(id: id, to: edit))

        edit.categoryID = env.food.id
        XCTAssertThrowsError(try env.service.update(id: id, to: edit)) {
            XCTAssertEqual($0 as? TransactionServiceError, .categoryArchived)
        }
        edit.categoryID = UUID()
        XCTAssertThrowsError(try env.service.update(id: id, to: edit)) {
            XCTAssertEqual($0 as? TransactionServiceError, .categoryNotFound)
        }
        edit.categoryID = nil
        XCTAssertThrowsError(try env.service.update(id: id, to: edit)) {
            XCTAssertEqual($0 as? TransactionServiceError, .categoryRequired)
        }
        XCTAssertEqual(try find(env, id)?.categoryID, env.fuel.id)

        edit.kind = .income              // income may have no category
        XCTAssertNoThrow(try env.service.update(id: id, to: edit))
        XCTAssertNil(try find(env, id)?.categoryID)
    }

    func testInvalidAmountsAreRejectedAndNothingChanges() throws {
        let env = try makeEnv()
        let id = try saved(env, amount: 2_500)
        var edit = try currentEdit(env, id)
        edit.amountMinor = 0
        XCTAssertThrowsError(try env.service.update(id: id, to: edit)) {
            XCTAssertEqual($0 as? TransactionValidationError, .nonPositiveAmount)
        }
        for amount: Int64 in [-1, .min, Money.maxInputMinorUnits + 1] {
            edit.amountMinor = amount
            XCTAssertThrowsError(try env.service.update(id: id, to: edit), "\(amount)")
        }
        XCTAssertEqual(try find(env, id)?.amountMinor, 2_500)
    }

    func testDateRules() throws {
        let env = try makeEnv()
        let id = try saved(env)
        let now = Date()
        var edit = try currentEdit(env, id)

        edit.timestamp = Date(timeIntervalSince1970: 946_684_799)          // before 2000
        XCTAssertThrowsError(try env.service.update(id: id, to: edit, now: now)) {
            XCTAssertEqual($0 as? TransactionServiceError, .invalidDate)
        }
        edit.timestamp = now.addingTimeInterval(2 * 86_400)                // too far ahead
        XCTAssertThrowsError(try env.service.update(id: id, to: edit, now: now)) {
            XCTAssertEqual($0 as? TransactionServiceError, .invalidDate)
        }
        edit.timestamp = now.addingTimeInterval(3_600)                     // within tolerance
        XCTAssertNoThrow(try env.service.update(id: id, to: edit, now: now))

        let past = now.addingTimeInterval(-40 * 86_400)
        edit.timestamp = past
        try env.service.update(id: id, to: edit, now: now)
        XCTAssertEqual(try find(env, id)?.timestamp, past)
    }

    func testNoteIsTrimmedAndLimited() throws {
        let env = try makeEnv()
        let id = try saved(env)
        var edit = try currentEdit(env, id)
        edit.note = "  lunch  "
        try env.service.update(id: id, to: edit)
        XCTAssertEqual(try find(env, id)?.note, "lunch")

        edit.note = String(repeating: "a", count: Transaction.maxNoteLength + 1)
        XCTAssertThrowsError(try env.service.update(id: id, to: edit)) {
            XCTAssertEqual($0 as? TransactionValidationError, .noteTooLong)
        }
        XCTAssertEqual(try find(env, id)?.note, "lunch")
    }

    func testTransferLegsAndKindChangesAreRejected() throws {
        let env = try makeEnv()
        let leg = try Transaction.makeValidated(
            amountMinor: 500, kind: .transferOut, walletID: env.cash.id, transferID: UUID())
        env.context.insert(leg)
        try env.context.save()

        let edit = TransactionEdit(
            kind: .expense, amountMinor: 500, walletID: env.cash.id,
            categoryID: env.food.id, note: "", timestamp: Date())
        XCTAssertThrowsError(try env.service.update(id: leg.id, to: edit)) {
            XCTAssertEqual($0 as? TransactionServiceError, .unsupportedKind)
        }
        XCTAssertThrowsError(try env.service.delete(id: leg.id)) {
            XCTAssertEqual($0 as? TransactionServiceError, .unsupportedKind)
        }
        XCTAssertEqual(try count(env), 1)

        let id = try saved(env)
        var ordinary = try currentEdit(env, id)
        ordinary.kind = .transferIn
        XCTAssertThrowsError(try env.service.update(id: id, to: ordinary)) {
            XCTAssertEqual($0 as? TransactionServiceError, .unsupportedKind)
        }
    }

    func testUnknownTransactionIsReportedNotIgnored() throws {
        let env = try makeEnv()
        let edit = TransactionEdit(
            kind: .expense, amountMinor: 100, walletID: env.cash.id,
            categoryID: env.food.id, note: "", timestamp: Date())
        XCTAssertThrowsError(try env.service.update(id: UUID(), to: edit)) {
            XCTAssertEqual($0 as? TransactionServiceError, .transactionNotFound)
        }
        XCTAssertThrowsError(try env.service.delete(id: UUID())) {
            XCTAssertEqual($0 as? TransactionServiceError, .transactionNotFound)
        }
    }

    func testDeleteRemovesTransactionAndRestoresBalance() throws {
        let env = try makeEnv()
        let first = try saved(env, amount: 2_500)
        let second = try saved(env, kind: .income, amount: 1_000)
        XCTAssertEqual(try balance(env, env.cash), 98_500)

        try env.service.delete(id: first)
        XCTAssertEqual(try count(env), 1)
        XCTAssertNil(try find(env, first))
        XCTAssertNotNil(try find(env, second))
        XCTAssertEqual(try balance(env, env.cash), 101_000)

        XCTAssertThrowsError(try env.service.delete(id: first)) {
            XCTAssertEqual($0 as? TransactionServiceError, .transactionNotFound)
        }
    }
}

@MainActor
final class WalletBalanceServiceTests: XCTestCase {
    private func makeContext() throws -> (ModelContainer, ModelContext) {
        let container = try AppDataStore.makeContainer(inMemory: true)
        return (container, ModelContext(container))
    }

    func testEmptyWalletBalanceIsOpeningBalance() throws {
        let (container, context) = try makeContext()
        let wallet = Wallet(name: "Cash", openingBalanceMinor: 12_345, currencyCode: "INR")
        context.insert(wallet)
        try context.save()
        let money = try WalletBalanceService(context: context).balance(of: wallet)
        XCTAssertEqual(money.minorUnits, 12_345)
        XCTAssertEqual(money.currencyCode, "INR")
        _ = container
    }

    func testIgnoresOtherWalletsAndMatchesCalculator() throws {
        let (container, context) = try makeContext()
        let a = Wallet(name: "A", openingBalanceMinor: 1_000)
        let b = Wallet(name: "B", openingBalanceMinor: 5_000)
        context.insert(a)
        context.insert(b)
        context.insert(Transaction(amountMinor: 400, kind: .income, walletID: a.id))
        context.insert(Transaction(amountMinor: 100, kind: .expense, walletID: a.id))
        context.insert(Transaction(amountMinor: 50, kind: .transferOut, walletID: a.id, transferID: UUID()))
        context.insert(Transaction(amountMinor: 999, kind: .expense, walletID: b.id))
        try context.save()

        let service = WalletBalanceService(context: context)
        XCTAssertEqual(try service.balance(of: a).minorUnits, 1_250)
        let all = try context.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(
            try BalanceCalculator.balance(of: a, transactions: all).minorUnits,
            try service.balance(of: a).minorUnits)
        _ = container
    }

    func testBalancesForSeveralWallets() throws {
        let (container, context) = try makeContext()
        let a = Wallet(name: "A", openingBalanceMinor: 100)
        let b = Wallet(name: "B", openingBalanceMinor: 200)
        context.insert(a)
        context.insert(b)
        context.insert(Transaction(amountMinor: 50, kind: .income, walletID: b.id))
        try context.save()

        let result = try WalletBalanceService(context: context).balances(for: [a, b])
        XCTAssertEqual(result[a.id]?.minorUnits, 100)
        XCTAssertEqual(result[b.id]?.minorUnits, 250)
        _ = container
    }

    func testLargeLedgerIsCorrect() throws {
        let (container, context) = try makeContext()
        let wallet = Wallet(name: "Big", openingBalanceMinor: 1_000)
        context.insert(wallet)
        for i in 0..<3_000 {
            let kind: TransactionKind = i.isMultiple(of: 2) ? .income : .expense
            context.insert(Transaction(amountMinor: kind == .income ? 150 : 100, kind: kind, walletID: wallet.id))
        }
        try context.save()

        let money = try WalletBalanceService(context: context).balance(of: wallet)
        XCTAssertEqual(money.minorUnits, 76_000)   // 1_000 + 1_500*150 - 1_500*100
        _ = container
    }

    func testUnknownKindFailsInsteadOfShowingWrongTotal() throws {
        let (container, context) = try makeContext()
        let wallet = Wallet(name: "Cash", openingBalanceMinor: 1_000)
        context.insert(wallet)
        let odd = Transaction(amountMinor: 100, kind: .expense, walletID: wallet.id)
        odd.kindRaw = "futureKind"
        context.insert(odd)
        try context.save()

        XCTAssertThrowsError(try WalletBalanceService(context: context).balance(of: wallet)) {
            XCTAssertEqual($0 as? BalanceError, .unknownKind)
        }
        _ = container
    }
}
