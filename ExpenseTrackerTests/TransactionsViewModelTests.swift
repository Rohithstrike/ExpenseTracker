import XCTest
import SwiftData
@testable import ExpenseTracker

@MainActor
final class TransactionsViewModelTests: XCTestCase {
    private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private struct Env {
        let container: ModelContainer   // keeps the in-memory store alive
        let context: ModelContext
        let iob: Wallet
        let sbi: Wallet
        let old: Wallet                 // archived
        let food: ExpenseTracker.Category
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let enIN = Locale(identifier: "en_IN")

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        utc.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private var saveNow: Date { date(2026, 10, 26, 12) }

    private func makeEnv() throws -> Env {
        let container = try AppDataStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let ws = WalletService(context: context)
        let iob = try ws.create(WalletInput(name: "IOB", emoji: "🏦", openingBalanceMinor: 1_000_000))
        let sbi = try ws.create(WalletInput(name: "SBI", emoji: "💳", openingBalanceMinor: 500_000))
        let old = try ws.create(WalletInput(name: "Old", emoji: "📦", openingBalanceMinor: 5_000))
        try ws.archive(old)
        let food = ExpenseTracker.Category(name: "Food", emoji: "🍔", colorHex: "#F97316")
        context.insert(food)
        try context.save()
        return Env(container: container, context: context, iob: iob, sbi: sbi, old: old, food: food)
    }

    private func model(_ env: Env, period: HistoryPeriod = .today, clock: Clock? = nil) -> TransactionsViewModel {
        let c = clock ?? Clock(date(2026, 10, 26, 12))
        return TransactionsViewModel(
            context: env.context, period: period, calendar: utc, locale: enIN, now: { c.now })
    }

    @discardableResult
    private func spend(_ env: Env, _ amount: Int64, wallet: Wallet? = nil, at: Date) throws -> UUID {
        let draft = TransactionDraft(
            kind: .expense, amountMinor: amount, walletID: (wallet ?? env.iob).id,
            categoryID: env.food.id, timestamp: at)
        try TransactionService(context: env.context).save(draft, now: saveNow)
        return draft.id
    }

    private func transfer(_ env: Env, _ amount: Int64, at: Date) throws {
        let draft = TransferDraft(
            fromWalletID: env.iob.id, toWalletID: env.sbi.id, amountMinor: amount, timestamp: at)
        try TransferService(context: env.context).save(draft, now: saveNow)
    }

    private func rows(_ m: TransactionsViewModel) -> [HistoryRow] {
        m.days.flatMap(\.wallets).flatMap(\.rows)
    }

    // MARK: Loading

    func testLoadsTodayByDefaultGroupedByWallet() throws {
        let env = try makeEnv()
        try spend(env, 500, at: date(2026, 10, 26, 9))
        try spend(env, 300, wallet: env.sbi, at: date(2026, 10, 26, 10))
        try spend(env, 100, at: date(2026, 10, 25, 10))
        let m = model(env)
        XCTAssertEqual(m.period, .today)
        XCTAssertNil(m.selectedWalletID)
        XCTAssertEqual(m.days.count, 1)
        XCTAssertEqual(m.days[0].wallets.map(\.walletName), ["IOB", "SBI"])
        XCTAssertEqual(rows(m).count, 2)
    }

    func testEmptyPeriodGivesEmptyState() throws {
        let env = try makeEnv()
        let m = model(env)
        XCTAssertEqual(m.state, .empty)
        XCTAssertEqual(m.emptyTitle, "No transactions today")
        XCTAssertFalse(m.emptyDetail.isEmpty)
    }

    func testChangingPeriodReloads() throws {
        let env = try makeEnv()
        try spend(env, 100, at: date(2026, 10, 26, 9))
        try spend(env, 200, at: date(2026, 10, 25, 10))
        try spend(env, 300, at: date(2026, 10, 3, 8))
        try spend(env, 400, at: date(2026, 9, 20, 8))
        let m = model(env)
        XCTAssertEqual(rows(m).map(\.amountMinor), [100])
        m.selectPeriod(.yesterday)
        XCTAssertEqual(rows(m).map(\.amountMinor), [200])
        m.selectPeriod(.thisMonth)
        XCTAssertEqual(rows(m).count, 3)
        m.selectPeriod(.lastMonth)
        XCTAssertEqual(rows(m).map(\.amountMinor), [400])
    }

    func testSelectingTheSamePeriodDoesNotReload() throws {
        let env = try makeEnv()
        try spend(env, 100, at: date(2026, 10, 26, 9))
        let m = model(env)
        XCTAssertEqual(rows(m).count, 1)
        try spend(env, 200, at: date(2026, 10, 26, 10))
        m.selectPeriod(.today)
        XCTAssertEqual(rows(m).count, 1)   // unchanged: no reload happened
        m.reload()
        XCTAssertEqual(rows(m).count, 2)
    }

    func testReloadPicksUpNewEntries() throws {
        let env = try makeEnv()
        let m = model(env)
        XCTAssertEqual(m.state, .empty)
        try spend(env, 100, at: date(2026, 10, 26, 9))
        XCTAssertEqual(m.state, .empty)
        m.reload()
        XCTAssertEqual(rows(m).count, 1)
    }

    func testTodayFollowsTheClock() throws {
        let env = try makeEnv()
        try spend(env, 100, at: date(2026, 10, 26, 9))
        let clock = Clock(date(2026, 10, 26, 12))
        let m = model(env, clock: clock)
        XCTAssertEqual(rows(m).count, 1)
        clock.now = date(2026, 10, 27, 12)
        m.reload()
        XCTAssertEqual(m.state, .empty)
        m.selectPeriod(.yesterday)
        XCTAssertEqual(rows(m).count, 1)
    }

    // MARK: Wallet filter

    func testWalletFilterNarrowsAndResets() throws {
        let env = try makeEnv()
        try spend(env, 500, at: date(2026, 10, 26, 9))
        try spend(env, 300, wallet: env.sbi, at: date(2026, 10, 26, 10))
        try transfer(env, 3_000, at: date(2026, 10, 26, 11))
        let m = model(env)
        XCTAssertEqual(rows(m).count, 4)   // transfer shows under both wallets

        m.selectWallet(env.sbi.id)
        XCTAssertEqual(m.selectedWalletID, env.sbi.id)
        XCTAssertEqual(m.days[0].wallets.map(\.walletName), ["SBI"])
        XCTAssertEqual(rows(m).count, 2)
        XCTAssertEqual(Set(rows(m).map(\.kind)), [.expense, .transferIn])

        m.selectWallet(nil)
        XCTAssertNil(m.selectedWalletID)
        XCTAssertEqual(rows(m).count, 4)
    }

    func testEmptyTitleNamesTheSelectedWallet() throws {
        let env = try makeEnv()
        try spend(env, 500, at: date(2026, 10, 26, 9))
        let m = model(env)
        m.selectWallet(env.sbi.id)
        XCTAssertEqual(m.state, .empty)
        XCTAssertEqual(m.emptyTitle, "No transactions for SBI today")
        m.selectPeriod(.yesterday)
        XCTAssertEqual(m.emptyTitle, "No transactions for SBI yesterday")
    }

    func testUnknownWalletSelectionIsIgnored() throws {
        let env = try makeEnv()
        let m = model(env)
        m.selectWallet(UUID())
        XCTAssertNil(m.selectedWalletID)
    }

    func testWalletOptionsIncludeArchivedInCreationOrder() throws {
        let env = try makeEnv()
        let m = model(env)
        XCTAssertEqual(m.walletOptions.map(\.name), ["IOB", "SBI", "Old"])
        XCTAssertEqual(m.walletOptions.map(\.isArchived), [false, false, true])
        XCTAssertEqual(m.walletOptions.first?.emoji, "🏦")
        XCTAssertEqual(m.walletFilterTitle, "All wallets")
        m.selectWallet(env.old.id)
        XCTAssertEqual(m.walletFilterTitle, "Old")
    }

    func testMissingSelectedWalletFallsBackToAll() throws {
        let env = try makeEnv()
        try spend(env, 500, at: date(2026, 10, 26, 9))
        let m = model(env)
        m.selectWallet(env.sbi.id)
        env.context.delete(env.sbi)
        try env.context.save()
        m.reload()
        XCTAssertNil(m.selectedWalletID)
        XCTAssertEqual(m.walletFilterTitle, "All wallets")
        XCTAssertEqual(rows(m).count, 1)
    }

    // MARK: Errors and titles

    func testUnreadableRowFailsThenRecovers() throws {
        let env = try makeEnv()
        try spend(env, 500, at: date(2026, 10, 26, 9))
        let row = try XCTUnwrap(try env.context.fetch(FetchDescriptor<Transaction>()).first)
        row.kindRaw = "mystery"
        try env.context.save()
        let m = model(env)
        XCTAssertEqual(m.state, .failed(TransactionsViewModel.unreadableMessage))
        XCTAssertEqual(m.days, [])
        row.kindRaw = TransactionKind.expense.rawValue
        try env.context.save()
        m.reload()
        XCTAssertEqual(rows(m).count, 1)
    }

    func testTitlesFollowSelection() throws {
        let env = try makeEnv()
        let m = model(env)
        var seen: [(String, String)] = []
        for period in HistoryPeriod.allCases {
            m.selectPeriod(period)
            seen.append((m.periodTitle, m.emptyTitle))
        }
        XCTAssertEqual(seen.map(\.0), ["Today", "Yesterday", "This month", "Last month"])
        XCTAssertEqual(seen.map(\.1), [
            "No transactions today", "No transactions yesterday",
            "No transactions this month", "No transactions last month"])
    }
}
