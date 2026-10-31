import Foundation

enum ProgressError: Error, Equatable {
    case overflow
    case unknownKind
}

/// Plain values, so the maths can be tested without a database.
struct ProgressTransaction: Equatable {
    let kind: TransactionKind
    let amountMinor: Int64
    let walletID: UUID
    let categoryID: UUID?
}

struct ProgressCategory: Equatable {
    let id: UUID
    let name: String
    let emoji: String
    let colorHex: String
    let isArchived: Bool
}

struct CategorySpend: Equatable, Identifiable {
    static let uncategorisedName = "Uncategorised"

    /// nil for spending with no category, or a category that no longer exists.
    let categoryID: UUID?
    let name: String
    let emoji: String
    let colorHex: String?
    let isArchived: Bool
    let amountMinor: Int64

    var id: String { categoryID?.uuidString ?? "uncategorised" }
}

struct CurrencySummary: Equatable, Identifiable {
    /// Empty when a transaction's wallet can't be found.
    let currencyCode: String
    let incomeMinor: Int64
    let expenseMinor: Int64
    let categories: [CategorySpend]

    var netMinor: Int64 { incomeMinor - expenseMinor }
    var id: String { currencyCode }
}

/// Totals for one period, kept separate per currency. Only income and expenses count:
/// a transfer moves money between your own wallets, so it is neither. Categories are
/// grouped by id; colours and names are only for display.
enum ProgressCalculator {
    private struct Accumulator {
        var income: Int64 = 0
        var expense: Int64 = 0
        var perCategory: [UUID?: Int64] = [:]
    }

    static func summaries(
        transactions: [ProgressTransaction],
        walletCurrencies: [UUID: String],
        categories: [UUID: ProgressCategory]
    ) throws -> [CurrencySummary] {
        var byCurrency: [String: Accumulator] = [:]
        for t in transactions {
            guard t.kind == .income || t.kind == .expense else { continue }
            let code = walletCurrencies[t.walletID] ?? ""
            var acc = byCurrency[code] ?? Accumulator()
            if t.kind == .income {
                let (value, overflow) = acc.income.addingReportingOverflow(t.amountMinor)
                if overflow { throw ProgressError.overflow }
                acc.income = value
            } else {
                let (value, overflow) = acc.expense.addingReportingOverflow(t.amountMinor)
                if overflow { throw ProgressError.overflow }
                acc.expense = value
                let key: UUID?
                if let id = t.categoryID, categories[id] != nil { key = id } else { key = nil }
                let current = acc.perCategory[key] ?? 0
                let (sum, overflow2) = current.addingReportingOverflow(t.amountMinor)
                if overflow2 { throw ProgressError.overflow }
                acc.perCategory[key] = sum
            }
            byCurrency[code] = acc
        }

        let result = byCurrency.map { code, acc -> CurrencySummary in
            let spends = acc.perCategory.map { key, amount -> CategorySpend in
                if let key, let c = categories[key] {
                    return CategorySpend(
                        categoryID: key, name: c.name, emoji: c.emoji, colorHex: c.colorHex,
                        isArchived: c.isArchived, amountMinor: amount)
                }
                return CategorySpend(
                    categoryID: nil, name: CategorySpend.uncategorisedName, emoji: "🏷️",
                    colorHex: nil, isArchived: false, amountMinor: amount)
            }
            let ordered = spends.sorted { a, b in
                if a.amountMinor != b.amountMinor { return a.amountMinor > b.amountMinor }
                if a.name != b.name { return a.name < b.name }
                return a.id < b.id
            }
            return CurrencySummary(
                currencyCode: code, incomeMinor: acc.income, expenseMinor: acc.expense, categories: ordered)
        }
        return result.sorted { a, b in
            if a.currencyCode.isEmpty != b.currencyCode.isEmpty { return !a.currencyCode.isEmpty }
            return a.currencyCode < b.currencyCode
        }
    }
}
