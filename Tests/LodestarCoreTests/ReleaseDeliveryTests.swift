import Foundation
import Stoic
import XCTest
@testable import LodestarCore

/// Saying what the records owe never waits on the main thread: the store holds
/// the cross-process lock while it delivers, and a main thread that is busy
/// must not hold that lock against the other instance of a handover.
final class ReleaseDeliveryTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("release-delivery-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private final class Box<T>: @unchecked Sendable {
        // Written once by one task, read after the semaphore says it is done.
        var value: T?
    }

    func testADeliveryFinishesWhileTheMainThreadIsBusy() {
        let path = folder.appendingPathComponent("releases").path
        let records = ReleaseRecords(path: path, lockWait: .seconds(1))
        let ready = DispatchSemaphore(value: 0)
        Task.detached {
            _ = await records.boot(.init(version: "0.54.25", pid: 1, updated: "0.54.25"))
            ready.signal()
        }
        XCTAssertEqual(ready.wait(timeout: .now() + 10), .success, "boot recorded the update")

        // The main thread is held here, by this test, for the whole delivery.
        XCTAssertTrue(Thread.isMainThread)
        let done = DispatchSemaphore(value: 0)
        let delivered = Box<Bool>()
        let presented = Box<String>()
        Task.detached {
            delivered.value = await records.deliver(deciding: { _ in .delivered },
                                                    onMain: { presented.value = $0.id })
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success,
                       "the delivery did not wait for the main thread, which was busy")
        XCTAssertEqual(delivered.value, true)
        XCTAssertNil(presented.value, "the words are on their way to the main thread, not yet said")
        // Let the main thread run what was handed to it.
        let landed = Date(timeIntervalSinceNow: 2)
        while presented.value == nil, Date() < landed { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
        XCTAssertEqual(presented.value, "0.54.25")
    }

    /// The records' files leave backups as soon as they exist, not at the next
    /// launch: a record restored onto another Mac would say a release failed there.
    func testTheRecordsAreKeptOutOfBackupsAsSoonAsTheyExist() throws {
        let path = folder.appendingPathComponent("releases").path
        let records = ReleaseRecords(path: path, lockWait: .seconds(1))
        let ready = DispatchSemaphore(value: 0)
        Task.detached {
            _ = await records.boot(.init(version: "0.54.25", pid: 1, updated: "0.54.25"))
            ready.signal()
        }
        XCTAssertEqual(ready.wait(timeout: .now() + 10), .success)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("releases") }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let values = try folder.appendingPathComponent(file).resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(values.isExcludedFromBackup, true, "\(file) is excluded from backups")
        }
    }
}
