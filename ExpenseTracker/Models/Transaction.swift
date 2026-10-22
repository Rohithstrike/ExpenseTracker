import Foundation
import SwiftData

enum TransactionKind: String, Codable, CaseIterable, Sendable {
    case expense, income, transferOut, transferIn
}

enum TransactionValidationError: Error, Equatable {
    case nonPositiveAmount
    case amountTooLarge
    case missingTransferID
    case unexpectedTransferID
    case transferCannotHaveCategory
    case noteTooLong
}

/// A ledger entry. amountMinor is ALWAYS positive; `kind` gives the direction.
/// Wallet and category are referenced by stable UUID, not by SwiftData relationships,
/// so archiving or removing a category can never corrupt history.
/// Create new records with `makeValidated`, which enforces the rules.
@Model
final class Transaction {
    var id: UUID = UUID()
    var amountMinor: Int64 = 0
    var kindRaw: String = TransactionKind.expense.rawValue
    var timestamp: Date = Date()
    var note: String = ""
    var walletID: UUID = UUID()
    var categoryID: UUID?
    var transferID: UUID?

    /// nil if the stored value is unknown (e.g. written by a newer app version).
    var kind: TransactionKind? { TransactionKind(rawValue: kindRaw) }

    init(
        id: UUID = UUID(),
        amountMinor: Int64,
        kind: TransactionKind,
        timestamp: Date = Date(),
        note: String = "",
        walletID: UUID,
        categoryID: UUID? = nil,
        transferID: UUID? = nil
    ) {
        self.id = id
        self.amountMinor = amountMinor
        self.kindRaw = kind.rawValue
        self.timestamp = timestamp
        self.note = note
        self.walletID = walletID
        self.categoryID = categoryID
        self.transferID = transferID
    }
}

extension Transaction {
    static let maxNoteLength = 500

    static func validate(
        amountMinor: Int64,
        kind: TransactionKind,
        categoryID: UUID?,
        transferID: UUID?,
        note: String
    ) throws {
        guard amountMinor > 0 else { throw TransactionValidationError.nonPositiveAmount }
        guard amountMinor <= Money.maxInputMinorUnits else {
            throw TransactionValidationError.amountTooLarge
        }
        switch kind {
        case .expense, .income:
            guard transferID == nil else { throw TransactionValidationError.unexpectedTransferID }
        case .transferOut, .transferIn:
            guard transferID != nil else { throw TransactionValidationError.missingTransferID }
            guard categoryID == nil else { throw TransactionValidationError.transferCannotHaveCategory }
        }
        guard note.count <= maxNoteLength else { throw TransactionValidationError.noteTooLong }
    }

    /// Validates, trims the note, and returns an un-inserted Transaction.
    static func makeValidated(
        amountMinor: Int64,
        kind: TransactionKind,
        walletID: UUID,
        categoryID: UUID? = nil,
        transferID: UUID? = nil,
        note: String = "",
        timestamp: Date = Date()
    ) throws -> Transaction {
        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        try validate(
            amountMinor: amountMinor,
            kind: kind,
            categoryID: categoryID,
            transferID: transferID,
            note: cleanNote
        )
        return Transaction(
            amountMinor: amountMinor,
            kind: kind,
            timestamp: timestamp,
            note: cleanNote,
            walletID: walletID,
            categoryID: categoryID,
            transferID: transferID
        )
    }

    func ledgerEntry() throws -> LedgerEntry {
        guard let kind else { throw BalanceError.unknownKind }
        return LedgerEntry(walletID: walletID, kind: kind, amountMinor: amountMinor)
    }
}
