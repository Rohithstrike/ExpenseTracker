import XCTest
@testable import ExpenseTracker

@MainActor
final class AmountInputTests: XCTestCase {
    /// Digits and "." press keys; "<" is backspace.
    private func type(_ keys: String, into input: inout AmountInput) {
        for key in keys {
            if let digit = key.wholeNumberValue, key.isASCII {
                input.appendDigit(digit)
            } else if key == "." {
                input.appendDecimal()
            } else if key == "<" {
                input.backspace()
            }
        }
    }

    private func result(_ keys: String, currency: String = "INR") -> String {
        var input = AmountInput(currencyCode: currency)
        type(keys, into: &input)
        return input.text
    }

    func testBasicDigits() {
        XCTAssertEqual(result("125"), "125")
    }

    func testLeadingZeros() {
        XCTAssertEqual(result("005"), "5")
        XCTAssertEqual(result("0"), "0")
        XCTAssertEqual(result("0.05"), "0.05")
    }

    func testSingleDecimalPoint() {
        XCTAssertEqual(result("1.2.3"), "1.23")
        XCTAssertEqual(result("."), "0.")
        XCTAssertEqual(result("5."), "5.")
    }

    func testPrecisionLimitByCurrency() {
        XCTAssertEqual(result("1.2345"), "1.23")
        XCTAssertEqual(result("1.2345", currency: "KWD"), "1.234")
        XCTAssertEqual(result("1.5", currency: "JPY"), "15")   // decimal key ignored
    }

    func testMagnitudeLimit() {
        XCTAssertEqual(result("9999999999"), "999999999")        // 10th digit rejected
        XCTAssertEqual(result("999999999.999"), "999999999.99")
        var input = AmountInput(currencyCode: "INR")
        type("999999999.99", into: &input)
        XCTAssertEqual(input.money?.minorUnits, Money.maxInputMinorUnits)
    }

    func testBackspaceAndClear() {
        XCTAssertEqual(result("12<"), "1")
        XCTAssertEqual(result("1<<<"), "")
        XCTAssertEqual(result("1.<"), "1")
        var input = AmountInput(currencyCode: "INR")
        type("45.6", into: &input)
        input.clear()
        XCTAssertTrue(input.isEmpty)
        XCTAssertEqual(input.displayText, "0")
    }

    func testDisplaySeparator() {
        var input = AmountInput(currencyCode: "EUR", decimalSeparator: ",")
        type("12.5", into: &input)
        XCTAssertEqual(input.text, "12.5")
        XCTAssertEqual(input.displayText, "12,5")
    }

    func testSavableOnlyWhenPositive() {
        for keys in ["", "0", "0.", "0.00"] {
            var input = AmountInput(currencyCode: "INR")
            type(keys, into: &input)
            XCTAssertFalse(input.isSavable, "'\(keys)'")
        }
        var input = AmountInput(currencyCode: "INR")
        type("0.01", into: &input)
        XCTAssertTrue(input.isSavable)
        XCTAssertEqual(input.money?.minorUnits, 1)
    }

    func testChangingCurrencyClearsAmount() {
        var input = AmountInput(currencyCode: "INR")
        type("12.5", into: &input)
        input.setCurrency("INR")
        XCTAssertEqual(input.text, "12.5")
        input.setCurrency("JPY")
        XCTAssertTrue(input.isEmpty)
    }
}
