import XCTest
@testable import lodestar
@testable import LodestarCore

/// Everything the history keeps of what was copied is the owner's alone:
/// each blob and thumbnail is written 0600, and the ones an older build left
/// readable are tightened once, at load, off the main thread.
final class ClipboardStoreModesTests: XCTestCase {
    private var directory: URL!
    private var previousMask: mode_t = 0
    private var items: URL { directory.appendingPathComponent("items") }
    private var thumbs: URL { directory.appendingPathComponent("thumbs") }

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-modes-\(UUID().uuidString)", isDirectory: true)
        previousMask = umask(0)
    }

    override func tearDown() {
        umask(previousMask)
        try? FileManager.default.removeItem(at: directory)
    }

    private func mode(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int) ?? -1
    }

    private func modes(_ url: URL) -> [String: Int] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return Dictionary(uniqueKeysWithValues: names.map { ($0, mode(url.appendingPathComponent($0))) })
    }

    func testEveryFileACopyLeavesIsPrivate() {
        let store = ClipboardStore(root: directory)
        store.readText = { _ in nil }
        let png = Stage.pngData(width: 30, height: 20)
        store.record(id: "image", kind: .image,
                     items: [.init(plain: nil, natives: [(NSPasteboard.PasteboardType.png.rawValue, png)])],
                     imageData: png, preview: "image 30×20", sourceBundleID: nil, sourceAppName: nil)
        store.record(id: "text", kind: .text,
                     items: [.init(plain: Data("t".utf8), natives: [("public.html", Data("<b>t</b>".utf8))]),
                             .init(plain: Data("u".utf8), natives: [])],
                     imageData: nil, preview: "t", sourceBundleID: nil, sourceAppName: nil)
        store.flushIO()
        XCTAssertEqual(Set(modes(items).keys), ["image.type0", "text.plain", "text.type0", "text.i1.plain"])
        XCTAssertEqual(Set(modes(thumbs).keys), ["image.png"])
        XCTAssertTrue((Array(modes(items).values) + Array(modes(thumbs).values)).allSatisfy { $0 == 0o600 },
                      "\(modes(items)) \(modes(thumbs))")
    }

    func testTheFilesOfAnEditAreAlsoPrivate() {
        let store = ClipboardStore(root: directory)
        store.record(id: "t", kind: .text, items: [.init(plain: Data("one".utf8), natives: [])],
                     imageData: nil, preview: "one", sourceBundleID: nil, sourceAppName: nil)
        store.flushIO()
        let replaced = store.replace(store.clips[0], withText: "two")
        let kept = store.fileEdit(from: store.clips[0], text: "three")
        store.flushIO()
        XCTAssertNotNil(replaced)
        XCTAssertNotNil(kept)
        let files = modes(items)
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files.values.allSatisfy { $0 == 0o600 }, "\(files)")
    }

    func testACopyWrittenOverAnOlderReadableBlobMakesItPrivate() throws {
        let store = ClipboardStore(root: directory)
        store.record(id: "t", kind: .text, items: [.init(plain: Data("one".utf8), natives: [])],
                     imageData: nil, preview: "one", sourceBundleID: nil, sourceAppName: nil)
        store.flushIO()
        let file = items.appendingPathComponent("t.plain")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        store.record(id: "t", kind: .text, items: [.init(plain: Data("different".utf8), natives: [])],
                     imageData: nil, preview: "one", sourceBundleID: nil, sourceAppName: nil)
        store.flushIO()
        XCTAssertEqual(try Data(contentsOf: file), Data("different".utf8))
        XCTAssertEqual(mode(file), 0o600)
    }

    func testWhatAnOlderBuildLeftReadableIsTightenedAtLoad() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: items, withIntermediateDirectories: true)
        try fm.createDirectory(at: thumbs, withIntermediateDirectories: true)
        let old = [items.appendingPathComponent("a.plain"), items.appendingPathComponent("a.type0"),
                   thumbs.appendingPathComponent("a.png")]
        for (n, file) in old.enumerated() {
            try Data("x".utf8).write(to: file)
            try fm.setAttributes([.posixPermissions: n == 1 ? 0o640 : 0o644], ofItemAtPath: file.path)
        }
        let already = items.appendingPathComponent("b.plain")
        try Data("x".utf8).write(to: already)
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: already.path)
        // A link planted among them: what it points at is not ours to change.
        let outside = directory.appendingPathComponent("outside")
        try Data("x".utf8).write(to: outside)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: outside.path)
        try fm.createSymbolicLink(at: items.appendingPathComponent("c.plain"), withDestinationURL: outside)

        let store = ClipboardStore(root: directory)
        store.flushIO()
        for file in old { XCTAssertEqual(mode(file), 0o600, file.lastPathComponent) }
        XCTAssertEqual(mode(already), 0o400, "a file with nothing for others to read is left as it is")
        XCTAssertEqual(mode(outside), 0o644, "a link is not followed")
    }
}
