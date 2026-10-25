// ExpenseTrackerTests/EntrySnapshotLoadTests.swift  (new file)
import XCTest
import SwiftData
@testable import ExpenseTracker

@MainActor
final class EntrySnapshotLoadTests: XCTestCase {
    private struct Env {
        let container: ModelContainer   // keeps the in-memory store alive
        let context: ModelContext
        let cash: Wallet      // INR 50_000
        let bank: Wallet      // INR 20_000
        let usd: Wallet       // USD 10_000
        let savings: Wallet   // INR 0
    }

    private func makeEnv() throws -> Env {
        let container = try AppDataStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let service = WalletService(context: context)
        let cash = try service.create(WalletInput(name: "Cash", openingBalanceMinor: 50_000))
        let bank = try service.create(WalletInput(name: "Bank", openingBalanceMinor: 20_000))
        let usd = try service.create(WalletInput(name: "Dollars", openingBalanceMinor: 10_000, currencyCode: "USD"))
        let savings = try service.create(WalletInput(name: "Savings", openingBalanceMinor: 0))
        for (index, wallet) in [cash, bank, usd, savings].enumerated() {
            wallet.createdAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60)
        }
        try context.save()
        return Env(container: container, context: context, cash: cash, bank: bank, usd: usd, savings: savings)
    }

    /// +5_000 income and -2_000 expense on Cash, then a 10_000 transfer Cash -> Bank.
    private func addLedger(_ env: Env) throws {
        env.context.insert(Transaction(amountMinor: 5_000, kind: .income, walletID: env.cash.id))
        env.context.insert(Transaction(amountMinor: 2_000, kind: .expense, walletID: env.cash.id))
        try env.context.save()
        try TransferService(context: env.context).save(
            TransferDraft(fromWalletID: env.cash.id, toWalletID: env.bank.id, amountMinor: 10_000))
    }

    func testLoadsActiveWalletsOldestFirstWithCurrentBalances() throws {
        let env = try makeEnv()
        let snapshot = try EntrySnapshot.load(from: env.context)
        XCTAssertEqual(snapshot.wallets.map(\.name), ["Cash", "Bank", "Dollars", "Savings"])
        XCTAssertEqual(snapshot.wallets.map(\.balanceMinor), [50_000, 20_000, 10_000, 0])
        XCTAssertEqual(snapshot.wallets.map(\.currencyCode), ["INR", "INR", "USD", "INR"])
        XCTAssertEqual(snapshot.wallets.map(\.id), [env.cash.id, env.bank.id, env.usd.id, env.savings.id])
    }

    func testCategoriesAreActiveOnlyAndSortedByName() throws {
        let env = try makeEnv()
        env.context.insert(ExpenseTracker.Category(name: "Fuel", emoji: "⛽", colorHex: "#FBBF24"))
        env.context.insert(ExpenseTracker.Category(name: "Food", emoji: "🍔", colorHex: "#F97316"))
        env.context.insert(ExpenseTracker.Category(name: "Old", isArchived: true))
        try env.context.save()
        let snapshot = try EntrySnapshot.load(from: env.context)
        XCTAssertEqual(snapshot.categories.map(\.name), ["Food", "Fuel"])
        XCTAssertEqual(snapshot.categories.map(\.emoji), ["🍔", "⛽"])
        XCTAssertEqual(snapshot.categories.map(\.colorHex), ["#F97316", "#FBBF24"])
    }

    func testBalancesIncludeIncomeExpensesAndTransferLegs() throws {
        let env = try makeEnv()
        try addLedger(env)
        let snapshot = try EntrySnapshot.load(from: env.context)
        let byName = Dictionary(uniqueKeysWithValues: snapshot.wallets.map { ($0.name, $0.balanceMinor) })
        XCTAssertEqual(byName["Cash"], 43_000)   // 50_000 + 5_000 - 2_000 - 10_000
        XCTAssertEqual(byName["Bank"], 30_000)   // 20_000 + 10_000
        XCTAssertEqual(byName["Dollars"], 10_000)
        XCTAssertEqual(byName["Savings"], 0)
    }

    func testDestinationOptionsMatchTransferServiceForEveryWallet() throws {
        let env = try makeEnv()
        try WalletService(context: env.context).archive(env.savings)
        let snapshot = try EntrySnapshot.load(from: env.context)
        XCTAssertEqual(snapshot.wallets.count, 3)
        let transfers = TransferService(context: env.context)
        for wallet in snapshot.wallets {
            var model = EntryFormModel(snapshot: snapshot)
            model.setFromWallet(wallet.id)
            let expected = try transfers.eligibleDestinations(forSource: wallet.id).map(\.id)
            XCTAssertEqual(model.destinationOptions.map(\.id), expected, wallet.name)
        }
    }

    func testAvailableBalancesMatchTransferService() throws {
        let env = try makeEnv()
        try addLedger(env)
        let snapshot = try EntrySnapshot.load(from: env.context)
        let transfers = TransferService(context: env.context)
        for wallet in snapshot.wallets {
            XCTAssertEqual(wallet.balanceMinor, try transfers.availableBalance(walletID: wallet.id), wallet.name)
        }
    }

    func testEmptyStoreGivesAnEmptySnapshotAndABlockedForm() throws {
        let container = try AppDataStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let snapshot = try EntrySnapshot.load(from: context)
        XCTAssertTrue(snapshot.wallets.isEmpty)
        XCTAssertTrue(snapshot.categories.isEmpty)
        let model = EntryFormModel(snapshot: snapshot)
        XCTAssertEqual(model.validate(), .blocked(.noWallet))
        _ = container
    }

    func testArchivingAWalletRemovesItAfterReload() throws {
        let env = try makeEnv()
        var model = EntryFormModel(snapshot: try EntrySnapshot.load(from: env.context))
        model.setFromWallet(env.bank.id)
        XCTAssertEqual(model.fromWalletID, env.bank.id)

        try WalletService(context: env.context).archive(env.bank)
        let reloaded = try EntrySnapshot.load(from: env.context)
        XCTAssertFalse(reloaded.wallets.contains { $0.id == env.bank.id })
        model.apply(snapshot: reloaded)
        XCTAssertEqual(model.fromWalletID, env.cash.id)
        XCTAssertNotEqual(model.toWalletID, env.bank.id)
    }

    func testUnknownKindFailsInsteadOfShowingAWrongBalance() throws {
        let env = try makeEnv()
        let odd = Transaction(amountMinor: 100, kind: .expense, walletID: env.cash.id)
        odd.kindRaw = "futureKind"
        env.context.insert(odd)
        try env.context.save()
        XCTAssertThrowsError(try EntrySnapshot.load(from: env.context)) {
            XCTAssertEqual($0 as? BalanceError, .unknownKind)
        }
    }
}
