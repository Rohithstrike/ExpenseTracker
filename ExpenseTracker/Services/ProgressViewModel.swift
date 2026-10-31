import Foundation
import Observation
import SwiftData

enum ProgressLoadState: Equatable {
    case loaded([CurrencySummary])
    case empty
    case failed(String)
}

/// State for the Progress screen. It only reads; it never changes stored data. Every
/// number is calculated fresh from the transactions each time.
@MainActor
@Observable
final class ProgressViewModel {
    static let loadFailureMessage = "Couldn't load your progress. Please try again."
    static let unreadableMessage = "Some transactions couldn't be read. Please update the app and try again."

    private(set) var period: HistoryPeriod
    private(set) var selectedCurrency: String?
    private(set) var state: ProgressLoadState = .empty

    let formatting: HistoryFormatting
    private let context: ModelContext
    private let calendar: Calendar
    private let now: () -> Date

    init(
        context: ModelContext,
        period: HistoryPeriod = .thisMonth,
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

    var summaries: [CurrencySummary] {
        if case .loaded(let list) = state { return list }
        return []
    }

    /// The chosen currency, or the first one when none is chosen or it has no activity.
    var selectedSummary: CurrencySummary? {
        summaries.first { $0.currencyCode == selectedCurrency } ?? summaries.first
    }

    var periodTitle: String { formatting.periodTitle(period) }

    var periodPhrase: String {
        switch period {
        case .today: "today"
        case .yesterday: "yesterday"
        case .thisMonth: "this month"
        case .lastMonth: "last month"
        }
    }

    func selectPeriod(_ newPeriod: HistoryPeriod) {
        guard newPeriod != period else { return }
        period = newPeriod
        reload()
    }

    /// Unknown currencies are ignored.
    func selectCurrency(_ code: String) {
        guard summaries.contains(where: { $0.currencyCode == code }) else { return }
        selectedCurrency = code
    }

    func reload() {
        guard let range = period.range(now: now(), calendar: calendar) else {
            state = .failed(Self.loadFailureMessage)
            return
        }
        let start = range.lowerBound
        let end = range.upperBound
        do {
            let fetched = try context.fetch(
                FetchDescriptor<Transaction>(
                    predicate: #Predicate { $0.timestamp >= start && $0.timestamp < end }))
            var currencies: [UUID: String] = [:]
            for wallet in try context.fetch(FetchDescriptor<Wallet>()) {
                currencies[wallet.id] = wallet.currencyCode.uppercased()
            }
            var categories: [UUID: ProgressCategory] = [:]
            for c in try context.fetch(FetchDescriptor<Category>()) {
                categories[c.id] = ProgressCategory(
                    id: c.id, name: c.name, emoji: c.emoji, colorHex: c.colorHex, isArchived: c.isArchived)
            }
            var items: [ProgressTransaction] = []
            items.reserveCapacity(fetched.count)
            for t in fetched {
                guard let kind = t.kind else { throw ProgressError.unknownKind }
                items.append(ProgressTransaction(
                    kind: kind, amountMinor: t.amountMinor, walletID: t.walletID, categoryID: t.categoryID))
            }
            let result = try ProgressCalculator.summaries(
                transactions: items, walletCurrencies: currencies, categories: categories)
            state = result.isEmpty ? .empty : .loaded(result)
        } catch ProgressError.unknownKind {
            state = .failed(Self.unreadableMessage)
        } catch {
            state = .failed(Self.loadFailureMessage)
        }
    }
}
