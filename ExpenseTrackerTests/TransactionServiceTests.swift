import XCTest
import SwiftData
@testable import ExpenseTracker

@MainActor
final class TransactionServiceTests: XCTestCase {

    private struct Env {
        let container: ModelContainer
        let context: ModelContext
        let wallet: Wallet
        let category: ExpenseTracker.Category

        var service: TransactionService {
            TransactionService(context: context)
        }
    }

    private func makeEnv(opening: Int64 = 100_000) throws -> Env {
        let container = try ModelContainer(
            for: Wallet.self,
            ExpenseTracker.Category.self,
            Transaction.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )

        let context = ModelContext(container)
        let wallet = Wallet(name: "Cash", openingBalanceMinor: opening)
        let category = ExpenseTracker.Category(name: "Food")

        context.insert(wallet)
        context.insert(category)
        try context.save()

        return Env(
            container: container,
            context: context,
            wallet: wallet,
            category: category
        )
    }

    private func count(_ env: Env) throws -> Int {
        try env.context.fetchCount(
            FetchDescriptor<Transaction>()
        )
    }

    func testExpenseIsSavedAndReducesBalance() throws {
        let env = try makeEnv()

        let draft = TransactionDraft(
            kind: .expense,
            amountMinor: 2_500,
            walletID: env.wallet.id,
            categoryID: env.category.id,
            note: "  lunch "
        )

        XCTAssertEqual(try env.service.save(draft), .saved)

        let all = try env.context.fetch(
            FetchDescriptor<Transaction>()
        )

        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].note, "lunch")

        let balance = try BalanceCalculator.balance(
            of: env.wallet,
            transactions: all
        )

        XCTAssertEqual(balance.minorUnits, 97_500)
    }

    func testIncomeWithoutCategoryIncreasesBalance() throws {
        let env = try makeEnv()

        let draft = TransactionDraft(
            kind: .income,
            amountMinor: 10_000,
            walletID: env.wallet.id
        )

        XCTAssertEqual(try env.service.save(draft), .saved)

        let all = try env.context.fetch(
            FetchDescriptor<Transaction>()
        )

        let balance = try BalanceCalculator.balance(
            of: env.wallet,
            transactions: all
        )

        XCTAssertEqual(balance.minorUnits, 110_000)
    }

    func testSavingSameDraftTwiceCreatesOneTransaction() throws {
        let env = try makeEnv()

        let draft = TransactionDraft(
            kind: .expense,
            amountMinor: 500,
            walletID: env.wallet.id,
            categoryID: env.category.id
        )

        XCTAssertEqual(try env.service.save(draft), .saved)
        XCTAssertEqual(try env.service.save(draft), .alreadySaved)
        XCTAssertEqual(try count(env), 1)
    }

    func testInvalidAmountsAreRejected() throws {
        let env = try makeEnv()

        for amount: Int64 in [
            0,
            -1,
            Money.maxInputMinorUnits + 1
        ] {
            let draft = TransactionDraft(
                kind: .expense,
                amountMinor: amount,
                walletID: env.wallet.id,
                categoryID: env.category.id
            )

            XCTAssertThrowsError(
                try env.service.save(draft),
                "amount \(amount)"
            )
        }

        XCTAssertEqual(try count(env), 0)
    }

    func testWalletRules() throws {
        let env = try makeEnv()

        let missing = TransactionDraft(
            kind: .income,
            amountMinor: 100,
            walletID: UUID()
        )

        XCTAssertThrowsError(try env.service.save(missing)) {
            XCTAssertEqual(
                $0 as? TransactionServiceError,
                .walletNotFound
            )
        }

        env.wallet.isArchived = true
        try env.context.save()

        let archived = TransactionDraft(
            kind: .income,
            amountMinor: 100,
            walletID: env.wallet.id
        )

        XCTAssertThrowsError(try env.service.save(archived)) {
            XCTAssertEqual(
                $0 as? TransactionServiceError,
                .walletArchived
            )
        }

        XCTAssertEqual(try count(env), 0)
    }

    func testCategoryRules() throws {
        let env = try makeEnv()

        let none = TransactionDraft(
            kind: .expense,
            amountMinor: 100,
            walletID: env.wallet.id
        )

        XCTAssertThrowsError(try env.service.save(none)) {
            XCTAssertEqual(
                $0 as? TransactionServiceError,
                .categoryRequired
            )
        }

        let unknown = TransactionDraft(
            kind: .expense,
            amountMinor: 100,
            walletID: env.wallet.id,
            categoryID: UUID()
        )

        XCTAssertThrowsError(try env.service.save(unknown)) {
            XCTAssertEqual(
                $0 as? TransactionServiceError,
                .categoryNotFound
            )
        }

        env.category.isArchived = true
        try env.context.save()

        let archived = TransactionDraft(
            kind: .expense,
            amountMinor: 100,
            walletID: env.wallet.id,
            categoryID: env.category.id
        )

        XCTAssertThrowsError(try env.service.save(archived)) {
            XCTAssertEqual(
                $0 as? TransactionServiceError,
                .categoryArchived
            )
        }

        XCTAssertEqual(try count(env), 0)
    }

    func testTransferKindsAreNotAcceptedHere() throws {
        let env = try makeEnv()

        let draft = TransactionDraft(
            kind: .transferOut,
            amountMinor: 100,
            walletID: env.wallet.id
        )

        XCTAssertThrowsError(try env.service.save(draft)) {
            XCTAssertEqual(
                $0 as? TransactionServiceError,
                .unsupportedKind
            )
        }
    }

    func testOverlongNoteIsRejected() throws {
        let env = try makeEnv()

        let draft = TransactionDraft(
            kind: .income,
            amountMinor: 100,
            walletID: env.wallet.id,
            note: String(
                repeating: "a",
                count: Transaction.maxNoteLength + 1
            )
        )

        XCTAssertThrowsError(try env.service.save(draft)) {
            XCTAssertEqual(
                $0 as? TransactionValidationError,
                .noteTooLong
            )
        }

        XCTAssertEqual(try count(env), 0)
    }
}

@MainActor
final class DefaultDataSeederTests: XCTestCase {

    private func makeContext() throws -> (
        ModelContainer,
        ModelContext
    ) {
        let container = try ModelContainer(
            for: Wallet.self,
            ExpenseTracker.Category.self,
            Transaction.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )

        return (container, ModelContext(container))
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(
            suiteName: "seeder-test-\(UUID().uuidString)"
        )!
    }

    func testSeedsOnlyOnce() throws {
        let (container, context) = try makeContext()
        let defaults = freshDefaults()

        try DefaultDataSeeder.seedIfNeeded(
            context: context,
            defaults: defaults
        )

        try DefaultDataSeeder.seedIfNeeded(
            context: context,
            defaults: defaults
        )

        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<Wallet>()),
            1
        )

        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<ExpenseTracker.Category>()
            ),
            6
        )

        _ = container
    }

    func testDoesNotSeedWhenDataAlreadyExists() throws {
        let (container, context) = try makeContext()
        let defaults = freshDefaults()

        context.insert(Wallet(name: "Bank 1"))
        try context.save()

        try DefaultDataSeeder.seedIfNeeded(
            context: context,
            defaults: defaults
        )

        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<Wallet>()),
            1
        )

        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<ExpenseTracker.Category>()
            ),
            0
        )

        XCTAssertTrue(
            defaults.bool(forKey: DefaultDataSeeder.seededKey)
        )

        _ = container
    }

    func testDoesNotReseedAfterUserDeletesDefaults() throws {
        let (container, context) = try makeContext()
        let defaults = freshDefaults()

        try DefaultDataSeeder.seedIfNeeded(
            context: context,
            defaults: defaults
        )

        for wallet in try context.fetch(
            FetchDescriptor<Wallet>()
        ) {
            context.delete(wallet)
        }

        try context.save()

        try DefaultDataSeeder.seedIfNeeded(
            context: context,
            defaults: defaults
        )

        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<Wallet>()),
            0
        )

        _ = container
    }
}

