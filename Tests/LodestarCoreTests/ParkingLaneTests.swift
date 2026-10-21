import ApplicationServices
import XCTest
@testable import LodestarCore

/// Lets a main-queue poll stop after the expectation has been waited on,
/// so a late turn does not fulfill twice.
private final class ParkingLaneStop {
    var flag = false
}

/// Parks and unparks on the move lane: the accessibility write leaves
/// the gesture, the bookkeeping does not, and a refusal that comes back
/// later undoes exactly the bookkeeping it belongs to.
final class ParkingLaneTests: XCTestCase {
    private final class Mover: WindowMoving {
        var positions: [(id: CGWindowID, point: CGPoint)] = []
        var frames: [(id: CGWindowID, frame: CGRect)] = []
        var refuse = false
        var refuseFrames = false
        let lock = NSLock()

        func setFrame(_ window: WindowModel.Window, _ frame: CGRect) -> Bool {
            lock.lock(); defer { lock.unlock() }
            frames.append((window.id, frame))
            return !refuse && !refuseFrames
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

    /// Queued `unpark` answers yes when the write is accepted. The refusal
    /// comes back later, and the frame has to be on the books again by the
    /// time a caller waiting on the lane looks — a quit that saved first
    /// would exit with the window a sliver and the record gone.
    func testARefusedUnparkOnTheLanePutsTheFrameBackBeforeWaitReturns() {
        let mover = Mover()
        let lane = DispatchQueue(label: "test.moves")
        let lot = ParkingLot(mover: mover, bounds: { [self.main] }, moveQueue: lane)
        let frame = CGRect(x: 80, y: 80, width: 640, height: 480)
        XCTAssertTrue(lot.park(window(7, frame: frame)))
        lot.waitForWrites()

        mover.refuseFrames = true
        var revised: CGRect?
        lot.onRevision = { revised = lot.snapshot()[7] }
        XCTAssertTrue(lot.unpark(window(7, frame: frame)), "queued is accepted, not finished")
        XCTAssertFalse(lot.isParked(7), "the intent leaves the books at once")
        lot.waitForWrites()
        XCTAssertTrue(lot.isParked(7), "the refusal puts the frame back before a waiter proceeds")
        XCTAssertEqual(lot.snapshot()[7], frame)
        XCTAssertEqual(revised, frame, "a save of the optimistic unpark can be rewritten")
    }

    func testARefusedUnparkOnTheLaneReachesTheMainThread() {
        let mover = Mover()
        mover.refuseFrames = true
        let lane = DispatchQueue(label: "test.moves")
        let lot = ParkingLot(mover: mover, bounds: { [self.main] }, moveQueue: lane)
        let frame = CGRect(x: 12, y: 12, width: 300, height: 200)
        XCTAssertTrue(lot.park(window(7, frame: frame)))
        lot.waitForWrites()
        XCTAssertTrue(lot.unpark(window(7, frame: frame)))

        let restored = expectation(description: "the refusal puts the frame back")
        restored.assertForOverFulfill = false
        let stop = ParkingLaneStop()
        func look() {
            if stop.flag { return }
            if lot.isParked(7), lot.snapshot()[7] == frame {
                stop.flag = true
                restored.fulfill()
            } else {
                DispatchQueue.main.async(execute: look)
            }
        }
        DispatchQueue.main.async(execute: look)
        wait(for: [restored], timeout: 2)
        stop.flag = true
    }

    /// A summon claims the window while the refused unpark is still on the
    /// lane. The claim owns the id now; the refusal must not write the old
    /// frame back over it.
    func testAClaimBeatsALaterUnparkRefusal() {
        let mover = Mover()
        let lane = DispatchQueue(label: "test.moves")
        let lot = ParkingLot(mover: mover, bounds: { [self.main] }, moveQueue: lane)
        let frame = CGRect(x: 1, y: 1, width: 200, height: 200)
        XCTAssertTrue(lot.park(window(7, frame: frame)))
        lot.waitForWrites()
        mover.refuseFrames = true
        XCTAssertTrue(lot.unpark(window(7, frame: frame)))
        lot.claim(7)
        lot.waitForWrites()
        XCTAssertFalse(lot.isParked(7))
    }
}
