import XCTest
@testable import lodestar
@testable import LodestarCore

/// ⏎ in the editor's lens: fixes land from the end of the text back, so
/// none moves another's range, and each is remembered where it stands once
/// all have landed, so one ⌫ can take the batch back.
final class FixAllOrderTests: XCTestCase {
    private func issue(_ location: Int, _ original: String, _ replacement: String) -> EditorIssue {
        EditorIssue(range: NSRange(location: location, length: (original as NSString).length),
                    original: original, replacement: replacement, kind: .spelling)
    }

    func testFixesApplyFromTheEndBack() {
        let order = EditorController.fixOrder([issue(0, "its", "it's"), issue(10, "teh", "the"),
                                               issue(5, "u", "you")])
        XCTAssertEqual(order.map(\.range.location), [10, 5, 0])
    }

    func testAMarkOverlappingOneTakenIsLeft() {
        let order = EditorController.fixOrder([issue(4, "recieve", "receive"), issue(8, "eve", "eave")])
        XCTAssertEqual(order.map(\.original), ["eve"], "the later one lands, the overlapping one waits")
    }

    func testEachFixIsRememberedWhereItStandsAfterAll() {
        // "its u teh" → "it's you the"
        let applied = EditorController.fixOrder([issue(0, "its", "it's"), issue(4, "u", "you"),
                                                 issue(6, "teh", "the")])
        let settled = Dictionary(uniqueKeysWithValues: zip(applied.map(\.original),
                                                           EditorController.settled(applied)))
        let text = "it's you the" as NSString
        XCTAssertEqual(text.substring(with: settled["its"]!), "it's")
        XCTAssertEqual(text.substring(with: settled["u"]!), "you")
        XCTAssertEqual(text.substring(with: settled["teh"]!), "the")
    }
}
