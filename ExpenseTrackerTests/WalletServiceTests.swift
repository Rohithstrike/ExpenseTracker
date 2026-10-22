// ExpenseTrackerTests/WalletServiceTests.swift  (new file)
import XCTest
import SwiftData
@testable import ExpenseTracker

@MainActor
final class WalletServiceTests: XCTestCase {
    private struct Env {
        let container: ModelContainer   // keeps the in-memory store alive
        let context: ModelContext
        var service: WalletService { WalletService(context: context) }
    }

    private func makeEnv() throws -> Env {
        let container = try AppDataStore.makeContainer(inMemory: true)
        return Env(container: container, context: ModelContext(container))
    }

    private func addTransaction(_ env: Env, wallet: Wallet, amount: Int64, kind: TransactionKind) throws {
        env.context.insert(
            try Transaction.makeValidated(amountMinor: amount, kind: kind, walletID: wallet.id)
        )
        try env.context.save()
    }

    private func walletCount(_ env: Env) throws -> Int {
        try env.context.fetchCount(FetchDescriptor<Wallet>())
    }

    func testCreateTrimsAndNormalises() throws {
        let env = try makeEnv()
        let wallet = try env.service.create(
            WalletInput(name: "  Bank 1 ", emoji: "  ", openingBalanceMinor: 500_000, currencyCode: "inr")
        )
        XCTAssertEqual(wallet.name, "Bank 1")
        XCTAssertEqual(wallet.emoji, WalletService.defaultEmoji)
        XCTAssertEqual(wallet.currencyCode, "INR")
        XCTAssertEqual(wallet.openingBalanceMinor, 500_000)
        XCTAssertEqual(try walletCount(env), 1)
    }

    func testNameValidation() throws {
        let env = try makeEnv()
        let bad = ["", "   ", String(repeating: "a", count: 31), "two\nlines"]
        for name in bad {
            XCTAssertThrowsError(try env.service.create(WalletInput(name: name)), "name '\(name)'") {
                XCTAssertEqual($0 as? WalletError, .invalidName)
            }
        }
        XCTAssertEqual(try walletCount(env), 0)
        XCTAssertNoThrow(try env.service.create(WalletInput(name: String(repeating: "a", count: 30))))
        XCTAssertEqual(try walletCount(env), 1)
    }

    func testDuplicateNameIsCaseInsensitive() throws {
        let env = try makeEnv()
        try env.service.create(WalletInput(name: "Cash"))
        XCTAssertThrowsError(try env.service.create(WalletInput(name: " cash "))) {
            XCTAssertEqual($0 as? WalletError, .duplicateName)
        }
        XCTAssertEqual(try walletCount(env), 1)
    }

    func testEmojiValidation() throws {
        for good in ["😀", "👨‍👩‍👧", "❤️", "🇮🇳", "1️⃣"] {
            XCTAssertTrue(WalletService.isSingleEmoji(good), good)
        }
        for bad in ["", "a", "1", "ab", "😀😀", "x😀"] {
            XCTAssertFalse(WalletService.isSingleEmoji(bad), "'\(bad)'")
        }
        let env = try makeEnv()
        XCTAssertThrowsError(try env.service.create(WalletInput(name: "A", emoji: "ab"))) {
            XCTAssertEqual($0 as? WalletError, .invalidEmoji)
        }
        XCTAssertEqual(try walletCount(env), 0)
    }

    func testOpeningBalanceLimits() throws {
        let env = try makeEnv()
        XCTAssertNoThrow(try env.service.create(
            WalletInput(name: "Max", openingBalanceMinor: Money.maxInputMinorUnits)))
        XCTAssertNoThrow(try env.service.create(
            WalletInput(name: "Overdrawn", openingBalanceMinor: -5_000)))
        for value: Int64 in [Money.maxInputMinorUnits + 1, -(Money.maxInputMinorUnits + 1), .max, .min] {
            XCTAssertThrowsError(try env.service.create(
                WalletInput(name: "Bad", openingBalanceMinor: value)), "\(value)") {
                XCTAssertEqual($0 as? WalletError, .invalidOpeningBalance)
            }
        }
        XCTAssertEqual(try walletCount(env), 2)
    }

    func testCurrencyValidation() throws {
        let env = try makeEnv()
        for code in ["IN", "I1R", "", "INRR"] {
            XCTAssertThrowsError(try env.service.create(WalletInput(name: "A", currencyCode: code)), code) {
                XCTAssertEqual($0 as? WalletError, .invalidCurrency)
            }
        }
        XCTAssertEqual(try walletCount(env), 0)
    }

    func testLimitOfFourActiveWallets() throws {
        let env = try makeEnv()
        var wallets: [Wallet] = []
        for name in ["A", "B", "C", "D"] {
            let wallet = try env.service.create(WalletInput(name: name))
            wallets.append(wallet)
        }
        XCTAssertThrowsError(try env.service.create(WalletInput(name: "E"))) {
            XCTAssertEqual($0 as? WalletError, .walletLimitReached)
        }
        try env.service.archive(wallets[0])
        XCTAssertNoThrow(try env.service.create(WalletInput(name: "E")))
        XCTAssertEqual(try walletCount(env), 5)   // archived wallets are kept
    }

    func testCannotArchiveLastActiveWallet() throws {
        let env = try makeEnv()
        let only = try env.service.create(WalletInput(name: "Cash"))
        XCTAssertThrowsError(try env.service.archive(only)) {
            XCTAssertEqual($0 as? WalletError, .lastActiveWallet)
        }
        XCTAssertFalse(only.isArchived)
    }

    func testArchiveKeepsHistoryAndBalance() throws {
        let env = try makeEnv()
        let bank = try env.service.create(WalletInput(name: "Bank", openingBalanceMinor: 500_000))
        try env.service.create(WalletInput(name: "Cash"))
        try addTransaction(env, wallet: bank, amount: 10_000, kind: .income)
        try addTransaction(env, wallet: bank, amount: 2_500, kind: .expense)

        try env.service.archive(bank)

        let all = try env.context.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(bank.isArchived)
        XCTAssertEqual(try BalanceCalculator.balance(of: bank, transactions: all).minorUnits, 507_500)
    }

    func testUnarchiveRespectsLimitAndNames() throws {
        let env = try makeEnv()
        let a = try env.service.create(WalletInput(name: "A"))
        try env.service.create(WalletInput(name: "B"))
        try env.service.archive(a)
        try env.service.create(WalletInput(name: "a"))        // same name as the archived one
        XCTAssertThrowsError(try env.service.unarchive(a)) {
            XCTAssertEqual($0 as? WalletError, .duplicateName)
        }

        let env2 = try makeEnv()
        var wallets: [Wallet] = []
        for name in ["A", "B", "C", "D"] {
            let wallet = try env2.service.create(WalletInput(name: name))
            wallets.append(wallet)
        }
        try env2.service.archive(wallets[0])
        try env2.service.create(WalletInput(name: "E"))       // four active again
        XCTAssertThrowsError(try env2.service.unarchive(wallets[0])) {
            XCTAssertEqual($0 as? WalletError, .walletLimitReached)
        }
        try env2.service.archive(wallets[1])
        XCTAssertNoThrow(try env2.service.unarchive(wallets[0]))
        XCTAssertFalse(wallets[0].isArchived)
    }

    func testCurrencyLockedAfterFirstTransaction() throws {
        let env = try makeEnv()
        let wallet = try env.service.create(WalletInput(name: "Cash"))
        try env.service.update(wallet, with: WalletInput(name: "Cash", currencyCode: "usd"))
        XCTAssertEqual(wallet.currencyCode, "USD")

        try addTransaction(env, wallet: wallet, amount: 100, kind: .income)
        XCTAssertThrowsError(try env.service.update(wallet, with: WalletInput(name: "Cash", currencyCode: "EUR"))) {
            XCTAssertEqual($0 as? WalletError, .currencyLocked)
        }
        XCTAssertEqual(wallet.currencyCode, "USD")

        try env.service.update(wallet, with: WalletInput(name: "Cash 2", openingBalanceMinor: 1_000, currencyCode: "usd"))
        XCTAssertEqual(wallet.name, "Cash 2")
        XCTAssertEqual(wallet.openingBalanceMinor, 1_000)
    }

    func testUpdateAllowsOwnNameAndRejectsInvalid() throws {
        let env = try makeEnv()
        let wallet = try env.service.create(WalletInput(name: "Cash"))
        try env.service.create(WalletInput(name: "Bank"))

        XCTAssertNoThrow(try env.service.update(wallet, with: WalletInput(name: "cash", emoji: "💵")))
        XCTAssertEqual(wallet.name, "cash")

        XCTAssertThrowsError(try env.service.update(wallet, with: WalletInput(name: "Bank"))) {
            XCTAssertEqual($0 as? WalletError, .duplicateName)
        }
        XCTAssertThrowsError(try env.service.update(wallet, with: WalletInput(name: ""))) {
            XCTAssertEqual($0 as? WalletError, .invalidName)
        }
        XCTAssertEqual(wallet.name, "cash")   // failed updates change nothing
        XCTAssertEqual(wallet.emoji, "💵")
    }
}
