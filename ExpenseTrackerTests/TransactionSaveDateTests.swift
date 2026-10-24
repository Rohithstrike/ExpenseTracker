// ExpenseTrackerTests/TransactionSaveDateTests.swift  (new file)
import XCTest
import SwiftData
@testable import ExpenseTracker

@MainActor
final class TransactionSaveDateTests: XCTestCase {
    private struct Env {
        let container: ModelContainer   // keeps the in-memory store alive
        let context: ModelContext
        let wallet: Wallet
        let category: ExpenseTracker.Category
        var service: TransactionService { TransactionService(context: context) }
    }

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeEnv() throws -> Env {
        let container = try AppDataStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let wallet = try WalletService(context: context)
            .create(WalletInput(name: "Cash", openingBalanceMinor: 100_000))
        let category = ExpenseTracker.Category(name: "Food")
        context.insert(category)
        try context.save()
        return Env(container: container, context: context, wallet: wallet, category: category)
    }

    private func draft(
        _ env: Env, kind: TransactionKind = .expense, amount: Int64 = 2_500, timestamp: Date? = nil
    ) -> TransactionDraft {
        TransactionDraft(
            kind: kind, amountMinor: amount, walletID: env.wallet.id,
            categoryID: kind == .expense ? env.category.id : nil, timestamp: timestamp)
    }

    private func stored(_ env: Env, _ id: UUID) throws -> Transaction? {
        try env.context.fetch(
            FetchDescriptor<Transaction>(predicate: #Predicate { $0.id == id })).first
    }

    private func count(_ env: Env) throws -> Int {
        try env.context.fetchCount(FetchDescriptor<Transaction>())
    }

    func testNoDateSavesNow() throws {
        let env = try makeEnv()
        let d = draft(env)
        XCTAssertEqual(try env.service.save(d, now: now), .saved)
        XCTAssertEqual(try stored(env, d.id)?.timestamp, now)
    }

    func testExplicitDateIsStoredForExpenseAndIncome() throws {
        let env = try makeEnv()
        let past = now.addingTimeInterval(-3 * 86_400)
        let expense = draft(env, timestamp: past)
        let income = draft(env, kind: .income, amount: 1_000, timestamp: past.addingTimeInterval(3_600))
        XCTAssertEqual(try env.service.save(expense, now: now), .saved)
        XCTAssertEqual(try env.service.save(income, now: now), .saved)
        XCTAssertEqual(try stored(env, expense.id)?.timestamp, past)
        XCTAssertEqual(try stored(env, income.id)?.timestamp, past.addingTimeInterval(3_600))
    }

    func testDatesOutsideTheWindowAreRejected() throws {
        let env = try makeEnv()
        let tooOld = Date(timeIntervalSince1970: 946_684_799)
        let tooLate = now.addingTimeInterval(TransactionService.futureTolerance + 1)
        for date in [tooOld, tooLate] {
            XCTAssertThrowsError(try env.service.save(draft(env, timestamp: date), now: now)) {
                XCTAssertEqual($0 as? TransactionServiceError, .invalidDate)
            }
        }
        XCTAssertEqual(try count(env), 0)
    }

    func testBoundaryDatesAreAccepted() throws {
        let env = try makeEnv()
        XCTAssertNoThrow(try env.service.save(
            draft(env, timestamp: TransactionService.earliestDate), now: now))
        XCTAssertNoThrow(try env.service.save(
            draft(env, timestamp: now.addingTimeInterval(TransactionService.futureTolerance)), now: now))
        XCTAssertEqual(try count(env), 2)
    }

    func testRejectedDateDoesNotConsumeTheDraft() throws {
        let env = try makeEnv()
        var d = draft(env, timestamp: now.addingTimeInterval(10 * 86_400))
        XCTAssertThrowsError(try env.service.save(d, now: now)) {
            XCTAssertEqual($0 as? TransactionServiceError, .invalidDate)
        }
        XCTAssertEqual(try count(env), 0)
        d.timestamp = now
        XCTAssertEqual(try env.service.save(d, now: now), .saved)
        XCTAssertEqual(try count(env), 1)
    }

    func testRepeatedDraftWithDifferentDateIsAlreadySaved() throws {
        let env = try makeEnv()
        let first = now.addingTimeInterval(-86_400)
        var d = draft(env, timestamp: first)
        XCTAssertEqual(try env.service.save(d, now: now), .saved)
        d.timestamp = now.addingTimeInterval(-2 * 86_400)
        XCTAssertEqual(try env.service.save(d, now: now), .alreadySaved)
        XCTAssertEqual(try stored(env, d.id)?.timestamp, first)
        XCTAssertEqual(try count(env), 1)
    }

    func testBalanceIgnoresTheDate() throws {
        let env = try makeEnv()
        try env.service.save(draft(env, amount: 2_500, timestamp: now.addingTimeInterval(-30 * 86_400)), now: now)
        try env.service.save(draft(env, amount: 2_500), now: now)
        let balance = try WalletBalanceService(context: env.context).balance(of: env.wallet).minorUnits
        XCTAssertEqual(balance, 95_000)
    }
}
