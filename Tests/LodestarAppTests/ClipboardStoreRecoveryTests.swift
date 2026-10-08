import XCTest
@testable import lodestar
@testable import LodestarCore

/// Keep's index is the only thing that points at the clips under items/.
/// One that will not decode (a schema change to Clip is the realistic
/// cause) is set aside and said out loud; one that cannot be read at all
/// leaves the store read-only, because writing an empty index over it
/// would orphan every clip.
final class ClipboardStoreRecoveryTests: XCTestCase {
    private var root: URL!
    private var index: URL { root.appendingPathComponent("index.json") }

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

    private func saved(_ store: ClipboardStore) {
        store.saveNow()
        store.flushIO()
    }

    func testAnIndexThatWillNotDecodeIsSetAsideAndNamed() throws {
        let first = ClipboardStore(root: root)
        record(first, "kept", id: "c1")
        saved(first)
        let blob = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("items").path)
        XCTAssertFalse(blob.isEmpty, "the clip's bytes are on disk")

        let garbage = Data("{\"clips\": [{\"id\": 1".utf8)
        try garbage.write(to: index)
        let second = ClipboardStore(root: root)
        XCTAssertEqual(second.clips.count, 0)
        XCTAssertNotNil(second.bootWarning, "said out loud, once, at boot")
        let aside = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("index.json.corrupt-") }
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try Data(contentsOf: aside[0]), garbage, "kept byte for byte")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("items").path),
                       blob, "no clip's bytes are deleted")
    }

    func testAnIndexThatCannotBeReadIsNeverWrittenOver() throws {
        let first = ClipboardStore(root: root)
        record(first, "kept", id: "c1")
        saved(first)
        let before = try Data(contentsOf: index)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: index.path)

        let second = ClipboardStore(root: root)
        record(second, "new", id: "c2")
        saved(second)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path)
        XCTAssertEqual(try Data(contentsOf: index), before, "read-only until it can be read")
    }

    func testAGoodIndexComesBackWhole() {
        let first = ClipboardStore(root: root)
        record(first, "one", id: "c1")
        record(first, "two", id: "c2")
        saved(first)
        let second = ClipboardStore(root: root)
        XCTAssertEqual(Set(second.clips.map(\.id)), ["c1", "c2"])
        XCTAssertNil(second.bootWarning)
        XCTAssertEqual(second.plainText("c1"), "one")
    }
}
