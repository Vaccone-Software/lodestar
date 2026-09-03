import XCTest
@testable import LodestarCore

/// The note a run leaves about itself: quit or died, readable at the
/// next boot without the process that wrote it.
final class RunMarkerTests: XCTestCase {
    func testADeadPidWithNoQuitNoteIsACrash() {
        XCTAssertTrue(RunMarker.diedUncleanly(contents: RunMarker.alive(pid: 4242),
                                              isAlive: { _ in false }))
    }

    func testALivePidIsAnInstanceOnItsWayOut() {
        XCTAssertFalse(RunMarker.diedUncleanly(contents: "4242\n", isAlive: { $0 == 4242 }))
    }

    func testAQuittingNoteIsAQuitHoweverFarItGot() {
        let note = RunMarker.quitting(pid: 4242)
        XCTAssertTrue(RunMarker.isQuitting(note))
        XCTAssertEqual(RunMarker.pid(in: note), 4242, "the pid still names whose note it is")
        XCTAssertFalse(RunMarker.diedUncleanly(contents: note, isAlive: { _ in false }),
                       "a logout that cut the restore short is not a crash")
    }

    func testGarbageIsNothingToRecoverFrom() {
        XCTAssertFalse(RunMarker.diedUncleanly(contents: "", isAlive: { _ in false }))
        XCTAssertFalse(RunMarker.diedUncleanly(contents: "pid", isAlive: { _ in false }))
        XCTAssertNil(RunMarker.pid(in: "quit"))
    }
}
