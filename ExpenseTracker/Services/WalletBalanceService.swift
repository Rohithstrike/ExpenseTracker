// ExpenseTracker/Services/WalletBalanceService.swift  (new file)
import Foundation
import SwiftData

/// Balance = opening balance + income + transfers in - expenses - transfers out,
/// always calculated from the ledger (never stored). Only the rows of the requested
/// wallet are fetched. If any row has an unknown kind this throws instead of
/// showing a total that might be wrong.
struct WalletBalanceService {
    let context: ModelContext

    func balance(of wallet: Wallet) throws -> Money {
        let id = wallet.id
        let rows = try context.fetch(
            FetchDescriptor<Transaction>(predicate: #Predicate { $0.walletID == id })
        )
        let entries = try rows.map { try $0.ledgerEntry() }
        let minor = try BalanceCalculator.balanceMinor(
            openingMinor: wallet.openingBalanceMinor,
            walletID: id,
            entries: entries
        )
        return Money(minorUnits: minor, currencyCode: wallet.currencyCode)
    }

    func balances(for wallets: [Wallet]) throws -> [UUID: Money] {
        var result: [UUID: Money] = [:]
        for wallet in wallets {
            result[wallet.id] = try balance(of: wallet)
        }
        return result
    }
}
