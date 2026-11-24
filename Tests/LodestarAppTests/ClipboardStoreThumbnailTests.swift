import XCTest
@testable import lodestar
@testable import LodestarCore

/// A strip of image cards must not read and decode pictures on the main
/// thread, where the key tap is waiting: a redraw shows the pictures it has
/// and the rest arrive, together, when they are ready.
final class ClipboardStoreThumbnailTests: XCTestCase {
    private var directory: URL!
    private var seeding: ClipboardStore!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-thumbs-\(UUID().uuidString)", isDirectory: true)
        seeding = SealedFixture.clipboardStore(directory)
        seeding.readText = { _ in nil }
    }

    override func tearDown() {
        seeding.close()
        try? FileManager.default.removeItem(at: directory)
    }

    /// An image card with its thumbnail on disk, `width` pixels wide.
    @discardableResult
    private func copyImage(width: Int, thumbnail: Bool = true) -> String {
        let png = Stage.pngData(width: width, height: 20)
        let id = ClipboardStore.identity(for: png)
        seeding.record(id: id, kind: .image,
                       items: [.init(plain: nil, natives: [(NSPasteboard.PasteboardType.png.rawValue, png)])],
                       imageData: thumbnail ? png : nil, preview: Clipboard.imagePreview(width: width, height: 20),
                       sourceBundleID: nil, sourceAppName: nil)
        seeding.flushIO()
        return id
    }

    /// A store that has decoded nothing, over what the seeding store wrote.
    private func reopened() -> ClipboardStore {
        seeding.close()
        return SealedFixture.clipboardStore(directory)
    }

    private func wait(_ what: String, timeout: TimeInterval = 10, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        XCTAssertTrue(condition(), what)
    }

    private func settle(_ seconds: TimeInterval = 0.15) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testAColdThumbnailIsAskedForWithoutWaitingAndArrivesDecoded() throws {
        let id = copyImage(width: 40)
        let store = reopened()
        var arrived = 0
        store.onThumbnail = { arrived += 1 }
        XCTAssertNil(store.thumbnail(for: id), "nothing is read on the asking thread")
        XCTAssertNil(store.thumbnail(for: id))
        wait("the picture arrives") { store.thumbnail(for: id) != nil }
        let image = try XCTUnwrap(store.thumbnail(for: id))
        XCTAssertEqual(image.size, NSSize(width: 40, height: 20), "a thumbnail's points are its pixels")
        XCTAssertEqual(store.decodes, 1, "asked for twice while it was coming, read once")
        settle()
        XCTAssertEqual(arrived, 1, "and the strip is told")
        XCTAssertNotNil(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }

    func testAPictureThatCannotBeReadIsAskedForOnce() {
        let id = copyImage(width: 40, thumbnail: false)
        let store = reopened()
        for _ in 0..<5 { XCTAssertNil(store.thumbnail(for: id)) }
        settle(0.3)
        for _ in 0..<5 { XCTAssertNil(store.thumbnail(for: id)) }
        XCTAssertEqual(store.decodes, 1, "a card with no thumbnail is not read again at every redraw")
    }

    /// The thumbnail of a copy is written a moment after its card exists,
    /// so a redraw in between finds nothing — and must find it afterwards.
    func testACardThatWasAskedForBeforeItsThumbnailExistedStillGetsIt() {
        let png = Stage.pngData(width: 30, height: 20)
        let id = ClipboardStore.identity(for: png)
        let store = SealedFixture.clipboardStore(directory)
        store.readText = { _ in nil }
        store.record(id: id, kind: .image,
                     items: [.init(plain: nil, natives: [(NSPasteboard.PasteboardType.png.rawValue, png)])],
                     imageData: png, preview: "image 30×20", sourceBundleID: nil, sourceAppName: nil)
        _ = store.thumbnail(for: id)
        store.flushIO()
        wait("the thumbnail lands, whichever of the two got there first") { store.thumbnail(for: id) != nil }
    }

    func testAStripsWorthOfPicturesIsOneRedraw() {
        let ids = (0..<12).map { copyImage(width: 30 + $0) }
        let store = reopened()
        var redraws = 0
        store.onThumbnail = { redraws += 1 }
        for id in ids { _ = store.thumbnail(for: id) }
        wait("all twelve arrive") { ids.allSatisfy { store.thumbnail(for: $0) != nil } }
        settle(0.3)
        XCTAssertGreaterThanOrEqual(redraws, 1)
        XCTAssertLessThanOrEqual(redraws, 2, "twelve arrivals, not twelve redraws")
    }

    func testDecodedThumbnailsAreBounded() {
        let ids = (0..<(ClipboardStore.thumbnailLimit + 12)).map { copyImage(width: 10 + $0) }
        let store = reopened()
        for id in ids { _ = store.thumbnail(for: id) }
        wait("every one is decoded") { store.decodes == ids.count }
        settle(0.5)
        XCTAssertEqual(store.cachedThumbnails, ClipboardStore.thumbnailLimit)
        XCTAssertNotNil(store.thumbnail(for: ids.last!), "the latest are the ones kept")
    }

    func testACardDeletedWhileItsPictureIsBeingReadStaysDeleted() {
        let id = copyImage(width: 40)
        let store = reopened()
        _ = store.thumbnail(for: id)
        store.delete(id)
        settle(0.3)
        XCTAssertEqual(store.cachedThumbnails, 0)
        XCTAssertNil(store.thumbnail(for: id))
    }
}
