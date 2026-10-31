import XCTest
import SwiftData
@testable import ExpenseTracker

/// A deterministic, realistic ledger: 5 wallets (one archived, one in USD), 12 categories
/// (one archived), 2,200 income and expense entries and 100 transfers over 24 months.
/// Expected values are tallied from the generator's own records with plain arithmetic and
/// fixed day numbers, never from the app's calculation or period code.
@MainActor
final class LargeDatasetTests: XCTestCase {
    private struct RNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ upper: Int) -> Int { Int(next() % UInt64(upper)) }
    }

    private struct Rec {
        var id: UUID
        var kind: TransactionKind
        var amount: Int64
        var wallet: Int
        var category: Int?
        var daysAgo: Int
        var seconds: Int
        var transferID: UUID?
        var note: String
    }

    private final class Dataset {
        let container: ModelContainer
        let context: ModelContext
        var records: [Rec]
        init(container: ModelContainer, context: ModelContext, records: [Rec]) {
            self.container = container
            self.context = context
            self.records = records
        }
    }

    private struct Expected {
        var income: Int64 = 0
        var expense: Int64 = 0
        var byCategory: [Int: Int64] = [:]
    }

    private static let walletSpecs: [(name: String, currency: String, archived: Bool, opening: Int64)] = [
        ("Cash", "INR", false, 50_000),
        ("Bank Account", "INR", false, 2_000_000),
        ("Savings", "INR", false, 10_000_000),
        ("Dollars", "USD", false, 500_000),
        ("Old Card", "INR", true, 100_000)
    ]

    private static let categorySpecs: [(name: String, hex: String, archived: Bool)] = [
        ("Food", "#F97316", false), ("Travel", "#60A5FA", false), ("Shopping", "#EC4899", false),
        ("Rent", "#A78BFA", false), ("Fuel", "#FBBF24", false), ("Health", "#34D399", false),
        ("Entertainment", "#14B8A6", false), ("Bills", "#EF4444", false), ("Education", "#6366F1", false),
        ("Salary", "#84CC16", false), ("Freelance", "#D946EF", false), ("Old Hobby", "#94A3B8", true)
    ]

    // MARK: Fixed clock (UTC, so results never depend on the Mac's time zone)

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// Thursday 29 October 2026, 12:00 UTC.
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 12))! }

    private func timestamp(_ r: Rec) -> Date {
        calendar.startOfDay(for: now).addingTimeInterval(TimeInterval(-r.daysAgo * 86_400 + r.seconds))
    }

    private func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012ld", n))!
    }

    /// Worked out by hand for the fixed date: 29 Oct is day 0, so 1 Oct is day 28, 30 Sep is
    /// day 29 and 1 Sep is day 58.
    private func inPeriod(_ period: HistoryPeriod, _ daysAgo: Int) -> Bool {
        switch period {
        case .today: return daysAgo == 0
        case .yesterday: return daysAgo == 1
        case .thisMonth: return (0...28).contains(daysAgo)
        case .lastMonth: return (29...58).contains(daysAgo)
        }
    }

    // MARK: Generator

    private func makeDataset() throws -> Dataset {
        let container = try AppDataStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        var rng = RNG(state: 20_261_029)
        var records: [Rec] = []

        // The first entries pin down same-day clusters and month and year boundaries.
        let boundary = [0, 0, 0, 1, 1, 28, 28, 29, 29, 58, 58, 59, 59, 365, 730]
        for i in 0..<2_200 {
            let isIncome = rng.int(100) < 18
            let band = rng.int(100)
            var amount: Int64
            if band < 70 {
                amount = Int64(5_000 + rng.int(195_000))
            } else if band < 95 {
                amount = Int64(200_000 + rng.int(1_800_000))
            } else {
                amount = Int64(2_000_000 + rng.int(8_000_000))
            }
            let wallet = rng.int(Self.walletSpecs.count)
            var days: Int
            if i < boundary.count {
                days = boundary[i]
            } else if rng.int(100) < 30 {
                days = rng.int(60)
            } else {
                days = rng.int(731)
            }
            let seconds = i < boundary.count ? (i % 2 == 0 ? 0 : 86_399) : rng.int(86_400)
            var category: Int?
            if !isIncome {
                category = rng.int(Self.categorySpecs.count)
            } else if rng.int(2) == 0 {
                category = rng.int(Self.categorySpecs.count)
            }
            records.append(Rec(
                id: uuid(1_000 + i), kind: isIncome ? .income : .expense, amount: amount,
                wallet: wallet, category: category, daysAgo: days, seconds: seconds,
                transferID: nil, note: i % 3 == 0 ? "" : "Note \(i)"))
        }

        let inrWallets = [0, 1, 2, 4]
        for k in 0..<100 {
            let from = inrWallets[rng.int(4)]
            var to = inrWallets[rng.int(4)]
            if to == from { to = inrWallets[(inrWallets.firstIndex(of: from)! + 1) % 4] }
            let amount = Int64(10_000 + rng.int(990_000))
            let days = rng.int(100) < 30 ? rng.int(60) : rng.int(731)
            let seconds = rng.int(86_400)
            let transferID = uuid(9_000 + k)
            let note = k % 2 == 0 ? "" : "Move \(k)"
            records.append(Rec(id: uuid(5_000 + 2 * k), kind: .transferOut, amount: amount, wallet: from,
                               category: nil, daysAgo: days, seconds: seconds, transferID: transferID, note: note))
            records.append(Rec(id: uuid(5_001 + 2 * k), kind: .transferIn, amount: amount, wallet: to,
                               category: nil, daysAgo: days, seconds: seconds, transferID: transferID, note: note))
        }

        for (i, spec) in Self.walletSpecs.enumerated() {
            context.insert(Wallet(
                id: uuid(1 + i), name: spec.name, emoji: "💵", openingBalanceMinor: spec.opening,
                currencyCode: spec.currency, createdAt: Date(timeIntervalSince1970: Double(i)),
                isArchived: spec.archived))
        }
        for (j, spec) in Self.categorySpecs.enumerated() {
            context.insert(ExpenseTracker.Category(
                id: uuid(100 + j), name: spec.name, emoji: "🏷️", colorHex: spec.hex,
                createdAt: Date(timeIntervalSince1970: Double(j)),
                updatedAt: Date(timeIntervalSince1970: Double(j)), isArchived: spec.archived))
        }
        for r in records {
            context.insert(Transaction(
                id: r.id, amountMinor: r.amount, kind: r.kind, timestamp: timestamp(r), note: r.note,
                walletID: uuid(1 + r.wallet), categoryID: r.category.map { uuid(100 + $0) },
                transferID: r.transferID))
        }
        try context.save()
        return Dataset(container: container, context: context, records: records)
    }

    // MARK: Independent expectations

    private func expected(_ records: [Rec], _ period: HistoryPeriod, _ currency: String) -> Expected {
        var result = Expected()
        for r in records where inPeriod(period, r.daysAgo) && Self.walletSpecs[r.wallet].currency == currency {
            switch r.kind {
            case .income:
                result.income += r.amount
            case .expense:
                result.expense += r.amount
                if let c = r.category { result.byCategory[c, default: 0] += r.amount }
            case .transferOut, .transferIn:
                break
            }
        }
        return result
    }

    private func verifyProgress(_ ds: Dataset, file: StaticString = #filePath, line: UInt = #line) {
        let fixedNow = now
        let cal = calendar
        for period in HistoryPeriod.allCases {
            let model = ProgressViewModel(
                context: ds.context, period: period, calendar: cal,
                locale: Locale(identifier: "en_US_POSIX"), now: { fixedNow })
            XCTAssertFalse(model.summaries.contains { $0.currencyCode.isEmpty }, file: file, line: line)
            for currency in ["INR", "USD"] {
                let exp = expected(ds.records, period, currency)
                let summary = model.summaries.first { $0.currencyCode == currency }
                let label = "\(period) \(currency)"
                XCTAssertEqual(summary?.incomeMinor ?? 0, exp.income, "\(label) income", file: file, line: line)
                XCTAssertEqual(summary?.expenseMinor ?? 0, exp.expense, "\(label) expense", file: file, line: line)
                XCTAssertEqual(summary?.netMinor ?? 0, exp.income - exp.expense, "\(label) net", file: file, line: line)
                var got: [UUID: Int64] = [:]
                for item in summary?.categories ?? [] {
                    if let id = item.categoryID { got[id] = item.amountMinor } else { XCTFail("\(label): uncategorised row", file: file, line: line) }
                }
                var want: [UUID: Int64] = [:]
                for (index, value) in exp.byCategory { want[uuid(100 + index)] = value }
                XCTAssertEqual(got, want, "\(label) categories", file: file, line: line)
                XCTAssertEqual(got.values.reduce(0, +), exp.expense, "\(label) category sum", file: file, line: line)
                let amounts = (summary?.categories ?? []).map(\.amountMinor)
                XCTAssertEqual(amounts, amounts.sorted(by: >), "\(label) order", file: file, line: line)
            }
        }
    }

    private func verifyBalances(_ ds: Dataset, file: StaticString = #filePath, line: UInt = #line) throws {
        let wallets = try ds.context.fetch(FetchDescriptor<Wallet>())
        let service = WalletBalanceService(context: ds.context)
        XCTAssertEqual(wallets.count, Self.walletSpecs.count, file: file, line: line)
        for (index, spec) in Self.walletSpecs.enumerated() {
            var want = spec.opening
            for r in ds.records where r.wallet == index {
                want += (r.kind == .income || r.kind == .transferIn) ? r.amount : -r.amount
            }
            let wallet = try XCTUnwrap(wallets.first { $0.id == uuid(1 + index) }, file: file, line: line)
            XCTAssertEqual(try service.balance(of: wallet).minorUnits, want, spec.name, file: file, line: line)
        }
    }

    // MARK: Tests

    func testDatasetShapeAndPeriodTotalsMatchIndependentTallies() throws {
        let ds = try makeDataset()
        defer { withExtendedLifetime(ds.container) {} }
        XCTAssertEqual(ds.records.count, 2_400)
        XCTAssertEqual(try ds.context.fetchCount(FetchDescriptor<Transaction>()), 2_400)
        for period in HistoryPeriod.allCases {
            XCTAssertGreaterThan(expected(ds.records, period, "INR").expense, 0, "\(period) has spending")
        }
        XCTAssertGreaterThan(expected(ds.records, .thisMonth, "USD").expense, 0)
        verifyProgress(ds)
    }

    func testBalancesIdsAndTransferPairsAreIntact() throws {
        let ds = try makeDataset()
        defer { withExtendedLifetime(ds.container) {} }
        try verifyBalances(ds)
        let all = try ds.context.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        let transfers = TransferService(context: ds.context)
        for k in 0..<100 {
            XCTAssertNoThrow(try transfers.pair(transferID: uuid(9_000 + k)), "transfer \(k)")
        }
    }

    func testEditingAndDeletingKeepEveryTotalCorrect() throws {
        let ds = try makeDataset()
        defer { withExtendedLifetime(ds.container) {} }
        let service = TransactionService(context: ds.context)

        // Edit last month's INR expense by +10.00.
        let ei = try XCTUnwrap(ds.records.firstIndex {
            $0.kind == .expense && (29...58).contains($0.daysAgo) && Self.walletSpecs[$0.wallet].currency == "INR"
        })
        var rec = ds.records[ei]
        try service.update(
            id: rec.id,
            to: TransactionEdit(
                kind: .expense, amountMinor: rec.amount + 1_000, walletID: uuid(1 + rec.wallet),
                categoryID: rec.category.map { uuid(100 + $0) }, note: rec.note, timestamp: timestamp(rec)),
            now: now)
        rec.amount += 1_000
        ds.records[ei] = rec
        verifyProgress(ds)
        try verifyBalances(ds)

        // Delete one of this month's expenses.
        let di = try XCTUnwrap(ds.records.firstIndex { $0.kind == .expense && $0.daysAgo <= 28 })
        try service.delete(id: ds.records[di].id)
        ds.records.remove(at: di)
        verifyProgress(ds)
        try verifyBalances(ds)

        // Delete a whole transfer: totals stay put, balances follow.
        let transferID = try XCTUnwrap(ds.records.first { $0.transferID != nil }?.transferID)
        try TransferService(context: ds.context).delete(transferID: transferID)
        ds.records.removeAll { $0.transferID == transferID }
        verifyProgress(ds)
        try verifyBalances(ds)
        XCTAssertEqual(try ds.context.fetchCount(FetchDescriptor<Transaction>()), ds.records.count)
    }

    func testViewModelCurrencyAndPeriodSelection() throws {
        let ds = try makeDataset()
        defer { withExtendedLifetime(ds.container) {} }
        let fixedNow = now
        let model = ProgressViewModel(
            context: ds.context, period: .thisMonth, calendar: calendar,
            locale: Locale(identifier: "en_US_POSIX"), now: { fixedNow })
        XCTAssertEqual(model.summaries.map(\.currencyCode), ["INR", "USD"])
        XCTAssertEqual(model.selectedSummary?.currencyCode, "INR")
        model.selectCurrency("USD")
        XCTAssertEqual(model.selectedSummary?.currencyCode, "USD")
        model.selectCurrency("XXX")
        XCTAssertEqual(model.selectedSummary?.currencyCode, "USD")
        model.selectPeriod(.lastMonth)
        XCTAssertEqual(model.period, .lastMonth)
        XCTAssertNotEqual(model.state, .empty)
    }

    func testEmptyStoreShowsEmptyState() throws {
        let container = try AppDataStore.makeContainer(inMemory: true)
        defer { withExtendedLifetime(container) {} }
        let model = ProgressViewModel(context: ModelContext(container))
        XCTAssertEqual(model.state, .empty)
        XCTAssertNil(model.selectedSummary)
    }

    func testPerformanceWithThousandsOfTransactions() throws {
        let clock = ContinuousClock()
        let buildStart = clock.now
        let ds = try makeDataset()
        defer { withExtendedLifetime(ds.container) {} }
        let buildSeconds = seconds(buildStart.duration(to: clock.now))

        let fixedNow = now
        let cal = calendar
        let reload = clock.measure {
            for period in HistoryPeriod.allCases {
                let model = ProgressViewModel(
                    context: ds.context, period: period, calendar: cal,
                    locale: Locale(identifier: "en_US_POSIX"), now: { fixedNow })
                XCTAssertNotEqual(model.state, .empty)
            }
        }
        let balances = clock.measure {
            let wallets = (try? ds.context.fetch(FetchDescriptor<Wallet>())) ?? []
            let result = try? WalletBalanceService(context: ds.context).balances(for: wallets)
            XCTAssertEqual(result?.count, wallets.count)
        }
        let history = clock.measure {
            let range = HistoryPeriod.lastMonth.range(now: fixedNow, calendar: cal)!
            let days = try? TransactionQueryService(context: ds.context).history(in: range, calendar: cal)
            XCTAssertFalse(days?.isEmpty ?? true)
        }
        print("PERF build+insert 2400 records: \(buildSeconds)s")
        print("PERF 4 Progress loads: \(seconds(reload))s")
        print("PERF all wallet balances: \(seconds(balances))s")
        print("PERF one month of history: \(seconds(history))s")
        XCTAssertLessThan(seconds(reload), 10)
        XCTAssertLessThan(seconds(balances), 10)
        XCTAssertLessThan(seconds(history), 10)
    }

    private func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
