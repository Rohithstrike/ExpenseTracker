// ExpenseTracker/Services/EntryFormSubmit.swift  (new file)
import Foundation
import SwiftData

enum EntrySubmitOutcome: Equatable {
    /// Saved (or already saved under the same id). The form has been reset and refreshed.
    case saved
    /// The form's own rules blocked Save. No service was called.
    case blocked(EntryIssue)
    /// A service refused or failed. The entry and its submission id are untouched.
    case failed(String)
}

/// Turns "Save was tapped" into a saved record, using the existing services only.
/// No rules live here: the model validates, the services decide and enforce.
struct EntryFormSubmit {
    static let genericFailure = "Couldn't save. Your entry is still here, so please try again."
    static let walletUnavailable = "That wallet is no longer available."
    static let categoryUnavailable = "That category is no longer available."
    static let currencyMismatch = "Both wallets must use the same currency."
    static let sameWallet = "Choose two different wallets."
    static let balanceTooLarge = "That amount would make a wallet balance too large."
    static let amountTooLarge = "That amount is too large."

    let saveTransaction: (TransactionDraft, Date) throws -> SaveResult
    let saveTransfer: (TransferDraft, Date) throws -> SaveResult
    let loadSnapshot: () throws -> EntrySnapshot

    /// Production: the real services and the real store.
    init(context: ModelContext) {
        self.saveTransaction = { draft, now in
            try TransactionService(context: context).save(draft, now: now)
        }
        self.saveTransfer = { draft, now in
            try TransferService(context: context).save(draft, now: now)
        }
        self.loadSnapshot = { try EntrySnapshot.load(from: context) }
    }

    /// Tests inject their own closures.
    init(
        saveTransaction: @escaping (TransactionDraft, Date) throws -> SaveResult,
        saveTransfer: @escaping (TransferDraft, Date) throws -> SaveResult,
        loadSnapshot: @escaping () throws -> EntrySnapshot
    ) {
        self.saveTransaction = saveTransaction
        self.saveTransfer = saveTransfer
        self.loadSnapshot = loadSnapshot
    }

    @discardableResult
    func submit(_ model: inout EntryFormModel, now: Date = Date()) -> EntrySubmitOutcome {
        if let issue = model.validate(now: now).issue { return .blocked(issue) }
        guard let from = model.fromWallet, let money = model.amount.money else {
            return .failed(Self.genericFailure)
        }

        do {
            switch model.mode {
            case .expense, .income:
                let draft = TransactionDraft(
                    id: model.submissionID,
                    kind: model.mode == .income ? .income : .expense,
                    amountMinor: money.minorUnits,
                    walletID: from.id,
                    categoryID: model.effectiveCategoryID,
                    note: model.note,
                    timestamp: model.date)
                _ = try saveTransaction(draft, now)
            case .transfer:
                guard let to = model.toWallet else { return .failed(Self.genericFailure) }
                let draft = TransferDraft(
                    id: model.submissionID,
                    fromWalletID: from.id,
                    toWalletID: to.id,
                    amountMinor: money.minorUnits,
                    note: model.note,
                    timestamp: model.date)
                _ = try saveTransfer(draft, now)
            }
        } catch {
            let message = Self.message(for: error, wallet: from)
            if Self.dataWentStale(error) { refresh(&model) }
            return .failed(message)
        }

        // .saved and .alreadySaved both mean the record exists.
        model.resetAfterSave()
        refresh(&model)
        return .saved
    }

    // MARK: Private

    /// If reloading fails the save still happened, so the form keeps its old snapshot.
    private func refresh(_ model: inout EntryFormModel) {
        if let fresh = try? loadSnapshot() { model.apply(snapshot: fresh) }
    }

    /// Errors that mean the form's snapshot no longer matches the store.
    static func dataWentStale(_ error: Error) -> Bool {
        switch error {
        case let e as TransactionServiceError:
            switch e {
            case .walletNotFound, .walletArchived, .categoryNotFound,
                 .categoryArchived, .walletCurrencyMismatch:
                return true
            default:
                return false
            }
        case let e as TransferServiceError:
            switch e {
            case .walletNotFound, .walletArchived, .currencyMismatch, .insufficientFunds:
                return true
            default:
                return false
            }
        default:
            return false
        }
    }

    static func message(for error: Error, wallet: EntryWallet) -> String {
        switch error {
        case let e as TransactionServiceError:
            switch e {
            case .walletNotFound, .walletArchived: return walletUnavailable
            case .categoryNotFound, .categoryArchived: return categoryUnavailable
            case .categoryRequired: return EntryIssue.categoryRequired.message
            case .walletCurrencyMismatch: return currencyMismatch
            case .invalidDate: return EntryIssue.dateOutOfRange.message
            case .unsupportedKind, .transactionNotFound: return genericFailure
            }
        case let e as TransferServiceError:
            switch e {
            case .sameWallet: return sameWallet
            case .walletNotFound, .walletArchived: return walletUnavailable
            case .currencyMismatch: return currencyMismatch
            case .insufficientFunds(let available):
                return EntryIssue.insufficientFunds(
                    availableMinor: available,
                    currencyCode: wallet.currencyCode,
                    walletName: wallet.name).message
            case .invalidDate: return EntryIssue.dateOutOfRange.message
            case .transferNotFound, .brokenTransfer: return genericFailure
            }
        case let e as TransactionValidationError:
            switch e {
            case .noteTooLong: return EntryIssue.noteTooLong.message
            case .nonPositiveAmount: return EntryIssue.amountMissing.message
            case .amountTooLarge: return amountTooLarge
            default: return genericFailure
            }
        case let e as BalanceError:
            return e == .overflow ? balanceTooLarge : genericFailure
        default:
            return genericFailure
        }
    }
}
