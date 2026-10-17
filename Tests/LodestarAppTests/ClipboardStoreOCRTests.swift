import XCTest
@testable import lodestar
@testable import LodestarCore

/// Reading what an image says is the heaviest thing the clipboard does, so
/// it goes through one queue: a burst of screenshots is read one after the
/// other, every card still learns its caption, and a screenshot copied
/// while the old ones are being captioned is not made to wait for them.
final class ClipboardStoreOCRTests: XCTestCase {
    private var directory: URL!
    private var store: ClipboardStore!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-ocr-\(UUID().uuidString)", isDirectory: true)
        store = ClipboardStore(root: directory)
    }

    override func tearDown() {
        store.saveNow()
        store.flushIO()
        try? FileManager.default.removeItem(at: directory)
    }

    /// What the stand-in recognizer saw: how many reads ran at once, and
    /// which images it was given, in order.
    private final class Reading: @unchecked Sendable {
        private let lock = NSLock()
        private var running = 0
        private(set) var widest = 0
        private(set) var order: [Int] = []
        /// Held by the first read until the test lets it go.
        let gate = DispatchSemaphore(value: 0)
        let first = DispatchSemaphore(value: 0)
        var holdsFirst = false

        func read(_ data: Data) -> String? {
            let place: Int = lock.withLock {
                running += 1
                widest = max(widest, running)
                order.append(data.count)
                return order.count
            }
            if holdsFirst, place == 1 {
                first.signal()
                gate.wait()
            } else {
                Thread.sleep(forTimeInterval: 0.03)
            }
            lock.withLock { running -= 1 }
            return "says \(data.count)"
        }
    }

    /// An image card whose bytes are `size` long, so what was read says
    /// which card it was. The bytes are not a picture: no thumbnail comes of
    /// them, which is not what is under test.
    private func copyImage(_ size: Int, recognizing: Bool = true) -> String {
        let bytes = Data(repeating: UInt8(size % 251), count: size)
        let id = ClipboardStore.identity(for: bytes)
        store.record(id: id, kind: .image,
                     items: [.init(plain: nil, natives: [(NSPasteboard.PasteboardType.png.rawValue, bytes)])],
                     imageData: recognizing ? bytes : nil, preview: "image 1×1",
                     sourceBundleID: nil, sourceAppName: nil)
        return id
    }

    private func preview(_ id: String) -> String? { store.clips.first { $0.id == id }?.preview }

    private func wait(_ what: String, timeout: TimeInterval = 10, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(condition(), what)
    }

    func testABurstOfScreenshotsIsReadOneAtATimeAndEveryCardLearnsItsCaption() {
        let reading = Reading()
        store.readText = reading.read
        let sizes = Array(100..<112)
        let ids = sizes.map { copyImage($0) }
        wait("every card has its caption") {
            ids.allSatisfy { preview($0)?.contains("\n") == true }
        }
        XCTAssertEqual(reading.widest, 1, "one pass of the recognizer at a time")
        XCTAssertEqual(Set(reading.order), Set(sizes), "each image read once")
        for (id, size) in zip(ids, sizes) {
            XCTAssertEqual(preview(id), "image 1×1\nsays \(size)", "the caption belongs to its own card")
        }
    }

    func testTheBacklogIsCaptionedThroughTheSameQueue() {
        let reading = Reading()
        store.readText = reading.read
        let ids = (200..<206).map { copyImage($0, recognizing: false) }
        store.flushIO()
        XCTAssertTrue(ids.allSatisfy { preview($0) == "image 1×1" }, "nothing was read at capture")
        store.captionImagesLackingText()
        wait("the backlog is captioned") { ids.allSatisfy { preview($0)?.contains("\n") == true } }
        XCTAssertEqual(reading.widest, 1)
        XCTAssertEqual(reading.order.count, 6)
    }

    func testAScreenshotCopiedDuringTheBacklogIsNotMadeToWaitForIt() {
        let reading = Reading()
        reading.holdsFirst = true
        store.readText = reading.read
        let backlog = (300..<305).map { copyImage($0, recognizing: false) }
        store.flushIO()
        store.captionImagesLackingText()
        // The first backlog image is being read, and stays so until the
        // fresh copy has been queued behind it.
        XCTAssertEqual(reading.first.wait(timeout: .now() + 10), .success)
        let fresh = copyImage(999)
        store.flushIO()
        reading.gate.signal()
        wait("everything is captioned") {
            (backlog + [fresh]).allSatisfy { preview($0)?.contains("\n") == true }
        }
        XCTAssertEqual(reading.order.count, 6)
        XCTAssertEqual(reading.order[1], 999, "the fresh copy is read next, ahead of the rest of the backlog")
        XCTAssertEqual(reading.widest, 1)
    }
}
