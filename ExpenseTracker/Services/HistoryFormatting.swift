import Foundation

/// How an amount should be coloured by the view. Transfers are neutral on purpose:
/// they move money between wallets and are neither spending nor income.
enum HistoryAmountStyle: Equatable {
    case income, expense, transfer
}

/// What to draw in a row's leading tile. The view maps these to SF Symbols and colours.
enum HistoryIcon: Equatable {
    case emoji(String)
    case transferOut
    case transferIn
    case warning
}

/// Pure text rules for the Transactions screen. No SwiftUI, no database.
/// Use the same calendar as the TransactionQueryService call that produced the data,
/// otherwise day titles can disagree with the day grouping near midnight.
struct HistoryFormatting {
    static let allWalletsTitle = "All wallets"
    static let uncategorisedExpenseEmoji = "🏷️"
    static let uncategorisedIncomeEmoji = "💵"

    let calendar: Calendar
    let locale: Locale

    init(calendar: Calendar = .current, locale: Locale = .current) {
        self.calendar = calendar
        self.locale = locale
    }

    // MARK: Headings

    func dayTitle(for day: Date, now: Date = Date()) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "EEEdMMM" : "EEEdMMMy")
        return formatter.string(from: day)
    }

    func periodTitle(_ period: HistoryPeriod) -> String {
        switch period {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .thisMonth: return "This month"
        case .lastMonth: return "Last month"
        }
    }

    func walletHeading(_ group: WalletHistory) -> String {
        let base = "\(group.walletEmoji) \(group.walletName)"
        return group.walletIsArchived ? "\(base) (archived)" : base
    }

    // MARK: Rows

    func title(for row: HistoryRow) -> String {
        switch row.kind {
        case .expense:
            return row.categoryName ?? "Uncategorised"
        case .income:
            return row.categoryName ?? "Income"
        case .transferOut:
            if let name = row.counterpartWalletName { return "Transfer to \(name)" }
            return "Transfer"
        case .transferIn:
            if let name = row.counterpartWalletName { return "Transfer from \(name)" }
            return "Transfer"
        }
    }

    /// The note (whitespace collapsed), preceded by "Incomplete transfer" when a
    /// transfer is missing its other half. Nil when there is nothing to show.
    func subtitle(for row: HistoryRow) -> String? {
        var parts: [String] = []
        if row.isBrokenTransfer { parts.append("Incomplete transfer") }
        let note = row.note
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !note.isEmpty { parts.append(note) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func amountText(for row: HistoryRow, currencyCode: String) -> String {
        let sign: String
        switch row.kind {
        case .income, .transferIn: sign = "+"
        case .expense, .transferOut: sign = "−"
        }
        return sign + magnitudeText(row.amountMinor, currencyCode: currencyCode)
    }

    func amountStyle(for row: HistoryRow) -> HistoryAmountStyle {
        switch row.kind {
        case .income: return .income
        case .expense: return .expense
        case .transferOut, .transferIn: return .transfer
        }
    }

    func icon(for row: HistoryRow) -> HistoryIcon {
        switch row.kind {
        case .transferOut, .transferIn:
            if row.isBrokenTransfer { return .warning }
            return row.kind == .transferOut ? .transferOut : .transferIn
        case .income:
            return .emoji(nonEmpty(row.categoryEmoji) ?? Self.uncategorisedIncomeEmoji)
        case .expense:
            return .emoji(nonEmpty(row.categoryEmoji) ?? Self.uncategorisedExpenseEmoji)
        }
    }

    func accessibilityLabel(for row: HistoryRow, currencyCode: String) -> String {
        let kindWord: String
        switch row.kind {
        case .expense: kindWord = "expense"
        case .income: kindWord = "income"
        case .transferOut: kindWord = "transfer out"
        case .transferIn: kindWord = "transfer in"
        }
        var parts = [
            title(for: row),
            kindWord,
            magnitudeText(row.amountMinor, currencyCode: currencyCode)
        ]
        if let subtitle = subtitle(for: row) { parts.append(subtitle) }
        return parts.joined(separator: ", ")
    }

    // MARK: Private

    /// Falls back to plain digits when the currency is unknown (for example the
    /// "Unknown wallet" case), rather than showing a made-up symbol.
    private func magnitudeText(_ minor: Int64, currencyCode: String) -> String {
        let money = Money(minorUnits: minor, currencyCode: currencyCode)
        return Money.isValidCurrencyCode(currencyCode)
            ? money.formatted(locale: locale)
            : money.plainString()
    }

    private func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}
