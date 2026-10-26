import Foundation
import Observation
import SwiftData

enum TransactionsLoadState: Equatable {
    case loaded([DayHistory])
    case empty
    case failed(String)
}

/// One entry in the wallet filter menu. Archived wallets stay filterable because
/// their history is kept.
struct WalletFilterOption: Equatable, Identifiable {
    let id: UUID
    let name: String
    let emoji: String
    let isArchived: Bool
}

/// State for the Transactions screen: which period and wallet are selected, and what
/// the query service returned. It only reads; it never changes stored data.
@MainActor
@Observable
final class TransactionsViewModel {
    static let loadFailureMessage = "Couldn't load your transactions. Please try again."
    static let unreadableMessage = "Some transactions couldn't be read. Please update the app and try again."

    private(set) var period: HistoryPeriod
    /// nil means all wallets.
    private(set) var selectedWalletID: UUID?
    private(set) var walletOptions: [WalletFilterOption] = []
    private(set) var state: TransactionsLoadState = .empty

    let formatting: HistoryFormatting
    private let context: ModelContext
    private let calendar: Calendar
    private let now: () -> Date

    init(
        context: ModelContext,
        period: HistoryPeriod = .today,
        calendar: Calendar = .current,
        locale: Locale = .current,
        now: @escaping () -> Date = { Date() }
    ) {
        self.context = context
        self.period = period
        self.calendar = calendar
        self.now = now
        self.formatting = HistoryFormatting(calendar: calendar, locale: locale)
        reload()
    }

    // MARK: Derived

    var days: [DayHistory] {
        if case .loaded(let days) = state { return days }
        return []
    }

    var selectedWallet: WalletFilterOption? {
        walletOptions.first { $0.id == selectedWalletID }
    }

    var periodTitle: String { formatting.periodTitle(period) }

    var walletFilterTitle: String {
        selectedWallet?.name ?? HistoryFormatting.allWalletsTitle
    }

    var emptyTitle: String {
        if let wallet = selectedWallet {
            return "No transactions for \(wallet.name) \(periodPhrase)"
        }
        return "No transactions \(periodPhrase)"
    }

    var emptyDetail: String { "Entries you add on Home appear here." }

    private var periodPhrase: String {
        switch period {
        case .today: "today"
        case .yesterday: "yesterday"
        case .thisMonth: "this month"
        case .lastMonth: "last month"
        }
    }

    // MARK: Actions

    func selectPeriod(_ newPeriod: HistoryPeriod) {
        guard newPeriod != period else { return }
        period = newPeriod
        reload()
    }

    /// nil selects all wallets. An unknown wallet is ignored.
    func selectWallet(_ id: UUID?) {
        guard id != selectedWalletID else { return }
        if let id, !walletOptions.contains(where: { $0.id == id }) { return }
        selectedWalletID = id
        reload()
    }

    /// Re-reads wallets and history. Call when the screen appears, since entries are
    /// saved on Home.
    func reload() {
        do {
            walletOptions = try loadWalletOptions()
            if let id = selectedWalletID, !walletOptions.contains(where: { $0.id == id }) {
                selectedWalletID = nil
            }
            guard let range = period.range(now: now(), calendar: calendar) else {
                state = .failed(Self.loadFailureMessage)
                return
            }
            let days = try TransactionQueryService(context: context).history(
                in: range, walletID: selectedWalletID, calendar: calendar)
            state = days.isEmpty ? .empty : .loaded(days)
        } catch TransactionQueryError.unknownKind(_) {
            state = .failed(Self.unreadableMessage)
        } catch {
            state = .failed(Self.loadFailureMessage)
        }
    }

    // MARK: Private

    private func loadWalletOptions() throws -> [WalletFilterOption] {
        let wallets = try context.fetch(
            FetchDescriptor<Wallet>(sortBy: [SortDescriptor(\.createdAt)]))
        return wallets.map {
            WalletFilterOption(id: $0.id, name: $0.name, emoji: $0.emoji, isArchived: $0.isArchived)
        }
    }
}
