import XCTest
@testable import lodestar
@testable import LodestarCore

/// A rollback is said by the instance that stays. After one the old build is
/// launched again and is often a relay: it hands the session to launchd and
/// bows out within a second, before the four seconds a flash waits. The
/// marker it read has to be there for the resident, and is retired by the
/// instance that says it. A test run resolves `Paths.update` into a home of
/// its own, which `setUp` checks before anything is written there.
///
/// An instance that is gone is an instance that is deallocated: its pending
/// flash holds it weakly, as a process that has exited runs nothing, so no
/// flash of one test's instance outlives it into the next test.
final class RollbackMarkerTests: XCTestCase {
    private var rolledBack: URL { Paths.update.appendingPathComponent("rolled-back") }
    private var refused: URL { Paths.update.appendingPathComponent("refused") }
    private var updated: URL { Paths.update.appendingPathComponent("updated-to") }
    private let tag = "v9.9.9"

    override func setUp() {
        continueAfterFailure = false
        XCTAssertTrue(Paths.update.standardizedFileURL.path.hasPrefix(TestRun.home.standardizedFileURL.path),
                      "the update directory is the test run's own, not the person's")
        continueAfterFailure = true
        clean()
    }

    override func tearDown() {
        clean()
    }

    private func clean() {
        for url in [rolledBack, refused, updated] { try? FileManager.default.removeItem(at: url) }
    }

    private func leaveRollback() throws {
        try? FileManager.default.createDirectory(at: Paths.update, withIntermediateDirectories: true)
        try Data(tag.utf8).write(to: rolledBack)
    }

    private func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    private var message: String { "⚠ \(tag) did not start, so Lodestar went back to \(Lodestar.version)" }

    /// Turn the run loop until `done` or `seconds` have passed.
    private func pump(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    }

    private final class Said {
        var flashes: [String] = []
    }

    private func instance(_ said: Said) -> UpdateController {
        let controller = UpdateController()
        controller.flash = { said.flashes.append($0) }
        return controller
    }

    func testARelayThatBowsOutLeavesTheRollbackForTheResident() throws {
        try leaveRollback()
        let relaySaid = Said()
        var relay: UpdateController? = instance(relaySaid)
        weak var gone = relay
        relay?.start()
        relay = nil
        XCTAssertNil(gone, "the relay has exited: it will run nothing")
        XCTAssertEqual(text(rolledBack), tag, "an instance that exits before it can say so leaves the marker")
        XCTAssertEqual(text(refused), tag, "the tombstone is written the first time")

        let said = Said()
        let resident = instance(said)
        resident.start()
        XCTAssertEqual(text(refused), tag, "written again by the resident: still the one tag")
        pump(6) { !said.flashes.isEmpty }
        XCTAssertEqual(said.flashes, [message], "the resident says it")
        XCTAssertNil(text(rolledBack), "and retires the marker when it has")
        XCTAssertEqual(text(refused), tag)
        XCTAssertEqual(relaySaid.flashes, [], "the relay said nothing")
        withExtendedLifetime(resident) {}
    }

    func testAResidentThatNeverSaysReadyStillSaysTheRollbackAndAThirdInstanceSaysNothing() throws {
        try leaveRollback()
        let said = Said()
        let resident = instance(said)
        resident.start()
        XCTAssertEqual(text(rolledBack), tag, "read, not retired: it is retired by being said")
        pump(6) { !said.flashes.isEmpty }
        XCTAssertEqual(said.flashes, [message])
        XCTAssertNil(text(rolledBack))
        XCTAssertEqual(text(refused), tag)

        let thirdSaid = Said()
        let third = instance(thirdSaid)
        third.start()
        pump(4.5)
        XCTAssertEqual(thirdSaid.flashes, [], "a rollback said once is not said again")
        XCTAssertEqual(said.flashes, [message])
        withExtendedLifetime((resident, third)) {}
    }

    func testTheResidentRetiresTheRollbackWhenItSaysReadyAndStillSaysIt() throws {
        try leaveRollback()
        let said = Said()
        let resident = instance(said)
        resident.start()
        resident.acknowledgeBoot()
        XCTAssertNil(text(rolledBack), "said ready: the marker has done its work")
        XCTAssertEqual(text(refused), tag, "the tombstone outlives it")
        pump(6) { !said.flashes.isEmpty }
        XCTAssertEqual(said.flashes, [message], "the flash scheduled at boot still fires")
        withExtendedLifetime(resident) {}
    }

    func testARelayThatSurvivesPastFourSecondsAndTheResidentBothSayItAndNeitherIsLost() throws {
        try leaveRollback()
        let relaySaid = Said()
        let residentSaid = Said()
        let relay = instance(relaySaid)
        let resident = instance(residentSaid)
        relay.start()
        resident.start()
        pump(6) { !relaySaid.flashes.isEmpty && !residentSaid.flashes.isEmpty }
        XCTAssertEqual(relaySaid.flashes, [message])
        XCTAssertEqual(residentSaid.flashes, [message], "a second flash of the same words, never a lost one")
        XCTAssertNil(text(rolledBack))
        XCTAssertEqual(text(refused), tag)
        withExtendedLifetime((relay, resident)) {}
    }
}
