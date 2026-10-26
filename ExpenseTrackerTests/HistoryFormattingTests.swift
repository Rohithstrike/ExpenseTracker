import XCTest
import SwiftData
@testable import ExpenseTracker

@MainActor
final class HistoryFormattingTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    private let enIN = Locale(identifier: "en_IN")
    private var fmt: HistoryFormatting { HistoryFormatting(calendar: utc, locale: enIN) }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        utc.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func row(
        kind: TransactionKind = .expense,
        amount: Int64 = 50_000,
        note: String = "",
        categoryName: String? = "Fuel",
        emoji: String? = "⛽",
        archived: Bool = false,
        counterpart: String? = nil,
        broken: Bool = false
    ) -> HistoryRow {
        HistoryRow(
            id: UUID(), kind: kind, amountMinor: amount, timestamp: Date(), note: note,
            categoryID: categoryName == nil ? nil : UUID(), categoryName: categoryName,
            categoryEmoji: emoji, categoryColorHex: "#F97316", categoryIsArchived: archived,
            transferID: nil, counterpartWalletID: nil, counterpartWalletName: counterpart,
            isBrokenTransfer: broken)
    }

    // MARK: Day titles

    func testDayTitleTodayAndYesterday() {
        let now = date(2026, 10, 26, 12)
        XCTAssertEqual(fmt.dayTitle(for: date(2026, 10, 26), now: now), "Today")
        XCTAssertEqual(fmt.dayTitle(for: date(2026, 10, 25), now: now), "Yesterday")
    }

    func testDayTitleOlderDateUsesWeekdayDayAndMonth() {
        let now = date(2026, 10, 26, 12)
        let title = fmt.dayTitle(for: date(2026, 10, 24), now: now)   // a Saturday
        XCTAssertTrue(title.contains("Sat"), title)
        XCTAssertTrue(title.contains("24"), title)
        XCTAssertTrue(title.contains("Oct"), title)
        XCTAssertFalse(title.contains("2026"), title)
    }

    func testDayTitleAddsYearOnlyForOtherYears() {
        let now = date(2026, 1, 5, 12)
        let title = fmt.dayTitle(for: date(2025, 12, 31), now: now)
        XCTAssertTrue(title.contains("2025"), title)
        XCTAssertTrue(title.contains("Dec"), title)
        XCTAssertTrue(title.contains("31"), title)
    }

    func testDayTitleAcrossMonthBoundary() {
        let now = date(2026, 11, 1, 0, 30)
        XCTAssertEqual(fmt.dayTitle(for: date(2026, 10, 31), now: now), "Yesterday")
        XCTAssertEqual(fmt.dayTitle(for: date(2026, 11, 1), now: now), "Today")
    }

    func testDayTitleFollowsTheGivenTimeZone() {
        var ist = Calendar(identifier: .gregorian)
        ist.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let india = HistoryFormatting(calendar: ist, locale: enIN)
        let now = date(2026, 10, 25, 20)   // 01:30 on 26 October in India
        XCTAssertEqual(india.dayTitle(for: ist.startOfDay(for: now), now: now), "Today")
        // The same instant is still 25 October in UTC.
        XCTAssertEqual(fmt.dayTitle(for: utc.startOfDay(for: now), now: now), "Today")
        XCTAssertEqual(india.dayTitle(for: date(2026, 10, 24, 19), now: now), "Yesterday")
    }

    // MARK: Amounts

    func testSignedAmounts() {
        let money = Money(minorUnits: 250_000, currencyCode: "INR").formatted(locale: enIN)
        XCTAssertEqual(fmt.amountText(for: row(kind: .income, amount: 250_000), currencyCode: "INR"), "+" + money)
        XCTAssertEqual(fmt.amountText(for: row(kind: .expense, amount: 250_000), currencyCode: "INR"), "−" + money)
        XCTAssertEqual(fmt.amountText(for: row(kind: .transferIn, amount: 250_000), currencyCode: "INR"), "+" + money)
        XCTAssertEqual(fmt.amountText(for: row(kind: .transferOut, amount: 250_000), currencyCode: "INR"), "−" + money)
        XCTAssertTrue(fmt.amountText(for: row(), currencyCode: "INR").hasPrefix("\u{2212}"))
    }

    func testAmountFallsBackWhenCurrencyIsUnknown() {
        XCTAssertEqual(fmt.amountText(for: row(amount: 50_000), currencyCode: ""), "−500.00")
        XCTAssertEqual(fmt.amountText(for: row(kind: .income, amount: 5), currencyCode: "??"), "+0.05")
    }

    // MARK: Titles, subtitles, icons

    func testTitlesForOrdinaryRows() {
        XCTAssertEqual(fmt.title(for: row()), "Fuel")
        XCTAssertEqual(fmt.title(for: row(kind: .income, categoryName: "Salary")), "Salary")
        XCTAssertEqual(fmt.title(for: row(kind: .income, categoryName: nil)), "Income")
        XCTAssertEqual(fmt.title(for: row(categoryName: nil)), "Uncategorised")
        XCTAssertEqual(fmt.title(for: row(archived: true)), "Fuel")   // archived keeps its name
    }

    func testTransferTitles() {
        XCTAssertEqual(fmt.title(for: row(kind: .transferOut, categoryName: nil, counterpart: "SBI")), "Transfer to SBI")
        XCTAssertEqual(fmt.title(for: row(kind: .transferIn, categoryName: nil, counterpart: "IOB")), "Transfer from IOB")
        XCTAssertEqual(fmt.title(for: row(kind: .transferOut, categoryName: nil, broken: true)), "Transfer")
        XCTAssertEqual(fmt.title(for: row(kind: .transferIn, categoryName: nil, counterpart: "IOB", broken: true)), "Transfer from IOB")
    }

    func testSubtitles() {
        XCTAssertNil(fmt.subtitle(for: row()))
        XCTAssertNil(fmt.subtitle(for: row(note: "  \n ")))
        XCTAssertEqual(fmt.subtitle(for: row(note: "lunch")), "lunch")
        XCTAssertEqual(fmt.subtitle(for: row(note: "  lunch\n with   team ")), "lunch with team")
        XCTAssertEqual(fmt.subtitle(for: row(kind: .transferOut, categoryName: nil, broken: true)), "Incomplete transfer")
        XCTAssertEqual(
            fmt.subtitle(for: row(kind: .transferOut, note: "rent", categoryName: nil, broken: true)),
            "Incomplete transfer · rent")
    }

    func testIcons() {
        XCTAssertEqual(fmt.icon(for: row()), .emoji("⛽"))
        XCTAssertEqual(fmt.icon(for: row(emoji: nil)), .emoji("🏷️"))
        XCTAssertEqual(fmt.icon(for: row(emoji: "")), .emoji("🏷️"))
        XCTAssertEqual(fmt.icon(for: row(kind: .income, categoryName: nil, emoji: nil)), .emoji("💵"))
        XCTAssertEqual(fmt.icon(for: row(kind: .transferOut, categoryName: nil, emoji: nil)), .transferOut)
        XCTAssertEqual(fmt.icon(for: row(kind: .transferIn, categoryName: nil, emoji: nil)), .transferIn)
        XCTAssertEqual(fmt.icon(for: row(kind: .transferOut, categoryName: nil, emoji: nil, broken: true)), .warning)
    }

    func testAmountStylesKeepTransfersNeutral() {
        XCTAssertEqual(fmt.amountStyle(for: row(kind: .income)), .income)
        XCTAssertEqual(fmt.amountStyle(for: row(kind: .expense)), .expense)
        XCTAssertEqual(fmt.amountStyle(for: row(kind: .transferOut)), .transfer)
        XCTAssertEqual(fmt.amountStyle(for: row(kind: .transferIn)), .transfer)
    }

    func testAccessibilityLabels() {
        let money = Money(minorUnits: 50_000, currencyCode: "INR").formatted(locale: enIN)
        XCTAssertEqual(
            fmt.accessibilityLabel(for: row(note: "lunch"), currencyCode: "INR"),
            "Fuel, expense, \(money), lunch")
        XCTAssertEqual(
            fmt.accessibilityLabel(for: row(kind: .transferOut, categoryName: nil, counterpart: "SBI"), currencyCode: "INR"),
            "Transfer to SBI, transfer out, \(money)")
        XCTAssertEqual(
            fmt.accessibilityLabel(for: row(kind: .income, categoryName: nil), currencyCode: "INR"),
            "Income, income, \(money)")
    }

    // MARK: Headings

    func testHeadingsAndPeriodTitles() {
        func group(archived: Bool) -> WalletHistory {
            WalletHistory(walletID: UUID(), walletName: "IOB", walletEmoji: "🏦", currencyCode: "INR",
                          walletIsArchived: archived, rows: [])
        }
        XCTAssertEqual(fmt.walletHeading(group(archived: false)), "🏦 IOB")
        XCTAssertEqual(fmt.walletHeading(group(archived: true)), "🏦 IOB (archived)")
        XCTAssertEqual(HistoryFormatting.allWalletsTitle, "All wallets")
        XCTAssertEqual(HistoryPeriod.allCases.map(fmt.periodTitle),
                       ["Today", "Yesterday", "This month", "Last month"])
    }

    // MARK: Against the real query service

    func testFormattingMatchesRealQueryOutput() throws {
        let container = try AppDataStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let ws = WalletService(context: context)
        let iob = try ws.create(WalletInput(name: "IOB", emoji: "🏦", openingBalanceMinor: 1_000_000))
        let sbi = try ws.create(WalletInput(name: "SBI", emoji: "💳", openingBalanceMinor: 500_000))
        let food = ExpenseTracker.Category(name: "Food", emoji: "🍔", colorHex: "#F97316")
        context.insert(food)
        try context.save()

        let now = date(2026, 10, 26, 12)
        try TransactionService(context: context).save(
            TransactionDraft(kind: .expense, amountMinor: 50_000, walletID: iob.id,
                             categoryID: food.id, note: "lunch", timestamp: date(2026, 10, 25, 10)),
            now: now)
        try TransferService(context: context).save(
            TransferDraft(fromWalletID: iob.id, toWalletID: sbi.id, amountMinor: 300_000,
                          timestamp: date(2026, 10, 25, 11)),
            now: now)

        let days = try TransactionQueryService(context: context)
            .history(in: date(2026, 10, 25)..<date(2026, 10, 26), calendar: utc)
        let day = try XCTUnwrap(days.first)
        XCTAssertEqual(fmt.dayTitle(for: day.day, now: now), "Yesterday")

        let iobGroup = try XCTUnwrap(day.wallets.first { $0.walletName == "IOB" })
        let sbiGroup = try XCTUnwrap(day.wallets.first { $0.walletName == "SBI" })
        XCTAssertEqual(fmt.walletHeading(iobGroup), "🏦 IOB")

        let expense = try XCTUnwrap(iobGroup.rows.first { $0.kind == .expense })
        XCTAssertEqual(fmt.title(for: expense), "Food")
        XCTAssertEqual(fmt.subtitle(for: expense), "lunch")
        XCTAssertEqual(fmt.icon(for: expense), .emoji("🍔"))
        XCTAssertEqual(
            fmt.amountText(for: expense, currencyCode: iobGroup.currencyCode),
            "−" + Money(minorUnits: 50_000, currencyCode: "INR").formatted(locale: enIN))

        let out = try XCTUnwrap(iobGroup.rows.first { $0.kind == .transferOut })
        XCTAssertEqual(fmt.title(for: out), "Transfer to SBI")
        XCTAssertEqual(fmt.icon(for: out), .transferOut)
        XCTAssertEqual(fmt.amountStyle(for: out), .transfer)
        XCTAssertNil(fmt.subtitle(for: out))

        let inn = try XCTUnwrap(sbiGroup.rows.first { $0.kind == .transferIn })
        XCTAssertEqual(fmt.title(for: inn), "Transfer from IOB")
        XCTAssertTrue(fmt.amountText(for: inn, currencyCode: sbiGroup.currencyCode).hasPrefix("+"))
    }
}
