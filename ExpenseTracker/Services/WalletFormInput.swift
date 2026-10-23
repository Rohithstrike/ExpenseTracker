// ExpenseTracker/Services/WalletFormInput.swift  (new file)
import Foundation

enum WalletFormError: Error, Equatable {
    case invalidFormat
    case tooManyDecimals
    case tooLarge
    case invalidCurrency
}

/// Turns wallet-form text into values `WalletService` accepts. Money maths goes
/// through `Money` (integer minor units); no Double is used anywhere.
enum WalletFormInput {
    /// Currencies offered in the wallet form.
    static let currencyChoices = ["INR", "USD", "EUR", "GBP", "AED", "AUD", "CAD", "SGD", "JPY"]

    /// Parses an opening balance such as "5000", "-250.75" or "" (empty means zero).
    /// Accepts one leading minus (- or −), digits, and one decimal separator.
    /// Grouping separators, letters and extra decimals are rejected, never rounded.
    static func openingBalanceMinor(
        from text: String,
        currencyCode: String,
        decimalSeparator: Character = "."
    ) throws -> Int64 {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { return 0 }

        var isNegative = false
        if let first = body.first, first == "-" || first == "\u{2212}" {
            isNegative = true
            body.removeFirst()
            if body.first?.isWhitespace == true { throw WalletFormError.invalidFormat }
        }

        do {
            let money = try Money.parse(
                body,
                currencyCode: currencyCode,
                decimalSeparator: decimalSeparator
            )
            return isNegative ? -money.minorUnits : money.minorUnits
        } catch let error as MoneyError {
            switch error {
            case .tooManyDecimals: throw WalletFormError.tooManyDecimals
            case .exceedsLimit, .overflow: throw WalletFormError.tooLarge
            case .invalidCurrency: throw WalletFormError.invalidCurrency
            default: throw WalletFormError.invalidFormat
            }
        } catch {
            throw WalletFormError.invalidFormat
        }
    }

    /// Text to show when editing an existing wallet's opening balance.
    static func text(
        forOpeningBalance minorUnits: Int64,
        currencyCode: String,
        decimalSeparator: Character = "."
    ) -> String {
        Money(minorUnits: minorUnits, currencyCode: currencyCode)
            .plainString(decimalSeparator: String(decimalSeparator))
    }

    /// Builds the value passed to `WalletService`; the service does the real validation.
    static func makeInput(
        name: String,
        emoji: String,
        openingBalanceText: String,
        currencyCode: String,
        decimalSeparator: Character = "."
    ) throws -> WalletInput {
        WalletInput(
            name: name,
            emoji: emoji,
            openingBalanceMinor: try openingBalanceMinor(
                from: openingBalanceText,
                currencyCode: currencyCode,
                decimalSeparator: decimalSeparator
            ),
            currencyCode: currencyCode
        )
    }
}
