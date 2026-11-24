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
        // would be a highlight the geometry cannot keep. The left column
        // is still one column, though, even with the right one's line
        // sitting between its lines in reading order.
        let runs = SelectRuns.merge([
            leaf(0, "left column", x: 10, y: 100, w: 120),
            leaf(1, "right column", x: 400, y: 100, w: 120),
            leaf(2, "left continues", x: 10, y: 120, w: 120),
        ])
        XCTAssertEqual(runs.map(\.text), ["left column\nleft continues", "right column"],
                       "a layout gap is a wall, not a space")
    }

    func testInterleavedColumnsEachBecomeOneRun() {
        // A sidebar beside a page, as reading order delivers it: the two
        // columns alternate line by line. Each column is one run, and no
        // run holds a line of the other.
        let runs = SelectRuns.merge([
            leaf(0, "Inbox", x: 0, y: 100, w: 120),
            leaf(1, "The sensor is the screen itself.", x: 400, y: 100, w: 500),
            leaf(2, "Starred", x: 0, y: 120, w: 120),
            leaf(3, "Trees build lazily and un-build after idle.", x: 400, y: 120, w: 500),
            leaf(4, "Sent", x: 0, y: 140, w: 120),
            leaf(5, "Pixels have none of those properties.", x: 400, y: 140, w: 500),
        ])
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].text, "Inbox\nStarred\nSent")
        XCTAssertEqual(runs[0].fragments.map(\.leaf), [0, 2, 4])
        XCTAssertEqual(runs[1].text,
                       "The sensor is the screen itself.\n"
                       + "Trees build lazily and un-build after idle.\n"
                       + "Pixels have none of those properties.")
        XCTAssertEqual(runs[1].fragments.map(\.leaf), [1, 3, 5])
    }

    func testCardsBesideASidebarEachBecomeOneRun() {
        // Three columns: a sidebar and two cards in a grid. Every group
        // comes out whole, in the order each began.
        let runs = SelectRuns.merge([
            leaf(0, "Inbox", x: 0, y: 100, w: 120),
            leaf(1, "Card one", x: 300, y: 100, w: 300),
            leaf(2, "Card two", x: 800, y: 100, w: 300),
            leaf(3, "Starred", x: 0, y: 120, w: 120),
            leaf(4, "First line of card one.", x: 300, y: 120, w: 300),
            leaf(5, "First line of card two.", x: 800, y: 120, w: 300),
            leaf(6, "Sent", x: 0, y: 140, w: 120),
            leaf(7, "Second line of card one.", x: 300, y: 140, w: 300),
            leaf(8, "Second line of card two.", x: 800, y: 140, w: 300),
            leaf(9, "Drafts", x: 0, y: 160, w: 120),
        ])
        XCTAssertEqual(runs.map { $0.fragments.map(\.leaf) },
                       [[0, 3, 6, 9], [1, 4, 7], [2, 5, 8]])
    }

    func testAnInterleavedColumnDoesNotBridgeABlockGap() {
        // The vertical reach is the block gap, whichever column's line
        // happens to sit between: a left line far below the left block
        // starts a new run, exactly as it would with nothing between.
        let runs = SelectRuns.merge([
            leaf(0, "left paragraph", x: 10, y: 100, w: 200),
            leaf(1, "right column", x: 400, y: 100, w: 200),
            leaf(2, "left footer", x: 10, y: 150, w: 200),
        ])
        XCTAssertEqual(runs.map(\.text), ["left paragraph", "right column", "left footer"])
    }

    func testALeafLeftOfALineIsNotItsContinuation() {
        // A tall heading sorts ahead of a short sidebar item on the same
        // visual line (its top is higher, its center is not). The item
        // lies to the heading's left, so it is not the heading's next
        // fragment — appending it would spell "heading" + "item" for text
        // that reads the other way round.
        let runs = SelectRuns.merge([
            leaf(0, "A year of memory", x: 400, y: 100, w: 500, h: 24),
            leaf(1, "Inbox", x: 0, y: 108, w: 100, h: 12),
        ])
        XCTAssertEqual(runs.map(\.text), ["A year of memory", "Inbox"])
    }

    func testSameLineFragmentsJoinTheirOwnColumn() {
        // A styling split inside the right column's line, with the left
        // column's line on the same row: the fragment joins the run
        // whose line ends nearest to its left, not the leftmost one.
        let runs = SelectRuns.merge([
            leaf(0, "left", x: 0, y: 100, w: 60),
            leaf(1, "this", x: 400, y: 100, w: 30),
            leaf(2, "word", x: 434, y: 100, w: 34),
            leaf(3, "left again", x: 0, y: 120, w: 60),
        ])
        XCTAssertEqual(runs.map(\.text), ["left\nleft again", "this word"])
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

    func testLeavesAreStitchedWithinTheirOwnWindow() {
        // A narrow front window laid over a paragraph, showing a line in
        // the same column. Without windows the three lines read as one
        // run; with them, the front window's line is a run of its own and
        // the paragraph beneath is stitched around it.
        let leaves = [
            leaf(0, "paragraph line one", x: 100, y: 100, w: 500),
            leaf(1, "front window line", x: 100, y: 120, w: 500),
            leaf(2, "paragraph line two", x: 100, y: 140, w: 500),
        ]
        XCTAssertEqual(SelectRuns.merge(leaves).count, 1)
        let front = CGRect(x: 50, y: 112, width: 700, height: 30)
        let back = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let runs = SelectRuns.merge(leaves, windows: [front, back])
        XCTAssertEqual(runs.map(\.text),
                       ["front window line", "paragraph line one\nparagraph line two"])
    }

    func testALeafOutsideEveryWindowStandsAlone() {
        // Menu bar text above every window: close enough to a window's
        // first line to stitch by geometry, but owned by no window.
        let leaves = [
            leaf(0, "File", x: 20, y: 10, w: 40),
            leaf(1, "body line", x: 20, y: 40, w: 300),
        ]
        XCTAssertEqual(SelectRuns.merge(leaves).count, 1)
        let window = CGRect(x: 0, y: 30, width: 1000, height: 1000)
        XCTAssertEqual(SelectRuns.merge(leaves, windows: [window]).map(\.text),
                       ["body line", "File"], "the window's runs first, the unowned after")
    }

    func testNoWindowsMeansNoPartition() {
        let leaves = [
            leaf(0, "first line", x: 10, y: 100, w: 300),
            leaf(1, "second line", x: 10, y: 120, w: 300),
        ]
        XCTAssertEqual(SelectRuns.merge(leaves, windows: []), SelectRuns.merge(leaves))
    }

    func testEmptyInputMakesNoRuns() {
        XCTAssertEqual(SelectRuns.merge([]), [])
    }
}
