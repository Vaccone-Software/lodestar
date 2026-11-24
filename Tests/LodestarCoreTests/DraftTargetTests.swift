import XCTest
@testable import LodestarCore

/// When ⏎ posts the paste and when it only copies: only a positive "nothing
/// here takes text" refuses, and every doubt pastes.
final class DraftTargetTests: XCTestCase {
    func testNothingFocusedIsACopy() {
        XCTAssertFalse(Draft.pastes(into: .noFocus), "Finder with no window, a desktop")
    }

    func testAListOutlineTableBrowserOrImageIsACopy() {
        for role in ["AXList", "AXOutline", "AXTable", "AXBrowser", "AXImage"] {
            XCTAssertFalse(Draft.pastes(into: .focus(role: role, text: false)), role)
        }
    }

    func testFieldsAndTextAreasPaste() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"] {
            XCTAssertTrue(Draft.pastes(into: .focus(role: role, text: true)), role)
        }
    }

    func testATerminalWhoseTextAreaDoesNotLookLikeAFieldStillPastes() {
        // Ghostty draws its own text: what the focus shows is a group or a
        // scroll area, with or without a caret.
        XCTAssertTrue(Draft.pastes(into: .focus(role: "AXGroup", text: false)))
        XCTAssertTrue(Draft.pastes(into: .focus(role: "AXScrollArea", text: false)))
        XCTAssertTrue(Draft.pastes(into: .focus(role: "AXTextArea", text: false)))
    }

    func testAWebAreaPastes() {
        XCTAssertTrue(Draft.pastes(into: .focus(role: "AXWebArea", text: false)))
    }

    func testAListThatShowsACaretPastes() {
        XCTAssertTrue(Draft.pastes(into: .focus(role: "AXTable", text: true)),
                      "a cell being edited is the text, whatever holds it")
    }

    func testAnUnansweredQuestionPastes() {
        XCTAssertTrue(Draft.pastes(into: .unknown))
    }
}
