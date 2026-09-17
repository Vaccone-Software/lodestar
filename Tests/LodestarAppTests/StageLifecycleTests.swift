import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// A dead Stage leaves nothing behind: no window, no controller, and no
/// run-loop residue that makes the next suite's turns slower. The suite
/// once lost a hundred seconds to exactly that — each scenario alone in
/// two seconds, the same scenario twenty seconds in after the others.
final class StageLifecycleTests: XCTestCase {
    private func pumpCost() -> Double {
        let start = Date()
        for _ in 0..<200 { Stage.pump() }
        return Date().timeIntervalSince(start)
    }

    func testADeadStageLeavesNothingAlive() {
        let baseline = pumpCost()
        weak var clipboard: ClipboardController?
        weak var engine: HotkeyEngine?
        weak var hud: HUD?
        weak var health: HealthMonitor?
        weak var observations: ObservationStore?
        for _ in 0..<30 {
            autoreleasepool {
                let stage = Stage()
                stage.pressHeld("a", for: 0.05)
                clipboard = stage.clipboard
                engine = stage.engine
                hud = stage.hud
                health = stage.health
                observations = stage.observations
            }
            Stage.pump()
        }
        Stage.pump()
        XCTAssertNil(clipboard)
        XCTAssertNil(engine)
        XCTAssertNil(hud)
        XCTAssertNil(health)
        XCTAssertNil(observations)
        XCTAssertEqual(NSApplication.shared.windows.count, 0, "no panel outlives its stage")
        let after = pumpCost()
        XCTAssertLessThan(after, max(0.5, baseline * 2), "thirty dead stages must not slow the run loop")
    }
}
