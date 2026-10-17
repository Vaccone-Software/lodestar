import XCTest
@testable import lodestar
@testable import LodestarCore

/// Copying something the history already holds only raises its card: the
/// files under it are not written again, its thumbnail is not made again and
/// its picture is not read again. What a copy does bring, its source and its
/// moment, still lands.
final class ClipboardStoreRecopyTests: XCTestCase {
    private var directory: URL!
    private var store: ClipboardStore!
    private let long = Date(timeIntervalSince1970: 1_000_000_000)

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-recopy-\(UUID().uuidString)", isDirectory: true)
        store = ClipboardStore(root: directory)
    }

    override func tearDown() {
        store.saveNow()
        store.flushIO()
        try? FileManager.default.removeItem(at: directory)
    }

    private func blob(_ id: String, _ ext: String) -> URL {
        directory.appendingPathComponent("items/\(id).\(ext)")
    }

    private func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func age(_ url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: long], ofItemAtPath: url.path)
    }

    private func copyText(_ text: String, html: String? = nil, app: String = "Safari") -> String {
        let plain = Data(text.utf8)
        let id = ClipboardStore.identity(for: plain)
        store.record(id: id, kind: .text,
                     items: [.init(plain: plain, natives: html.map { [("public.html", Data($0.utf8))] } ?? [])],
                     imageData: nil, preview: Clipboard.preview(of: text),
                     sourceBundleID: "com.\(app)", sourceAppName: app)
        store.flushIO()
        return id
    }

    private func wait(_ what: String, timeout: TimeInterval = 10, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(condition(), what)
    }

    func testARecopiedTextRisesWithoutItsFilesBeingWrittenAgain() throws {
        let id = copyText("same words", html: "<b>same words</b>")
        _ = copyText("something else")
        try age(blob(id, "plain"))
        try age(blob(id, "type0"))
        _ = copyText("same words", html: "<b>same words</b>", app: "Notes")
        XCTAssertEqual(store.clips.map(\.id).first, id, "it rises to the front")
        XCTAssertEqual(store.clips.count, 2, "and does not duplicate")
        XCTAssertEqual(store.clips.first?.sourceAppName, "Notes", "the source is the copy's")
        XCTAssertEqual(modified(blob(id, "plain")), long, "the plain file was not written again")
        XCTAssertEqual(modified(blob(id, "type0")), long, "nor the rich one")
        XCTAssertEqual(store.plainText(id), "same words")
    }

    /// The same words from another page carry another rich form under one
    /// id. The index says what the copy brought, so the file has to say it.
    func testARecopyWithADifferentRichFormStillWritesIt() throws {
        let id = copyText("same words", html: "<b>one</b>")
        try age(blob(id, "plain"))
        try age(blob(id, "type0"))
        _ = copyText("same words", html: "<i>two</i>")
        XCTAssertEqual(try String(contentsOf: blob(id, "type0"), encoding: .utf8), "<i>two</i>")
        XCTAssertEqual(modified(blob(id, "plain")), long, "the plain file, unchanged, was left")
    }

    func testARecopyWhoseFileWentMissingWritesItAgain() throws {
        let id = copyText("same words")
        try FileManager.default.removeItem(at: blob(id, "plain"))
        _ = copyText("same words")
        XCTAssertEqual(store.plainText(id), "same words", "a card is never left pointing at nothing")
    }

    func testARecopiedImageKeepsItsCaptionAndIsNotReadOrThumbnailedAgain() throws {
        let reads = NSLock()
        var read: [Int] = []
        store.readText = { data in
            reads.withLock { read.append(data.count) }
            return "build failed"
        }
        func copyImage(_ png: Data, app: String) -> String {
            let id = ClipboardStore.identity(for: png)
            store.record(id: id, kind: .image,
                         items: [.init(plain: nil, natives: [(NSPasteboard.PasteboardType.png.rawValue, png)])],
                         imageData: png, preview: Clipboard.imagePreview(width: 40, height: 30),
                         sourceBundleID: "com.\(app)", sourceAppName: app)
            store.flushIO()
            return id
        }
        let shot = Stage.pngData(width: 40, height: 30)
        let id = copyImage(shot, app: "Safari")
        wait("the caption arrives") { store.clips.first?.preview.contains("build failed") == true }
        let thumb = directory.appendingPathComponent("thumbs/\(id).png")
        XCTAssertNotNil(modified(thumb), "the thumbnail was made")
        try age(thumb)
        try age(blob(id, "type0"))

        // Another picture goes in between, so the re-copy has somewhere to rise from.
        let other = copyImage(Stage.pngData(width: 41, height: 30), app: "Preview")
        wait("the other is captioned too") { store.clips.first?.id == other && reads.withLock { read.count } == 2 }
        XCTAssertEqual(store.clips.last?.id, id)

        _ = copyImage(shot, app: "Notes")
        XCTAssertEqual(store.clips.first?.id, id, "it rises")
        XCTAssertEqual(store.clips.first?.preview, "image 40×30\nbuild failed",
                       "with the caption it already had, not the arrival's bare size line")
        XCTAssertEqual(store.clips.first?.sourceAppName, "Notes")
        XCTAssertEqual(modified(thumb), long, "the thumbnail was not made again")
        XCTAssertEqual(modified(blob(id, "type0")), long, "the picture was not written again")

        // Whatever the re-copy had queued would have run before this does.
        let sentinel = copyImage(Stage.pngData(width: 42, height: 30), app: "Preview")
        wait("the sentinel is captioned") { store.clips.first { $0.id == sentinel }?.preview.contains("\n") == true }
        XCTAssertEqual(reads.withLock { read.count }, 3, "three pictures, three reads: the re-copy was not read")
    }

    func testARecopiedImageWhoseThumbnailIsMissingGetsItBack() throws {
        let shot = Stage.pngData(width: 40, height: 30)
        let id = ClipboardStore.identity(for: shot)
        func copy() {
            store.record(id: id, kind: .image,
                         items: [.init(plain: nil, natives: [(NSPasteboard.PasteboardType.png.rawValue, shot)])],
                         imageData: shot, preview: Clipboard.imagePreview(width: 40, height: 30),
                         sourceBundleID: nil, sourceAppName: nil)
            store.flushIO()
        }
        store.readText = { _ in nil }
        copy()
        let thumb = directory.appendingPathComponent("thumbs/\(id).png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumb.path))
        try FileManager.default.removeItem(at: thumb)
        copy()
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumb.path), "made again, because it was missing")
    }
}
