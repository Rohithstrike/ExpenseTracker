// ExpenseTrackerTests/MigrationSafetyTests.swift  (new file)
import XCTest
import SwiftData
@testable import ExpenseTracker

/// FROZEN copy of the stored shape of the 1.0 baseline. Never edit these classes when
/// the real models change. Staying old is the whole point of this file.
enum LegacySnapshotV1 {
    @Model
    final class Wallet {
        var id: UUID = UUID()
        var name: String = ""
        var emoji: String = "👛"
        var openingBalanceMinor: Int64 = 0
        var currencyCode: String = "INR"
        var createdAt: Date = Date()
        var isArchived: Bool = false

        init(id: UUID, name: String, emoji: String, openingBalanceMinor: Int64,
             currencyCode: String, createdAt: Date, isArchived: Bool) {
            self.id = id
            self.name = name
            self.emoji = emoji
            self.openingBalanceMinor = openingBalanceMinor
            self.currencyCode = currencyCode
            self.createdAt = createdAt
            self.isArchived = isArchived
        }
    }

    @Model
    final class Category {
        var id: UUID = UUID()
        var name: String = ""
        var emoji: String = "🏷️"
        var colorHex: String = "#00E5FF"
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var isArchived: Bool = false

        init(id: UUID, name: String, emoji: String, colorHex: String,
             createdAt: Date, updatedAt: Date, isArchived: Bool) {
            self.id = id
            self.name = name
            self.emoji = emoji
            self.colorHex = colorHex
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.isArchived = isArchived
        }
    }

    @Model
    final class Transaction {
        var id: UUID = UUID()
        var amountMinor: Int64 = 0
        var kindRaw: String = "expense"
        var timestamp: Date = Date()
        var note: String = ""
        var walletID: UUID = UUID()
        var categoryID: UUID?
        var transferID: UUID?

        init(id: UUID, amountMinor: Int64, kindRaw: String, timestamp: Date, note: String,
             walletID: UUID, categoryID: UUID?, transferID: UUID?) {
            self.id = id
            self.amountMinor = amountMinor
            self.kindRaw = kindRaw
            self.timestamp = timestamp
            self.note = note
            self.walletID = walletID
            self.categoryID = categoryID
            self.transferID = transferID
        }
    }
}

// MARK: - Fixture data (one source of truth for writing and checking)

private func fixedID(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
}

private enum Fixture {
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    static let cash = fixedID(1)
    static let bank = fixedID(2)
    static let dollars = fixedID(3)
    static let food = fixedID(101)
    static let fuel = fixedID(102)
    static let family = fixedID(103)
    static let transfer = fixedID(201)

    struct WalletData {
        let id: UUID; let name: String; let emoji: String
        let opening: Int64; let currency: String; let archived: Bool
    }
    struct CategoryData {
        let id: UUID; let name: String; let emoji: String; let color: String; let archived: Bool
    }
    struct TransactionData {
        let id: UUID; let amount: Int64; let kind: String; let offset: TimeInterval
        let note: String; let wallet: UUID; let category: UUID?; let transfer: UUID?
        var timestamp: Date { t0.addingTimeInterval(offset) }
    }

    static let wallets: [WalletData] = [
        WalletData(id: cash, name: "Cash", emoji: "💵", opening: 100_000, currency: "INR", archived: false),
        WalletData(id: bank, name: "Bank", emoji: "🏦", opening: -2_500, currency: "INR", archived: true),
        WalletData(id: dollars, name: "Dollars", emoji: "💳", opening: 50_000, currency: "USD", archived: false)
    ]

    static let categories: [CategoryData] = [
        CategoryData(id: food, name: "Food", emoji: "🍔", color: "#F97316", archived: false),
        CategoryData(id: fuel, name: "Fuel", emoji: "⛽", color: "#FBBF24", archived: false),
        CategoryData(id: family, name: "खाना", emoji: "👨‍👩‍👧", color: "#34D399", archived: true)
    ]

    static let transactions: [TransactionData] = [
        TransactionData(id: fixedID(1001), amount: 2_500, kind: "expense", offset: 100,
                        note: "lunch", wallet: cash, category: food, transfer: nil),
        TransactionData(id: fixedID(1002), amount: 10_000, kind: "income", offset: 200,
                        note: "", wallet: cash, category: nil, transfer: nil),
        TransactionData(id: fixedID(1003), amount: 99_999_999_999, kind: "expense", offset: 250,
                        note: "😀 café 日本", wallet: dollars, category: fuel, transfer: nil),
        TransactionData(id: fixedID(1004), amount: 30_000, kind: "transferOut", offset: 300,
                        note: "to bank", wallet: cash, category: nil, transfer: transfer),
        TransactionData(id: fixedID(1005), amount: 30_000, kind: "transferIn", offset: 300,
                        note: "to bank", wallet: bank, category: nil, transfer: transfer),
        TransactionData(id: fixedID(1006), amount: 500, kind: "expense", offset: 400,
                        note: "", wallet: bank, category: family, transfer: nil)
    ]

    static let expectedBalances: [UUID: Int64] = [
        cash: 77_500,                 // 100_000 - 2_500 + 10_000 - 30_000
        bank: 27_000,                 // -2_500 + 30_000 - 500
        dollars: -99_999_949_999      // 50_000 - 99_999_999_999
    ]
}

/// Writes a store using ONLY the frozen snapshot classes.
private func writeLegacyStore(at url: URL) throws {
    let schema = Schema([
        LegacySnapshotV1.Wallet.self,
        LegacySnapshotV1.Category.self,
        LegacySnapshotV1.Transaction.self
    ])
    let container = try ModelContainer(
        for: schema,
        configurations: ModelConfiguration(
            schema: schema, url: url,
            cloudKitDatabase: ModelConfiguration.CloudKitDatabase.none)
    )
    let context = ModelContext(container)
    for w in Fixture.wallets {
        context.insert(LegacySnapshotV1.Wallet(
            id: w.id, name: w.name, emoji: w.emoji, openingBalanceMinor: w.opening,
            currencyCode: w.currency, createdAt: Fixture.t0, isArchived: w.archived))
    }
    for c in Fixture.categories {
        context.insert(LegacySnapshotV1.Category(
            id: c.id, name: c.name, emoji: c.emoji, colorHex: c.color,
            createdAt: Fixture.t0, updatedAt: Fixture.t0, isArchived: c.archived))
    }
    for t in Fixture.transactions {
        context.insert(LegacySnapshotV1.Transaction(
            id: t.id, amountMinor: t.amount, kindRaw: t.kind, timestamp: t.timestamp,
            note: t.note, walletID: t.wallet, categoryID: t.category, transferID: t.transfer))
    }
    try context.save()
}

// MARK: - Tests

@MainActor
final class MigrationSafetyTests: XCTestCase {
    private struct Opened {
        let container: ModelContainer   // keeps the store alive
        let context: ModelContext
    }

    private func makeStoreURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MigrationSafety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("default.store")
    }

    private func open(_ url: URL) throws -> Opened {
        let container = try AppDataStore.makeContainer(storeURL: url)
        return Opened(container: container, context: ModelContext(container))
    }

    private func fingerprint(_ context: ModelContext) throws -> [String] {
        var lines: [String] = []
        for w in try context.fetch(FetchDescriptor<Wallet>()) {
            lines.append("W|\(w.id)|\(w.name)|\(w.emoji)|\(w.openingBalanceMinor)|\(w.currencyCode)|\(w.createdAt.timeIntervalSince1970)|\(w.isArchived)")
        }
        for c in try context.fetch(FetchDescriptor<ExpenseTracker.Category>()) {
            lines.append("C|\(c.id)|\(c.name)|\(c.emoji)|\(c.colorHex)|\(c.createdAt.timeIntervalSince1970)|\(c.updatedAt.timeIntervalSince1970)|\(c.isArchived)")
        }
        for t in try context.fetch(FetchDescriptor<Transaction>()) {
            lines.append("T|\(t.id)|\(t.amountMinor)|\(t.kindRaw)|\(t.timestamp.timeIntervalSince1970)|\(t.note)|\(t.walletID)|\(String(describing: t.categoryID))|\(String(describing: t.transferID))")
        }
        return lines.sorted()
    }

    func testExistingRowsSurviveOpeningWithTheAppContainer() throws {
        let url = try makeStoreURL()
        try writeLegacyStore(at: url)
        let opened = try open(url)
        let context = opened.context

        let wallets = try context.fetch(FetchDescriptor<Wallet>())
        let categories = try context.fetch(FetchDescriptor<ExpenseTracker.Category>())
        let rows = try context.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(wallets.count, Fixture.wallets.count)
        XCTAssertEqual(categories.count, Fixture.categories.count)
        XCTAssertEqual(rows.count, Fixture.transactions.count)

        for expected in Fixture.wallets {
            let w = try XCTUnwrap(wallets.first { $0.id == expected.id }, expected.name)
            XCTAssertEqual(w.name, expected.name)
            XCTAssertEqual(w.emoji, expected.emoji)
            XCTAssertEqual(w.openingBalanceMinor, expected.opening)
            XCTAssertEqual(w.currencyCode, expected.currency)
            XCTAssertEqual(w.createdAt, Fixture.t0)
            XCTAssertEqual(w.isArchived, expected.archived)
        }
        for expected in Fixture.categories {
            let c = try XCTUnwrap(categories.first { $0.id == expected.id }, expected.name)
            XCTAssertEqual(c.name, expected.name)
            XCTAssertEqual(c.emoji, expected.emoji)
            XCTAssertEqual(c.colorHex, expected.color)
            XCTAssertEqual(c.isArchived, expected.archived)
        }
        for expected in Fixture.transactions {
            let t = try XCTUnwrap(rows.first { $0.id == expected.id }, "\(expected.id)")
            XCTAssertEqual(t.amountMinor, expected.amount)
            XCTAssertEqual(t.kindRaw, expected.kind)
            XCTAssertEqual(t.timestamp, expected.timestamp)
            XCTAssertEqual(t.note, expected.note)
            XCTAssertEqual(t.walletID, expected.wallet)
            XCTAssertEqual(t.categoryID, expected.category)
            XCTAssertEqual(t.transferID, expected.transfer)
        }

        let balances = WalletBalanceService(context: context)
        for wallet in wallets {
            let expected = try XCTUnwrap(Fixture.expectedBalances[wallet.id])
            XCTAssertEqual(try balances.balance(of: wallet).minorUnits, expected, wallet.name)
        }
        _ = opened.container
    }

    func testReopeningTwiceKeepsEverythingIdentical() throws {
        let url = try makeStoreURL()
        try writeLegacyStore(at: url)

        var first: [String] = []
        do {
            let opened = try open(url)
            first = try fingerprint(opened.context)
            _ = opened.container
        }
        let opened = try open(url)
        let second = try fingerprint(opened.context)
        _ = opened.container

        XCTAssertEqual(first.count, 12)
        XCTAssertEqual(first, second)
    }

    func testStoreStaysWritableAndPersistsAfterOpening() throws {
        let url = try makeStoreURL()
        try writeLegacyStore(at: url)

        do {
            let opened = try open(url)
            let draft = TransactionDraft(
                kind: .expense, amountMinor: 1_000, walletID: Fixture.cash, categoryID: Fixture.food)
            XCTAssertEqual(try TransactionService(context: opened.context).save(draft), .saved)
            _ = opened.container
        }

        let reopened = try open(url)
        let rows = try reopened.context.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(rows.count, Fixture.transactions.count + 1)
        let cash = try XCTUnwrap(
            try reopened.context.fetch(FetchDescriptor<Wallet>()).first { $0.id == Fixture.cash })
        XCTAssertEqual(try WalletBalanceService(context: reopened.context).balance(of: cash).minorUnits, 76_500)
        _ = reopened.container
    }

    func testSeederAddsNothingToAnExistingStore() throws {
        let url = try makeStoreURL()
        try writeLegacyStore(at: url)
        let opened = try open(url)
        let defaults = UserDefaults(suiteName: "migration-test-\(UUID().uuidString)")!

        try DefaultDataSeeder.seedIfNeeded(context: opened.context, defaults: defaults)

        XCTAssertEqual(try opened.context.fetchCount(FetchDescriptor<Wallet>()), Fixture.wallets.count)
        XCTAssertEqual(try opened.context.fetchCount(FetchDescriptor<ExpenseTracker.Category>()), Fixture.categories.count)
        _ = opened.container
    }
}
