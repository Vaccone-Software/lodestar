import XCTest
@testable import LodestarCore
@testable import lodestar

/// Tests never write the live log, whichever runner started them: the
/// sharded runner calls xctest directly, without the environment
/// `swift test` sets, and once wrote test lines into the user's log.
final class AppLogSealTests: XCTestCase {
    func testTestsNeverWriteTheLiveLog() {
        XCTAssertFalse(Log.fileEnabled)
    }
}
