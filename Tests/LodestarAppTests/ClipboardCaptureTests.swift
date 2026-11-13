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
        store = SealedFixture.clipboardStore(directory)
        controller = ClipboardController(store: store)
    }

    override func tearDown() {
        store.close()
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

    /// A card whose blob will not open pastes nothing, and the board keeps
    /// what the hand copied last: the paste used to clear the board before
    /// it knew it had anything to write, so a failed paste wiped it.
    func testACardThatWillNotOpenLeavesTheBoardAsItWas() throws {
        copy("the card that will not open")
        store.flushIO()
        let card = try XCTUnwrap(store.clips.first)
        try FileManager.default.removeItem(at: try XCTUnwrap(store.blobURL(for: card.id)))
        let board = SystemEvents.pasteboard
        board.clearContents()
        board.setString("what the hand copied last", forType: .string)
        let before = board.changeCount
        var flashed: [String] = []
        controller.flash = { flashed.append($0) }
        var posted = 0
        controller.postPaste = { posted += 1 }

        controller.paste(card, action: .plain)

        XCTAssertEqual(flashed, ["✕ That clip could not be read"])
        XCTAssertEqual(posted, 0, "nothing was pasted")
        XCTAssertEqual(board.string(forType: .string), "what the hand copied last")
        XCTAssertEqual(board.changeCount, before, "the board was never touched")
    }

    /// A browser's Copy Image: one item that leads with the HTML of an
    /// `<img>` and carries the picture after it, in that order on the board.
    private func copyBrowserImage() throws -> (clip: Clipboard.Clip, html: Data, png: Data) {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let html = Data(#"<img src="https://example.com/picture.png">"#.utf8)
        let board = SystemEvents.pasteboard
        board.clearContents()
        let item = NSPasteboardItem()
        item.setData(html, forType: .html)
        item.setData(png, forType: .png)
        board.writeObjects([item])
        controller.capture()
        store.flushIO()
        let clip = try XCTUnwrap(store.clips.first)
        XCTAssertEqual(clip.kind, .image)
        XCTAssertEqual(store.nativeData(clip).map(\.type), [NSPasteboard.PasteboardType.html.rawValue,
                                                            NSPasteboard.PasteboardType.png.rawValue],
                       "kept in the board's order, the HTML first")
        return (clip, html, png)
    }

    /// Pastes the clip over a board that holds something else, and gives
    /// the one item the paste wrote.
    private func paste(_ clip: Clipboard.Clip, action: PasteAction) throws -> NSPasteboardItem {
        let board = SystemEvents.pasteboard
        board.clearContents()
        board.setString("something else", forType: .string)
        controller.secureInput = { false }
        var posted = 0
        controller.postPaste = { posted += 1 }
        controller.paste(clip, action: action)
        XCTAssertEqual(posted, 1)
        let items = try XCTUnwrap(board.pasteboardItems)
        XCTAssertEqual(items.count, 1)
        return try XCTUnwrap(items.first)
    }

    /// A plain paste of an image card is the picture, not whatever form
    /// led the copy: a browser leads with the HTML of an `<img>`, and an
    /// app that takes pictures but not that HTML got nothing, or a link.
    func testAPlainPasteOfABrowserImageIsThePicture() throws {
        let (clip, _, png) = try copyBrowserImage()
        let pasted = try paste(clip, action: .plain)
        XCTAssertEqual(pasted.data(forType: .png), png, "the picture")
        XCTAssertNil(pasted.data(forType: .html), "and not the HTML that led the copy")
    }

    /// ⇧ pastes as copied: every form, the HTML and the picture both.
    func testAPasteAsCopiedOfABrowserImageIsEveryForm() throws {
        let (clip, html, png) = try copyBrowserImage()
        let pasted = try paste(clip, action: .native)
        XCTAssertEqual(pasted.data(forType: .html), html)
        XCTAssertEqual(pasted.data(forType: .png), png)
    }
}

/// A copy is written in two steps the poll can fall between: the board is
/// cleared (the change count moves, the board is empty) and then written,
/// which does not move the count again (measured). A read that finds the
/// board cleared and not yet written must not spend the change, or that
/// copy is never seen.
final class ClipboardUnfilledCopyTests: XCTestCase {
    private var directory: URL!
    private var store: ClipboardStore!
    private var controller: ClipboardController!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-unfilled-\(UUID().uuidString)", isDirectory: true)
        store = SealedFixture.clipboardStore(directory)
        controller = ClipboardController(store: store)
    }

    override func tearDown() {
        store.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func testACopyCaughtBetweenClearAndWriteIsReadOnceWritten() {
        let board = SystemEvents.pasteboard
        board.clearContents()
        let cleared = board.changeCount
        controller.capture()
        XCTAssertTrue(store.clips.isEmpty, "nothing to keep yet")
        board.setString("written after the poll saw the clear", forType: .string)
        XCTAssertEqual(board.changeCount, cleared, "the write did not move the count")
        controller.capture()
        XCTAssertEqual(store.clips.first?.preview, "written after the poll saw the clear")
    }

    /// A board that stays empty is read again only for a while, then let be.
    func testABoardThatStaysEmptyIsLetBe() {
        final class Counting: PasteboardReading {
            var reads = 0
            var busy: Bool { false }
            func read(sourceBundleID: String?, excludedApps: Set<String>, done: @escaping (PasteboardSnapshot?) -> Void) {
                reads += 1
                done(PasteboardRead.snapshot(of: SystemEvents.pasteboard, sourceBundleID: sourceBundleID, excludedApps: excludedApps))
            }
            func stop() {}
        }
        let counting = Counting()
        controller.reader = counting
        SystemEvents.pasteboard.clearContents()
        for _ in 0..<(ClipboardController.unfilledRereads + 10) { controller.capture() }
        XCTAssertEqual(counting.reads, ClipboardController.unfilledRereads + 1, "the first read and its bounded rereads")
        XCTAssertTrue(store.clips.isEmpty)
    }
}
