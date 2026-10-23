// ExpenseTrackerTests/WalletFormInputTests.swift  (new file)
import XCTest
@testable import ExpenseTracker

final class WalletFormInputTests: XCTestCase {
    private func parse(_ text: String, _ currency: String = "INR", sep: Character = ".") throws -> Int64 {
        try WalletFormInput.openingBalanceMinor(from: text, currencyCode: currency, decimalSeparator: sep)
    }

    func testEmptyMeansZero() throws {
        XCTAssertEqual(try parse(""), 0)
        XCTAssertEqual(try parse("   "), 0)
    }

    func testPositiveValues() throws {
        XCTAssertEqual(try parse("5000"), 500_000)
        XCTAssertEqual(try parse("5000.5"), 500_050)
        XCTAssertEqual(try parse("0.07"), 7)
        XCTAssertEqual(try parse(".5"), 50)
        XCTAssertEqual(try parse("12."), 1_200)
        XCTAssertEqual(try parse("  45.60 "), 4_560)
    }

    func testNegativeValues() throws {
        XCTAssertEqual(try parse("-250"), -25_000)
        XCTAssertEqual(try parse("\u{2212}250.75"), -25_075)   // typographic minus
        XCTAssertEqual(try parse("-0"), 0)
    }

    func testSeparatorsAndCurrencyPrecision() throws {
        XCTAssertEqual(try parse("12,5", sep: ","), 1_250)
        XCTAssertEqual(try parse("150", "JPY"), 150)
        XCTAssertEqual(try parse("1.234", "KWD"), 1_234)
    }

    func testInvalidFormatIsRejected() {
        for text in ["abc", "1.2.3", "--5", "+5", "- 5", "-", "1e5", "5,000", "1 000", "5-"] {
            XCTAssertThrowsError(try parse(text), "'\(text)'") {
                XCTAssertEqual($0 as? WalletFormError, .invalidFormat)
            }
        }
    }

    func testTooManyDecimalsIsRejectedNotRounded() {
        XCTAssertThrowsError(try parse("1.234")) {
            XCTAssertEqual($0 as? WalletFormError, .tooManyDecimals)
        }
        XCTAssertThrowsError(try parse("1.5", "JPY")) {
            XCTAssertEqual($0 as? WalletFormError, .tooManyDecimals)
        }
    }

    func testSizeLimitsApplyToBothSigns() throws {
        XCTAssertEqual(try parse("999999999.99"), Money.maxInputMinorUnits)
        XCTAssertEqual(try parse("-999999999.99"), -Money.maxInputMinorUnits)
        for text in ["1000000000", "-1000000000", "99999999999999999999"] {
            XCTAssertThrowsError(try parse(text), text) {
                XCTAssertEqual($0 as? WalletFormError, .tooLarge)
            }
        }
    }

    func testInvalidCurrencyIsReported() {
        XCTAssertThrowsError(try parse("1", "IN")) {
            XCTAssertEqual($0 as? WalletFormError, .invalidCurrency)
        }
    }

    func testTextRoundTrip() throws {
        let values: [Int64] = [0, 1, 99, 100, 12_345, -5, -50_000,
                               Money.maxInputMinorUnits, -Money.maxInputMinorUnits]
        for value in values {
            for currency in ["INR", "JPY", "KWD"] {
                let text = WalletFormInput.text(forOpeningBalance: value, currencyCode: currency)
                XCTAssertEqual(try parse(text, currency), value, "\(value) \(currency) via '\(text)'")
            }
        }
        XCTAssertEqual(
            WalletFormInput.text(forOpeningBalance: -1_050, currencyCode: "INR", decimalSeparator: ","),
            "-10,50")
    }

    func testMakeInputPassesFieldsThrough() throws {
        let input = try WalletFormInput.makeInput(
            name: " Cash ", emoji: "💵", openingBalanceText: "-10.5", currencyCode: "inr")
        XCTAssertEqual(input, WalletInput(
            name: " Cash ", emoji: "💵", openingBalanceMinor: -1_050, currencyCode: "inr"))
    }

    func testMakeInputPropagatesErrors() {
        XCTAssertThrowsError(try WalletFormInput.makeInput(
            name: "Cash", emoji: "💵", openingBalanceText: "abc", currencyCode: "INR")) {
            XCTAssertEqual($0 as? WalletFormError, .invalidFormat)
        }
    }

    func testCurrencyChoicesAreValidAndUnique() {
        let choices = WalletFormInput.currencyChoices
        XCTAssertTrue(choices.contains("INR"))
        XCTAssertEqual(Set(choices).count, choices.count)
        for code in choices {
            XCTAssertTrue(Money.isValidCurrencyCode(code), code)
        }
    }
}
