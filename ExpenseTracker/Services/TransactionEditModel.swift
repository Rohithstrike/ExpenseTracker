import Foundation
import SwiftData

struct EditWalletOption: Equatable, Identifiable {
    let id: UUID
    let name: String
    let emoji: String
    let currencyCode: String
    let isArchived: Bool
    var label: String { "\(emoji) \(name)\(isArchived ? " (archived)" : "")" }
}

struct EditCategoryOption: Equatable, Identifiable {
    let id: UUID
    let name: String
    let emoji: String
    let isArchived: Bool
    var label: String { "\(emoji) \(name)\(isArchived ? " (archived)" : "")" }
}

/// Every wallet and category (archived ones too, because history can point at them).
struct EditOptions: Equatable {
    var wallets: [EditWalletOption]
    var categories: [EditCategoryOption]

    static func load(from context: ModelContext) throws -> EditOptions {
        let wallets = try context.fetch(FetchDescriptor<Wallet>(sortBy: [SortDescriptor(\.createdAt)]))
        let categories = try context.fetch(FetchDescriptor<Category>(sortBy: [SortDescriptor(\.name)]))
        return EditOptions(
            wallets: wallets.map {
                EditWalletOption(id: $0.id, name: $0.name, emoji: $0.emoji,
                                 currencyCode: $0.currencyCode, isArchived: $0.isArchived)
            },
            categories: categories.map {
                EditCategoryOption(id: $0.id, name: $0.name, emoji: $0.emoji, isArchived: $0.isArchived)
            })
    }
}

enum EditIssue: Equatable {
    case amountMissing, categoryRequired, sameWallet, noteTooLong

    var message: String {
        switch self {
        case .amountMissing: return "Enter an amount greater than zero."
        case .categoryRequired: return "Choose a category."
        case .sameWallet: return "Choose two different wallets."
        case .noteTooLong: return "The note is too long. Use up to \(Transaction.maxNoteLength) characters."
        }
    }
}

/// Plain-value state of the edit sheet. It explains problems early; the services stay the
/// authority and re-check everything when saving.
struct TransactionEditModel: Equatable {
    enum Target: Equatable {
        case ordinary(id: UUID)
        case transfer(transferID: UUID)
    }

    let target: Target
    let options: EditOptions
    let currencyCode: String
    let originalWalletID: UUID
    let originalToWalletID: UUID?
    let originalCategoryID: UUID?

    var kind: TransactionKind
    var amount: AmountInput
    /// The wallet of an expense or income, or the From wallet of a transfer.
    var walletID: UUID
    var toWalletID: UUID?
    var categoryID: UUID?
    var date: Date
    var note: String

    private init(
        target: Target, options: EditOptions, currencyCode: String,
        originalWalletID: UUID, originalToWalletID: UUID?, originalCategoryID: UUID?,
        kind: TransactionKind, amount: AmountInput, walletID: UUID, toWalletID: UUID?,
        categoryID: UUID?, date: Date, note: String
    ) {
        self.target = target
        self.options = options
        self.currencyCode = currencyCode
        self.originalWalletID = originalWalletID
        self.originalToWalletID = originalToWalletID
        self.originalCategoryID = originalCategoryID
        self.kind = kind
        self.amount = amount
        self.walletID = walletID
        self.toWalletID = toWalletID
        self.categoryID = categoryID
        self.date = date
        self.note = note
    }

    /// nil when the row cannot be edited (an incomplete transfer, or a transfer whose
    /// other wallet is unknown). Those can still be deleted.
    static func make(
        row: HistoryRow, walletID: UUID, currencyCode: String, options: EditOptions,
        decimalSeparator: Character = "."
    ) -> TransactionEditModel? {
        guard !row.isBrokenTransfer else { return nil }
        var amount = AmountInput(currencyCode: currencyCode, decimalSeparator: decimalSeparator)
        amount.load(minorUnits: row.amountMinor)
        switch row.kind {
        case .expense, .income:
            return TransactionEditModel(
                target: .ordinary(id: row.id), options: options, currencyCode: currencyCode,
                originalWalletID: walletID, originalToWalletID: nil, originalCategoryID: row.categoryID,
                kind: row.kind, amount: amount, walletID: walletID, toWalletID: nil,
                categoryID: row.categoryID, date: row.timestamp, note: row.note)
        case .transferOut, .transferIn:
            guard let transferID = row.transferID, let other = row.counterpartWalletID else { return nil }
            let from = row.kind == .transferOut ? walletID : other
            let to = row.kind == .transferOut ? other : walletID
            return TransactionEditModel(
                target: .transfer(transferID: transferID), options: options, currencyCode: currencyCode,
                originalWalletID: from, originalToWalletID: to, originalCategoryID: nil,
                kind: .transferOut, amount: amount, walletID: from, toWalletID: to,
                categoryID: nil, date: row.timestamp, note: row.note)
        }
    }

    // MARK: Choices

    /// Same currency only, and archived wallets only when the transaction already uses them.
    var walletChoices: [EditWalletOption] {
        options.wallets.filter {
            $0.currencyCode == currencyCode
                && (!$0.isArchived || $0.id == originalWalletID || $0.id == originalToWalletID)
        }
    }

    var destinationChoices: [EditWalletOption] { walletChoices.filter { $0.id != walletID } }

    var categoryChoices: [EditCategoryOption] {
        options.categories.filter { !$0.isArchived || $0.id == originalCategoryID }
    }

    var isTransfer: Bool {
        if case .transfer = target { return true }
        return false
    }

    var currencySymbol: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        return formatter.currencySymbol ?? currencyCode
    }

    // MARK: Changes

    mutating func setKind(_ newKind: TransactionKind) {
        guard !isTransfer, newKind == .expense || newKind == .income else { return }
        kind = newKind
    }

    mutating func setWallet(_ id: UUID?) {
        guard let id, walletChoices.contains(where: { $0.id == id }) else { return }
        walletID = id
        if isTransfer, toWalletID == nil || toWalletID == id {
            toWalletID = destinationChoices.first?.id
        }
    }

    mutating func setToWallet(_ id: UUID?) {
        guard isTransfer, let id, destinationChoices.contains(where: { $0.id == id }) else { return }
        toWalletID = id
    }

    mutating func setCategory(_ id: UUID?) {
        guard !isTransfer else { return }
        guard let id else { categoryID = nil; return }
        if categoryChoices.contains(where: { $0.id == id }) { categoryID = id }
    }

    mutating func setDate(_ newDate: Date) { date = newDate }
    mutating func setNote(_ text: String) { note = String(text.prefix(Transaction.maxNoteLength)) }

    // MARK: Validation and results

    func validate() -> EditIssue? {
        guard let money = amount.money, money.minorUnits > 0 else { return .amountMissing }
        if isTransfer {
            guard let to = toWalletID, to != walletID else { return .sameWallet }
        } else if kind == .expense && categoryID == nil {
            return .categoryRequired
        }
        if note.trimmingCharacters(in: .whitespacesAndNewlines).count > Transaction.maxNoteLength {
            return .noteTooLong
        }
        return nil
    }

    func transactionEdit() -> TransactionEdit? {
        guard !isTransfer, validate() == nil, let money = amount.money else { return nil }
        return TransactionEdit(
            kind: kind, amountMinor: money.minorUnits, walletID: walletID,
            categoryID: categoryID, note: note, timestamp: date)
    }

    func transferEdit() -> TransferEdit? {
        guard isTransfer, validate() == nil, let money = amount.money, let to = toWalletID else { return nil }
        return TransferEdit(
            fromWalletID: walletID, toWalletID: to, amountMinor: money.minorUnits,
            note: note, timestamp: date)
    }
}

// MARK: Delete wording

extension HistoryFormatting {
    func deleteTitle(for row: HistoryRow, currencyCode: String) -> String {
        "Delete \(amountText(for: row, currencyCode: currencyCode)) \(title(for: row))?"
    }

    func deleteMessage(for row: HistoryRow) -> String {
        let when = dayTitle(for: row.timestamp)
        if row.transferID != nil {
            return row.isBrokenTransfer
                ? "\(when). This incomplete transfer will be removed. This can't be undone."
                : "\(when). This removes both sides of the transfer. This can't be undone."
        }
        return "\(when). This can't be undone."
    }
}
