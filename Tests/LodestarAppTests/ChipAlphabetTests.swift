import LodestarCore
import XCTest
@testable import lodestar

/// The label alphabet's order is a promise to the hand: the same target
/// wears the same chip whichever window it is in, and the hand never
/// leaves the home row while a home-row letter is still unspent.
final class ChipAlphabetTests: XCTestCase {
    func testRowsComeInOneFixedOrder() {
        let alphabet = KeyboardLayout.chipAlphabet()
        XCTAssertTrue(alphabet.hasPrefix("asdfghjkl"), "the home row is spent first")
        XCTAssertEqual(alphabet, "asdfghjklqwertyuiopzxcvbnm",
                       "home row, then the top row, then the bottom")
    }

    func testEveryLetterIsALetterAndAppearsOnce() {
        let alphabet = KeyboardLayout.chipAlphabet()
        XCTAssertEqual(Set(alphabet).count, alphabet.count)
        XCTAssertTrue(alphabet.allSatisfy { $0.isLetter && $0.isASCII && $0.isLowercase })
        XCTAssertEqual(alphabet.count, 26, "no key of the three rows is left out")
    }

    func testSinglesReachTheWholeAlphabetBeforePairs() {
        // The point of the wider alphabet: twenty-six targets answer on
        // one keystroke where nine letters made every one of them two.
        let labels = HintLabels.labels(count: 26, alphabet: KeyboardLayout.chipAlphabet())
        XCTAssertTrue(labels.allSatisfy { $0.count == 1 })
        XCTAssertEqual(labels.first, "a")
        XCTAssertEqual(labels[9], "q", "the tenth chip is the top row's first key")
    }
}
