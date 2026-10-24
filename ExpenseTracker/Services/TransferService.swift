import Foundation
import SwiftData

/// `id` becomes the shared transferID, so saving the same draft twice is a safe no-op.
struct TransferDraft: Equatable {
    var id: UUID = UUID()
    var fromWalletID: UUID
    var toWalletID: UUID
    var amountMinor: Int64
    var note: String = ""
    /// nil means "now".
    var timestamp: Date? = nil
}

struct TransferEdit: Equatable {
    var fromWalletID: UUID
    var toWalletID: UUID
    var amountMinor: Int64
    var note: String
    var timestamp: Date
}

enum TransferServiceError: Error, Equatable {
    case sameWallet
    case walletNotFound
    case walletArchived
    case currencyMismatch
    case insufficientFunds(availableMinor: Int64)
    case invalidDate
    case transferNotFound
    /// Missing, duplicated or inconsistent legs. Cannot be edited, can still be deleted.
    case brokenTransfer
}

/// Two intact legs of one transfer.
struct TransferPair {
    let transferID: UUID
    let outLeg: Transaction
    let inLeg: Transaction
}

/// The single path for creating, changing and removing transfers between wallets.
/// Balances are never stored; funds checks use balances calculated from the ledger.
/// Limitation (by decision): the funds check uses the CURRENT balance, not the
/// balance as of the transfer date.
struct TransferService {
    let context: ModelContext
    private let saveAction: (ModelContext) throws -> Void

    init(
        context: ModelContext,
        save: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.context = context
        self.saveAction = save
    }

    // MARK: Create

    @discardableResult
    func save(_ draft: TransferDraft, now: Date = Date()) throws -> SaveResult {
        if try legs(transferID: draft.id).count > 0 { return .alreadySaved }

        guard draft.fromWalletID != draft.toWalletID else { throw TransferServiceError.sameWallet }
        guard let from = try findWallet(id: draft.fromWalletID),
              let to = try findWallet(id: draft.toWalletID)
        else { throw TransferServiceError.walletNotFound }
        guard !from.isArchived, !to.isArchived else { throw TransferServiceError.walletArchived }
        guard from.currencyCode == to.currencyCode else { throw TransferServiceError.currencyMismatch }

        let when = draft.timestamp ?? now
        try validateDate(when, now: now)

        let outLeg = try Transaction.makeValidated(
            amountMinor: draft.amountMinor, kind: .transferOut, walletID: from.id,
            transferID: draft.id, note: draft.note, timestamp: when)
        let inLeg = try Transaction.makeValidated(
            amountMinor: draft.amountMinor, kind: .transferIn, walletID: to.id,
            transferID: draft.id, note: draft.note, timestamp: when)

        try checkFunds(from: from, to: to, amountMinor: draft.amountMinor, excluding: [])

        context.insert(outLeg)
        context.insert(inLeg)
        try commit()
        return .saved
    }

    // MARK: Update

    func update(transferID: UUID, to edit: TransferEdit, now: Date = Date()) throws {
        let pair = try pair(transferID: transferID)

        guard edit.fromWalletID != edit.toWalletID else { throw TransferServiceError.sameWallet }
        guard let from = try findWallet(id: edit.fromWalletID),
              let to = try findWallet(id: edit.toWalletID)
        else { throw TransferServiceError.walletNotFound }
        // Unchanged wallets may be archived; newly chosen ones must be active.
        if edit.fromWalletID != pair.outLeg.walletID, from.isArchived {
            throw TransferServiceError.walletArchived
        }
        if edit.toWalletID != pair.inLeg.walletID, to.isArchived {
            throw TransferServiceError.walletArchived
        }
        guard from.currencyCode == to.currencyCode else { throw TransferServiceError.currencyMismatch }
        try validateDate(edit.timestamp, now: now)

        let cleanNote = edit.note.trimmingCharacters(in: .whitespacesAndNewlines)
        try Transaction.validate(
            amountMinor: edit.amountMinor, kind: .transferOut,
            categoryID: nil, transferID: transferID, note: cleanNote)

        // The transfer's own legs must not count against itself.
        try checkFunds(
            from: from, to: to, amountMinor: edit.amountMinor,
            excluding: [pair.outLeg.id, pair.inLeg.id])

        pair.outLeg.walletID = edit.fromWalletID
        pair.inLeg.walletID = edit.toWalletID
        for leg in [pair.outLeg, pair.inLeg] {
            leg.amountMinor = edit.amountMinor
            leg.note = cleanNote
            leg.timestamp = edit.timestamp
        }
        try commit()
    }

    // MARK: Delete

    /// Removes every row carrying this transferID, so broken transfers (e.g. one
    /// orphan leg) are recoverable. Permanent; the UI must confirm first.
    func delete(transferID: UUID) throws {
        let rows = try legs(transferID: transferID)
        guard !rows.isEmpty else { throw TransferServiceError.transferNotFound }
        for row in rows { context.delete(row) }
        try commit()
    }

    // MARK: Queries

    /// Throws `.transferNotFound` if no rows exist, `.brokenTransfer` if the rows
    /// are not exactly one consistent out/in pair.
    func pair(transferID: UUID) throws -> TransferPair {
        let rows = try legs(transferID: transferID)
        guard !rows.isEmpty else { throw TransferServiceError.transferNotFound }
        guard rows.count == 2,
              let out = rows.first(where: { $0.kind == .transferOut }),
              let inn = rows.first(where: { $0.kind == .transferIn }),
              out.walletID != inn.walletID,
              out.amountMinor == inn.amountMinor,
              out.timestamp == inn.timestamp,
              out.note == inn.note,
              out.categoryID == nil, inn.categoryID == nil
        else { throw TransferServiceError.brokenTransfer }
        return TransferPair(transferID: transferID, outLeg: out, inLeg: inn)
    }

    /// Current balance (minor units) of a wallet, from the ledger.
    func availableBalance(walletID: UUID) throws -> Int64 {
        guard let wallet = try findWallet(id: walletID) else {
            throw TransferServiceError.walletNotFound
        }
        return try balanceMinor(of: wallet, excluding: [])
    }

    /// Active wallets with the same currency as the source, excluding the source.
    func eligibleDestinations(forSource sourceID: UUID) throws -> [Wallet] {
        guard let source = try findWallet(id: sourceID) else {
            throw TransferServiceError.walletNotFound
        }
        let active = try context.fetch(
            FetchDescriptor<Wallet>(
                predicate: #Predicate { $0.isArchived == false },
                sortBy: [SortDescriptor(\.createdAt)]))
        return active.filter { $0.id != sourceID && $0.currencyCode == source.currencyCode }
    }

    // MARK: Private

    private func validateDate(_ date: Date, now: Date) throws {
        guard date >= TransactionService.earliestDate,
              date <= now.addingTimeInterval(TransactionService.futureTolerance)
        else { throw TransferServiceError.invalidDate }
    }

    /// Source must not go below zero; destination must not overflow.
    private func checkFunds(
        from: Wallet, to: Wallet, amountMinor: Int64, excluding: Set<UUID>
    ) throws {
        let available = try balanceMinor(of: from, excluding: excluding)
        guard available >= amountMinor else {
            throw TransferServiceError.insufficientFunds(availableMinor: available)
        }
        let destination = try balanceMinor(of: to, excluding: excluding)
        let (_, overflow) = destination.addingReportingOverflow(amountMinor)
        guard !overflow else { throw BalanceError.overflow }
    }

    private func balanceMinor(of wallet: Wallet, excluding: Set<UUID>) throws -> Int64 {
        let id = wallet.id
        let rows = try context.fetch(
            FetchDescriptor<Transaction>(predicate: #Predicate { $0.walletID == id }))
        let entries = try rows.filter { !excluding.contains($0.id) }.map { try $0.ledgerEntry() }
        return try BalanceCalculator.balanceMinor(
            openingMinor: wallet.openingBalanceMinor, walletID: id, entries: entries)
    }

    private func legs(transferID: UUID) throws -> [Transaction] {
        let target: UUID? = transferID
        return try context.fetch(
            FetchDescriptor<Transaction>(predicate: #Predicate { $0.transferID == target }))
    }

    private func findWallet(id: UUID) throws -> Wallet? {
        var query = FetchDescriptor<Wallet>(predicate: #Predicate { $0.id == id })
        query.fetchLimit = 1
        return try context.fetch(query).first
    }

    private func commit() throws {
        do {
            try saveAction(context)
        } catch {
            context.rollback()
            throw error
        }
    }
}
