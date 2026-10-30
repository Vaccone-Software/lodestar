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
        // A paste goes to the sealed test board, never to the one in use.
        controller.pasteboard = board
        // Secure input is the machine's, not the test's: a locked screen
        // holds it, and the paste would stop to ask for a ⌘V by hand.
        controller.secureInput = { false }
        // These tests delete files to paste their cards; the cards stay
        // unless a test is about their leaving.
        store.prunesGoneFiles = false
        // Real QuickLook is another process's to answer in its own time; the
        // tests stand in for it, and the icon fallback is the real one.
        setOverride(\FileSense.Type.thumbnailer, to: { _ in Self.swatch() })
    }

    override func tearDown() {
        FileSense.deadline = 2
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
        setOverride(\FileSense.Type.thumbnailer, to: { _ in nil })
        copy([try make("plain.txt")])
        let id = try XCTUnwrap(store.clips.first).id
        wait("the icon is kept as its picture") { self.store.thumbnail(for: id) != nil }
        let image = try XCTUnwrap(store.thumbnail(for: id))
        XCTAssertEqual(image.size, NSSize(width: FileSense.side, height: FileSense.side), "the icon at the same size")
        wait("and the facts say it is an icon") { self.store.clips.first?.fileFacts?.first?.pictured == false }
    }

    /// A slow volume must not hold the card, nor the capture, nor make the
    /// card wait for a picture that is not coming: the icon is drawn.
    ///
    /// The slow answer never comes until the test has its verdict: the
    /// thumbnailer waits to be released, so "without waiting for it" is a
    /// fact, not a race. It slept two seconds once, against a 1.8 second
    /// bound, and a slow runner spent the difference (CI, 2026-10-25).
    func testAThumbnailerThatOverrunsItsDeadlineIsAnsweredWithTheIcon() throws {
        FileSense.deadline = 1
        let release = DispatchSemaphore(value: 0)
        let answered = NSLock()
        var returned = false
        setOverride(\FileSense.Type.thumbnailer, to: { _ in
            release.wait()
            answered.withLock { returned = true }
            return Self.swatch()
        })
        addTeardownBlock { for _ in 0..<8 { release.signal() } }
        let url = try make("slow.txt")
        let began = Date()
        copy([url])
        XCTAssertLessThan(Date().timeIntervalSince(began), FileSense.deadline * 0.9,
                          "the card exists before anything is read, and before the deadline")
        let id = try XCTUnwrap(store.clips.first).id
        wait("the icon stands in", timeout: 20) { self.store.thumbnail(for: id) != nil }
        XCTAssertFalse(answered.withLock { returned }, "without waiting for the slow answer")
        wait("and the card is told it is an icon") { self.store.clips.first?.fileFacts?.first?.pictured == false }
    }

    /// A file iCloud has evicted is described by what is known of it and
    /// drawn as its icon: asking it for its pages or its picture would
    /// fetch it from the network.
    func testAFileThatIsNotOnThisMacIsNeverOpenedForItsPagesOrItsPicture() throws {
        setOverride(\FileSense.Type.dataless, to: { _, _ in true })
        var asked = 0
        setOverride(\FileSense.Type.thumbnailer, to: { _ in asked += 1; return Self.swatch() })
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
        setOverride(\FileSense.Type.thumbnailer, to: { _ in Thread.sleep(forTimeInterval: 0.5); return Self.swatch() })
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

    // MARK: Pasting files

    /// What the Finder puts on the board for a copied file: its address, and
    /// its name as the plain form.
    private func finderCopy(_ urls: [URL]) {
        board.clearContents()
        let items = urls.map { url -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            item.setString(url.lastPathComponent, forType: .string)
            return item
        }
        board.writeObjects(items)
        controller.capture()
    }

    func testAPlainPasteOfFilesPutsTheFilesOnTheBoardAndNotTheirNames() throws {
        let urls = [try make("a.txt"), try make("b.txt")]
        finderCopy(urls)
        let clip = try XCTUnwrap(store.clips.first)
        XCTAssertEqual(clip.kind, .file)
        var posted = 0
        controller.postPaste = { posted += 1 }
        // Something else has been copied since, as it has by the time a card
        // is pasted: the board holds nothing of the files.
        board.clearContents()
        board.setString("something else", forType: .string)

        controller.paste(clip, action: .plain)

        let back = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(back?.map { $0.standardizedFileURL.path }, urls.map { $0.standardizedFileURL.path },
                       "the Finder pastes files only when the board holds their addresses")
        XCTAssertEqual(posted, 1)
    }

    func testFilesThatAreGonePasteAsNothingAndSayWhy() throws {
        let urls = [try make("a.txt"), try make("b.txt")]
        finderCopy(urls)
        let clip = try XCTUnwrap(store.clips.first)
        for url in urls { try FileManager.default.removeItem(at: url) }
        // No wait for the strip's own answer: a quick hand pastes before it
        // has come in, and the paste asks the disk itself.
        XCTAssertNil(store.filesPresent(clip.id), "the strip has not been told yet")
        board.clearContents()
        board.setString("kept", forType: .string)
        var said: [String] = []
        var posted = 0
        controller.flash = { said.append($0) }
        controller.postPaste = { posted += 1 }

        controller.paste(clip, action: .plain)

        XCTAssertEqual(board.string(forType: .string), "kept", "the board is left as it was")
        XCTAssertEqual(posted, 0, "nothing is pasted")
        XCTAssertEqual(said, ["✕ Those files are no longer there"])
    }

    /// A file copied the way the Finder copies it: by reference, an address
    /// that names the file by identity, not by place. The clip comes back
    /// once its bookmarks have been made, as the strip holds it.
    private func finderReferenceCopy(_ urls: [URL]) throws -> Clipboard.Clip {
        board.clearContents()
        let items = try urls.map { url -> NSPasteboardItem in
            // Through Objective-C: bridged to a Swift URL, a reference comes
            // back as the path it points to, and the test would copy a path.
            let reference = try XCTUnwrap((url as NSURL).perform(#selector(NSURL.fileReferenceURL))?
                .takeUnretainedValue() as? NSURL)
            let address = try XCTUnwrap(reference.absoluteString)
            XCTAssertTrue(address.hasPrefix("file:///.file/"), "copied by reference, as the Finder does")
            let item = NSPasteboardItem()
            item.setString(address, forType: .fileURL)
            item.setString(url.lastPathComponent, forType: .string)
            return item
        }
        board.writeObjects(items)
        controller.capture()
        wait("a bookmark per file is made at the copy") {
            self.store.clips.first?.fileBookmarks?.compactMap { $0 }.count == urls.count
        }
        return try XCTUnwrap(store.clips.first)
    }

    /// Pastes the clip over a board that holds something else, and says
    /// what the paste did.
    private func pasteOverSomethingElse(_ clip: Clipboard.Clip) -> (said: [String], posted: Int) {
        board.clearContents()
        board.setString("kept", forType: .string)
        var said: [String] = []
        var posted = 0
        controller.flash = { said.append($0) }
        controller.postPaste = { posted += 1 }
        controller.paste(clip, action: .plain)
        return (said, posted)
    }

    private var pastedPaths: [String] {
        (board.pasteboardItems ?? []).compactMap { $0.string(forType: .fileURL) }
            .compactMap(URL.init(string:)).map { $0.resolvingSymlinksInPath().path }
    }

    func testACopyOfFilesKeepsABookmarkForEachFile() throws {
        let clip = try finderReferenceCopy([try make("a.txt"), try make("b.txt")])
        XCTAssertEqual(clip.fileBookmarks?.count, 2)
    }

    func testAMovedAndRenamedFilePastesFromWhereItIsNow() throws {
        let url = try make("report.pdf")
        let clip = try finderReferenceCopy([url])
        let elsewhere = directory.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let moved = elsewhere.appendingPathComponent("final report.pdf")
        try FileManager.default.moveItem(at: url, to: moved)

        let pasted = pasteOverSomethingElse(clip)

        XCTAssertEqual(pasted.posted, 1)
        XCTAssertEqual(pastedPaths, [moved.resolvingSymlinksInPath().path], "its path now, never the old reference")
        XCTAssertEqual(board.string(forType: .string), "final report.pdf", "and its name now")
    }

    /// Delete in the Finder moves the file to the Trash, where the bookmark
    /// still finds it. The Finder will not paste it from there (it pastes
    /// the file's icon as a file instead, measured 2026-10-19), so it is not
    /// offered, and the pill says where it went.
    func testAFileDeletedToTheTrashPastesAsNothingAndSaysWhereItWent() throws {
        let url = try make("photo.jpeg")
        let clip = try finderReferenceCopy([url])
        let trash = directory.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent("photo.jpeg"))

        let pasted = pasteOverSomethingElse(clip)

        XCTAssertEqual(board.string(forType: .string), "kept", "the board is left as it was")
        XCTAssertEqual(pasted.posted, 0, "nothing is pasted, so the Finder makes no icon file")
        XCTAssertEqual(pasted.said, ["✕ That file is in the Trash"])
        store.forgetFilePresence()
        wait("its card learns it is gone") { self.store.filesPresent(clip.id) == [false] }
    }

    func testAFileDeletedForGoodPastesAsNothingAndItsCardSaysSo() throws {
        let url = try make("photo.jpeg")
        let clip = try finderReferenceCopy([url])
        try FileManager.default.removeItem(at: url)

        let pasted = pasteOverSomethingElse(clip)

        XCTAssertEqual(board.string(forType: .string), "kept", "the board is left as it was")
        XCTAssertEqual(pasted.posted, 0, "nothing is pasted, so the Finder makes no clipping")
        XCTAssertEqual(pasted.said, ["✕ That file is no longer there"])
        store.forgetFilePresence()
        wait("the card learns its file is gone") { self.store.filesPresent(clip.id) == [false] }
    }

    // MARK: Show in Finder, Open, Move here

    func testShowInFinderSelectsTheFilesWhereTheyAreNow() throws {
        let url = try make("report.pdf")
        let clip = try finderReferenceCopy([url])
        let elsewhere = directory.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let moved = elsewhere.appendingPathComponent("report.pdf")
        try FileManager.default.moveItem(at: url, to: moved)
        var shown: [String] = []
        controller.revealFiles = { shown = $0.map { $0.resolvingSymlinksInPath().path } }

        controller.reveal(clip)

        XCTAssertEqual(shown, [moved.resolvingSymlinksInPath().path])
    }

    func testShowInFinderShowsATrashedFileInTheTrash() throws {
        let url = try make("photo.jpeg")
        let clip = try finderReferenceCopy([url])
        let trash = directory.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let trashed = trash.appendingPathComponent("photo.jpeg")
        try FileManager.default.moveItem(at: url, to: trashed)
        var shown: [String] = []
        controller.revealFiles = { shown = $0.map { $0.resolvingSymlinksInPath().path } }

        controller.reveal(clip)

        XCTAssertEqual(shown, [trashed.resolvingSymlinksInPath().path], "where it went is where it is shown")
    }

    func testOpenOpensOneFileAndNeverAGroup() throws {
        let one = try make("report.pdf")
        copy([one])
        let single = try XCTUnwrap(store.clips.first)
        copy([try make("a.txt"), try make("b.txt")])
        let group = try XCTUnwrap(store.clips.first)
        var opened: [String] = []
        controller.openFile = { opened.append($0.resolvingSymlinksInPath().path) }

        controller.open(group)
        XCTAssertEqual(opened, [], "a group does not open")
        controller.open(single)
        XCTAssertEqual(opened, [one.resolvingSymlinksInPath().path])
    }

    func testMoveHerePutsTheFilesOnTheBoardAndPressesMoveItemHere() throws {
        let url = try make("report.pdf")
        let clip = try finderReferenceCopy([url])
        var pastes = 0, moves = 0
        controller.postPaste = { pastes += 1 }
        controller.postMove = { moves += 1 }
        board.clearContents()
        board.setString("something else", forType: .string)

        controller.paste(clip, action: .plain, moving: true)

        XCTAssertEqual(pastedPaths, [url.resolvingSymlinksInPath().path], "the files, as for a paste")
        XCTAssertEqual(moves, 1, "and the Finder's ⌥⌘V, which moves them")
        XCTAssertEqual(pastes, 0)
    }

    // MARK: What a file is found by

    func testADownloadedFileKnowsItsSiteFromTheMacsOwnNote() throws {
        let url = try make("archive.zip")
        let froms = try PropertyListSerialization.data(
            fromPropertyList: ["https://www.github.com/x/y/archive.zip?token=SECRET", "https://github.com/x/y"],
            format: .binary, options: 0)
        let written = froms.withUnsafeBytes {
            setxattr(url.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, froms.count, 0, 0)
        }
        XCTAssertEqual(written, 0)
        XCTAssertEqual(FileSense.site(of: url), "github.com", "the host alone, never the token")
        XCTAssertNil(FileSense.site(of: try make("plain.txt")), "a file made here came from nowhere")
    }

    // MARK: The reading: paths

    func testControlPastesThePathsWhereTheFilesAreNowAsText() throws {
        let a = try make("a b.txt"), b = try make("c.txt")
        let clip = try finderReferenceCopy([a, b])
        let elsewhere = directory.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let moved = elsewhere.appendingPathComponent("c.txt")
        try FileManager.default.moveItem(at: b, to: moved)
        var posted = 0
        controller.postPaste = { posted += 1 }
        board.clearContents()

        controller.pastePaths(of: clip)

        let text = try XCTUnwrap(board.string(forType: .string))
        let quoted = try XCTUnwrap(Clipboard.reading(of: clip, units: .metric, paths: [a, moved]))
        XCTAssertEqual(text.replacingOccurrences(of: "/private/var/", with: "/var/"),
                       quoted.replacingOccurrences(of: "/private/var/", with: "/var/"),
                       "each in quotes, the moved one where it is now")
        XCTAssertNil(board.string(forType: .fileURL), "text only: this is the form for what takes text")
        XCTAssertEqual(posted, 1)
    }

    func testTheStripLearnsWhereTheFilesAreForTheReadingItShows() throws {
        let url = try make("report.pdf")
        let clip = try finderReferenceCopy([url])
        _ = store.filePaths(clip.id)
        wait("the paths are found off the main thread") { self.store.filePaths(clip.id) != nil }
        XCTAssertEqual(store.filePaths(clip.id)?.map { $0.resolvingSymlinksInPath().path },
                       [url.resolvingSymlinksInPath().path])
    }

    // MARK: Cards whose files are gone

    /// One look over the cards of files, waited for.
    private func prune() {
        store.prunesGoneFiles = true
        store.flushIO()
        var done = false
        store.pruneGoneFiles { done = true }
        wait("the cards have been looked over") { done }
    }

    private func ids() -> Set<String> { Set(store.clips.map(\.id)) }

    func testACardWhoseFilesAreGoneLeavesAndOneWhoseFilesAreThereStays() throws {
        let gone = try make("gone.txt"), kept = try make("kept.txt")
        copy([gone])
        let goneID = try XCTUnwrap(store.clips.first?.id)
        copy([kept])
        let keptID = try XCTUnwrap(store.clips.first?.id)
        try FileManager.default.removeItem(at: gone)

        prune()

        XCTAssertFalse(ids().contains(goneID), "a card that can paste nothing leaves")
        XCTAssertTrue(ids().contains(keptID))
    }

    func testACardWhoseFileIsInTheTrashLeaves() throws {
        let url = try make("photo.jpeg")
        let clip = try finderReferenceCopy([url])
        let trash = directory.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent("photo.jpeg"))

        prune()

        XCTAssertFalse(ids().contains(clip.id))
    }

    /// A group loses the files that are gone and keeps its place: it is the
    /// same card, holding what is left of it.
    func testAGroupWithSomeOfItsFilesGoneKeepsItsPlaceAndTheRest() throws {
        let one = try make("one.txt"), two = try make("two.txt"), three = try make("three.txt")
        copy([one, two, three])
        let group = try XCTUnwrap(store.clips.first)
        copy([try make("newer.txt")])
        let newer = try XCTUnwrap(store.clips.first?.id)
        try FileManager.default.removeItem(at: one)

        prune()

        XCTAssertEqual(store.clips.count, 2, "no card left and none was added")
        XCTAssertEqual(store.clips.first?.id, newer, "the order is as it was")
        let shrunk = try XCTUnwrap(store.clips.last)
        XCTAssertNotEqual(shrunk.id, group.id, "a card's id is what it holds")
        XCTAssertEqual(shrunk.itemCount, 2)
        XCTAssertEqual(shrunk.kind, .file)
        XCTAssertEqual(shrunk.created, group.created, "and it is as old as it was")
        XCTAssertEqual(Clipboard.namesOnCard(of: shrunk), ["two.txt", "three.txt"])
        _ = pasteOverSomethingElse(shrunk)
        XCTAssertEqual(pastedPaths, [two, three].map { $0.resolvingSymlinksInPath().path }, "it pastes what is left")
    }

    func testAKeptGroupKeepsEveryFileWhenSomeAreGone() throws {
        let one = try make("one.txt"), two = try make("two.txt")
        copy([one, two])
        let id = try XCTUnwrap(store.clips.first?.id)
        XCTAssertTrue(store.pin(id))
        try FileManager.default.removeItem(at: one)

        prune()

        XCTAssertEqual(store.clips.first(where: { $0.id == id })?.itemCount, 2, "a keepsake changes only by hand")
    }

    func testAKeepsakeStaysWhenItsFilesAreGone() throws {
        let url = try make("kept on purpose.pdf")
        copy([url])
        let id = try XCTUnwrap(store.clips.first?.id)
        XCTAssertTrue(store.pin(id))
        try FileManager.default.removeItem(at: url)

        prune()

        XCTAssertTrue(ids().contains(id), "kept on purpose, it leaves only by hand")
    }

    func testAFileOnADiskThatIsNotConnectedKeepsItsCard() throws {
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString("file:///Volumes/No%20Such%20Disk/report.pdf", forType: .fileURL)
        item.setString("report.pdf", forType: .string)
        board.writeObjects([item])
        controller.capture()
        let id = try XCTUnwrap(store.clips.first?.id)

        prune()

        XCTAssertTrue(ids().contains(id), "an unplugged disk decides nothing")
    }

    func testNoCardLeavesWhileTheStripIsUp() throws {
        let url = try make("gone.txt")
        copy([url])
        let id = try XCTUnwrap(store.clips.first?.id)
        try FileManager.default.removeItem(at: url)
        var stripUp = true
        store.removalsHeld = { stripUp }

        prune()
        XCTAssertTrue(ids().contains(id), "the letters under the hand must not shift")

        stripUp = false
        prune()
        XCTAssertFalse(ids().contains(id), "and once the strip is down, it leaves")
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
