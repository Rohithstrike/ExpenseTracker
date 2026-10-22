import XCTest
@testable import ExpenseTracker

final class MoneyTests: XCTestCase {
    private func parse(_ s: String, _ c: String = "INR", sep: Character = ".") throws -> Int64 {
        try Money.parse(s, currencyCode: c, decimalSeparator: sep).minorUnits
    }

    func testParsesValidInput() throws {
        XCTAssertEqual(try parse("123"), 12_300)
        XCTAssertEqual(try parse("12.34"), 1_234)
        XCTAssertEqual(try parse("12.3"), 1_230)
        XCTAssertEqual(try parse("12."), 1_200)
        XCTAssertEqual(try parse(".5"), 50)
        XCTAssertEqual(try parse("0.07"), 7)
        XCTAssertEqual(try parse("0"), 0)
        XCTAssertEqual(try parse("  45.60 "), 4_560)
        XCTAssertEqual(try parse("12,34", sep: ","), 1_234)
    }

    func testParsesCurrencyPrecision() throws {
        XCTAssertEqual(try parse("150", "JPY"), 150)
        XCTAssertEqual(try parse("1.234", "KWD"), 1_234)
    }

    func testRejectsInvalidInput() {
        let bad = ["", "   ", "abc", "1.2.3", "-5", "+5", "1e5", "1 000", ".", "1,000", "٣", "5\u{0301}"]
        for text in bad {
            XCTAssertThrowsError(try parse(text), "Should reject '\(text)'")
        }
        XCTAssertThrowsError(try parse("12,34")) // comma is not the separator here
    }

    func testRejectsExtraDecimalsInsteadOfRounding() {
        XCTAssertThrowsError(try parse("1.234")) { XCTAssertEqual($0 as? MoneyError, .tooManyDecimals) }
        XCTAssertThrowsError(try parse("1.5", "JPY")) { XCTAssertEqual($0 as? MoneyError, .tooManyDecimals) }
    }

    func testLimitAndOverflowBoundaries() throws {
        XCTAssertEqual(try parse("999999999.99"), Money.maxInputMinorUnits)
        XCTAssertThrowsError(try parse("1000000000.00")) { XCTAssertEqual($0 as? MoneyError, .exceedsLimit) }
        XCTAssertThrowsError(try parse("99999999999999999999")) { XCTAssertEqual($0 as? MoneyError, .overflow) }
    }

    func testRejectsInvalidCurrency() {
        for code in ["IN", "I1R", "", "INRR"] {
            XCTAssertThrowsError(try parse("1", code)) { XCTAssertEqual($0 as? MoneyError, .invalidCurrency) }
        }
        XCTAssertEqual(try parse("1", "inr"), 100) // lowercase accepted
    }

    func testPlainStringFormatting() {
        XCTAssertEqual(Money(minorUnits: 1_234, currencyCode: "INR").plainString(), "12.34")
        XCTAssertEqual(Money(minorUnits: 5, currencyCode: "INR").plainString(), "0.05")
        XCTAssertEqual(Money(minorUnits: -5, currencyCode: "INR").plainString(), "-0.05")
        XCTAssertEqual(Money(minorUnits: 100, currencyCode: "JPY").plainString(), "100")
        XCTAssertEqual(Money(minorUnits: 1_234, currencyCode: "KWD").plainString(), "1.234")
        XCTAssertEqual(Money(minorUnits: 1_234, currencyCode: "INR").plainString(decimalSeparator: ","), "12,34")
        XCTAssertEqual(Money(minorUnits: Int64.min, currencyCode: "INR").plainString(), "-92233720368547758.08")
        XCTAssertEqual(Money(minorUnits: Int64.max, currencyCode: "INR").plainString(), "92233720368547758.07")
    }

    func testRoundTrip() throws {
        for value: Int64 in [0, 1, 99, 100, 12_345, Money.maxInputMinorUnits] {
            let text = Money(minorUnits: value, currencyCode: "INR").plainString()
            XCTAssertEqual(try parse(text), value)
        }
    }

    func testLocalisedFormatting() {
        let text = Money(minorUnits: 123_450, currencyCode: "USD").formatted(locale: Locale(identifier: "en_US"))
        XCTAssertTrue(text.contains("1,234.50"), text)
    }

    func testArithmeticAndOverflow() throws {
        let a = Money(minorUnits: 1_000, currencyCode: "INR")
        let b = Money(minorUnits: 250, currencyCode: "INR")
        XCTAssertEqual(try a.adding(b).minorUnits, 1_250)
        XCTAssertEqual(try a.subtracting(b).minorUnits, 750)
        XCTAssertThrowsError(try a.adding(Money(minorUnits: 1, currencyCode: "USD"))) {
            XCTAssertEqual($0 as? MoneyError, .currencyMismatch)
        }
        XCTAssertThrowsError(try Money(minorUnits: .max, currencyCode: "INR").adding(b)) {
            XCTAssertEqual($0 as? MoneyError, .overflow)
        }
        XCTAssertThrowsError(try Money(minorUnits: .min, currencyCode: "INR").subtracting(b)) {
            XCTAssertEqual($0 as? MoneyError, .overflow)
        }
    }
}
