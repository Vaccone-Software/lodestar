import XCTest
@testable import lodestar
@testable import LodestarCore

/// Everything the history keeps of what was copied is sealed and the owner's
/// alone: each blob and thumbnail is written 0600 under a name that says
/// nothing, in folders 0700, whatever the umask.
final class ClipboardStoreModesTests: XCTestCase {
    private var directory: URL!
    private var previousMask: mode_t = 0

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-modes-\(UUID().uuidString)", isDirectory: true)
        previousMask = umask(0)
    }

    override func tearDown() {
        umask(previousMask)
        try? FileManager.default.removeItem(at: directory)
    }

    private func assertPrivate(file: StaticString = #filePath, line: UInt = #line) {
        let modes = ClipboardSynth.modes(under: directory)
        XCTAssertFalse(modes.isEmpty, file: file, line: line)
        for (name, mode) in modes {
            let isDirectory = (try? directory.appendingPathComponent(name).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            XCTAssertEqual(mode, isDirectory ? 0o700 : 0o600, "\(name)", file: file, line: line)
        }
    }

    func testEveryFileACopyLeavesIsPrivate() {
        let store = SealedFixture.clipboardStore(directory)
        store.readText = { _ in nil }
        let png = Stage.pngData(width: 30, height: 20)
        store.record(id: "image", kind: .image,
                     items: [.init(plain: nil, natives: [(NSPasteboard.PasteboardType.png.rawValue, png)])],
                     imageData: png, preview: "image 30×20", sourceBundleID: nil, sourceAppName: nil)
        store.record(id: "text", kind: .text,
                     items: [.init(plain: Data("t".utf8), natives: [("public.html", Data("<b>t</b>".utf8))]),
                             .init(plain: Data("u".utf8), natives: [])],
                     imageData: nil, preview: "t", sourceBundleID: nil, sourceAppName: nil)
        store.close()
        let items = SealedFixture.v2(directory).appendingPathComponent("items")
        let thumbs = SealedFixture.v2(directory).appendingPathComponent("thumbs")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: items.path).count, 2, "one sealed file per clip")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: thumbs.path).count, 1)
        assertPrivate()
    }

    func testTheFilesOfAnEditAreAlsoPrivate() {
        let store = SealedFixture.clipboardStore(directory)
        store.record(id: "t", kind: .text, items: [.init(plain: Data("one".utf8), natives: [])],
                     imageData: nil, preview: "one", sourceBundleID: nil, sourceAppName: nil)
        store.flushIO()
        let replaced = store.replace(store.clips[0], withText: "two")
        let kept = store.fileEdit(from: store.clips[0], text: "three")
        store.close()
        XCTAssertNotNil(replaced)
        XCTAssertNotNil(kept)
        assertPrivate()
    }

    func testACopyWrittenOverASealedBlobMakesItPrivateStill() throws {
        let store = SealedFixture.clipboardStore(directory)
        store.record(id: "t", kind: .text, items: [.init(plain: Data("one".utf8), natives: [])],
                     imageData: nil, preview: "one", sourceBundleID: nil, sourceAppName: nil)
        store.flushIO()
        let file = try XCTUnwrap(store.blobURL(for: "t"))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        store.record(id: "t", kind: .text, items: [.init(plain: Data("different".utf8), natives: [])],
                     imageData: nil, preview: "one", sourceBundleID: nil, sourceAppName: nil)
        store.flushIO()
        XCTAssertEqual(store.plainText("t"), "different")
        let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode, 0o600)
        store.close()
    }
}
