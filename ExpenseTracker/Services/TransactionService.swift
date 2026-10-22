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
}

/// The single save path for ordinary income and expenses (manual entry now,
/// Shortcuts later). Saving the same draft id twice is a safe no-op.
struct TransactionService {
    let context: ModelContext

    @discardableResult
    func save(_ draft: TransactionDraft, now: Date = Date()) throws -> SaveResult {
        guard draft.kind == .expense || draft.kind == .income else {
            throw TransactionServiceError.unsupportedKind
        }

        // Idempotency: this draft was already saved.
        let draftID = draft.id
        var existing = FetchDescriptor<Transaction>(predicate: #Predicate { $0.id == draftID })
        existing.fetchLimit = 1
        let found = try context.fetch(existing)
        if !found.isEmpty { return .alreadySaved }

        // Wallet must exist and be active.
        let walletID = draft.walletID
        var walletQuery = FetchDescriptor<Wallet>(predicate: #Predicate { $0.id == walletID })
        walletQuery.fetchLimit = 1
        guard let wallet = try context.fetch(walletQuery).first else {
            throw TransactionServiceError.walletNotFound
        }
        guard !wallet.isArchived else { throw TransactionServiceError.walletArchived }

        // Category: required for expenses, optional for income; if given, must be active.
        if let categoryID = draft.categoryID {
            var categoryQuery = FetchDescriptor<Category>(predicate: #Predicate { $0.id == categoryID })
            categoryQuery.fetchLimit = 1
            guard let category = try context.fetch(categoryQuery).first else {
                throw TransactionServiceError.categoryNotFound
            }
            guard !category.isArchived else { throw TransactionServiceError.categoryArchived }
        } else if draft.kind == .expense {
            throw TransactionServiceError.categoryRequired
        }

        // Phase 2 validation (amount > 0, limits, note length).
        let transaction = try Transaction.makeValidated(
            amountMinor: draft.amountMinor,
            kind: draft.kind,
            walletID: draft.walletID,
            categoryID: draft.categoryID,
            note: draft.note,
            timestamp: now
        )
        transaction.id = draft.id

        context.insert(transaction)
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return .saved
    }
}
