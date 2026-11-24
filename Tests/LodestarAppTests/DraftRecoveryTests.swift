import XCTest
@testable import lodestar

/// A draft a run left in flight comes back whatever ended the run, and as
/// a card when the history can take one, so the pasteboard is not taken.
final class DraftRecoveryTests: XCTestCase {
    func testARecoveredDraftBecomesACardAndLeavesThePasteboardAlone() {
        let stage = Stage()
        stage.seedClip("something copied last")
        var pasteboard: [String] = []
        var flashes: [String] = []
        DraftRecovery.restore("words that were in flight",
                              keepCard: { stage.clipboard.keepRecovered($0) },
                              pasteboard: { pasteboard.append($0) },
                              flash: { flashes.append($0) })
        stage.clipboard.history.flushIO()
        XCTAssertEqual(stage.clipboard.history.clips.first?.preview, "words that were in flight")
        XCTAssertEqual(stage.clipboard.history.clips.count, 2, "the earlier card is still there")
        XCTAssertTrue(pasteboard.isEmpty, "what the hand copied last is not replaced")
        XCTAssertEqual(flashes, ["⌂ Your draft is in the clipboard history"])
    }

    func testAHistoryThatCannotTakeItFallsBackToThePasteboard() {
        var pasteboard: [String] = []
        var flashes: [String] = []
        DraftRecovery.restore("words that were in flight",
                              keepCard: { _ in false },
                              pasteboard: { pasteboard.append($0) },
                              flash: { flashes.append($0) })
        XCTAssertEqual(pasteboard, ["words that were in flight"])
        XCTAssertEqual(flashes, ["⌂ Your draft is on the clipboard"])
    }

    func testTheSameWordsKeptTwiceAreOneCardAtTheTop() {
        let stage = Stage()
        XCTAssertTrue(stage.clipboard.keepRecovered("one draft"))
        stage.seedClip("later copy")
        XCTAssertTrue(stage.clipboard.keepRecovered("one draft"))
        stage.clipboard.history.flushIO()
        XCTAssertEqual(stage.clipboard.history.clips.map(\.preview), ["one draft", "later copy"])
    }

    func testAnEmptyDraftIsNotACard() {
        let stage = Stage()
        XCTAssertFalse(stage.clipboard.keepRecovered(""))
    }
}
