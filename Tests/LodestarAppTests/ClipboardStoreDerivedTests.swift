import XCTest
@testable import lodestar
@testable import LodestarCore

/// What a redraw asks of the whole history — the recents, the keepsakes,
/// the source counts — is worked out once for each state of the index, and
/// is never stale: every way the index can change moves it on.
final class ClipboardStoreDerivedTests: XCTestCase {
    private var directory: URL!
    private var store: ClipboardStore!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-derived-\(UUID().uuidString)", isDirectory: true)
        store = SealedFixture.clipboardStore(directory)
        store.readText = { _ in nil }
    }

    override func tearDown() {
        store.close()
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func copy(_ text: String, app: String = "Safari") -> String {
        let data = Data(text.utf8)
        let id = ClipboardStore.identity(for: data)
        store.record(id: id, kind: .text, items: [.init(plain: data, natives: [])], imageData: nil,
                     preview: text, sourceBundleID: nil, sourceAppName: app)
        return id
    }

    private func assertAgrees(_ step: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(store.recents.map(\.id), Clipboard.recents(store.clips).map(\.id), step, file: file, line: line)
        XCTAssertEqual(store.pins.map(\.id), Clipboard.pins(store.clips).map(\.id), step, file: file, line: line)
        XCTAssertEqual(store.sourceCounts, Clipboard.sourceCounts(store.clips), step, file: file, line: line)
    }

    func testTheRecentsAreWorkedOutOncePerStateOfTheIndex() {
        copy("one")
        copy("two", app: "Notes")
        let derived = store.derivations
        for _ in 0..<5 { _ = store.recents; _ = store.pins; _ = store.sourceCounts }
        XCTAssertEqual(store.derivations, derived + 1, "fifteen questions, one pass over the clips")
        copy("three")
        _ = store.recents
        XCTAssertEqual(store.derivations, derived + 2, "a change is worked out again, once")
        assertAgrees("after a copy")
    }

    func testAskingForAThumbnailIsNotAChangeToTheIndex() {
        let id = copy("one")
        _ = store.recents
        let before = (store.generation, store.derivations)
        _ = store.thumbnail(for: id)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        _ = store.recents
        XCTAssertEqual(store.generation, before.0)
        XCTAssertEqual(store.derivations, before.1, "a picture arriving redraws, it does not re-derive")
    }

    /// Every door into the index, each followed by the check that what was
    /// derived is what the clips say.
    func testNothingThatChangesTheIndexLeavesTheDerivedStale() {
        let a = copy("alpha", app: "Safari")
        let b = copy("beta", app: "Notes")
        let c = copy("gamma", app: "Safari")
        assertAgrees("copies")
        var generation = store.generation
        func moved(_ what: String, _ change: () -> Void) {
            _ = store.recents
            change()
            XCTAssertGreaterThan(store.generation, generation, "\(what) moves the generation on")
            generation = store.generation
            assertAgrees(what)
        }
        moved("pin") { XCTAssertTrue(store.pin(b)) }
        moved("name") { store.name(b, "Beta") }
        moved("place") { store.place(a, at: 1) }
        moved("move") { store.move(a, to: 3) }
        moved("unpin") { store.unpin(b) }
        moved("keepsakes restored") { store.restoreKeepsakes([c: (slot: 2, name: nil)]) }
        moved("replace") { _ = store.replace(store.clips.first { $0.id == c }!, withText: "gamma two") }
        moved("file an edit") { _ = store.fileEdit(from: store.clips[0], text: "an edit") }
        moved("a recopy") { copy("alpha") }
        moved("delete") { store.delete(a) }
        moved("trim") { store.trim(maxBytes: Int.max, maxItems: 1) }
        moved("clear") { store.clearAll() }
        XCTAssertTrue(store.recents.isEmpty)
    }

    func testACaptionArrivingMovesTheGenerationOn() {
        let png = Stage.pngData(width: 20, height: 20)
        let id = ClipboardStore.identity(for: png)
        store.readText = { _ in "caption" }
        store.record(id: id, kind: .image,
                     items: [.init(plain: nil, natives: [(NSPasteboard.PasteboardType.png.rawValue, png)])],
                     imageData: png, preview: "image 20×20", sourceBundleID: nil, sourceAppName: nil)
        let before = store.generation
        let deadline = Date().addingTimeInterval(10)
        while store.recents.first?.preview.contains("caption") != true, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertGreaterThan(store.generation, before)
        XCTAssertEqual(store.recents.first?.preview, "image 20×20\ncaption", "the derived recents carry the caption")
    }

    func testALoadedHistoryIsDerivedFromWhatWasLoaded() {
        copy("one")
        copy("two")
        store.close()
        let reloaded = SealedFixture.clipboardStore(directory)
        XCTAssertEqual(reloaded.recents.map(\.id), store.recents.map(\.id))
    }
}
