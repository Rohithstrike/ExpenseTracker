import XCTest
import SwiftData
@testable import ExpenseTracker

@MainActor
final class TransactionQueryServiceTests: XCTestCase {
    private struct Env {
        let container: ModelContainer   // keeps the in-memory store alive
        let context: ModelContext
        let iob: Wallet                 // INR 1_000_000, created first
        let sbi: Wallet                 // INR 500_000, created second
        let food: ExpenseTracker.Category
        var query: TransactionQueryService { TransactionQueryService(context: context) }
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        utc.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private var now: Date { date(2026, 10, 26, 12) }
    private var allTime: Range<Date> {
        Date(timeIntervalSince1970: 0)..<Date(timeIntervalSince1970: 4_000_000_000)
    }

    private func makeEnv() throws -> Env {
        let container = try AppDataStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let ws = WalletService(context: context)
        let iob = try ws.create(WalletInput(name: "IOB", emoji: "🏦", openingBalanceMinor: 1_000_000))
        let sbi = try ws.create(WalletInput(name: "SBI", emoji: "💳", openingBalanceMinor: 500_000))
        let food = ExpenseTracker.Category(name: "Food", emoji: "🍔", colorHex: "#F97316")
        context.insert(food)
        try context.save()
        return Env(container: container, context: context, iob: iob, sbi: sbi, food: food)
    }

    @discardableResult
    private func spend(_ env: Env, _ amount: Int64, wallet: Wallet? = nil,
                       category: ExpenseTracker.Category? = nil, at: Date,
                       note: String = "") throws -> UUID {
        let draft = TransactionDraft(
            kind: .expense, amountMinor: amount, walletID: (wallet ?? env.iob).id,
            categoryID: (category ?? env.food).id, note: note, timestamp: at)
        try TransactionService(context: env.context).save(draft, now: now)
        return draft.id
    }

    @discardableResult
    private func earn(_ env: Env, _ amount: Int64, wallet: Wallet? = nil, at: Date) throws -> UUID {
        let draft = TransactionDraft(
            kind: .income, amountMinor: amount, walletID: (wallet ?? env.iob).id, timestamp: at)
        try TransactionService(context: env.context).save(draft, now: now)
        return draft.id
    }

    @discardableResult
    private func transfer(_ env: Env, _ amount: Int64, from: Wallet? = nil, to: Wallet? = nil,
                          at: Date) throws -> UUID {
        let draft = TransferDraft(
            fromWalletID: (from ?? env.iob).id, toWalletID: (to ?? env.sbi).id,
            amountMinor: amount, timestamp: at)
        try TransferService(context: env.context).save(draft, now: now)
        return draft.id
    }

    private func legs(_ env: Env, _ transferID: UUID) throws -> [Transaction] {
        try env.context.fetch(FetchDescriptor<Transaction>()).filter { $0.transferID == transferID }
    }

    private func history(_ env: Env, _ range: Range<Date>? = nil,
                         wallet: Wallet? = nil) throws -> [DayHistory] {
        try env.query.history(in: range ?? allTime, walletID: wallet?.id, calendar: utc)
    }

    // MARK: Grouping and order

    func testGroupsByDayThenWalletNewestFirst() throws {
        let env = try makeEnv()
        try spend(env, 500, at: date(2026, 10, 25, 10))
        try spend(env, 200, at: date(2026, 10, 25, 9))
        try spend(env, 300, wallet: env.sbi, at: date(2026, 10, 25, 11))
        try spend(env, 150, at: date(2026, 10, 24, 8))

        let days = try history(env)
        XCTAssertEqual(days.map(\.day), [date(2026, 10, 25), date(2026, 10, 24)])
        let first = days[0]
        // Wallets follow creation order, even though SBI has the newest entry.
        XCTAssertEqual(first.wallets.map(\.walletName), ["IOB", "SBI"])
        XCTAssertEqual(first.wallets[0].rows.map(\.amountMinor), [500, 200])
        XCTAssertEqual(first.wallets[1].rows.map(\.amountMinor), [300])
        XCTAssertEqual(days[1].wallets.map(\.walletName), ["IOB"])
        XCTAssertEqual(first.wallets[0].walletEmoji, "🏦")
        XCTAssertEqual(first.wallets[0].currencyCode, "INR")
    }

    func testSameTimestampUsesAStableOrder() throws {
        let env = try makeEnv()
        let stamp = date(2026, 10, 25, 10)
        let a = try spend(env, 100, at: stamp)
        let b = try spend(env, 200, at: stamp)
        let c = try spend(env, 300, at: stamp)
        let expected = [a, b, c].sorted { $0.uuidString > $1.uuidString }
        let rows = try history(env)[0].wallets[0].rows
        XCTAssertEqual(rows.map(\.id), expected)
        XCTAssertEqual(try history(env)[0].wallets[0].rows.map(\.id), expected)   // repeatable
    }

    func testDayGroupingFollowsTheGivenTimeZone() throws {
        let env = try makeEnv()
        var ist = Calendar(identifier: .gregorian)
        ist.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let stamp = date(2026, 10, 25, 20, 0)   // 01:30 on 26 October in India
        try spend(env, 100, at: stamp)
        let days = try env.query.history(in: allTime, calendar: ist)
        XCTAssertEqual(days.map(\.day), [ist.startOfDay(for: stamp)])
        XCTAssertNotEqual(ist.startOfDay(for: stamp), utc.startOfDay(for: stamp))
    }

    // MARK: Filtering and boundaries

    func testWalletFilterKeepsOnlyThatWalletsRows() throws {
        let env = try makeEnv()
        try spend(env, 500, at: date(2026, 10, 25, 10))
        try spend(env, 300, wallet: env.sbi, at: date(2026, 10, 25, 11))
        try transfer(env, 3_000, at: date(2026, 10, 25, 12))

        let days = try history(env, wallet: env.sbi)
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days[0].wallets.map(\.walletName), ["SBI"])
        XCTAssertEqual(Set(days[0].wallets[0].rows.map(\.kind)), [.expense, .transferIn])
    }

    func testRangeIncludesStartAndExcludesEnd() throws {
        let env = try makeEnv()
        try spend(env, 1, at: date(2026, 10, 24, 23, 59))
        let atStart = try spend(env, 2, at: date(2026, 10, 25, 0, 0))
        let lastMinute = try spend(env, 3, at: date(2026, 10, 25, 23, 59))
        try spend(env, 4, at: date(2026, 10, 26, 0, 0))

        let range = date(2026, 10, 25)..<date(2026, 10, 26)
        let rows = try history(env, range).flatMap(\.wallets).flatMap(\.rows)
        XCTAssertEqual(Set(rows.map(\.id)), [atStart, lastMinute])
    }

    func testEmptyPeriodGivesNoGroups() throws {
        let env = try makeEnv()
        try spend(env, 100, at: date(2026, 10, 25, 10))
        XCTAssertEqual(try history(env, date(2026, 1, 1)..<date(2026, 2, 1)), [])
        XCTAssertEqual(try makeEnv().query.history(in: allTime, calendar: utc), [])
    }

    func testReadingNeverChangesTheStore() throws {
        let env = try makeEnv()
        try spend(env, 100, at: date(2026, 10, 25, 10))
        try transfer(env, 1_000, at: date(2026, 10, 25, 11))
        let before = try env.context.fetchCount(FetchDescriptor<Transaction>())
        _ = try history(env)
        XCTAssertFalse(env.context.hasChanges)
        XCTAssertEqual(try env.context.fetchCount(FetchDescriptor<Transaction>()), before)
    }

    // MARK: Categories and wallets

    func testRowCarriesCategoryDetailsAndNote() throws {
        let env = try makeEnv()
        try spend(env, 500, at: date(2026, 10, 25, 10), note: "lunch")
        let row = try XCTUnwrap(try history(env).first?.wallets.first?.rows.first)
        XCTAssertEqual(row.kind, .expense)
        XCTAssertEqual(row.amountMinor, 500)
        XCTAssertEqual(row.note, "lunch")
        XCTAssertEqual(row.categoryID, env.food.id)
        XCTAssertEqual(row.categoryName, "Food")
        XCTAssertEqual(row.categoryEmoji, "🍔")
        XCTAssertEqual(row.categoryColorHex, "#F97316")
        XCTAssertFalse(row.categoryIsArchived)
        XCTAssertNil(row.transferID)
        XCTAssertFalse(row.isBrokenTransfer)
    }

    func testArchivedCategoryStillShowsOnHistory() throws {
        let env = try makeEnv()
        try spend(env, 500, at: date(2026, 10, 25, 10))
        env.food.isArchived = true
        try env.context.save()
        let row = try XCTUnwrap(try history(env).first?.wallets.first?.rows.first)
        XCTAssertEqual(row.categoryName, "Food")
        XCTAssertTrue(row.categoryIsArchived)
    }

    func testMissingCategoryIsHandledWithoutCrashing() throws {
        let env = try makeEnv()
        let ghost = UUID()
        let txn = try Transaction.makeValidated(
            amountMinor: 100, kind: .expense, walletID: env.iob.id,
            categoryID: ghost, timestamp: date(2026, 10, 25, 10))
        env.context.insert(txn)
        try env.context.save()
        let row = try XCTUnwrap(try history(env).first?.wallets.first?.rows.first)
        XCTAssertEqual(row.categoryID, ghost)
        XCTAssertNil(row.categoryName)
        XCTAssertNil(row.categoryEmoji)
        XCTAssertNil(row.categoryColorHex)
    }

    func testIncomeWithoutCategory() throws {
        let env = try makeEnv()
        try earn(env, 2_500, at: date(2026, 10, 25, 10))
        let row = try XCTUnwrap(try history(env).first?.wallets.first?.rows.first)
        XCTAssertEqual(row.kind, .income)
        XCTAssertNil(row.categoryID)
        XCTAssertNil(row.categoryName)
    }

    func testArchivedWalletHistoryStillShows() throws {
        let env = try makeEnv()
        try spend(env, 300, wallet: env.sbi, at: date(2026, 10, 25, 10))
        try WalletService(context: env.context).archive(env.sbi)
        let group = try XCTUnwrap(try history(env).first?.wallets.first)
        XCTAssertEqual(group.walletName, "SBI")
        XCTAssertTrue(group.walletIsArchived)
        XCTAssertEqual(group.rows.count, 1)
    }

    // MARK: Transfers

    func testTransferShowsOnBothWalletsWithTheOtherSideNamed() throws {
        let env = try makeEnv()
        let id = try transfer(env, 3_000, at: date(2026, 10, 25, 10))
        let wallets = try XCTUnwrap(try history(env).first?.wallets)
        let out = try XCTUnwrap(wallets.first { $0.walletName == "IOB" }?.rows.first)
        let inn = try XCTUnwrap(wallets.first { $0.walletName == "SBI" }?.rows.first)
        XCTAssertEqual(out.kind, .transferOut)
        XCTAssertEqual(out.counterpartWalletName, "SBI")
        XCTAssertEqual(out.counterpartWalletID, env.sbi.id)
        XCTAssertEqual(inn.kind, .transferIn)
        XCTAssertEqual(inn.counterpartWalletName, "IOB")
        XCTAssertEqual(out.transferID, id)
        XCTAssertEqual(inn.transferID, id)
        XCTAssertEqual(out.amountMinor, 3_000)
        XCTAssertNil(out.categoryID)
        XCTAssertFalse(out.isBrokenTransfer)
        XCTAssertFalse(inn.isBrokenTransfer)
        XCTAssertNoThrow(try TransferService(context: env.context).pair(transferID: id))
    }

    func testOrphanLegIsFlaggedBroken() throws {
        let env = try makeEnv()
        let id = try transfer(env, 3_000, at: date(2026, 10, 25, 10))
        let inLeg = try XCTUnwrap(try legs(env, id).first { $0.kind == .transferIn })
        env.context.delete(inLeg)
        try env.context.save()

        let row = try XCTUnwrap(try history(env).first?.wallets.first?.rows.first)
        XCTAssertEqual(row.kind, .transferOut)
        XCTAssertTrue(row.isBrokenTransfer)
        XCTAssertNil(row.counterpartWalletID)
        XCTAssertNil(row.counterpartWalletName)
        XCTAssertThrowsError(try TransferService(context: env.context).pair(transferID: id)) {
            XCTAssertEqual($0 as? TransferServiceError, .brokenTransfer)
        }
    }

    func testInconsistentLegsAreBrokenButStillNameTheOtherWallet() throws {
        let env = try makeEnv()
        let id = try transfer(env, 3_000, at: date(2026, 10, 25, 10))
        let inLeg = try XCTUnwrap(try legs(env, id).first { $0.kind == .transferIn })
        inLeg.amountMinor = 2_999
        try env.context.save()

        let wallets = try XCTUnwrap(try history(env).first?.wallets)
        let rows = wallets.flatMap(\.rows)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy(\.isBrokenTransfer))
        XCTAssertEqual(rows.first { $0.kind == .transferOut }?.counterpartWalletName, "SBI")
        XCTAssertThrowsError(try TransferService(context: env.context).pair(transferID: id))
    }

    func testPartnerOutsideTheSelectedPeriodStillResolves() throws {
        let env = try makeEnv()
        let id = try transfer(env, 3_000, at: date(2026, 10, 25, 10))
        let inLeg = try XCTUnwrap(try legs(env, id).first { $0.kind == .transferIn })
        inLeg.timestamp = date(2026, 10, 20, 10)   // drifted to another day
        try env.context.save()

        let range = date(2026, 10, 25)..<date(2026, 10, 26)
        let rows = try history(env, range).flatMap(\.wallets).flatMap(\.rows)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].kind, .transferOut)
        XCTAssertTrue(rows[0].isBrokenTransfer)
        XCTAssertEqual(rows[0].counterpartWalletName, "SBI")
    }

    // MARK: Safety and consistency

    func testUnknownKindThrowsInsteadOfGuessing() throws {
        let env = try makeEnv()
        let id = try spend(env, 100, at: date(2026, 10, 25, 10))
        let row = try XCTUnwrap(
            try env.context.fetch(FetchDescriptor<Transaction>()).first { $0.id == id })
        row.kindRaw = "mystery"
        try env.context.save()
        XCTAssertThrowsError(try history(env)) {
            XCTAssertEqual($0 as? TransactionQueryError, .unknownKind(transactionID: id))
        }
    }

    func testHistoryReproducesWalletBalances() throws {
        let env = try makeEnv()
        try spend(env, 500, at: date(2026, 10, 24, 10))
        try spend(env, 300, wallet: env.sbi, at: date(2026, 10, 25, 11))
        try earn(env, 7_000, at: date(2026, 10, 25, 12))
        try transfer(env, 4_000, at: date(2026, 10, 25, 13))
        try transfer(env, 1_500, from: env.sbi, to: env.iob, at: date(2026, 10, 26, 9))

        let days = try history(env)
        let balances = WalletBalanceService(context: env.context)
        for wallet in [env.iob, env.sbi] {
            let entries = days.flatMap(\.wallets)
                .filter { $0.walletID == wallet.id }
                .flatMap(\.rows)
                .map { LedgerEntry(walletID: wallet.id, kind: $0.kind, amountMinor: $0.amountMinor) }
            let fromHistory = try BalanceCalculator.balanceMinor(
                openingMinor: wallet.openingBalanceMinor, walletID: wallet.id, entries: entries)
            XCTAssertEqual(fromHistory, try balances.balance(of: wallet).minorUnits, wallet.name)
        }
    }

    // MARK: Periods

    func testPeriodRanges() throws {
        let now = date(2026, 10, 26, 15, 30)
        XCTAssertEqual(HistoryPeriod.today.range(now: now, calendar: utc),
                       date(2026, 10, 26)..<date(2026, 10, 27))
        XCTAssertEqual(HistoryPeriod.yesterday.range(now: now, calendar: utc),
                       date(2026, 10, 25)..<date(2026, 10, 26))
        XCTAssertEqual(HistoryPeriod.thisMonth.range(now: now, calendar: utc),
                       date(2026, 10, 1)..<date(2026, 11, 1))
        XCTAssertEqual(HistoryPeriod.lastMonth.range(now: now, calendar: utc),
                       date(2026, 9, 1)..<date(2026, 10, 1))
    }

    func testPeriodsAtMonthAndYearEdges() throws {
        let january = date(2027, 1, 15, 8)
        XCTAssertEqual(HistoryPeriod.lastMonth.range(now: january, calendar: utc),
                       date(2026, 12, 1)..<date(2027, 1, 1))
        let firstMidnight = date(2026, 11, 1, 0, 0)
        XCTAssertEqual(HistoryPeriod.thisMonth.range(now: firstMidnight, calendar: utc),
                       date(2026, 11, 1)..<date(2026, 12, 1))
        XCTAssertEqual(HistoryPeriod.yesterday.range(now: firstMidnight, calendar: utc),
                       date(2026, 10, 31)..<date(2026, 11, 1))
    }
}
