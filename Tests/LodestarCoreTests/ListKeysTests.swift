import AppKit
import XCTest
@testable import LodestarCore

final class ListKeysTests: XCTestCase {
    private func delta(_ selector: Selector, letter: String? = nil, control: Bool = false) -> Int? {
        ListKeys.delta(for: selector, letter: letter, control: control)
    }

    /// The arrows, and with them ⌃N/⌃P — macOS binds those to the very same
    /// selectors, so the panels never see the difference.
    func testArrowsMove() {
        XCTAssertEqual(delta(#selector(NSResponder.moveDown(_:))), 1)
        XCTAssertEqual(delta(#selector(NSResponder.moveUp(_:))), -1)
    }

    /// ⌃K arrives as the kill-to-end selector and nothing else produces it,
    /// so it is read as intent whatever key a personal binding put it on.
    func testKillToEndIsPrevious() {
        XCTAssertEqual(delta(#selector(NSResponder.deleteToEndOfParagraph(_:))), -1)
        XCTAssertEqual(delta(#selector(NSResponder.deleteToEndOfParagraph(_:)),
                             letter: "k", control: true), -1)
    }

    /// ⌃J lands in `noop:` — the bucket every unclaimed control key falls
    /// into — so it is claimed only when the event says J, with control.
    func testControlJIsNextAndNothingElseInTheBucketIs() {
        XCTAssertEqual(delta(ListKeys.noop, letter: "j", control: true), 1)
        XCTAssertEqual(delta(ListKeys.noop, letter: "J", control: true), 1)
        XCTAssertNil(delta(ListKeys.noop, letter: "g", control: true))
        XCTAssertNil(delta(ListKeys.noop, letter: "z", control: true))
        XCTAssertNil(delta(ListKeys.noop, letter: "j", control: false))
        XCTAssertNil(delta(ListKeys.noop, letter: nil, control: true))
    }

    /// Everything a field editor does that is not about the list stays the
    /// field editor's — typing, escaping, committing, and the other emacs
    /// motions the system already answers inside the query itself.
    func testTheRestPassesThrough() {
        for selector in [#selector(NSResponder.insertNewline(_:)),
                         #selector(NSResponder.cancelOperation(_:)),
                         #selector(NSResponder.insertTab(_:)),
                         #selector(NSResponder.deleteForward(_:)),
                         #selector(NSResponder.deleteBackward(_:)),
                         #selector(NSResponder.moveToBeginningOfParagraph(_:)),
                         #selector(NSResponder.moveToEndOfParagraph(_:)),
                         #selector(NSResponder.moveForward(_:)),
                         #selector(NSResponder.moveBackward(_:))] {
            XCTAssertNil(delta(selector, letter: "x", control: true),
                         "\(NSStringFromSelector(selector)) is not the list's key")
        }
    }
}
