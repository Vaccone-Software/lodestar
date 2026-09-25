import XCTest
@testable import LodestarCore

/// Arithmetic is read as its answer; what only looks like arithmetic is not.
final class ClipSumTests: XCTestCase {
    private let english = Locale(identifier: "en_US")
    private func answer(_ text: String) -> String? { ClipSum.parse(text)?.voice(locale: english) }

    func testAnswers() {
        XCTAssertEqual(answer("1234 * 1.08"), "1,332.72")
        XCTAssertEqual(answer("(12 + 7) / 3"), "6.3333")
        XCTAssertEqual(answer("2^10"), "1,024")
        XCTAssertEqual(answer("2^3^2"), "512", "powers from the right")
        XCTAssertEqual(answer("200 * 15%"), "30")
        XCTAssertEqual(answer("-3 + 5"), "2")
        XCTAssertEqual(answer("10 - 3"), "7")
        XCTAssertEqual(answer("10 − 3"), "7", "the minus sign")
        XCTAssertEqual(answer("3 × 4"), "12")
        XCTAssertEqual(answer("10 ÷ 4"), "2.5")
        XCTAssertEqual(answer("1,234 + 1"), "1,235")
        XCTAssertEqual(answer("0.1 + 0.2"), "0.3")
    }

    func testWhatOnlyLooksLikeArithmetic() {
        for text in ["555-1234", "2026-09-25", "10-20", "9/25", "24/7", "1920x1080", "5", "-5", "50%",
                     "1/0", "1.2.3", "+1 555 123 4567", "hello + 2", "3 * (2", "1,5 + 2", "12:30 + 1"] {
            XCTAssertNil(ClipSum.parse(text), text)
        }
    }
}
