// ExpenseTracker/Services/EntrySnapshotLoader.swift  (new file)
import Foundation
import SwiftData

extension EntrySnapshot {
    /// Active wallets (oldest first) with their current balances calculated from the
    /// ledger, and active categories (by name). Read-only. Throws rather than showing a
    /// balance that might be wrong.
    static func load(from context: ModelContext) throws -> EntrySnapshot {
        let wallets = try context.fetch(
            FetchDescriptor<Wallet>(
                predicate: #Predicate { $0.isArchived == false },
                sortBy: [SortDescriptor(\.createdAt)]))
        let balances = WalletBalanceService(context: context)
        var entryWallets: [EntryWallet] = []
        for wallet in wallets {
            let balance = try balances.balance(of: wallet).minorUnits
            entryWallets.append(EntryWallet(
                id: wallet.id,
                name: wallet.name,
                emoji: wallet.emoji,
                currencyCode: wallet.currencyCode,
                balanceMinor: balance))
        }

        let categories = try context.fetch(
            FetchDescriptor<Category>(
                predicate: #Predicate { $0.isArchived == false },
                sortBy: [SortDescriptor(\.name)]))
        let entryCategories = categories.map {
            EntryCategory(id: $0.id, name: $0.name, emoji: $0.emoji, colorHex: $0.colorHex)
        }
        return EntrySnapshot(wallets: entryWallets, categories: entryCategories)
    }
}
