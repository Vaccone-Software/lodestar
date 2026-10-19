import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// A copy of files: told apart at the pasteboard, read off the main thread
/// into facts and a picture per file, kept after the file moves, and never
/// allowed to make a slow volume the card's problem.
final class ClipboardFilesTests: XCTestCase {
    private var directory: URL!
    private var files: URL!
    private var store: ClipboardStore!
    private var controller: ClipboardController!
    private let board = SystemEvents.pasteboard

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-files-\(UUID().uuidString)", isDirectory: true)
        files = directory.appendingPathComponent("Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        store = SealedFixture.clipboardStore(directory.appendingPathComponent("history", isDirectory: true))
        controller = ClipboardController(store: store)
        // Real QuickLook is another process's to answer in its own time; the
        // tests stand in for it, and the icon fallback is the real one.
        FileSense.thumbnailer = { _ in Self.swatch() }
    }

    override func tearDown() {
        FileSense.deadline = 2
        FileSense.thumbnailer = FileSense.quickLook
        FileSense.dataless = FileSense.isDataless
        store.close()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Helpers

    private static func swatch() -> CGImage {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return context.makeImage()!
    }

    @discardableResult
    private func make(_ name: String, text: String = "hello") throws -> URL {
        let url = files.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func copy(_ urls: [URL]) {
        board.clearContents()
        board.writeObjects(urls.map { $0 as NSURL })
        controller.capture()
    }

    private func wait(_ what: String, timeout: TimeInterval = 20, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(condition(), what)
    }

    private func read(_ id: String, facts count: Int) -> [Clipboard.FileFact] {
        wait("the facts of \(count) files are read") { store.clips.first { $0.id == id }?.fileFacts?.count == count }
        return store.clips.first { $0.id == id }?.fileFacts ?? []
    }

    // MARK: What kind of clip

    func testACopyOfFilesIsAFileClipAndNotMeasuredAsText() throws {
        let urls = [try make("a.txt"), try make("b.txt"), try make("c.txt")]
        copy(urls)
        let clip = try XCTUnwrap(store.clips.first)
        XCTAssertEqual(clip.kind, .file)
        XCTAssertEqual(clip.itemCount, 3)
        XCTAssertEqual(clip.itemsLabel, "3 files")
        XCTAssertNil(clip.lines, "paths are not text to count")
        XCTAssertNil(Clipboard.lengthBadge(for: clip))
        XCTAssertFalse(clip.isEditable)
        for name in ["a.txt", "b.txt", "c.txt"] {
            XCTAssertNotNil(Clipboard.relevance(of: clip, to: name), "\(name) is found by its name")
        }
    }

    func testOneFileIsAFileClipToo() throws {
        copy([try make("only.txt")])
        XCTAssertEqual(store.clips.first?.kind, .file)
        XCTAssertNil(store.clips.first?.itemsLabel, "one thing says nothing")
    }

    func testAFileBesideAStringIsStillText() throws {
        let url = try make("a.txt")
        let withFile = NSPasteboardItem()
        withFile.setString(url.absoluteString, forType: .fileURL)
        let withString = NSPasteboardItem()
        withString.setString("just words", forType: .string)
        board.clearContents()
        board.writeObjects([withFile, withString])
        controller.capture()
        XCTAssertEqual(store.clips.first?.kind, .text, "a mixed copy is not a copy of files")
        XCTAssertNil(store.clips.first?.fileFacts)
    }

    func testAPictureCopyStaysAPicture() throws {
        let png = Stage.pngData(width: 30, height: 20)
        board.clearContents()
        board.setData(png, forType: .png)
        controller.capture()
        XCTAssertEqual(store.clips.first?.kind, .image)
    }

    func testTextIsStillText() {
        board.clearContents()
        board.setString("hello", forType: .string)
        controller.capture()
        XCTAssertEqual(store.clips.first?.kind, .text)
        XCTAssertEqual(store.clips.first?.lines, 1)
    }

    func testCopyingTheSameFilesAgainLandsOnTheSameCard() throws {
        let urls = [try make("a.txt"), try make("b.txt")]
        copy(urls)
        let id = try XCTUnwrap(store.clips.first).id
        copy([try make("other.txt")])
        copy(urls)
        XCTAssertEqual(store.clips.count, 2, "no second card for the same two files")
        XCTAssertEqual(store.clips.first?.id, id, "and it rose to the top")
    }

    /// A file copy recorded before files were a kind is text with a file
    /// address in it; copying the same files again makes it the new kind.
    func testAFileCopyFromBeforeBecomesAFileClipWhenCopiedAgain() throws {
        let url = try make("old.txt")
        copy([url])
        let current = try XCTUnwrap(store.clips.first)
        // Rewritten as the old build wrote it.
        let items = store.itemData(current)
        store.delete(current.id)
        store.record(id: current.id, kind: .text, items: items, imageData: nil,
                     preview: url.path, sourceBundleID: nil, sourceAppName: nil)
        XCTAssertEqual(store.clips.first?.kind, .text)
        copy([url])
        XCTAssertEqual(store.clips.count, 1)
        XCTAssertEqual(store.clips.first?.kind, .file)
    }

    func testAnExcludedPatternKeepsAFileOutAsItAlwaysDid() throws {
        controller.excludedPatterns = ["secret-project"]
        let hidden = directory.appendingPathComponent("secret-project", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        let url = hidden.appendingPathComponent("plan.txt")
        try Data("x".utf8).write(to: url)
        copy([url])
        XCTAssertTrue(store.clips.isEmpty, "nothing recorded")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.files.thumbs.path), [],
                       "and nothing of it read or pictured")
    }

    // MARK: What each file is

    func testEachFilesNameFolderKindSizeAndDetailAreReadInCopyOrder() throws {
        let text = try make("notes.txt", text: "hello")
        let png = files.appendingPathComponent("pic.png")
        try Stage.pngData(width: 40, height: 20).write(to: png)
        let pdf = files.appendingPathComponent("two pages.pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        let page = CGContext(pdf as CFURL, mediaBox: &box, nil)!
        for _ in 0..<2 { page.beginPDFPage(nil); page.endPDFPage() }
        page.closePDF()
        let folder = files.appendingPathComponent("Album", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["1", "2", "3"] { try Data(name.utf8).write(to: folder.appendingPathComponent(name)) }
        try Data("hidden".utf8).write(to: folder.appendingPathComponent(".DS_Store"))

        copy([text, png, pdf, folder])
        let id = try XCTUnwrap(store.clips.first).id
        let facts = read(id, facts: 4)
        XCTAssertEqual(facts.map(\.name), ["notes.txt", "pic.png", "two pages.pdf", "Album"], "in copy order")
        XCTAssertEqual(Set(facts.map(\.folder)), ["Documents"], "the folder by its name, not its path")
        XCTAssertFalse(facts.contains { $0.folder.contains("/") })
        XCTAssertEqual(facts[0].bytes, 5)
        XCTAssertEqual(facts[1].detail, "40 × 20")
        XCTAssertEqual(facts[2].detail, "2 pages")
        XCTAssertNil(facts[0].detail)
        XCTAssertNil(facts[3].bytes, "a folder has no size")
        XCTAssertEqual(facts[3].items, 3, "it says what it holds, one level deep, hidden files left out")
        XCTAssertTrue(facts.allSatisfy { $0.kind.first?.isUppercase == true }, "the Finder's word, capitalised: \(facts.map(\.kind))")
        XCTAssertTrue(facts.allSatisfy { !$0.kind.isEmpty && $0.type != nil })
    }

    func testOnlyTheFirstDozenFilesAreKeptButTheCopyKnowsItsCount() throws {
        let urls = try (0..<14).map { try make("f\($0).txt") }
        copy(urls)
        let id = try XCTUnwrap(store.clips.first).id
        let facts = read(id, facts: Clipboard.fileFactsKept)
        XCTAssertEqual(facts.last?.name, "f11.txt")
        XCTAssertEqual(store.clips.first?.itemCount, 14)
        XCTAssertEqual(store.clips.first?.itemsLabel, "14 files")
        XCTAssertNil(Clipboard.totalBytes(of: facts, itemCount: 14))
    }

    func testRecopyingAFileReadsItAgain() throws {
        let url = try make("grow.txt", text: "12345")
        copy([url])
        let id = try XCTUnwrap(store.clips.first).id
        XCTAssertEqual(read(id, facts: 1)[0].bytes, 5)
        try Data("1234567890".utf8).write(to: url)
        copy([url])
        wait("the new size is read") { self.store.clips.first?.fileFacts?.first?.bytes == 10 }
    }

    // MARK: Pictures

    func testTheFirstFourFilesGetAPictureEachAndNoMore() throws {
        let urls = try (0..<6).map { try make("p\($0).txt") }
        copy(urls)
        let id = try XCTUnwrap(store.clips.first).id
        let storage = try XCTUnwrap(store.storageName(of: id))
        wait("four pictures are kept") {
            (0..<Clipboard.thumbnailedFiles).allSatisfy { self.store.files.hasThumb(storage: storage, index: $0) }
        }
        XCTAssertFalse(store.files.hasThumb(storage: storage, index: Clipboard.thumbnailedFiles), "a fifth is not made")
        wait("and their facts say whose face they are") {
            self.store.clips.first?.fileFacts?.prefix(4).allSatisfy { $0.pictured == true } == true
        }
        XCTAssertNil(store.clips.first?.fileFacts?[4].pictured, "a file with no picture of its own says nothing")
        for index in 0..<4 {
            wait("picture \(index) is decoded for the strip") { self.store.thumbnail(for: id, index: index) != nil }
            let image = try XCTUnwrap(store.thumbnail(for: id, index: index))
            XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), CGFloat(FileSense.side))
        }
        XCTAssertNil(store.thumbnail(for: id, index: 4))
    }

    func testAFileWithNoThumbnailIsDrawnAsItsIcon() throws {
        FileSense.thumbnailer = { _ in nil }
        copy([try make("plain.txt")])
        let id = try XCTUnwrap(store.clips.first).id
        wait("the icon is kept as its picture") { self.store.thumbnail(for: id) != nil }
        let image = try XCTUnwrap(store.thumbnail(for: id))
        XCTAssertEqual(image.size, NSSize(width: FileSense.side, height: FileSense.side), "the icon at the same size")
        wait("and the facts say it is an icon") { self.store.clips.first?.fileFacts?.first?.pictured == false }
    }

    /// A slow volume must not hold the card, nor the capture, nor make the
    /// card wait for a picture that is not coming: the icon is drawn.
    func testAThumbnailerThatOverrunsItsDeadlineIsAnsweredWithTheIcon() throws {
        FileSense.deadline = 0.3
        FileSense.thumbnailer = { _ in Thread.sleep(forTimeInterval: 2); return Self.swatch() }
        let url = try make("slow.txt")
        let began = Date()
        copy([url])
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.25, "the card exists before anything is read")
        let id = try XCTUnwrap(store.clips.first).id
        wait("the icon stands in", timeout: 1.8) { self.store.thumbnail(for: id) != nil }
        XCTAssertLessThan(Date().timeIntervalSince(began), 1.8, "without waiting for the slow answer")
        wait("and the card is told it is an icon") { self.store.clips.first?.fileFacts?.first?.pictured == false }
    }

    /// A file iCloud has evicted is described by what is known of it and
    /// drawn as its icon: asking it for its pages or its picture would
    /// fetch it from the network.
    func testAFileThatIsNotOnThisMacIsNeverOpenedForItsPagesOrItsPicture() throws {
        FileSense.dataless = { _, _ in true }
        var asked = 0
        FileSense.thumbnailer = { _ in asked += 1; return Self.swatch() }
        let png = files.appendingPathComponent("evicted.png")
        try Stage.pngData(width: 40, height: 20).write(to: png)
        copy([png])
        let id = try XCTUnwrap(store.clips.first).id
        let fact = read(id, facts: 1)[0]
        wait("its icon is its picture") { self.store.clips.first?.fileFacts?.first?.pictured == false }
        XCTAssertEqual(fact.name, "evicted.png")
        XCTAssertNotNil(fact.bytes, "what the directory says of it is still said")
        XCTAssertNil(fact.detail, "its pixels are not read: that would open it")
        XCTAssertEqual(asked, 0, "and QuickLook is not asked for it")
    }

    func testTheFactsAndPicturesOutliveTheFileAndTheSession() throws {
        let urls = [try make("keep-a.txt"), try make("keep-b.txt")]
        copy(urls)
        let id = try XCTUnwrap(store.clips.first).id
        wait("the facts are read and the pictures made") {
            self.store.clips.first?.fileFacts?.count == 2 && self.store.clips.first?.fileFacts?.allSatisfy { $0.pictured != nil } == true
        }
        let before = try XCTUnwrap(store.clips.first?.fileFacts)
        wait("pictures are kept") { (0..<2).allSatisfy { self.store.thumbnail(for: id, index: $0) != nil } }
        store.flushIO()
        for url in urls { try FileManager.default.removeItem(at: url) }
        store.close()

        let reopened = SealedFixture.clipboardStore(directory.appendingPathComponent("history", isDirectory: true))
        reopened.waitUntilOpen()
        XCTAssertEqual(reopened.clips.first?.fileFacts, before, "the card keeps what it knew of files that are gone")
        for index in 0..<2 {
            wait("picture \(index) is read back") { reopened.thumbnail(for: id, index: index) != nil }
        }
        reopened.close()
    }

    func testDeletingAFileCardRemovesEveryPictureOfIt() throws {
        copy(try (0..<4).map { try make("d\($0).txt") })
        let id = try XCTUnwrap(store.clips.first).id
        let storage = try XCTUnwrap(store.storageName(of: id))
        wait("four pictures") { (0..<4).allSatisfy { self.store.files.hasThumb(storage: storage, index: $0) } }
        wait("all decoded") { (0..<4).allSatisfy { self.store.thumbnail(for: id, index: $0) != nil } }
        XCTAssertEqual(store.cachedThumbnails, 4)
        store.delete(id)
        store.flushIO()
        for index in 0..<4 { XCTAssertFalse(store.files.hasThumb(storage: storage, index: index), "picture \(index)") }
        XCTAssertEqual(store.cachedThumbnails, 0, "and none is held in memory")
    }

    func testAFileCardDeletedWhileItsFilesAreBeingReadLeavesNoPicturesBehind() throws {
        FileSense.thumbnailer = { _ in Thread.sleep(forTimeInterval: 0.5); return Self.swatch() }
        copy([try make("late.txt")])
        let id = try XCTUnwrap(store.clips.first).id
        let storage = try XCTUnwrap(store.storageName(of: id))
        store.delete(id)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        store.flushIO()
        XCTAssertFalse(store.files.hasThumb(storage: storage), "the picture that landed after the delete went with it")
        XCTAssertTrue(store.clips.isEmpty)
    }

    func testPicturesOfManyFileCardsStayWithinTheBoundedCache() throws {
        let cards = ClipboardStore.thumbnailLimit / 4 + 3
        var ids: [String] = []
        for card in 0..<cards {
            copy(try (0..<4).map { try make("c\(card)-\($0).txt", text: "\(card)\($0)") })
            ids.append(try XCTUnwrap(store.clips.first).id)
            wait("card \(card) is pictured") { self.store.files.hasThumb(storage: self.store.storageName(of: ids[card]) ?? "", index: 3) }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        for id in ids { for index in 0..<4 { _ = store.thumbnail(for: id, index: index) } }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(store.cachedThumbnails, ClipboardStore.thumbnailLimit, "bounded, and full")
    }

    // MARK: Whether the files are still there

    func testWhetherFilesAreThereIsAskedOffTheMainThreadAndKeptForTheShowing() throws {
        let urls = [try make("here.txt"), try make("going.txt")]
        copy(urls)
        let id = try XCTUnwrap(store.clips.first).id
        store.flushIO()
        XCTAssertNil(store.filesPresent(id), "drawing is not answered from the disk")
        wait("the answer arrives") { self.store.filesPresent(id) != nil }
        XCTAssertEqual(store.filesPresent(id), [true, true])
        try FileManager.default.removeItem(at: urls[1])
        XCTAssertEqual(store.filesPresent(id), [true, true], "kept for as long as the strip is up")
        store.forgetFilePresence()
        XCTAssertNil(store.filesPresent(id))
        wait("asked again at the next opening") { self.store.filesPresent(id) != nil }
        XCTAssertEqual(store.filesPresent(id), [true, false])
        XCTAssertFalse(Clipboard.allMissing(store.filesPresent(id)), "one file left is not missing")
        try FileManager.default.removeItem(at: urls[0])
        store.forgetFilePresence()
        wait("and again") { self.store.filesPresent(id) != nil }
        XCTAssertTrue(Clipboard.allMissing(store.filesPresent(id)))
    }

    /// The question goes to another thread, and its answer comes back to
    /// the main one after the strip has opened again: it belongs to the
    /// showing it was asked in, and the new showing asks for itself.
    func testAnAnswerToAnEarlierShowingIsNotTakenForTheNextOne() throws {
        let url = try make("x.txt")
        copy([url])
        let id = try XCTUnwrap(store.clips.first).id
        store.flushIO()
        XCTAssertNil(store.filesPresent(id))
        store.forgetFilePresence()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertNil(store.filesPresent(id), "the answer that arrived after the reopening was dropped, so this asks afresh")
        wait("and the new answer comes") { self.store.filesPresent(id) != nil }
    }
}
