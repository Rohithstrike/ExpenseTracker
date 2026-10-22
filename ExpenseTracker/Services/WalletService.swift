// ExpenseTracker/Services/WalletService.swift  (new file)
import Foundation
import SwiftData

enum WalletError: Error, Equatable {
    case invalidName
    case duplicateName
    case invalidEmoji
    case invalidOpeningBalance
    case invalidCurrency
    case walletLimitReached
    case currencyLocked
    case lastActiveWallet
}

/// What the user types into the wallet form.
struct WalletInput: Equatable {
    var name: String
    var emoji: String = WalletService.defaultEmoji
    var openingBalanceMinor: Int64 = 0
    var currencyCode: String = "INR"
}

/// All wallet rules live here so every screen enforces the same ones.
/// Wallets are archived, never deleted, so history is never orphaned.
struct WalletService {
    static let maxActiveWallets = 4
    static let maxNameLength = 30
    static let defaultEmoji = "👛"

    let context: ModelContext

    @discardableResult
    func create(_ input: WalletInput) throws -> Wallet {
        let clean = try validated(input, excluding: nil)
        guard try activeWallets().count < Self.maxActiveWallets else {
            throw WalletError.walletLimitReached
        }
        let wallet = Wallet(
            name: clean.name,
            emoji: clean.emoji,
            openingBalanceMinor: clean.openingBalanceMinor,
            currencyCode: clean.currencyCode
        )
        context.insert(wallet)
        try commit()
        return wallet
    }

    func update(_ wallet: Wallet, with input: WalletInput) throws {
        let clean = try validated(input, excluding: wallet.id)
        if clean.currencyCode != wallet.currencyCode, try hasTransactions(walletID: wallet.id) {
            throw WalletError.currencyLocked
        }
        wallet.name = clean.name
        wallet.emoji = clean.emoji
        wallet.openingBalanceMinor = clean.openingBalanceMinor
        wallet.currencyCode = clean.currencyCode
        try commit()
    }

    func archive(_ wallet: Wallet) throws {
        guard !wallet.isArchived else { return }
        guard try activeWallets().count > 1 else { throw WalletError.lastActiveWallet }
        wallet.isArchived = true
        try commit()
    }

    func unarchive(_ wallet: Wallet) throws {
        guard wallet.isArchived else { return }
        let active = try activeWallets()
        guard active.count < Self.maxActiveWallets else { throw WalletError.walletLimitReached }
        let clash = active.contains {
            $0.name.caseInsensitiveCompare(wallet.name) == .orderedSame
        }
        guard !clash else { throw WalletError.duplicateName }
        wallet.isArchived = false
        try commit()
    }

    /// True for exactly one emoji (including multi-part ones such as family or flag emoji).
    static func isSingleEmoji(_ text: String) -> Bool {
        guard text.count == 1,
              let character = text.first,
              !character.isASCII,
              let first = character.unicodeScalars.first
        else { return false }
        return first.properties.isEmoji
    }

    // MARK: Private

    private func validated(_ input: WalletInput, excluding walletID: UUID?) throws -> WalletInput {
        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasControlCharacters = name.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
        guard !name.isEmpty, name.count <= Self.maxNameLength, !hasControlCharacters else {
            throw WalletError.invalidName
        }

        let trimmedEmoji = input.emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        let emoji = trimmedEmoji.isEmpty ? Self.defaultEmoji : trimmedEmoji
        guard Self.isSingleEmoji(emoji) else { throw WalletError.invalidEmoji }

        guard input.openingBalanceMinor.magnitude <= UInt64(Money.maxInputMinorUnits) else {
            throw WalletError.invalidOpeningBalance
        }

        let currency = input.currencyCode.uppercased()
        guard Money.isValidCurrencyCode(currency) else { throw WalletError.invalidCurrency }

        let others = try activeWallets().filter { $0.id != walletID }
        if others.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw WalletError.duplicateName
        }

        return WalletInput(
            name: name,
            emoji: emoji,
            openingBalanceMinor: input.openingBalanceMinor,
            currencyCode: currency
        )
    }

    private func activeWallets() throws -> [Wallet] {
        try context.fetch(
            FetchDescriptor<Wallet>(predicate: #Predicate { $0.isArchived == false })
        )
    }

    private func hasTransactions(walletID: UUID) throws -> Bool {
        let id = walletID
        let count = try context.fetchCount(
            FetchDescriptor<Transaction>(predicate: #Predicate { $0.walletID == id })
        )
        return count > 0
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
