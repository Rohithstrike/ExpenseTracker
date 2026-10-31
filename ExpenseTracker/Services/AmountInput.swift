import Foundation

/// Keypad logic only. Text is kept canonical (always "." as the separator);
/// a key press is accepted only if the result still parses as valid Money,
/// so precision and size limits come from the Phase 2 parser.
struct AmountInput: Equatable {
    private(set) var currencyCode: String
    let decimalSeparator: Character
    private(set) var text: String = ""

    init(currencyCode: String, decimalSeparator: Character = ".") {
        self.currencyCode = currencyCode.uppercased()
        self.decimalSeparator = decimalSeparator
    }

    var isEmpty: Bool { text.isEmpty }
    var allowsDecimal: Bool { Money.fractionDigits(for: currencyCode) > 0 }
    var money: Money? { try? Money.parse(text, currencyCode: currencyCode) }
    var isSavable: Bool { (money?.minorUnits ?? 0) > 0 }

    var displayText: String {
        (text.isEmpty ? "0" : text)
            .replacingOccurrences(of: ".", with: String(decimalSeparator))
    }

    mutating func appendDigit(_ digit: Int) {
        guard (0...9).contains(digit) else { return }
        if text == "0" {
            guard digit != 0 else { return }   // no "00"
            accept(String(digit))              // "0" then 5 becomes "5"
        } else {
            accept(text + String(digit))
        }
    }

    mutating func appendDecimal() {
        guard allowsDecimal, !text.contains(".") else { return }
        accept(text.isEmpty ? "0." : text + ".")
    }

    mutating func backspace() {
        guard !text.isEmpty else { return }
        text.removeLast()
    }

    mutating func clear() { text = "" }

    mutating func setCurrency(_ code: String) {
        let upper = code.uppercased()
        guard upper != currencyCode else { return }
        currencyCode = upper
        text = ""
    }

    /// Pre-fills the amount (for editing). Rejected, empty or non-positive amounts leave it empty.
    mutating func load(minorUnits: Int64) {
        text = ""
        guard minorUnits > 0 else { return }
        accept(Money(minorUnits: minorUnits, currencyCode: currencyCode).plainString())
    }

    private mutating func accept(_ candidate: String) {
        if (try? Money.parse(candidate, currencyCode: currencyCode)) != nil {
            text = candidate
        }
    }
}
