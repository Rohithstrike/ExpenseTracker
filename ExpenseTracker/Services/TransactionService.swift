// ExpenseTracker/Services/TransactionService.swift  (replaces existing contents)
import Foundation
import SwiftData

struct TransactionDraft: Equatable {
    var id: UUID = UUID()
    var kind: TransactionKind
    var amountMinor: Int64
    var walletID: UUID
    var categoryID: UUID?
    var note: String = ""
}

enum SaveResult: Equatable {
    case saved
    case alreadySaved
}

enum TransactionServiceError: Error, Equatable {
    case unsupportedKind
    case walletNotFound
    case walletArchived
    case categoryRequired
    case categoryNotFound
    case categoryArchived
    case transactionNotFound
    case invalidDate
    case walletCurrencyMismatch
}

/// Every editable field of an ordinary (expense or income) transaction.
struct TransactionEdit: Equatable {
    var kind: TransactionKind
    var amountMinor: Int64
    var walletID: UUID
    var categoryID: UUID?
    var note: String
    var timestamp: Date
}

/// The single path for creating, changing and removing ordinary income and
/// expenses (manual entry now, Shortcuts later). Transfers arrive in Phase 5.
struct TransactionService {
    /// Earliest and latest (relative to now) dates a transaction may carry.
    static let earliestDate = Date(timeIntervalSince1970: 946_684_800)   // 2000-01-01 UTC
    static let futureTolerance: TimeInterval = 24 * 60 * 60

    let context: ModelContext

    // MARK: Create

    /// Saving the same draft id twice is a safe no-op.
    @discardableResult
    func save(_ draft: TransactionDraft, now: Date = Date()) throws -> SaveResult {
        guard draft.kind == .expense || draft.kind == .income else {
            throw TransactionServiceError.unsupportedKind
        }
        if try findTransaction(id: draft.id) != nil { return .alreadySaved }

        guard let wallet = try findWallet(id: draft.walletID) else {
            throw TransactionServiceError.walletNotFound
        }
        guard !wallet.isArchived else { throw TransactionServiceError.walletArchived }

        if let categoryID = draft.categoryID {
            guard let category = try findCategory(id: categoryID) else {
                throw TransactionServiceError.categoryNotFound
            }
            guard !category.isArchived else { throw TransactionServiceError.categoryArchived }
        } else if draft.kind == .expense {
            throw TransactionServiceError.categoryRequired
        }

        let created = try Transaction.makeValidated(
            amountMinor: draft.amountMinor,
            kind: draft.kind,
            walletID: draft.walletID,
            categoryID: draft.categoryID,
            note: draft.note,
            timestamp: now
        )
        created.id = draft.id

        context.insert(created)
        try commit()
        return .saved
    }

    // MARK: Update

    func update(id: UUID, to edit: TransactionEdit, now: Date = Date()) throws {
        guard let existing = try findTransaction(id: id) else {
            throw TransactionServiceError.transactionNotFound
        }
        guard let currentKind = existing.kind, currentKind == .expense || currentKind == .income else {
            throw TransactionServiceError.unsupportedKind
        }
        guard edit.kind == .expense || edit.kind == .income else {
            throw TransactionServiceError.unsupportedKind
        }
        guard edit.timestamp >= Self.earliestDate,
              edit.timestamp <= now.addingTimeInterval(Self.futureTolerance)
        else { throw TransactionServiceError.invalidDate }

        // Wallet: unchanged is always fine; a new one must be active and share the currency.
        guard let targetWallet = try findWallet(id: edit.walletID) else {
            throw TransactionServiceError.walletNotFound
        }
        if edit.walletID != existing.walletID {
            guard !targetWallet.isArchived else { throw TransactionServiceError.walletArchived }
            if let currentWallet = try findWallet(id: existing.walletID),
               currentWallet.currencyCode != targetWallet.currencyCode {
                throw TransactionServiceError.walletCurrencyMismatch
            }
        }

        // Category: unchanged is always fine; a new one must exist and be active.
        if let categoryID = edit.categoryID {
            guard let category = try findCategory(id: categoryID) else {
                throw TransactionServiceError.categoryNotFound
            }
            if categoryID != existing.categoryID, category.isArchived {
                throw TransactionServiceError.categoryArchived
            }
        } else if edit.kind == .expense {
            throw TransactionServiceError.categoryRequired
        }

        // Same amount, size and note rules as creating a transaction.
        let cleanNote = edit.note.trimmingCharacters(in: .whitespacesAndNewlines)
        try Transaction.validate(
            amountMinor: edit.amountMinor,
            kind: edit.kind,
            categoryID: edit.categoryID,
            transferID: nil,
            note: cleanNote
        )

        existing.amountMinor = edit.amountMinor
        existing.kindRaw = edit.kind.rawValue
        existing.walletID = edit.walletID
        existing.categoryID = edit.categoryID
        existing.note = cleanNote
        existing.timestamp = edit.timestamp
        try commit()
    }

    // MARK: Delete

    /// Permanent. The UI must ask for confirmation first.
    func delete(id: UUID) throws {
        guard let existing = try findTransaction(id: id) else {
            throw TransactionServiceError.transactionNotFound
        }
        guard let kind = existing.kind, kind == .expense || kind == .income else {
            throw TransactionServiceError.unsupportedKind
        }
        context.delete(existing)
        try commit()
    }

    // MARK: Private

    private func findTransaction(id: UUID) throws -> Transaction? {
        var query = FetchDescriptor<Transaction>(predicate: #Predicate { $0.id == id })
        query.fetchLimit = 1
        return try context.fetch(query).first
    }

    private func findWallet(id: UUID) throws -> Wallet? {
        var query = FetchDescriptor<Wallet>(predicate: #Predicate { $0.id == id })
        query.fetchLimit = 1
        return try context.fetch(query).first
    }

    private func findCategory(id: UUID) throws -> Category? {
        var query = FetchDescriptor<Category>(predicate: #Predicate { $0.id == id })
        query.fetchLimit = 1
        return try context.fetch(query).first
    }

    private func commit() throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}
