import ApplicationServices
import XCTest
@testable import LodestarCore

/// Parks and unparks on the move lane: the accessibility write leaves
/// the gesture, the bookkeeping does not, and a refusal that comes back
/// later undoes exactly the bookkeeping it belongs to.
final class ParkingLaneTests: XCTestCase {
    private final class Mover: WindowMoving {
        var positions: [(id: CGWindowID, point: CGPoint)] = []
        var frames: [(id: CGWindowID, frame: CGRect)] = []
        var refuse = false
        let lock = NSLock()

        func setFrame(_ window: WindowModel.Window, _ frame: CGRect) -> Bool {
            lock.lock(); defer { lock.unlock() }
            frames.append((window.id, frame))
            return !refuse
        }

        func setPosition(_ window: WindowModel.Window, _ point: CGPoint) -> Bool {
            lock.lock(); defer { lock.unlock() }
            positions.append((window.id, point))
            return !refuse
        }

        func raise(_ window: WindowModel.Window) {}
    }

    private let main = CGRect(x: 0, y: 0, width: 1600, height: 900)

    private func window(_ id: CGWindowID, frame: CGRect) -> WindowModel.Window {
        WindowModel.Window(id: id, element: AXUIElementCreateApplication(1), pid: 1,
                           appName: "Test", bundleID: "com.test", title: "",
                           frame: frame, isMinimized: false, isAlive: true,
                           lastFocused: nil, deadAt: nil)
    }

    func testAQueuedParkRecordsTheSpotBeforeTheWriteLands() {
        let mover = Mover()
        let lane = DispatchQueue(label: "test.moves")
        let lot = ParkingLot(mover: mover, bounds: { [self.main] }, moveQueue: lane)
        let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
        XCTAssertTrue(lot.park(window(7, frame: frame)), "queued is a yes")
        XCTAssertTrue(lot.isParked(7), "the intent is on the books at once")
        XCTAssertEqual(lot.snapshot()[7], frame)
        lot.waitForWrites()
        XCTAssertEqual(mover.positions.count, 1, "and the write landed on the lane")
        XCTAssertEqual(mover.positions.first?.id, 7)
    }

    func testARefusedParkForgetsTheSpotOnMain() {
        let mover = Mover()
        mover.refuse = true
        let lane = DispatchQueue(label: "test.moves")
        let lot = ParkingLot(mover: mover, bounds: { [self.main] }, moveQueue: lane)
        XCTAssertTrue(lot.park(window(8, frame: CGRect(x: 0, y: 0, width: 10, height: 10))))
        lot.waitForWrites()
        let forgotten = expectation(description: "the refusal reaches the books")
        DispatchQueue.main.async {
            XCTAssertFalse(lot.isParked(8), "a park the app refused is not a park")
            forgotten.fulfill()
        }
        wait(for: [forgotten], timeout: 2)
    }

    func testInlineParkStillAnswersHonestly() {
        let mover = Mover()
        mover.refuse = true
        let lot = ParkingLot(mover: mover, bounds: { [self.main] })
        XCTAssertFalse(lot.park(window(9, frame: CGRect(x: 0, y: 0, width: 10, height: 10))),
                       "with no lane the write's own answer is the answer")
        XCTAssertFalse(lot.isParked(9))
    }

    func testParksAndUnparksKeepTheirOrderOnOneLane() {
        let mover = Mover()
        let lane = DispatchQueue(label: "test.moves")
        let lot = ParkingLot(mover: mover, bounds: { [self.main] }, moveQueue: lane)
        let w = window(3, frame: CGRect(x: 50, y: 50, width: 300, height: 200))
        XCTAssertTrue(lot.park(w))
        XCTAssertTrue(lot.unpark(w))
        XCTAssertFalse(lot.isParked(3), "unparked on the books the moment it was asked")
        lot.waitForWrites()
        XCTAssertEqual(mover.positions.count, 1)
        XCTAssertEqual(mover.frames.count, 1, "the restore landed after the park, on the same lane")
        XCTAssertEqual(mover.frames.first?.frame, CGRect(x: 50, y: 50, width: 300, height: 200))
    }

    func testTheLayoutRunsLaneWorkInOrder() {
        let lane = DispatchQueue(label: "test.moves")
        let layout = LayoutController(model: WindowModel(), parking: ParkingLot(moveQueue: lane),
                                      moveQueue: lane)
        var order: [Int] = []
        let lock = NSLock()
        for step in 1...3 {
            layout.onMoveLane { lock.lock(); order.append(step); lock.unlock() }
        }
        lane.sync {}
        XCTAssertEqual(order, [1, 2, 3])
        let inline = LayoutController(model: WindowModel(), parking: ParkingLot())
        var ran = false
        inline.onMoveLane { ran = true }
        XCTAssertTrue(ran, "no lane: the work runs where it was asked")
    }
}
