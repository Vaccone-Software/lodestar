import XCTest
@testable import LodestarCore

/// Stitching shattered text back into prose: the merge rules are what let
/// a phrase match across a bold boundary and a span cross fragments, and
/// the conservative side of those rules is what keeps unrelated columns
/// from being promised as one selectable stretch.
final class SelectRunsTests: XCTestCase {
    private func leaf(_ id: Int, _ text: String, x: CGFloat, y: CGFloat,
                      w: CGFloat, h: CGFloat = 16) -> SelectRuns.Leaf {
        SelectRuns.Leaf(id: id, text: text, frame: CGRect(x: x, y: y, width: w, height: h))
    }

    func testFragmentsOnOneLineStitchWithTheGapTheLayoutDrew() {
        // "this " + "word" + " here" as three styling runs, tightly packed.
        let runs = SelectRuns.merge([
            leaf(0, "this", x: 0, y: 100, w: 30),
            leaf(1, "word", x: 34, y: 100, w: 34),
            leaf(2, "here", x: 72, y: 100, w: 30),
        ])
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].text, "this word here",
                       "a drawn gap becomes a space; the phrase is matchable")
    }

    func testTightFragmentsJoinWithNothing() {
        // "http" + "s://" split mid-token by styling: no gap, no space.
        let runs = SelectRuns.merge([
            leaf(0, "http", x: 0, y: 100, w: 28),
            leaf(1, "s://", x: 28.5, y: 100, w: 24),
        ])
        XCTAssertEqual(runs[0].text, "https://")
    }

    func testLinesOfOneColumnJoinWithNewlines() {
        let runs = SelectRuns.merge([
            leaf(0, "first line of the paragraph", x: 10, y: 100, w: 300),
            leaf(1, "second line of the paragraph", x: 10, y: 120, w: 300),
        ])
        XCTAssertEqual(runs.count, 1)
        XCTAssertTrue(runs[0].text.contains("paragraph\nsecond"))
    }

    func testSideBySideColumnsNeverMerge() {
        // Two columns on the same lines: promising a span across them
        // would be a highlight the geometry cannot keep.
        let runs = SelectRuns.merge([
            leaf(0, "left column", x: 10, y: 100, w: 120),
            leaf(1, "right column", x: 400, y: 100, w: 120),
            leaf(2, "left continues", x: 10, y: 120, w: 120),
        ])
        XCTAssertEqual(runs.count, 3, "a layout gap is a wall, not a space")
    }

    func testABigVerticalGapBreaksTheBlock() {
        let runs = SelectRuns.merge([
            leaf(0, "paragraph one", x: 10, y: 100, w: 200),
            leaf(1, "far away footer", x: 10, y: 400, w: 200),
        ])
        XCTAssertEqual(runs.count, 2)
    }

    func testSlicesMapARangeBackOntoFragments() {
        let runs = SelectRuns.merge([
            leaf(7, "this", x: 0, y: 100, w: 30),
            leaf(8, "word", x: 34, y: 100, w: 34),
            leaf(9, "here", x: 72, y: 100, w: 30),
        ])
        // "s word he" — starts inside leaf 7, covers 8, ends inside 9.
        let range = NSRange(location: 3, length: 9)
        let slices = runs[0].slices(of: range)
        XCTAssertEqual(slices.map(\.leaf), [7, 8, 9])
        XCTAssertEqual(slices[0].localRange, NSRange(location: 3, length: 1))
        XCTAssertEqual(slices[1].localRange, NSRange(location: 0, length: 4))
        XCTAssertEqual(slices[2].localRange, NSRange(location: 0, length: 2))
        // The joiner spaces belong to nobody: total sliced length is 7,
        // the two spaces drop out of geometry but stay in the copy.
        XCTAssertEqual(slices.map(\.localRange.length).reduce(0, +), 7)
        XCTAssertEqual((runs[0].text as NSString).substring(with: range), "s word he")
    }

    func testEmptyInputMakesNoRuns() {
        XCTAssertEqual(SelectRuns.merge([]), [])
    }
}
