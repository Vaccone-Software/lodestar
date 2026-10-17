import XCTest
@testable import lodestar
@testable import LodestarCore

/// Forgetting a clip removes everything it left on disk and nothing that is
/// another clip's, and forgetting many (a trim) is one change to the index
/// and one look at the directory.
final class ClipboardStoreDeleteTests: XCTestCase {
    private var directory: URL!
    private var store: ClipboardStore!
    private var items: URL { directory.appendingPathComponent("items") }
    private var thumbs: URL { directory.appendingPathComponent("thumbs") }

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-delete-\(UUID().uuidString)", isDirectory: true)
        store = ClipboardStore(root: directory)
        store.readText = { _ in nil }
    }

    override func tearDown() {
        store.saveNow()
        store.flushIO()
        try? FileManager.default.removeItem(at: directory)
    }

    private func names(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    /// A clip under a name of the test's choosing: a plain form and one rich
    /// form on each of two items, so four files, and a thumbnail beside them.
    private func seed(_ id: String, minutesAgo: Double = 0) {
        let form = [("public.html", Data("<b>\(id)</b>".utf8))]
        store.record(id: id, kind: .text,
                     items: [.init(plain: Data(id.utf8), natives: form),
                             .init(plain: Data("\(id) second".utf8), natives: form)],
                     imageData: nil, preview: id, sourceBundleID: nil, sourceAppName: nil)
        try? Data("png".utf8).write(to: thumbs.appendingPathComponent("\(id).png"))
        store.flushIO()
    }

    func testDeletingAClipRemovesEveryFileItLeftAndNothingThatIsAnothers() {
        seed("c1")
        seed("c10")
        seed("c1-b")
        XCTAssertEqual(names(items).filter { $0.hasPrefix("c1.") },
                       ["c1.i1.plain", "c1.i1.type0", "c1.plain", "c1.type0"])
        store.delete("c1")
        store.flushIO()
        XCTAssertEqual(names(items).filter { $0.hasPrefix("c1.") }, [])
        XCTAssertEqual(names(items).filter { $0.hasPrefix("c10.") }.count, 4, "c10 is not c1")
        XCTAssertEqual(names(items).filter { $0.hasPrefix("c1-b.") }.count, 4)
        XCTAssertEqual(names(thumbs), ["c1-b.png", "c10.png"])
    }

    func testAFileNoIndexEntryNamesAnyMoreGoesWithItsClip() {
        seed("c1")
        try? Data("stray".utf8).write(to: items.appendingPathComponent("c1.type7"))
        store.delete("c1")
        store.flushIO()
        XCTAssertEqual(names(items), [], "what an earlier copy of the clip left is not kept")
    }

    func testATrimRemovesEveryDoomedClipsFilesInOneChangeToTheIndex() {
        let ids = (0..<12).map { "t\($0)" }
        for id in ids { seed(id) }
        let before = store.generation
        // Newest first, so the oldest are the last: all but three go.
        store.trim(maxBytes: Int.max, maxItems: 3)
        store.flushIO()
        XCTAssertEqual(store.clips.count, 3)
        XCTAssertEqual(store.generation, before + 1, "twelve clips gone, one change to the index")
        let kept = Set(store.clips.map(\.id))
        for id in ids {
            let files = names(items).filter { $0.prefix(while: { $0 != "." }) == id }
            XCTAssertEqual(files.count, kept.contains(id) ? 4 : 0, "\(id)")
            XCTAssertEqual(FileManager.default.fileExists(atPath: thumbs.appendingPathComponent("\(id).png").path),
                           kept.contains(id), "\(id)'s thumbnail")
        }
    }

    func testWhichFilesBelongToWhichClips() {
        let ids: Set<String> = ["ab", "x.y"]
        XCTAssertTrue(ClipboardStore.belongs("ab.plain", toOneOf: ids))
        XCTAssertTrue(ClipboardStore.belongs("ab.i2.type3", toOneOf: ids))
        XCTAssertTrue(ClipboardStore.belongs("x.y.plain", toOneOf: ids), "an id with a dot in it")
        XCTAssertFalse(ClipboardStore.belongs("abc.plain", toOneOf: ids))
        XCTAssertFalse(ClipboardStore.belongs("ab", toOneOf: ids), "no dot, no clip")
        XCTAssertFalse(ClipboardStore.belongs("a.plain", toOneOf: ids))
    }

    func testADeletedCardsThumbnailIsForgottenToo() {
        seed("c1")
        store.delete("c1")
        XCTAssertNil(store.thumbnail(for: "c1"), "never asked of the disk for a card that is gone")
        XCTAssertEqual(store.cachedThumbnails, 0)
    }
}
