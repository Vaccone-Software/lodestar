import XCTest
@testable import lodestar
@testable import LodestarCore

/// What an older build's index does to the history that replaces it: one that
/// will not decode is set aside and said out loud, one that cannot be read at
/// all is never written over, and a good one is taken in whole.
final class ClipboardStoreRecoveryTests: XCTestCase {
    private var root: URL!
    private var index: URL { ClipboardV1.indexFile(root) }

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("keep-recovery-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path)
        try? FileManager.default.removeItem(at: root)
    }

    private func record(_ store: ClipboardStore, _ text: String, id: String) {
        store.record(id: id, kind: .text, items: [.init(plain: Data(text.utf8), natives: [])],
                     imageData: nil, preview: text, sourceBundleID: nil, sourceAppName: nil)
    }

    private func olderHistory(_ words: [String]) throws -> [Clipboard.Clip] {
        var clips: [Clipboard.Clip] = []
        for (n, word) in words.enumerated() {
            let clip = Clipboard.Clip(id: "old\(n)", kind: .text, created: Date(timeIntervalSince1970: 1_700_000_000 - Double(n)),
                                      sourceBundleID: nil, sourceAppName: nil, preview: word, bytes: word.utf8.count)
            try ClipboardV1.write(clip, items: [.init(plain: Data(word.utf8), natives: [])], to: root)
            clips.append(clip)
        }
        try ClipboardV1.writeIndex(clips, to: root)
        return clips
    }

    /// What is copied is private: everything under the clipboard folder is the owner's alone.
    func testEverythingTheHistoryKeepsIsTheOwnersAlone() throws {
        let store = SealedFixture.clipboardStore(root)
        record(store, "secret", id: "c1")
        store.close()
        let tree = ClipboardSynth.modes(under: root)
        XCTAssertFalse(tree.isEmpty)
        for (name, mode) in tree {
            let directory = (try? URL(fileURLWithPath: root.appendingPathComponent(name).path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            XCTAssertEqual(mode, directory ? 0o700 : 0o600, name)
        }
    }

    func testAnIndexThatWillNotDecodeIsSetAsideAndNamed() throws {
        _ = try olderHistory(["kept"])
        let blobs = try FileManager.default.contentsOfDirectory(atPath: ClipboardV1.items(root).path)
        let garbage = Data("{\"clips\": [{\"id\": 1".utf8)
        try garbage.write(to: index)
        let second = SealedFixture.clipboardStore(root)
        XCTAssertEqual(second.clips.count, 0)
        XCTAssertNotNil(second.bootWarning, "said out loud, once, at boot")
        let aside = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("index.json.corrupt-") }
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try Data(contentsOf: aside[0]), garbage, "kept byte for byte")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: ClipboardV1.items(root).path), blobs,
                       "no clip's bytes are deleted")
        second.close()
    }

    func testAnIndexThatCannotBeReadIsNeverWrittenOverOrRemoved() throws {
        _ = try olderHistory(["kept"])
        let before = try Data(contentsOf: index)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: index.path)
        let second = SealedFixture.clipboardStore(root)
        record(second, "new", id: "c2")
        second.close()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path)
        XCTAssertEqual(try Data(contentsOf: index), before, "left until it can be read")
    }

    func testAGoodOlderHistoryComesBackWholeAndIsSealed() throws {
        let clips = try olderHistory(["one", "two"])
        let second = SealedFixture.clipboardStore(root)
        XCTAssertEqual(second.clips, clips)
        XCTAssertNil(second.bootWarning)
        XCTAssertEqual(second.plainText("old0"), "one")
        XCTAssertEqual(ClipboardV1.plaintextFiles(root), [])
        second.close()
    }
}
