import XCTest
@testable import LodestarCore

/// The rule behind the Keyboards page's watch: redraw when the boards
/// differ from what the page was drawn from, and never otherwise.
final class KeyboardWatchTests: XCTestCase {
    private let apple = "1452:834:bc1af98d"
    private let kinesis = "7504:24926:782ec294"
    private let keychron = "13364:2064:cf3d8489"

    func testAWatchThatIsNotStandingHasNothingToSay() {
        var watch = KeyboardWatch()
        XCTAssertFalse(watch.isWatching)
        XCTAssertFalse(watch.shouldRedraw([apple, kinesis]), "no page, no redraw")
        XCTAssertFalse(watch.shouldRedraw([]), "still none")
    }

    func testATurnRedrawsOnlyWhenTheBoardsDiffer() {
        var watch = KeyboardWatch()
        watch.drew([apple, keychron])
        XCTAssertTrue(watch.isWatching)
        XCTAssertFalse(watch.shouldRedraw([apple, keychron]), "nothing moved")
        XCTAssertFalse(watch.shouldRedraw([apple, keychron]), "still nothing")
        XCTAssertTrue(watch.shouldRedraw([apple, kinesis]), "one left and another arrived")
        XCTAssertFalse(watch.shouldRedraw([apple, kinesis]), "and the redraw settles it")
    }

    func testEveryKindOfChangeCounts() {
        var watch = KeyboardWatch()
        watch.drew([apple])
        XCTAssertTrue(watch.shouldRedraw([apple, kinesis]), "one arrived")
        XCTAssertTrue(watch.shouldRedraw([apple]), "one left")
        XCTAssertTrue(watch.shouldRedraw([]), "the last one left")
        XCTAssertFalse(watch.shouldRedraw([]), "and stays gone")
    }

    func testStoppingEndsIt() {
        var watch = KeyboardWatch()
        watch.drew([apple])
        watch.stopped()
        XCTAssertFalse(watch.isWatching)
        XCTAssertFalse(watch.shouldRedraw([apple, kinesis]), "the page has gone; nothing to draw")
    }

    /// A page redrawn from the same boards is not a page that changed.
    func testDrawingAgainRebasesTheComparison() {
        var watch = KeyboardWatch()
        watch.drew([apple])
        watch.drew([apple, kinesis])
        XCTAssertFalse(watch.shouldRedraw([apple, kinesis]))
        XCTAssertTrue(watch.shouldRedraw([apple]))
    }
}
