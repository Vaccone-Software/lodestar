import XCTest
@testable import LodestarCore

final class ModelHoldTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testNothingIsHeldBeforeAWarning() {
        XCTAssertFalse(ModelHold().holds(at: start, level: .critical), "the level alone sends nothing away")
    }

    func testTheQuietHoldsWhateverTheLevelSays() {
        var hold = ModelHold()
        hold.pressed(at: start)
        XCTAssertTrue(hold.holds(at: start, level: .normal))
        XCTAssertTrue(hold.holds(at: start.addingTimeInterval(ModelHold.quiet - 1), level: .normal))
        XCTAssertFalse(hold.holds(at: start.addingTimeInterval(ModelHold.quiet), level: .normal))
    }

    func testAShortLevelHoldsPastTheQuietUpToTheCeiling() {
        var hold = ModelHold()
        hold.pressed(at: start)
        XCTAssertTrue(hold.holds(at: start.addingTimeInterval(ModelHold.quiet), level: .warning))
        XCTAssertTrue(hold.holds(at: start.addingTimeInterval(ModelHold.longest - 1), level: .critical))
        XCTAssertFalse(hold.holds(at: start.addingTimeInterval(ModelHold.longest), level: .critical),
                       "a Mac that lives at the warning level keeps its model")
    }

    func testAnotherWarningStartsTheWaitAgain() {
        var hold = ModelHold()
        hold.pressed(at: start)
        let later = start.addingTimeInterval(ModelHold.quiet - 1)
        hold.pressed(at: later)
        XCTAssertTrue(hold.holds(at: later.addingTimeInterval(ModelHold.quiet - 1), level: .normal))
    }

    func testTheLevelIsNotAskedWhenNothingWaits() {
        var asked = 0
        func level() -> MemoryLevel { asked += 1; return .normal }
        XCTAssertFalse(ModelHold().holds(at: start, level: level()))
        XCTAssertEqual(asked, 0, "the editor asks every beat")
    }
}

final class MemoryLogPlanTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testAFirstLookThenTheHeartbeat() {
        var plan = MemoryLogPlan()
        XCTAssertEqual(plan.why(at: start, level: .normal), "start")
        XCTAssertNil(plan.why(at: start.addingTimeInterval(15), level: .normal))
        XCTAssertNil(plan.why(at: start.addingTimeInterval(MemoryLogPlan.heartbeat - 1), level: .normal))
        XCTAssertEqual(plan.why(at: start.addingTimeInterval(MemoryLogPlan.heartbeat), level: .normal), "beat")
        XCTAssertNil(plan.why(at: start.addingTimeInterval(MemoryLogPlan.heartbeat + 15), level: .normal))
    }

    func testEveryChangeOfLevelIsALine() {
        var plan = MemoryLogPlan()
        _ = plan.why(at: start, level: .normal)
        XCTAssertEqual(plan.why(at: start.addingTimeInterval(15), level: .warning), "level")
        XCTAssertNil(plan.why(at: start.addingTimeInterval(30), level: .warning))
        XCTAssertEqual(plan.why(at: start.addingTimeInterval(45), level: .normal), "level")
    }

    func testALevelLineStartsTheHeartbeatAgain() {
        var plan = MemoryLogPlan()
        _ = plan.why(at: start, level: .normal)
        let change = start.addingTimeInterval(MemoryLogPlan.heartbeat - 1)
        XCTAssertEqual(plan.why(at: change, level: .warning), "level")
        XCTAssertNil(plan.why(at: start.addingTimeInterval(MemoryLogPlan.heartbeat + 1), level: .warning))
    }
}

final class MemoryReportTests: XCTestCase {
    func testAHelperCountsUnderItsApplication() {
        XCTAssertEqual(MemoryReport.appName(path: "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Versions/1/Helpers/Brave Browser Helper (Renderer).app/Contents/MacOS/Brave Browser Helper (Renderer)"),
                       "Brave Browser", "the outermost bundle, not the helper's own")
        XCTAssertEqual(MemoryReport.appName(path: "/Applications/lodestar.app/Contents/MacOS/lodestar"), "lodestar")
    }

    func testAToolIsItsOwnName() {
        XCTAssertEqual(MemoryReport.appName(path: "/opt/homebrew/bin/node"), "node")
        XCTAssertEqual(MemoryReport.appName(path: "/Users/vac/Library/Application Support/Basalt/bin/basalt-mac"), "basalt-mac")
    }

    func testTheLargestAreSummedAndSorted() {
        let mb: UInt64 = 1 << 20
        let top = MemoryReport.largest([
            ("/Applications/B.app/Contents/MacOS/B", 100 * mb),
            ("/Applications/B.app/Contents/Frameworks/H.app/Contents/MacOS/H", 300 * mb),
            ("/usr/bin/a", 500 * mb),
            ("/usr/bin/c", 10 * mb),
            ("/usr/bin/node", 5 * mb),
            ("/opt/node", 6 * mb),
        ], count: 3)
        XCTAssertEqual(top, [MemoryApp(name: "a", mb: 500), MemoryApp(name: "B", mb: 400), MemoryApp(name: "node", mb: 11)])
    }

    func testTheTopLineReadsInOneField() {
        let reading = MemoryReading(footprintMB: 1, peakMB: 2, level: .warning, freePercent: 3, compressorMB: 4, swapMB: 5,
                                    top: [MemoryApp(name: "basalt-mac", mb: 7040), MemoryApp(name: "Brave Browser", mb: 3000)])
        XCTAssertEqual(reading.topLine, "basalt-mac 7040, Brave Browser 3000")
    }

    /// Off the real Mac, whichever one: the calls must read what they say.
    func testARealReadingFindsThisProcess() {
        let reading = MemoryReport.read(topCount: 2000)
        XCTAssertGreaterThan(reading.footprintMB, 0)
        XCTAssertGreaterThanOrEqual(reading.peakMB, reading.footprintMB)
        XCTAssertTrue((0...100).contains(reading.freePercent), "\(reading.freePercent)")
        XCTAssertGreaterThanOrEqual(reading.compressorMB, 0)
        XCTAssertGreaterThanOrEqual(reading.swapMB, 0)
        let own = MemoryReport.appName(path: ProcessInfo.processInfo.arguments[0])
        XCTAssertTrue(reading.top.contains { $0.name == own }, "\(own) in \(reading.topLine)")
    }

    func testTheLevelIsOneTheKernelNames() {
        XCTAssertTrue([MemoryLevel.normal, .warning, .critical].contains(.current))
    }
}
