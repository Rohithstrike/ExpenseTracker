import Foundation

enum MoneyError: Error, Equatable {
    case empty, invalidFormat, tooManyDecimals, exceedsLimit
    case overflow, invalidCurrency, currencyMismatch
}

/// Exact money: Int64 minor units (e.g. paise) plus an ISO 4217 code.
/// No Double is used anywhere. Parsing never rounds: extra decimals are rejected.
struct Money: Equatable, Hashable, Sendable {
    let minorUnits: Int64
    let currencyCode: String

    /// Largest amount accepted from user input, in minor units.
    /// 99,999,999,999 = 999,999,999.99 for a 2-decimal currency.
    static let maxInputMinorUnits: Int64 = 99_999_999_999

    init(minorUnits: Int64, currencyCode: String) {
        self.minorUnits = minorUnits
        self.currencyCode = currencyCode.uppercased()
    }

    // MARK: Currency rules (small fixed table, so behaviour is deterministic)

    private static let zeroDigitCurrencies: Set<String> = [
        "BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW",
        "PYG", "RWF", "UGX", "UYI", "VND", "VUV", "XAF", "XOF", "XPF"
    ]
    private static let threeDigitCurrencies: Set<String> = [
        "BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND"
    ]

    static func fractionDigits(for currencyCode: String) -> Int {
        let code = currencyCode.uppercased()
        if zeroDigitCurrencies.contains(code) { return 0 }
        if threeDigitCurrencies.contains(code) { return 3 }
        return 2
    }

    static func isValidCurrencyCode(_ code: String) -> Bool {
        code.count == 3 && code.allSatisfy { $0.isASCII && $0.isLetter }
    }

    // MARK: Parsing

    /// Parses plain keypad-style text such as "12", "12.5", "12." or ".5".
    /// Rejects signs, grouping separators, letters, exponents and extra decimals.
    static func parse(
        _ text: String,
        currencyCode: String,
        decimalSeparator: Character = "."
    ) throws -> Money {
        guard isValidCurrencyCode(currencyCode) else { throw MoneyError.invalidCurrency }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MoneyError.empty }

        let parts = trimmed.split(separator: decimalSeparator, omittingEmptySubsequences: false)
        guard parts.count <= 2 else { throw MoneyError.invalidFormat }
        let wholePart = String(parts[0])
        let fractionPart = parts.count == 2 ? String(parts[1]) : ""
        guard !(wholePart.isEmpty && fractionPart.isEmpty) else { throw MoneyError.invalidFormat }

        let allDigits = (wholePart + fractionPart).allSatisfy {
            guard let ascii = $0.asciiValue else { return false }
            return ascii >= 48 && ascii <= 57
        }
        guard allDigits else { throw MoneyError.invalidFormat }

        let digits = fractionDigits(for: currencyCode)
        guard fractionPart.count <= digits else { throw MoneyError.tooManyDecimals }

        let padded = fractionPart + String(repeating: "0", count: digits - fractionPart.count)
        guard let value = Int64(wholePart + padded) else { throw MoneyError.overflow }
        guard value <= maxInputMinorUnits else { throw MoneyError.exceedsLimit }
        return Money(minorUnits: value, currencyCode: currencyCode)
    }

    // MARK: Arithmetic (overflow-checked)

    func adding(_ other: Money) throws -> Money {
        guard currencyCode == other.currencyCode else { throw MoneyError.currencyMismatch }
        let (result, overflow) = minorUnits.addingReportingOverflow(other.minorUnits)
        guard !overflow else { throw MoneyError.overflow }
        return Money(minorUnits: result, currencyCode: currencyCode)
    }

    func subtracting(_ other: Money) throws -> Money {
        guard currencyCode == other.currencyCode else { throw MoneyError.currencyMismatch }
        let (result, overflow) = minorUnits.subtractingReportingOverflow(other.minorUnits)
        guard !overflow else { throw MoneyError.overflow }
        return Money(minorUnits: result, currencyCode: currencyCode)
    }

    // MARK: Formatting

    /// Plain digits with no symbol or grouping, e.g. "-12.34". Uses integer maths only.
    func plainString(decimalSeparator: String = ".") -> String {
        let digits = Money.fractionDigits(for: currencyCode)
        var divisor: UInt64 = 1
        for _ in 0..<digits { divisor *= 10 }
        let magnitude = minorUnits.magnitude
        let whole = magnitude / divisor
        let sign = minorUnits < 0 ? "-" : ""
        guard digits > 0 else { return "\(sign)\(whole)" }
        let fraction = String(magnitude % divisor)
        let padded = String(repeating: "0", count: digits - fraction.count) + fraction
        return "\(sign)\(whole)\(decimalSeparator)\(padded)"
    }

    /// Localised display string with currency symbol, built from an exact Decimal.
    func formatted(locale: Locale = .current) -> String {
        let digits = Money.fractionDigits(for: currencyCode)
        let decimal = Decimal(
            sign: minorUnits < 0 ? .minus : .plus,
            exponent: -digits,
            significand: Decimal(minorUnits.magnitude)
        )
        return decimal.formatted(.currency(code: currencyCode).locale(locale))
    }
}
