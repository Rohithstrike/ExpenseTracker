import Foundation
import SwiftData

enum TransactionQueryError: Error, Equatable {
    /// A stored row has a kind this version doesn't understand. Throwing is safer than
    /// showing a history that might be wrong.
    case unknownKind(transactionID: UUID)
}

/// One transaction as the history screen needs it. Plain values, no SwiftData.
struct HistoryRow: Equatable, Identifiable {
    let id: UUID
    let kind: TransactionKind
    let amountMinor: Int64
    let timestamp: Date
    let note: String
    let categoryID: UUID?
    let categoryName: String?
    let categoryEmoji: String?
    let categoryColorHex: String?
    let categoryIsArchived: Bool
    let transferID: UUID?
    /// For transfer legs: the wallet on the other side, when it can be determined.
    let counterpartWalletID: UUID?
    let counterpartWalletName: String?
    /// True when the transfer's legs are missing or inconsistent. Such a transfer can
    /// still be deleted but not edited.
    let isBrokenTransfer: Bool
}

struct WalletHistory: Equatable, Identifiable {
    let walletID: UUID
    let walletName: String
    let walletEmoji: String
    let currencyCode: String
    let walletIsArchived: Bool
    let rows: [HistoryRow]
    var id: UUID { walletID }
}

struct DayHistory: Equatable, Identifiable {
    /// Start of the day in the calendar used for the query.
    let day: Date
    let wallets: [WalletHistory]
    var id: Date { day }
}

/// The periods the Transactions screen starts with.
enum HistoryPeriod: CaseIterable, Equatable {
    case today, yesterday, thisMonth, lastMonth

    /// Start inclusive, end exclusive. nil only if the calendar cannot compute it.
    func range(now: Date = Date(), calendar: Calendar = .current) -> Range<Date>? {
        switch self {
        case .today:
            let start = calendar.startOfDay(for: now)
            guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            return start..<end
        case .yesterday:
            let today = calendar.startOfDay(for: now)
            guard let start = calendar.date(byAdding: .day, value: -1, to: today) else { return nil }
            return start..<today
        case .thisMonth:
            guard let month = calendar.dateInterval(of: .month, for: now) else { return nil }
            return month.start..<month.end
        case .lastMonth:
            guard let this = calendar.dateInterval(of: .month, for: now),
                  let before = calendar.date(byAdding: .month, value: -1, to: this.start),
                  let last = calendar.dateInterval(of: .month, for: before)
            else { return nil }
            return last.start..<last.end
        }
    }
}

/// Read-only: finds transactions for a period and groups them by day, then wallet.
/// It never writes, and it applies no spending rules; it only describes the ledger.
struct TransactionQueryService {
    let context: ModelContext

    func history(
        in range: Range<Date>,
        walletID: UUID? = nil,
        calendar: Calendar = .current
    ) throws -> [DayHistory] {
        let start = range.lowerBound
        let end = range.upperBound
        let fetched = try context.fetch(
            FetchDescriptor<Transaction>(
                predicate: #Predicate { $0.timestamp >= start && $0.timestamp < end }))
        let scoped = fetched.filter { walletID == nil || $0.walletID == walletID }

        let allWallets = try context.fetch(FetchDescriptor<Wallet>())
        let wallets = Dictionary(allWallets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let allCategories = try context.fetch(FetchDescriptor<Category>())
        let categories = Dictionary(allCategories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var legsByTransfer: [UUID: [Transaction]] = [:]
        if scoped.contains(where: { $0.transferID != nil }) {
            let legs = try context.fetch(
                FetchDescriptor<Transaction>(predicate: #Predicate { $0.transferID != nil }))
            for leg in legs {
                if let id = leg.transferID { legsByTransfer[id, default: []].append(leg) }
            }
        }

        var grouped: [Date: [UUID: [HistoryRow]]] = [:]
        for txn in scoped {
            guard let kind = txn.kind else {
                throw TransactionQueryError.unknownKind(transactionID: txn.id)
            }
            let row = makeRow(
                txn, kind: kind, categories: categories, wallets: wallets, legs: legsByTransfer)
            let day = calendar.startOfDay(for: txn.timestamp)
            grouped[day, default: [:]][txn.walletID, default: []].append(row)
        }

        return grouped.keys.sorted(by: >).map { day -> DayHistory in
            let perWallet = grouped[day] ?? [:]
            let orderedIDs = perWallet.keys.sorted { Self.walletOrder($0, $1, wallets) }
            let groups = orderedIDs.map { id -> WalletHistory in
                let wallet = wallets[id]
                return WalletHistory(
                    walletID: id,
                    walletName: wallet?.name ?? "Unknown wallet",
                    walletEmoji: wallet?.emoji ?? "❔",
                    currencyCode: wallet?.currencyCode ?? "",
                    walletIsArchived: wallet?.isArchived ?? false,
                    rows: (perWallet[id] ?? []).sorted(by: Self.rowOrder))
            }
            return DayHistory(day: day, wallets: groups)
        }
    }

    // MARK: Private

    private func makeRow(
        _ txn: Transaction,
        kind: TransactionKind,
        categories: [UUID: Category],
        wallets: [UUID: Wallet],
        legs: [UUID: [Transaction]]
    ) -> HistoryRow {
        let category = txn.categoryID.flatMap { categories[$0] }

        var counterpartID: UUID?
        var broken = false
        if let transferID = txn.transferID, kind == .transferOut || kind == .transferIn {
            let group = legs[transferID] ?? []
            broken = !Self.isIntactPair(group)
            let wanted: TransactionKind = kind == .transferOut ? .transferIn : .transferOut
            let others = group.filter { $0.id != txn.id && $0.kind == wanted }
            if others.count == 1 { counterpartID = others[0].walletID }
        }

        return HistoryRow(
            id: txn.id,
            kind: kind,
            amountMinor: txn.amountMinor,
            timestamp: txn.timestamp,
            note: txn.note,
            categoryID: txn.categoryID,
            categoryName: category?.name,
            categoryEmoji: category?.emoji,
            categoryColorHex: category?.colorHex,
            categoryIsArchived: category?.isArchived ?? false,
            transferID: txn.transferID,
            counterpartWalletID: counterpartID,
            counterpartWalletName: counterpartID.flatMap { wallets[$0]?.name },
            isBrokenTransfer: broken)
    }

    /// Same definition as TransferService.pair: exactly one out and one in, in different
    /// wallets, with equal amount, timestamp and note, and no category.
    private static func isIntactPair(_ group: [Transaction]) -> Bool {
        guard group.count == 2,
              let out = group.first(where: { $0.kind == .transferOut }),
              let inn = group.first(where: { $0.kind == .transferIn })
        else { return false }
        return out.walletID != inn.walletID
            && out.amountMinor == inn.amountMinor
            && out.timestamp == inn.timestamp
            && out.note == inn.note
            && out.categoryID == nil
            && inn.categoryID == nil
    }

    private static func walletOrder(_ a: UUID, _ b: UUID, _ wallets: [UUID: Wallet]) -> Bool {
        switch (wallets[a], wallets[b]) {
        case let (x?, y?):
            if x.createdAt != y.createdAt { return x.createdAt < y.createdAt }
            if x.name != y.name { return x.name < y.name }
            return a.uuidString < b.uuidString
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return a.uuidString < b.uuidString
        }
    }

    private static func rowOrder(_ a: HistoryRow, _ b: HistoryRow) -> Bool {
        if a.timestamp != b.timestamp { return a.timestamp > b.timestamp }
        return a.id.uuidString > b.id.uuidString
    }
}
