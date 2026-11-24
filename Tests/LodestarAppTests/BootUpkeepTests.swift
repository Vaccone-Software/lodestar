import XCTest
@testable import lodestar

/// Upkeep waits for an instance that has settled and is staying.
final class BootUpkeepTests: XCTestCase {
    private func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testAResidentInstanceIsTendedOnceSettledAndNotBefore() {
        var tended = 0
        BootUpkeep.schedule(after: 0.3, isResident: { true }, tend: { tended += 1 })
        settle(0.1)
        XCTAssertEqual(tended, 0, "not on the launch path")
        settle(0.5)
        XCTAssertEqual(tended, 1)
    }

    func testARelayIsNeverTended() {
        var tended = 0
        BootUpkeep.schedule(after: 0.1, isResident: { false }, tend: { tended += 1 })
        settle(0.4)
        XCTAssertEqual(tended, 0, "a relay hands over; launchd's instance does the upkeep")
    }

    /// The app reads its records at launch without their upkeep, and hands
    /// the upkeep to BootUpkeep with the relay check.
    func testTheAppReadsAtLaunchAndTendsThroughBootUpkeep() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let main = try String(contentsOf: root.appendingPathComponent("Sources/lodestar/main.swift"), encoding: .utf8)
        XCTAssertTrue(main.contains("observationStore?.load(compacting: false)"))
        XCTAssertFalse(main.contains("observationStore?.load()"), "a launch read never carries the upkeep")
        XCTAssertTrue(main.contains("BootUpkeep.schedule(isResident: { [weak self] in self?.handingOverToLaunchd == false }"))
    }
}
