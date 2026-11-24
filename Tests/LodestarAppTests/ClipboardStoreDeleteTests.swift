import XCTest
@testable import lodestar
@testable import LodestarCore

/// Forgetting a clip unlinks its sealed blob and thumbnail and nothing that is
/// another clip's, and forgetting many (a trim) is one change to the index
/// and one record.
final class ClipboardStoreDeleteTests: XCTestCase {
    private var directory: URL!
    private var store: ClipboardStore!
    private var items: URL { SealedFixture.v2(directory).appendingPathComponent("items") }
    private var thumbs: URL { SealedFixture.v2(directory).appendingPathComponent("thumbs") }

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-delete-\(UUID().uuidString)", isDirectory: true)
        store = SealedFixture.clipboardStore(directory)
        store.readText = { _ in nil }
    }

    override func tearDown() {
        store.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private func names(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    /// A clip under a name of the test's choosing: a plain form and one rich
    /// form on each of two items, one sealed blob, and a thumbnail beside it.
    private func seed(_ id: String) {
        let form = [("public.html", Data("<b>\(id)</b>".utf8))]
        store.record(id: id, kind: .text,
                     items: [.init(plain: Data(id.utf8), natives: form),
                             .init(plain: Data("\(id) second".utf8), natives: form)],
                     imageData: nil, preview: id, sourceBundleID: nil, sourceAppName: nil)
        store.flushIO()
        try? store.files.writeThumb(storage: store.storageName(of: id)!, key: store.sealedKey(for: id)!, png: Data("png".utf8))
    }

    func testDeletingAClipRemovesItsBlobAndThumbnailAndNothingThatIsAnothers() {
        seed("c1")
        seed("c10")
        seed("c1-b")
        XCTAssertEqual(names(items).count, 3, "one sealed file per clip, whatever it holds")
        let mine = store.storageName(of: "c1")!
        let others = ["c10", "c1-b"].map { store.storageName(of: $0)! }
        store.delete("c1")
        store.flushIO()
        XCTAssertEqual(names(items), others.sorted())
        XCTAssertEqual(names(thumbs), others.sorted())
        XCTAssertFalse(names(items).contains(mine))
        XCTAssertNotNil(store.plainText("c10"))
    }

    func testNoFileNameSaysWhatIsInIt() {
        seed("zebra-clip")
        XCTAssertTrue(names(items).allSatisfy { ClipboardSealed.isStorageName($0) }, "\(names(items))")
        XCTAssertFalse((names(items) + names(thumbs)).joined().contains("zebra"))
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
        XCTAssertEqual(names(items).count, 3)
        XCTAssertEqual(names(thumbs).count, 3)
        for id in store.clips.map(\.id) { XCTAssertTrue(names(items).contains(store.storageName(of: id)!), id) }
    }

    func testADeletedCardsThumbnailIsForgottenToo() {
        seed("c1")
        store.delete("c1")
        XCTAssertNil(store.thumbnail(for: "c1"), "never asked of the disk for a card that is gone")
        XCTAssertEqual(store.cachedThumbnails, 0)
    }
}
