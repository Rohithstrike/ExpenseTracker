// ExpenseTrackerTests/EntryFormSubmitTests.swift  (new file)
import XCTest
import SwiftData
@testable import ExpenseTracker

@MainActor
final class EntryFormSubmitTests: XCTestCase {
    private struct InjectedFailure: Error {}
    private final class Calls { var transactions = 0; var transfers = 0 }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Env {
        let container: ModelContainer   // keeps the in-memory store alive
        let context: ModelContext
        let cash: Wallet                // INR 100_000
        let bank: Wallet                // INR 50_000
        let food: ExpenseTracker.Category
        var submitter: EntryFormSubmit { EntryFormSubmit(context: context) }
    }

    private func makeEnv() throws -> Env {
        let container = try AppDataStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let ws = WalletService(context: context)
        let cash = try ws.create(WalletInput(name: "Cash", openingBalanceMinor: 100_000))
        let bank = try ws.create(WalletInput(name: "Bank", openingBalanceMinor: 50_000))
        let food = ExpenseTracker.Category(name: "Food")
        context.insert(food)
        try context.save()
        return Env(container: container, context: context, cash: cash, bank: bank, food: food)
    }

    private func makeModel(_ env: Env) throws -> EntryFormModel {
        EntryFormModel(snapshot: try EntrySnapshot.load(from: env.context))
    }

    private func typed(_ model: inout EntryFormModel, _ text: String) {
        for ch in text {
            if ch == "." { model.amount.appendDecimal() }
            else if let d = ch.wholeNumberValue { model.amount.appendDigit(d) }
        }
    }

    private func expenseModel(_ env: Env, amount: String = "25") throws -> EntryFormModel {
        var model = try makeModel(env)
        model.setCategory(env.food.id)
        typed(&model, amount)
        return model
    }

    private func transferModel(_ env: Env, amount: String = "100") throws -> EntryFormModel {
        var model = try makeModel(env)
        model.setMode(.transfer)
        typed(&model, amount)
        return model
    }

    private func all(_ env: Env) throws -> [Transaction] {
        try env.context.fetch(FetchDescriptor<Transaction>())
    }

    private func balance(_ model: EntryFormModel, _ wallet: Wallet) -> Int64? {
        model.snapshot.wallets.first { $0.id == wallet.id }?.balanceMinor
    }

    private func stub(
        _ snapshot: EntrySnapshot,
        tx: @escaping (TransactionDraft, Date) throws -> SaveResult = { _, _ in .saved },
        tr: @escaping (TransferDraft, Date) throws -> SaveResult = { _, _ in .saved },
        load: (() throws -> EntrySnapshot)? = nil
    ) -> EntryFormSubmit {
        EntryFormSubmit(saveTransaction: tx, saveTransfer: tr, loadSnapshot: load ?? { snapshot })
    }

    // MARK: Successful saves against a real store

    func testExpenseIsSavedAndFormResets() throws {
        let env = try makeEnv()
        var model = try expenseModel(env)
        model.setNote("lunch")
        let oldID = model.submissionID

        XCTAssertEqual(env.submitter.submit(&model, now: now), .saved)

        let rows = try all(env)
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.id, oldID)
        XCTAssertEqual(row.kind, .expense)
        XCTAssertEqual(row.amountMinor, 2_500)
        XCTAssertEqual(row.categoryID, env.food.id)
        XCTAssertEqual(row.walletID, env.cash.id)
        XCTAssertEqual(row.note, "lunch")
        XCTAssertEqual(row.timestamp, now)

        XCTAssertTrue(model.amount.isEmpty)
        XCTAssertEqual(model.note, "")
        XCTAssertNil(model.date)
        XCTAssertNotEqual(model.submissionID, oldID)
        XCTAssertEqual(model.mode, .expense)
        XCTAssertEqual(model.fromWalletID, env.cash.id)
        XCTAssertEqual(model.categoryID, env.food.id)
        XCTAssertEqual(balance(model, env.cash), 97_500)
    }

    func testIncomeWithoutCategoryIsSaved() throws {
        let env = try makeEnv()
        var model = try makeModel(env)
        model.setMode(.income)
        typed(&model, "10")

        XCTAssertEqual(env.submitter.submit(&model, now: now), .saved)

        let row = try XCTUnwrap(try all(env).first)
        XCTAssertEqual(row.kind, .income)
        XCTAssertEqual(row.amountMinor, 1_000)
        XCTAssertNil(row.categoryID)
        XCTAssertEqual(balance(model, env.cash), 101_000)
    }

    func testTransferCreatesTwoLegsAndUpdatesBalances() throws {
        let env = try makeEnv()
        var model = try transferModel(env)
        let oldID = model.submissionID
        XCTAssertEqual(model.toWalletID, env.bank.id)

        XCTAssertEqual(env.submitter.submit(&model, now: now), .saved)

        let rows = try all(env)
        XCTAssertEqual(rows.count, 2)
        let out = try XCTUnwrap(rows.first { $0.kind == .transferOut })
        let inn = try XCTUnwrap(rows.first { $0.kind == .transferIn })
        XCTAssertEqual(out.transferID, oldID)
        XCTAssertEqual(inn.transferID, oldID)
        XCTAssertEqual(out.walletID, env.cash.id)
        XCTAssertEqual(inn.walletID, env.bank.id)
        XCTAssertEqual(out.amountMinor, 10_000)
        XCTAssertEqual(inn.amountMinor, 10_000)
        XCTAssertEqual(balance(model, env.cash), 90_000)
        XCTAssertEqual(balance(model, env.bank), 60_000)
        XCTAssertEqual(model.mode, .transfer)
        XCTAssertEqual(model.toWalletID, env.bank.id)
        XCTAssertNotEqual(model.submissionID, oldID)
    }

    func testTransferNeverCarriesARememberedCategory() throws {
        let env = try makeEnv()
        var model = try makeModel(env)
        model.setCategory(env.food.id)
        model.setMode(.transfer)
        typed(&model, "100")

        XCTAssertEqual(env.submitter.submit(&model, now: now), .saved)

        let rows = try all(env)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.categoryID == nil })
        XCTAssertEqual(model.categoryID, env.food.id)   // still remembered for later
    }

    func testCustomDateReachesTheStoredRecord() throws {
        let env = try makeEnv()
        var model = try expenseModel(env)
        let chosen = now.addingTimeInterval(-3 * 86_400)
        model.setDate(chosen)

        XCTAssertEqual(env.submitter.submit(&model, now: now), .saved)
        XCTAssertEqual(try all(env).first?.timestamp, chosen)
    }

    // MARK: Blocked, failed and retried

    func testBlockedFormCallsNoService() throws {
        let env = try makeEnv()
        let calls = Calls()
        var model = try makeModel(env)   // no amount yet
        let s = stub(
            model.snapshot,
            tx: { _, _ in calls.transactions += 1; return .saved },
            tr: { _, _ in calls.transfers += 1; return .saved })

        XCTAssertEqual(s.submit(&model, now: now), .blocked(.amountMissing))
        typed(&model, "25")
        XCTAssertEqual(s.submit(&model, now: now), .blocked(.categoryRequired))
        model.setMode(.transfer)
        typed(&model, "9999")   // more than the balance
        guard case .blocked(.insufficientFunds) = s.submit(&model, now: now) else {
            return XCTFail("expected insufficient funds")
        }
        XCTAssertEqual(calls.transactions, 0)
        XCTAssertEqual(calls.transfers, 0)
    }

    func testFailureKeepsTheEntryAndSubmissionID() throws {
        let env = try makeEnv()
        var model = try expenseModel(env)
        model.setNote("keep me")
        let before = model
        let s = stub(model.snapshot, tx: { _, _ in throw InjectedFailure() })

        XCTAssertEqual(s.submit(&model, now: now), .failed(EntryFormSubmit.genericFailure))
        XCTAssertEqual(model, before)
        XCTAssertEqual(model.submissionID, before.submissionID)
    }

    func testRetryAfterFailureCreatesExactlyOneRecord() throws {
        let env = try makeEnv()
        var model = try expenseModel(env)
        let originalID = model.submissionID
        let failing = stub(model.snapshot, tx: { _, _ in throw InjectedFailure() })

        XCTAssertEqual(failing.submit(&model, now: now), .failed(EntryFormSubmit.genericFailure))
        XCTAssertEqual(try all(env).count, 0)

        XCTAssertEqual(env.submitter.submit(&model, now: now), .saved)
        let rows = try all(env)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, originalID)
    }

    func testResubmittingASavedCopyIsANoOp() throws {
        let env = try makeEnv()
        var model = try expenseModel(env)
        var copy = model   // a second tap on the same, unreset form

        XCTAssertEqual(env.submitter.submit(&model, now: now), .saved)
        XCTAssertEqual(env.submitter.submit(&copy, now: now), .saved)

        XCTAssertEqual(try all(env).count, 1)
        XCTAssertEqual(balance(copy, env.cash), 97_500)
        XCTAssertTrue(copy.amount.isEmpty)
    }

    func testResubmittingASavedTransferIsANoOp() throws {
        let env = try makeEnv()
        var model = try transferModel(env)
        var copy = model

        XCTAssertEqual(env.submitter.submit(&model, now: now), .saved)
        XCTAssertEqual(env.submitter.submit(&copy, now: now), .saved)

        XCTAssertEqual(try all(env).count, 2)
        XCTAssertEqual(balance(copy, env.cash), 90_000)
    }

    func testSubmittingAfterSuccessIsBlockedNotDuplicated() throws {
        let env = try makeEnv()
        var model = try expenseModel(env)
        XCTAssertEqual(env.submitter.submit(&model, now: now), .saved)
        XCTAssertEqual(env.submitter.submit(&model, now: now), .blocked(.amountMissing))
        XCTAssertEqual(try all(env).count, 1)
    }

    func testAlreadySavedCountsAsSuccess() throws {
        let env = try makeEnv()
        var model = try expenseModel(env)
        let oldID = model.submissionID
        let s = stub(model.snapshot, tx: { _, _ in .alreadySaved })

        XCTAssertEqual(s.submit(&model, now: now), .saved)
        XCTAssertTrue(model.amount.isEmpty)
        XCTAssertNotEqual(model.submissionID, oldID)
    }

    // MARK: Error messages

    func testTransactionErrorMessages() throws {
        let env = try makeEnv()
        let cases: [(Error, String)] = [
            (TransactionServiceError.walletNotFound, "That wallet is no longer available."),
            (TransactionServiceError.walletArchived, "That wallet is no longer available."),
            (TransactionServiceError.categoryNotFound, "That category is no longer available."),
            (TransactionServiceError.categoryArchived, "That category is no longer available."),
            (TransactionServiceError.categoryRequired, "Choose a category."),
            (TransactionServiceError.walletCurrencyMismatch, "Both wallets must use the same currency."),
            (TransactionServiceError.invalidDate, EntryIssue.dateOutOfRange.message),
            (TransactionServiceError.unsupportedKind, EntryFormSubmit.genericFailure),
            (TransactionValidationError.noteTooLong, EntryIssue.noteTooLong.message),
            (TransactionValidationError.amountTooLarge, "That amount is too large."),
            (BalanceError.overflow, "That amount would make a wallet balance too large."),
            (BalanceError.unknownKind, EntryFormSubmit.genericFailure),
            (InjectedFailure(), EntryFormSubmit.genericFailure)
        ]
        for (error, expected) in cases {
            var model = try expenseModel(env)
            let s = stub(model.snapshot, tx: { _, _ in throw error })
            XCTAssertEqual(s.submit(&model, now: now), .failed(expected), "\(error)")
        }
    }

    func testTransferErrorMessages() throws {
        let env = try makeEnv()
        let funds = EntryIssue.insufficientFunds(
            availableMinor: 500, currencyCode: "INR", walletName: "Cash").message
        let cases: [(Error, String)] = [
            (TransferServiceError.sameWallet, "Choose two different wallets."),
            (TransferServiceError.walletNotFound, "That wallet is no longer available."),
            (TransferServiceError.walletArchived, "That wallet is no longer available."),
            (TransferServiceError.currencyMismatch, "Both wallets must use the same currency."),
            (TransferServiceError.insufficientFunds(availableMinor: 500), funds),
            (TransferServiceError.invalidDate, EntryIssue.dateOutOfRange.message),
            (TransferServiceError.brokenTransfer, EntryFormSubmit.genericFailure),
            (TransactionValidationError.noteTooLong, EntryIssue.noteTooLong.message),
            (BalanceError.overflow, "That amount would make a wallet balance too large."),
            (InjectedFailure(), EntryFormSubmit.genericFailure)
        ]
        for (error, expected) in cases {
            var model = try transferModel(env)
            let s = stub(model.snapshot, tr: { _, _ in throw error })
            XCTAssertEqual(s.submit(&model, now: now), .failed(expected), "\(error)")
        }
    }

    // MARK: Stale data, real store

    func testArchivedWalletReloadsSnapshotAndKeepsEntry() throws {
        let env = try makeEnv()
        var model = try makeModel(env)
        model.setFromWallet(env.bank.id)
        model.setCategory(env.food.id)
        typed(&model, "25")
        let id = model.submissionID
        try WalletService(context: env.context).archive(env.bank)

        XCTAssertEqual(
            env.submitter.submit(&model, now: now),
            .failed("That wallet is no longer available."))

        XCTAssertEqual(model.fromWalletID, env.cash.id)
        XCTAssertEqual(model.snapshot.wallets.count, 1)
        XCTAssertEqual(model.amount.text, "25")
        XCTAssertEqual(model.submissionID, id)
        XCTAssertEqual(try all(env).count, 0)
    }

    func testArchivedCategoryReloadsSnapshotAndKeepsEntry() throws {
        let env = try makeEnv()
        var model = try expenseModel(env)
        let id = model.submissionID
        env.food.isArchived = true
        try env.context.save()

        XCTAssertEqual(
            env.submitter.submit(&model, now: now),
            .failed("That category is no longer available."))

        XCTAssertNil(model.categoryID)
        XCTAssertEqual(model.amount.text, "25")
        XCTAssertEqual(model.submissionID, id)
        XCTAssertEqual(try all(env).count, 0)
    }

    func testStaleBalanceIsCaughtByTheService() throws {
        let env = try makeEnv()
        var model = try transferModel(env, amount: "1000")   // all of Cash, per the snapshot
        let id = model.submissionID
        // Money leaves Cash after the form loaded its snapshot.
        try TransactionService(context: env.context).save(
            TransactionDraft(kind: .expense, amountMinor: 2_500,
                             walletID: env.cash.id, categoryID: env.food.id))

        let expected = EntryIssue.insufficientFunds(
            availableMinor: 97_500, currencyCode: "INR", walletName: "Cash").message
        XCTAssertEqual(env.submitter.submit(&model, now: now), .failed(expected))

        XCTAssertEqual(try all(env).count, 1)               // only the expense
        XCTAssertEqual(balance(model, env.cash), 97_500)    // snapshot refreshed
        XCTAssertEqual(model.amount.text, "1000")
        XCTAssertEqual(model.submissionID, id)
        XCTAssertEqual(model.validate(now: now).issue,
                       .insufficientFunds(availableMinor: 97_500, currencyCode: "INR", walletName: "Cash"))
    }

    func testSnapshotReloadFailureAfterSuccessStillReportsSaved() throws {
        let env = try makeEnv()
        var model = try expenseModel(env)
        let s = stub(model.snapshot, load: { throw InjectedFailure() })

        XCTAssertEqual(s.submit(&model, now: now), .saved)
        XCTAssertTrue(model.amount.isEmpty)
    }
}
