import XCTest
@testable import LodestarCore

/// Tests never write the live log, whichever runner started them: the
/// sharded runner calls xctest directly, without the environment
/// `swift test` sets, and once wrote test lines into the user's log.
final class LogSealTests: XCTestCase {
    func testTestsNeverWriteTheLiveLog() {
        XCTAssertFalse(Log.fileEnabled)
    }
}
