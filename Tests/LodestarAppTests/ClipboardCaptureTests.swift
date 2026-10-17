import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// What the poll does with a copy on the main thread, and what it leaves
/// for after the card exists.
final class ClipboardCaptureTests: XCTestCase {
    private var directory: URL!
    private var store: ClipboardStore!
    private var controller: ClipboardController!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-capture-\(UUID().uuidString)", isDirectory: true)
        store = ClipboardStore(root: directory)
        controller = ClipboardController(store: store)
    }

    override func tearDown() {
        store.saveNow()
        store.flushIO()
        try? FileManager.default.removeItem(at: directory)
    }

    private func copy(_ text: String) {
        let board = SystemEvents.pasteboard
        board.clearContents()
        board.setString(text, forType: .string)
        controller.capture()
    }

    private func wait(_ what: String, timeout: TimeInterval = 20, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(condition(), what)
    }

    func testAShortTextIsCountedAtOnce() throws {
        copy("one\ntwo\nthree")
        let clip = try XCTUnwrap(store.clips.first)
        XCTAssertEqual(clip.lines, 3)
        XCTAssertEqual(clip.characters, 13)
    }

    func testALongTextHasItsCardAtOnceAndItsCountsAfterwards() throws {
        let line = "the quick brown fox jumps over the lazy dog\r\n"
        let text = String(repeating: line, count: ClipboardController.countedInlineLimit / line.utf8.count + 10)
        XCTAssertGreaterThan(text.utf8.count, ClipboardController.countedInlineLimit)
        var redraws = 0
        store.onThumbnail = { redraws += 1 }
        let before = store.generation
        copy(text)
        let card = try XCTUnwrap(store.clips.first)
        XCTAssertNil(card.lines, "the main thread did not count it")
        XCTAssertNil(card.characters)
        XCTAssertEqual(card.preview, Clipboard.preview(of: text), "but the card is there, with its preview")
        XCTAssertGreaterThan(store.generation, before)

        wait("the counts arrive") { store.clips.first?.lines != nil }
        let expected = Clipboard.counts(of: text)
        XCTAssertEqual(store.clips.first?.lines, expected.lines)
        XCTAssertEqual(store.clips.first?.characters, expected.characters)
        XCTAssertGreaterThanOrEqual(redraws, 1, "an open strip is told, so the badge can say it")
    }

    func testCountsForACardThatWasDeletedMeanwhileGoNowhere() {
        let text = String(repeating: "x", count: ClipboardController.countedInlineLimit + 1)
        copy(text)
        let id = store.clips[0].id
        store.delete(id)
        let before = store.generation
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(store.clips.isEmpty)
        XCTAssertEqual(store.generation, before)
    }

    func testTheLongTextPastesWholeWhateverItsCardKnows() throws {
        let text = String(repeating: "abc ", count: ClipboardController.countedInlineLimit / 4 + 10)
        copy(text)
        store.flushIO()
        let id = try XCTUnwrap(store.clips.first).id
        XCTAssertEqual(store.plainText(id), text)
    }
}
