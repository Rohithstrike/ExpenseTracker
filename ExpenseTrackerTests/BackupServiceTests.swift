import XCTest
import SwiftData
@testable import ExpenseTracker

@MainActor
final class BackupServiceTests: XCTestCase {
    private struct Env {
        let container: ModelContainer   // keeps the in-memory store alive
        let context: ModelContext
    }

    private func makeEnv() throws -> Env {
        let container = try AppDataStore.makeContainer(inMemory: true)
        return Env(container: container, context: ModelContext(container))
    }

    private func freshDefaults() throws -> UserDefaults {
        let suite = "BackupServiceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    /// 3 wallets (one archived, with a transaction), 3 categories (one archived, used),
    /// 6 transactions including one transfer whose timestamp has fractional seconds.
    @discardableResult
    private func populate(_ env: Env) throws -> UUID {
        let wallets = WalletService(context: env.context)
        let cash = try wallets.create(WalletInput(name: "Cash", openingBalanceMinor: 50_000))
        let iob = try wallets.create(WalletInput(name: "IOB", emoji: "🏦", openingBalanceMinor: 100_000))
        let old = try wallets.create(WalletInput(name: "Old", openingBalanceMinor: 7_000))

        let categories = CategoryService(context: env.context)
        let fuel = try categories.create(CategoryInput(name: "Fuel", emoji: "⛽", colorHex: "#FBBF24"))
        try categories.create(CategoryInput(name: "Food", emoji: "🍔", colorHex: "#F97316"))
        let gym = try categories.create(CategoryInput(name: "Gym", emoji: "🏋️", colorHex: "#123456"))

        let txns = TransactionService(context: env.context)
        try txns.save(TransactionDraft(kind: .expense, amountMinor: 12_345, walletID: cash.id,
                                       categoryID: fuel.id, note: "Full tank"))
        try txns.save(TransactionDraft(kind: .income, amountMinor: 60_000, walletID: cash.id, note: "Pay"))
        try txns.save(TransactionDraft(kind: .expense, amountMinor: 500, walletID: iob.id,
                                       categoryID: gym.id, note: "Gym"))
        try txns.save(TransactionDraft(kind: .income, amountMinor: 1_000, walletID: old.id, note: "Refund"))

        let transfer = TransferDraft(
            fromWalletID: iob.id, toWalletID: cash.id, amountMinor: 20_000, note: "Move",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000.123456))
        _ = try TransferService(context: env.context).save(transfer)

        try categories.archive(gym)
        try wallets.archive(old)
        return transfer.id
    }

    private func snapshot(_ context: ModelContext) throws -> [String] {
        var lines: [String] = []
        for w in try context.fetch(FetchDescriptor<Wallet>()) {
            lines.append("W|\(w.id)|\(w.name)|\(w.emoji)|\(w.openingBalanceMinor)|\(w.currencyCode)|\(w.createdAt.timeIntervalSinceReferenceDate)|\(w.isArchived)")
        }
        for c in try context.fetch(FetchDescriptor<ExpenseTracker.Category>()) {
            lines.append("C|\(c.id)|\(c.name)|\(c.emoji)|\(c.colorHex)|\(c.createdAt.timeIntervalSinceReferenceDate)|\(c.updatedAt.timeIntervalSinceReferenceDate)|\(c.isArchived)")
        }
        for t in try context.fetch(FetchDescriptor<Transaction>()) {
            lines.append("T|\(t.id)|\(t.amountMinor)|\(t.kindRaw)|\(t.timestamp.timeIntervalSinceReferenceDate)|\(t.note)|\(t.walletID)|\(String(describing: t.categoryID))|\(String(describing: t.transferID))")
        }
        return lines.sorted()
    }

    private func exportFile(_ env: Env) throws -> BackupFile {
        let data = try BackupService(context: env.context).export(appVersion: "1.0")
        return try JSONDecoder().decode(BackupFile.self, from: data)
    }

    private func encode(_ file: BackupFile) throws -> Data { try JSONEncoder().encode(file) }

    // MARK: Round trip and replace-all

    func testRoundTripIntoEmptyStoreIsIdentical() throws {
        let source = try makeEnv()
        let transferID = try populate(source)
        let data = try BackupService(context: source.context).export(appVersion: "1.0")

        let dest = try makeEnv()
        try BackupService(context: dest.context).restore(data: data, defaults: try freshDefaults())

        XCTAssertEqual(try snapshot(dest.context), try snapshot(source.context))
        XCTAssertEqual(try dest.context.fetchCount(FetchDescriptor<Wallet>()), 3)
        XCTAssertEqual(try dest.context.fetchCount(FetchDescriptor<ExpenseTracker.Category>()), 3)
        XCTAssertEqual(try dest.context.fetchCount(FetchDescriptor<Transaction>()), 6)

        XCTAssertNoThrow(try TransferService(context: dest.context).pair(transferID: transferID))
        let sourceBalances = WalletBalanceService(context: source.context)
        let destBalances = WalletBalanceService(context: dest.context)
        for wallet in try source.context.fetch(FetchDescriptor<Wallet>()) {
            let match = try XCTUnwrap(try dest.context.fetch(FetchDescriptor<Wallet>()).first { $0.id == wallet.id })
            XCTAssertEqual(try destBalances.balance(of: match).minorUnits,
                           try sourceBalances.balance(of: wallet).minorUnits)
        }
    }

    func testRestoreReplacesSeededDataAndSeederStaysQuiet() throws {
        let source = try makeEnv()
        try populate(source)
        let data = try BackupService(context: source.context).export(appVersion: "1.0")

        let dest = try makeEnv()
        let defaults = try freshDefaults()
        try DefaultDataSeeder.seedIfNeeded(context: dest.context, defaults: defaults)
        let seededIDs = Set(try dest.context.fetch(FetchDescriptor<Wallet>()).map(\.id))
            .union(try dest.context.fetch(FetchDescriptor<ExpenseTracker.Category>()).map(\.id))
        XCTAssertFalse(seededIDs.isEmpty)

        try BackupService(context: dest.context).restore(data: data, defaults: defaults)
        let restoredIDs = Set(try dest.context.fetch(FetchDescriptor<Wallet>()).map(\.id))
            .union(try dest.context.fetch(FetchDescriptor<ExpenseTracker.Category>()).map(\.id))
        XCTAssertTrue(seededIDs.isDisjoint(with: restoredIDs))
        XCTAssertEqual(try snapshot(dest.context), try snapshot(source.context))

        // Even with the flag cleared, a non-empty store is never seeded again.
        defaults.set(false, forKey: DefaultDataSeeder.seededKey)
        try DefaultDataSeeder.seedIfNeeded(context: dest.context, defaults: defaults)
        XCTAssertEqual(try snapshot(dest.context), try snapshot(source.context))
    }

    func testFailedSaveLeavesDataUnchangedAndFlagUnset() throws {
        let source = try makeEnv()
        try populate(source)
        let data = try BackupService(context: source.context).export(appVersion: "1.0")

        let dest = try makeEnv()
        let defaults = try freshDefaults()
        try DefaultDataSeeder.seedIfNeeded(context: dest.context, defaults: defaults)
        defaults.set(false, forKey: DefaultDataSeeder.seededKey)
        let before = try snapshot(dest.context)

        struct Boom: Error {}
        let failing = BackupService(context: dest.context, save: { _ in throw Boom() })
        XCTAssertThrowsError(try failing.restore(data: data, defaults: defaults)) {
            XCTAssertEqual($0 as? BackupError, .saveFailed)
        }
        XCTAssertEqual(try snapshot(dest.context), before)
        XCTAssertFalse(defaults.bool(forKey: DefaultDataSeeder.seededKey))
    }

    // MARK: Rejections

    func testRejectedFilesLeaveDataUnchanged() throws {
        let source = try makeEnv()
        try populate(source)
        let base = try exportFile(source)

        func wallet(_ f: BackupFile, _ name: String) -> Int { f.wallets.firstIndex { $0.name == name }! }
        func firstExpense(_ f: BackupFile) -> Int { f.transactions.firstIndex { $0.kindRaw == "expense" }! }
        func leg(_ f: BackupFile, _ kind: String) -> Int { f.transactions.firstIndex { $0.kindRaw == kind }! }

        let cases: [(String, (inout BackupFile) -> Void)] = [
            ("duplicate wallet id", { $0.wallets[1].id = $0.wallets[0].id }),
            ("duplicate category id", { $0.categories[1].id = $0.categories[0].id }),
            ("duplicate transaction id", { $0.transactions[1].id = $0.transactions[0].id }),
            ("no active wallet", { f in for i in f.wallets.indices { f.wallets[i].isArchived = true } }),
            ("no wallets", { $0.wallets = [] }),
            ("bad currency", { $0.wallets[0].currencyCode = "RS" }),
            ("opening balance too large", { $0.wallets[0].openingBalanceMinor = Money.maxInputMinorUnits + 1 }),
            ("blank wallet name", { $0.wallets[0].name = "  " }),
            ("bad colour", { $0.categories[0].colorHex = "red" }),
            ("missing wallet", { f in f.transactions[firstExpense(f)].walletID = UUID() }),
            ("missing category", { f in f.transactions[firstExpense(f)].categoryID = UUID() }),
            ("zero amount", { f in f.transactions[firstExpense(f)].amountMinor = 0 }),
            ("amount too large", { f in f.transactions[firstExpense(f)].amountMinor = Money.maxInputMinorUnits + 1 }),
            ("expense with transfer id", { f in f.transactions[firstExpense(f)].transferID = UUID() }),
            ("note too long", { f in f.transactions[firstExpense(f)].note = String(repeating: "a", count: 501) }),
            ("transfer missing a leg", { $0.transactions.removeAll { $0.kindRaw == "transferIn" } }),
            ("transfer time mismatch", { f in f.transactions[leg(f, "transferIn")].timestamp += 1 }),
            ("transfer same wallet", { f in f.transactions[leg(f, "transferIn")].walletID = f.transactions[leg(f, "transferOut")].walletID }),
            ("transfer with category", { f in f.transactions[leg(f, "transferOut")].categoryID = f.categories[0].id }),
            ("transfer across currencies", { f in f.wallets[wallet(f, "IOB")].currencyCode = "USD" })
        ]

        let dest = try makeEnv()
        try populate(dest)
        let before = try snapshot(dest.context)
        let defaults = try freshDefaults()

        for (name, mutate) in cases {
            var file = base
            mutate(&file)
            let data = try encode(file)
            XCTAssertThrowsError(try BackupService.decodeAndValidate(data), name) { error in
                guard case BackupError.invalid = error else { return XCTFail("\(name): \(error)") }
            }
            XCTAssertThrowsError(try BackupService(context: dest.context).restore(data: data, defaults: defaults), name)
        }
        XCTAssertEqual(try snapshot(dest.context), before)
        XCTAssertFalse(defaults.bool(forKey: DefaultDataSeeder.seededKey))
    }

    func testUnknownTransactionKindIsRejected() throws {
        let source = try makeEnv()
        try populate(source)
        var file = try exportFile(source)
        let index = try XCTUnwrap(file.transactions.firstIndex { $0.kindRaw == "expense" })
        file.transactions[index].kindRaw = "refund"
        let data = try encode(file)
        XCTAssertThrowsError(try BackupService.decodeAndValidate(data)) {
            XCTAssertEqual($0 as? BackupError, .unknownKind)
        }
    }

    func testVersionHandling() throws {
        let source = try makeEnv()
        try populate(source)
        var file = try exportFile(source)
        file.formatVersion = 2
        let newer = try encode(file)
        XCTAssertThrowsError(try BackupService.decodeAndValidate(newer)) {
            XCTAssertEqual($0 as? BackupError, .newerVersion)
        }
        file.formatVersion = 0
        let older = try encode(file)
        XCTAssertThrowsError(try BackupService.decodeAndValidate(older)) {
            XCTAssertEqual($0 as? BackupError, .unsupportedVersion)
        }
    }

    func testUnreadableFilesAreRejected() {
        for text in ["not json", "", "{}", "{\"formatVersion\":1}", "[]"] {
            XCTAssertThrowsError(try BackupService.decodeAndValidate(Data(text.utf8)), text) {
                XCTAssertEqual($0 as? BackupError, .unreadable, text)
            }
        }
    }

    // MARK: Edge cases

    func testEmptyCategoriesAndTransactionsAreValid() throws {
        let file = BackupFile(
            formatVersion: 1, appVersion: "1.0", backupID: UUID(), exportedAt: 0,
            wallets: [BackupWallet(id: UUID(), name: "Cash", emoji: "💵", openingBalanceMinor: 0,
                                   currencyCode: "INR", createdAt: 0, isArchived: false)],
            categories: [], transactions: [])
        let data = try encode(file)

        let dest = try makeEnv()
        try populate(dest)
        let defaults = try freshDefaults()
        try BackupService(context: dest.context).restore(data: data, defaults: defaults)
        XCTAssertEqual(try dest.context.fetchCount(FetchDescriptor<Wallet>()), 1)
        XCTAssertEqual(try dest.context.fetchCount(FetchDescriptor<ExpenseTracker.Category>()), 0)
        XCTAssertEqual(try dest.context.fetchCount(FetchDescriptor<Transaction>()), 0)
        XCTAssertTrue(defaults.bool(forKey: DefaultDataSeeder.seededKey))

        defaults.set(false, forKey: DefaultDataSeeder.seededKey)
        try DefaultDataSeeder.seedIfNeeded(context: dest.context, defaults: defaults)
        XCTAssertEqual(try dest.context.fetchCount(FetchDescriptor<Wallet>()), 1)
        XCTAssertEqual(try dest.context.fetchCount(FetchDescriptor<ExpenseTracker.Category>()), 0)
    }

    func testUnknownKeysAreIgnoredAndSummaryCountsAreCorrect() throws {
        let source = try makeEnv()
        try populate(source)
        let data = try BackupService(context: source.context).export(appVersion: "1.0")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["syncToken"] = "future"
        let extended = try JSONSerialization.data(withJSONObject: object)
        let checked = try BackupService.decodeAndValidate(extended)
        XCTAssertEqual(checked.summary.wallets, 3)
        XCTAssertEqual(checked.summary.categories, 3)
        XCTAssertEqual(checked.summary.transactions, 6)
        XCTAssertTrue(checked.summary.text.contains("3 wallets"))
    }
}
