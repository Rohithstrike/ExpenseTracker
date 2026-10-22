import Foundation

enum BalanceError: Error, Equatable {
    case invalidAmount
    case unknownKind
    case overflow
}

/// Plain value used for balance maths, independent of SwiftData.
struct LedgerEntry: Equatable {
    let walletID: UUID
    let kind: TransactionKind
    let amountMinor: Int64
}

enum BalanceCalculator {
    /// opening + income + transferIn - expense - transferOut, for one wallet.
    static func balanceMinor(
        openingMinor: Int64,
        walletID: UUID,
        entries: [LedgerEntry]
    ) throws -> Int64 {
        var total = openingMinor
        for entry in entries where entry.walletID == walletID {
            guard entry.amountMinor > 0 else { throw BalanceError.invalidAmount }
            let delta: Int64
            switch entry.kind {
            case .income, .transferIn: delta = entry.amountMinor
            case .expense, .transferOut: delta = -entry.amountMinor
            }
            let (result, overflow) = total.addingReportingOverflow(delta)
            guard !overflow else { throw BalanceError.overflow }
            total = result
        }
        return total
    }

    static func balance(of wallet: Wallet, transactions: [Transaction]) throws -> Money {
        let entries = try transactions
            .filter { $0.walletID == wallet.id }
            .map { try $0.ledgerEntry() }
        let minor = try balanceMinor(
            openingMinor: wallet.openingBalanceMinor,
            walletID: wallet.id,
            entries: entries
        )
        return Money(minorUnits: minor, currencyCode: wallet.currencyCode)
    }
}
