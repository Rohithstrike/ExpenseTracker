import XCTest
import SwiftData
@testable import ExpenseTracker

@MainActor
final class TransferServiceTests: XCTestCase {
    private struct InjectedFailure: Error {}
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Env {
        let container: ModelContainer
        let context: ModelContext
        let cash: Wallet      // INR 100_000
        let bank: Wallet      // INR 50_000
        let usd: Wallet       // USD 100_000
        let old: Wallet       // INR 5_000, archived
        let food: ExpenseTracker.Category
        var transfers: TransferService { TransferService(context: context) }
        var failing: TransferService {
            TransferService(context: context, save: { _ in throw InjectedFailure() })
        }
        var balances: WalletBalanceService { WalletBalanceService(context: context) }
    }

    private func makeEnv() throws -> Env {
        let container = try AppDataStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let ws = WalletService(context: context)
        let cash = try ws.create(WalletInput(name: "Cash", openingBalanceMinor: 100_000))
        let bank = try ws.create(WalletInput(name: "Bank", openingBalanceMinor: 50_000))
        let usd = try ws.create(WalletInput(name: "Dollar", openingBalanceMinor: 100_000, currencyCode: "USD"))
        let old = try ws.create(WalletInput(name: "Old", openingBalanceMinor: 5_000))
        try ws.archive(old)
        let food = ExpenseTracker.Category(name: "Food")
        context.insert(food)
        try context.save()
        return Env(container: container, context: context, cash: cash, bank: bank,
                   usd: usd, old: old, food: food)
    }

    private func bal(_ env: Env, _ wallet: Wallet) throws -> Int64 {
        try env.balances.balance(of: wallet).minorUnits
    }

    private func draft(_ env: Env, from: Wallet? = nil, to: Wallet? = nil,
                       amount: Int64 = 10_000, note: String = "") -> TransferDraft {
        TransferDraft(fromWalletID: (from ?? env.cash).id, toWalletID: (to ?? env.bank).id,
                      amountMinor: amount, note: note)
    }

    private func edit(_ env: Env, from: Wallet? = nil, to: Wallet? = nil,
                      amount: Int64, note: String = "", at: Date? = nil) -> TransferEdit {
        TransferEdit(fromWalletID: (from ?? env.cash).id, toWalletID: (to ?? env.bank).id,
                     amountMinor: amount, note: note, timestamp: at ?? now)
    }

    private func rows(_ env: Env, _ transferID: UUID) throws -> [Transaction] {
        let target: UUID? = transferID
        return try env.context.fetch(
            FetchDescriptor<Transaction>(predicate: #Predicate { $0.transferID == target }))
    }

    private func totalCount(_ env: Env) throws -> Int {
        try env.context.fetchCount(FetchDescriptor<Transaction>())
    }

    private func assertThrows<T, E: Error & Equatable>(
        _ expected: E, file: StaticString = #filePath, line: UInt = #line,
        _ body: () throws -> T
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual($0 as? E, expected, file: file, line: line)
        }
    }

    // MARK: Creation

    func testTransferMovesMoneyAndKeepsCombinedBalance() throws {
        let env = try makeEnv()
        let before = try bal(env, env.cash) + bal(env, env.bank)
        XCTAssertEqual(try env.transfers.save(draft(env), now: now), .saved)
        XCTAssertEqual(try bal(env, env.cash), 90_000)
        XCTAssertEqual(try bal(env, env.bank), 60_000)
        XCTAssertEqual(try bal(env, env.cash) + bal(env, env.bank), before)
    }

    func testLegsShareMetadataAndHaveOwnIDs() throws {
        let env = try makeEnv()
        let d = draft(env, note: "  rent ")
        try env.transfers.save(d, now: now)
        let legs = try rows(env, d.id)
        XCTAssertEqual(legs.count, 2)
        let out = try XCTUnwrap(legs.first { $0.kind == .transferOut })
        let inn = try XCTUnwrap(legs.first { $0.kind == .transferIn })
        XCTAssertNotEqual(out.id, inn.id)
        XCTAssertEqual(out.walletID, env.cash.id)
        XCTAssertEqual(inn.walletID, env.bank.id)
        XCTAssertEqual(out.transferID, d.id)
        XCTAssertEqual(inn.transferID, d.id)
        XCTAssertEqual(out.amountMinor, 10_000)
        XCTAssertEqual(inn.amountMinor, 10_000)
        XCTAssertEqual(out.note, "rent")
        XCTAssertEqual(inn.note, "rent")
        XCTAssertEqual(out.timestamp, now)
        XCTAssertEqual(inn.timestamp, now)
        XCTAssertNil(out.categoryID)
        XCTAssertNil(inn.categoryID)
    }

    func testTransferPersistsAfterReopeningStore() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransferTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("test.store")

        var d: TransferDraft!
        var cashID: UUID!
        var bankID: UUID!
        do {
            let container = try AppDataStore.makeContainer(storeURL: url)
            let context = ModelContext(container)
            let ws = WalletService(context: context)
            let cash = try ws.create(WalletInput(name: "Cash", openingBalanceMinor: 100_000))
            let bank = try ws.create(WalletInput(name: "Bank", openingBalanceMinor: 50_000))
            cashID = cash.id
            bankID = bank.id
            d = TransferDraft(fromWalletID: cash.id, toWalletID: bank.id, amountMinor: 25_000)
            try TransferService(context: context).save(d, now: now)
        }

        let container = try AppDataStore.makeContainer(storeURL: url)
        let context = ModelContext(container)
        let wallets = try context.fetch(FetchDescriptor<Wallet>())
        let cash = try XCTUnwrap(wallets.first { $0.id == cashID })
        let bank = try XCTUnwrap(wallets.first { $0.id == bankID })
        let balances = WalletBalanceService(context: context)
        XCTAssertEqual(try balances.balance(of: cash).minorUnits, 75_000)
        XCTAssertEqual(try balances.balance(of: bank).minorUnits, 75_000)
        XCTAssertNoThrow(try TransferService(context: context).pair(transferID: d.id))
        XCTAssertEqual(try TransferService(context: context).save(d, now: now), .alreadySaved)
    }

    func testRepeatedSubmissionDoesNotDuplicate() throws {
        let env = try makeEnv()
        let d = draft(env)
        XCTAssertEqual(try env.transfers.save(d, now: now), .saved)
        XCTAssertEqual(try env.transfers.save(d, now: now), .alreadySaved)
        XCTAssertEqual(try totalCount(env), 2)
        XCTAssertEqual(try bal(env, env.cash), 90_000)
    }

    // MARK: Wallet validation

    func testSameWalletRejected() throws {
        let env = try makeEnv()
        assertThrows(TransferServiceError.sameWallet) {
            try env.transfers.save(draft(env, from: env.cash, to: env.cash), now: now)
        }
        XCTAssertEqual(try totalCount(env), 0)
    }

    func testUnknownWalletsRejected() throws {
        let env = try makeEnv()
        var d = draft(env)
        d.toWalletID = UUID()
        assertThrows(TransferServiceError.walletNotFound) { try env.transfers.save(d, now: now) }
        d = draft(env)
        d.fromWalletID = UUID()
        assertThrows(TransferServiceError.walletNotFound) { try env.transfers.save(d, now: now) }
    }

    func testArchivedWalletsRejectedOnEitherSide() throws {
        let env = try makeEnv()
        assertThrows(TransferServiceError.walletArchived) {
            try env.transfers.save(draft(env, to: env.old), now: now)
        }
        assertThrows(TransferServiceError.walletArchived) {
            try env.transfers.save(draft(env, from: env.old, to: env.cash, amount: 1), now: now)
        }
        XCTAssertEqual(try totalCount(env), 0)
    }

    func testCurrencyMismatchRejected() throws {
        let env = try makeEnv()
        assertThrows(TransferServiceError.currencyMismatch) {
            try env.transfers.save(draft(env, to: env.usd), now: now)
        }
        XCTAssertEqual(try totalCount(env), 0)
    }

    // MARK: Amount, date, note

    func testInvalidAmountsRejected() throws {
        let env = try makeEnv()
        assertThrows(TransactionValidationError.nonPositiveAmount) {
            try env.transfers.save(draft(env, amount: 0), now: now)
        }
        assertThrows(TransactionValidationError.nonPositiveAmount) {
            try env.transfers.save(draft(env, amount: -1), now: now)
        }
        assertThrows(TransactionValidationError.amountTooLarge) {
            try env.transfers.save(draft(env, amount: Money.maxInputMinorUnits + 1), now: now)
        }
        XCTAssertEqual(try totalCount(env), 0)
    }

    func testDateWindow() throws {
        let env = try makeEnv()
        var d = draft(env, amount: 100)
        d.timestamp = TransactionService.earliestDate.addingTimeInterval(-1)
        assertThrows(TransferServiceError.invalidDate) { try env.transfers.save(d, now: now) }

        d = draft(env, amount: 100)
        d.timestamp = now.addingTimeInterval(TransactionService.futureTolerance + 1)
        assertThrows(TransferServiceError.invalidDate) { try env.transfers.save(d, now: now) }

        d = draft(env, amount: 100)
        d.timestamp = now.addingTimeInterval(TransactionService.futureTolerance)
        XCTAssertEqual(try env.transfers.save(d, now: now), .saved)

        d = draft(env, amount: 100)
        d.timestamp = TransactionService.earliestDate
        XCTAssertEqual(try env.transfers.save(d, now: now), .saved)
    }

    func testNoteRules() throws {
        let env = try makeEnv()
        let tooLong = String(repeating: "a", count: Transaction.maxNoteLength + 1)
        assertThrows(TransactionValidationError.noteTooLong) {
            try env.transfers.save(draft(env, note: tooLong), now: now)
        }
        XCTAssertEqual(try totalCount(env), 0)
        let maxNote = String(repeating: "a", count: Transaction.maxNoteLength)
        XCTAssertEqual(try env.transfers.save(draft(env, amount: 100, note: maxNote), now: now), .saved)
    }

    // MARK: Funds and overflow

    func testInsufficientFundsRejectedAndExactBalanceAllowed() throws {
        let env = try makeEnv()
        assertThrows(TransferServiceError.insufficientFunds(availableMinor: 100_000)) {
            try env.transfers.save(draft(env, amount: 100_001), now: now)
        }
        XCTAssertEqual(try totalCount(env), 0)

        XCTAssertEqual(try env.transfers.save(draft(env, amount: 100_000), now: now), .saved)
        XCTAssertEqual(try bal(env, env.cash), 0)
        assertThrows(TransferServiceError.insufficientFunds(availableMinor: 0)) {
            try env.transfers.save(draft(env, amount: 1), now: now)
        }
    }

    func testFundsCheckUsesBalanceAfterOrdinaryTransactions() throws {
        let env = try makeEnv()
        try TransactionService(context: env.context).save(
            TransactionDraft(kind: .expense, amountMinor: 2_500, walletID: env.cash.id,
                             categoryID: env.food.id))
        assertThrows(TransferServiceError.insufficientFunds(availableMinor: 97_500)) {
            try env.transfers.save(draft(env, amount: 97_501), now: now)
        }
        XCTAssertEqual(try env.transfers.availableBalance(walletID: env.cash.id), 97_500)
        XCTAssertEqual(try env.transfers.save(draft(env, amount: 97_500), now: now), .saved)
    }

    func testDestinationOverflowRejected() throws {
        let env = try makeEnv()
        env.bank.openingBalanceMinor = Int64.max - 10
        try env.context.save()
        assertThrows(BalanceError.overflow) {
            try env.transfers.save(draft(env, amount: 100), now: now)
        }
        XCTAssertEqual(try totalCount(env), 0)
    }

    func testEligibleDestinations() throws {
        let env = try makeEnv()
        let ids = try env.transfers.eligibleDestinations(forSource: env.cash.id).map(\.id)
        XCTAssertEqual(ids, [env.bank.id])   // not itself, not USD, not archived
        XCTAssertEqual(try env.transfers.eligibleDestinations(forSource: env.usd.id).count, 0)
    }

    // MARK: Rollback

    func testCreateRollsBackAfterSaveFailure() throws {
        let env = try makeEnv()
        let d = draft(env)
        XCTAssertThrowsError(try env.failing.save(d, now: now)) {
            XCTAssertTrue($0 is InjectedFailure)
        }
        XCTAssertEqual(try totalCount(env), 0)
        XCTAssertEqual(try bal(env, env.cash), 100_000)
        XCTAssertEqual(try bal(env, env.bank), 50_000)
        // Nothing persisted, so retrying the same draft succeeds.
        XCTAssertEqual(try env.transfers.save(d, now: now), .saved)
        XCTAssertEqual(try totalCount(env), 2)
    }

    func testUpdateRollsBackAfterSaveFailure() throws {
        let env = try makeEnv()
        let d = draft(env)
        try env.transfers.save(d, now: now)
        XCTAssertThrowsError(
            try env.failing.update(transferID: d.id, to: edit(env, amount: 20_000, note: "x"), now: now)
        ) { XCTAssertTrue($0 is InjectedFailure) }
        let pair = try env.transfers.pair(transferID: d.id)
        XCTAssertEqual(pair.outLeg.amountMinor, 10_000)
        XCTAssertEqual(pair.inLeg.amountMinor, 10_000)
        XCTAssertEqual(pair.outLeg.note, "")
        XCTAssertEqual(try bal(env, env.cash), 90_000)
    }

    func testDeleteRollsBackAfterSaveFailure() throws {
        let env = try makeEnv()
        let d = draft(env)
        try env.transfers.save(d, now: now)
        XCTAssertThrowsError(try env.failing.delete(transferID: d.id)) {
            XCTAssertTrue($0 is InjectedFailure)
        }
        XCTAssertEqual(try rows(env, d.id).count, 2)
        XCTAssertEqual(try bal(env, env.cash), 90_000)
    }

    // MARK: Editing

    func testEditUpdatesBothLegsTogether() throws {
        let env = try makeEnv()
        let d = draft(env)
        try env.transfers.save(d, now: now)
        let later = now.addingTimeInterval(3_600)
        try env.transfers.update(
            transferID: d.id,
            to: edit(env, amount: 20_000, note: "  updated ", at: later),
            now: now)
        let pair = try env.transfers.pair(transferID: d.id)
        for leg in [pair.outLeg, pair.inLeg] {
            XCTAssertEqual(leg.amountMinor, 20_000)
            XCTAssertEqual(leg.note, "updated")
            XCTAssertEqual(leg.timestamp, later)
        }
        XCTAssertEqual(try bal(env, env.cash), 80_000)
        XCTAssertEqual(try bal(env, env.bank), 70_000)
    }

    func testEditCanChangeWalletsAndDirection() throws {
        let env = try makeEnv()
        let ws = WalletService(context: env.context)
        let third = try ws.create(WalletInput(name: "Third", openingBalanceMinor: 0))
        let d = draft(env)   // cash -> bank, 10_000
        try env.transfers.save(d, now: now)

        // Move the destination: bank -> third.
        try env.transfers.update(transferID: d.id,
                                 to: edit(env, from: env.bank, to: third, amount: 10_000), now: now)
        XCTAssertEqual(try bal(env, env.cash), 100_000)
        XCTAssertEqual(try bal(env, env.bank), 40_000)
        XCTAssertEqual(try bal(env, third), 10_000)

        // Reverse direction relative to the original: bank -> cash.
        try env.transfers.update(transferID: d.id,
                                 to: edit(env, from: env.bank, to: env.cash, amount: 10_000), now: now)
        XCTAssertEqual(try bal(env, env.cash), 110_000)
        XCTAssertEqual(try bal(env, env.bank), 40_000)
        XCTAssertEqual(try bal(env, third), 0)

        // An edit that would overdraw the new source is still rejected, and changes nothing.
        assertThrows(TransferServiceError.insufficientFunds(availableMinor: 0)) {
            try env.transfers.update(transferID: d.id,
                                     to: edit(env, from: third, to: env.cash, amount: 1), now: now)
        }
        XCTAssertEqual(try bal(env, env.cash), 110_000)
        XCTAssertEqual(try bal(env, third), 0)
    }
    
    func testEditFundsCheckIgnoresTheTransfersOwnLegs() throws {
        let env = try makeEnv()
        let d = draft(env)
        try env.transfers.save(d, now: now)
        // Cash is at 90_000 now, but without this transfer it is 100_000.
        XCTAssertNoThrow(try env.transfers.update(transferID: d.id, to: edit(env, amount: 100_000), now: now))
        assertThrows(TransferServiceError.insufficientFunds(availableMinor: 100_000)) {
            try env.transfers.update(transferID: d.id, to: edit(env, amount: 100_001), now: now)
        }
        XCTAssertEqual(try bal(env, env.cash), 0)
    }

    func testEditValidationFailuresLeaveTransferUnchanged() throws {
        let env = try makeEnv()
        let d = draft(env)
        try env.transfers.save(d, now: now)
        assertThrows(TransferServiceError.sameWallet) {
            try env.transfers.update(transferID: d.id, to: edit(env, from: env.cash, to: env.cash, amount: 1), now: now)
        }
        assertThrows(TransferServiceError.currencyMismatch) {
            try env.transfers.update(transferID: d.id, to: edit(env, to: env.usd, amount: 1), now: now)
        }
        assertThrows(TransferServiceError.walletArchived) {
            try env.transfers.update(transferID: d.id, to: edit(env, to: env.old, amount: 1), now: now)
        }
        assertThrows(TransferServiceError.walletNotFound) {
            var e = edit(env, amount: 1)
            e.toWalletID = UUID()
            return try env.transfers.update(transferID: d.id, to: e, now: now)
        }
        assertThrows(TransferServiceError.invalidDate) {
            try env.transfers.update(transferID: d.id,
                                     to: edit(env, amount: 1, at: TransactionService.earliestDate.addingTimeInterval(-1)),
                                     now: now)
        }
        assertThrows(TransactionValidationError.nonPositiveAmount) {
            try env.transfers.update(transferID: d.id, to: edit(env, amount: 0), now: now)
        }
        assertThrows(TransactionValidationError.noteTooLong) {
            try env.transfers.update(
                transferID: d.id,
                to: edit(env, amount: 1, note: String(repeating: "a", count: 501)),
                now: now)
        }
        assertThrows(TransferServiceError.transferNotFound) {
            try env.transfers.update(transferID: UUID(), to: edit(env, amount: 1), now: now)
        }
        XCTAssertEqual(try env.transfers.pair(transferID: d.id).outLeg.amountMinor, 10_000)
        XCTAssertEqual(try bal(env, env.cash), 90_000)
    }

    // MARK: Delete and broken transfers

    func testDeleteRemovesBothLegsAndRestoresBalances() throws {
        let env = try makeEnv()
        let d = draft(env)
        try env.transfers.save(d, now: now)
        try env.transfers.delete(transferID: d.id)
        XCTAssertEqual(try totalCount(env), 0)
        XCTAssertEqual(try bal(env, env.cash), 100_000)
        XCTAssertEqual(try bal(env, env.bank), 50_000)
        assertThrows(TransferServiceError.transferNotFound) {
            try env.transfers.delete(transferID: d.id)
        }
    }

    func testOrphanLegCannotBeEditedButCanBeDeleted() throws {
        let env = try makeEnv()
        let d = draft(env)
        try env.transfers.save(d, now: now)
        let inLeg = try XCTUnwrap(try rows(env, d.id).first { $0.kind == .transferIn })
        env.context.delete(inLeg)
        try env.context.save()

        assertThrows(TransferServiceError.brokenTransfer) {
            try env.transfers.pair(transferID: d.id)
        }
        assertThrows(TransferServiceError.brokenTransfer) {
            try env.transfers.update(transferID: d.id, to: edit(env, amount: 5_000), now: now)
        }
        try env.transfers.delete(transferID: d.id)
        XCTAssertEqual(try totalCount(env), 0)
    }

    func testInconsistentLegsAreTreatedAsBroken() throws {
        let env = try makeEnv()
        let d = draft(env)
        try env.transfers.save(d, now: now)
        let inLeg = try XCTUnwrap(try rows(env, d.id).first { $0.kind == .transferIn })
        inLeg.amountMinor = 9_999
        try env.context.save()
        assertThrows(TransferServiceError.brokenTransfer) {
            try env.transfers.update(transferID: d.id, to: edit(env, amount: 5_000), now: now)
        }
        try env.transfers.delete(transferID: d.id)
        XCTAssertEqual(try totalCount(env), 0)
    }

    // MARK: Ordinary transactions unaffected

    func testOrdinaryTransactionsAreIndependentOfTransfers() throws {
        let env = try makeEnv()
        let txn = TransactionService(context: env.context)
        let d = draft(env)
        try env.transfers.save(d, now: now)

        let expense = TransactionDraft(kind: .expense, amountMinor: 2_500,
                                       walletID: env.cash.id, categoryID: env.food.id)
        XCTAssertEqual(try txn.save(expense), .saved)
        XCTAssertEqual(try bal(env, env.cash), 87_500)
        XCTAssertEqual(try bal(env, env.bank), 60_000)

        // The ordinary service still refuses transfer legs.
        let leg = try XCTUnwrap(try rows(env, d.id).first)
        assertThrows(TransactionServiceError.unsupportedKind) { try txn.delete(id: leg.id) }
        // And deleting an ordinary row doesn't touch the transfer.
        try txn.delete(id: expense.id)
        XCTAssertEqual(try rows(env, d.id).count, 2)
    }
}
