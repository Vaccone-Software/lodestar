import XCTest
@testable import lodestar
@testable import LodestarCore

/// `lodestar clipboard clear` prints that it cleared and exits. The removal
/// and the empty index are written on the store's own queue, so the call it
/// makes has to finish them before it returns.
final class ClipboardStoreClearTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-clear-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testClearingAndWaitingLeavesNothingOnDiskWhenItReturns() throws {
        let store = ClipboardStore(root: directory)
        for n in 0..<40 {
            let data = Data(repeating: UInt8(n), count: 200_000)
            store.record(id: ClipboardStore.identity(for: data), kind: .text,
                         items: [.init(plain: data, natives: [("public.html", data)])],
                         imageData: nil, preview: "clip \(n)", sourceBundleID: nil, sourceAppName: nil)
        }
        store.saveNow()
        store.flushIO()
        XCTAssertEqual(store.clips.count, 40)

        store.clearAllAndWait()

        // Nothing here waits for the store: this is what a process that
        // exits at once leaves behind.
        let items = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("items").path)
        XCTAssertEqual(items, [], "every blob is gone")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: directory.appendingPathComponent("thumbs").path), [])
        let index = try Data(contentsOf: directory.appendingPathComponent("index.json"))
        XCTAssertTrue(try XCTUnwrap(String(data: index, encoding: .utf8)).contains("\"clips\":[]"),
                      "and the index on disk is the empty one")
        XCTAssertEqual(ClipboardStore(root: directory).clips.count, 0)
    }
}
