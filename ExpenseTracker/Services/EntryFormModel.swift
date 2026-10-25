// ExpenseTracker/Services/EntryFormModel.swift  (new file)
import Foundation

/// What the Home entry form is recording.
enum EntryMode: String, CaseIterable, Equatable {
    case expense, income, transfer

    var title: String {
        switch self {
        case .expense: "Expense"
        case .income: "Income"
        case .transfer: "Transfer"
        }
    }

    /// Label of the first wallet row.
    var walletLabel: String {
        switch self {
        case .expense: "Paid from"
        case .income: "Deposit to"
        case .transfer: "From"
        }
    }
}

/// Plain-value copies of what the form needs, so its rules can be tested without a database.
struct EntryWallet: Equatable, Identifiable {
    let id: UUID
    var name: String
    var emoji: String
    var currencyCode: String
    /// Current balance, calculated from the ledger, in minor units.
    var balanceMinor: Int64
}

struct EntryCategory: Equatable, Identifiable {
    let id: UUID
    var name: String
    var emoji: String
    var colorHex: String
}

struct EntrySnapshot: Equatable {
    /// Active wallets, oldest first.
    var wallets: [EntryWallet]
    /// Active categories, by name.
    var categories: [EntryCategory]
}

enum TransferAvailability: Equatable {
    case available
    case needsSecondWallet
    case noWalletInSameCurrency(String)
}

/// Why Save is not allowed right now. `message` is shown to the user.
enum EntryIssue: Equatable {
    case noWallet
    case amountMissing
    case categoryRequired
    case needsSecondWallet
    case noWalletInSameCurrency(String)
    case insufficientFunds(availableMinor: Int64, currencyCode: String, walletName: String)
    case noteTooLong
    case dateOutOfRange

    var message: String {
        switch self {
        case .noWallet:
            return "No wallet is available."
        case .amountMissing:
            return "Enter an amount greater than zero."
        case .categoryRequired:
            return "Choose a category."
        case .needsSecondWallet:
            return "You need a second wallet to make a transfer."
        case .noWalletInSameCurrency(let code):
            return "There is no other \(code) wallet to transfer to."
        case .insufficientFunds(let available, let code, let name):
            if available <= 0 {
                return "\(name) has no money available to transfer."
            }
            let formatted = Money(minorUnits: available, currencyCode: code).formatted()
            return "You have \(formatted) available in \(name). Reduce the amount or choose another wallet."
        case .noteTooLong:
            return "The note is too long. Use up to \(Transaction.maxNoteLength) characters."
        case .dateOutOfRange:
            return "Choose a date from 1 January 2000 up to tomorrow."
        }
    }
}

enum EntryValidation: Equatable {
    case ready
    case blocked(EntryIssue)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var issue: EntryIssue? {
        if case .blocked(let issue) = self { return issue }
        return nil
    }
}

/// All the Home entry form's decisions for Expense, Income and Transfer, as plain state.
/// The services stay the authority; this only explains problems before Save.
struct EntryFormModel: Equatable {
    var snapshot: EntrySnapshot
    var mode: EntryMode = .expense
    var amount: AmountInput
    var fromWalletID: UUID?
    var toWalletID: UUID?
    var categoryID: UUID?
    /// nil means "now".
    var date: Date?
    var note: String = ""
    /// Becomes the transaction or transfer id. Kept until a save succeeds, so a repeated
    /// tap re-sends the same id and cannot create a duplicate.
    var submissionID: UUID = UUID()

    init(snapshot: EntrySnapshot, decimalSeparator: Character = ".") {
        self.snapshot = snapshot
        let first = snapshot.wallets.first
        self.amount = AmountInput(
            currencyCode: first?.currencyCode ?? "INR",
            decimalSeparator: decimalSeparator
        )
        self.fromWalletID = first?.id
        repairSelections()
    }

    // MARK: Derived

    var fromWallet: EntryWallet? { snapshot.wallets.first { $0.id == fromWalletID } }
    var toWallet: EntryWallet? { snapshot.wallets.first { $0.id == toWalletID } }
    var category: EntryCategory? { snapshot.categories.first { $0.id == categoryID } }

    var currencyCode: String { fromWallet?.currencyCode ?? amount.currencyCode }

    var currencySymbol: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        return formatter.currencySymbol ?? currencyCode
    }

    /// Active wallets in the same currency as the From wallet, excluding it.
    var destinationOptions: [EntryWallet] {
        guard let from = fromWallet else { return [] }
        return snapshot.wallets.filter { $0.id != from.id && $0.currencyCode == from.currencyCode }
    }

    var transferAvailability: TransferAvailability {
        if snapshot.wallets.count < 2 { return .needsSecondWallet }
        if destinationOptions.isEmpty { return .noWalletInSameCurrency(currencyCode) }
        return .available
    }

    var showsCategory: Bool { mode != .transfer }
    var categoryIsRequired: Bool { mode == .expense }
    var showsDestination: Bool { mode == .transfer }

    /// The category a save would use. Transfers never carry one, even if one is remembered.
    var effectiveCategoryID: UUID? { mode == .transfer ? nil : categoryID }

    var buttonTitle: String {
        switch mode {
        case .expense:
            return "Save Expense"
        case .income:
            return "Save Income"
        case .transfer:
            if let money = amount.money, money.minorUnits > 0 {
                return "Transfer \(money.formatted())"
            }
            return "Transfer"
        }
    }

    /// One muted line under the amount.
    var contextLine: String? {
        guard let from = fromWallet else { return nil }
        let money = Money(minorUnits: from.balanceMinor, currencyCode: from.currencyCode).formatted()
        if mode == .transfer {
            if from.balanceMinor <= 0 { return "No money available in \(from.name)" }
            return "\(money) available in \(from.name)"
        }
        return "\(from.name) balance: \(money)"
    }

    // MARK: Validation (fixed order: wallet, amount, category, destination, funds, note, date)

    func validate(now: Date = Date()) -> EntryValidation {
        guard let from = fromWallet else { return .blocked(.noWallet) }
        guard let money = amount.money, money.minorUnits > 0 else { return .blocked(.amountMissing) }
        if mode == .expense && category == nil { return .blocked(.categoryRequired) }

        if mode == .transfer {
            switch transferAvailability {
            case .needsSecondWallet:
                return .blocked(.needsSecondWallet)
            case .noWalletInSameCurrency(let code):
                return .blocked(.noWalletInSameCurrency(code))
            case .available:
                break
            }
            if toWallet == nil { return .blocked(.noWalletInSameCurrency(from.currencyCode)) }
            if money.minorUnits > from.balanceMinor {
                return .blocked(.insufficientFunds(
                    availableMinor: from.balanceMinor,
                    currencyCode: from.currencyCode,
                    walletName: from.name))
            }
        }

        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > Transaction.maxNoteLength { return .blocked(.noteTooLong) }

        if let chosen = date,
           chosen < TransactionService.earliestDate
            || chosen > now.addingTimeInterval(TransactionService.futureTolerance) {
            return .blocked(.dateOutOfRange)
        }
        return .ready
    }

    // MARK: Changes

    mutating func setMode(_ newMode: EntryMode) {
        mode = newMode
        repairSelections()
    }

    mutating func setFromWallet(_ id: UUID?) {
        fromWalletID = id
        repairSelections()
    }

    /// Ignored unless the wallet is a valid destination (active, same currency, not the source).
    mutating func setToWallet(_ id: UUID?) {
        guard let id, destinationOptions.contains(where: { $0.id == id }) else { return }
        toWalletID = id
    }

    /// Ignored for transfers and for unknown categories.
    mutating func setCategory(_ id: UUID?) {
        guard mode != .transfer else { return }
        guard let id else {
            categoryID = nil
            return
        }
        if snapshot.categories.contains(where: { $0.id == id }) { categoryID = id }
    }

    mutating func setDate(_ newDate: Date?) { date = newDate }
    /// Notes are cut at the maximum length.
    mutating func setNote(_ text: String) { note = String(text.prefix(Transaction.maxNoteLength)) }

    /// Use after data changes (new balances, an archived wallet or category).
    mutating func apply(snapshot newSnapshot: EntrySnapshot) {
        snapshot = newSnapshot
        repairSelections()
    }

    /// After a successful save: clear amount, note and date; keep the mode, wallets and
    /// category for quick repeat entry; new id.
    mutating func resetAfterSave() {
        amount.clear()
        note = ""
        date = nil
        submissionID = UUID()
    }

    /// Keeps every selection valid for the current snapshot and mode.
    mutating func repairSelections() {
        if fromWallet == nil { fromWalletID = snapshot.wallets.first?.id }
        // The amount follows the From wallet's currency (changing it clears the amount).
        if let from = fromWallet { amount.setCurrency(from.currencyCode) }
        if category == nil { categoryID = nil }
        let options = destinationOptions
        if !options.contains(where: { $0.id == toWalletID }) {
            toWalletID = options.first?.id
        }
    }
}
