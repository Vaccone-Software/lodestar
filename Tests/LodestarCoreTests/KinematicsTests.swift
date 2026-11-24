import CoreGraphics
import XCTest
@testable import LodestarCore

/// A reach's profile from its deltas: a clean reach has one submovement
/// and its peak early; a reach with a 5 Hz shake in it puts its power in
/// the middle band; a short reach has no bands to give.
final class KinematicsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// A bell-shaped speed profile, sampled at `hz`, lasting `seconds`,
    /// with an optional sinusoidal shake at `shakeHz` on top.
    private func reach(seconds: Double, hz: Double = 125, shakeHz: Double? = nil,
                       shake: Double = 0.4) -> ReachMotion {
        var motion = ReachMotion()
        let n = Int(seconds * hz)
        for i in 0..<n {
            let t = Double(i) / hz
            let phase = t / seconds
            var speed = 40 * sin(Double.pi * phase) * sin(Double.pi * phase)
            if let shakeHz { speed *= 1 + shake * sin(2 * Double.pi * shakeHz * t) }
            motion.add(dx: speed / hz, dy: 0, at: start.addingTimeInterval(t))
        }
        return motion
    }

    func testACleanReachHasOneSubmovementAndAnEarlyPeak() {
        let k = reach(seconds: 0.6).kinematics(end: start.addingTimeInterval(0.6))!
        XCTAssertEqual(k.submovements, 1)
        XCTAssertEqual(k.timeToPeak, 0.5, accuracy: 0.1)
        XCTAssertEqual(k.rate, 125, accuracy: 5)
        XCTAssertGreaterThan(k.path, 0)
        XCTAssertTrue(k.bands.isEmpty, "a reach under a second resolves no band")
    }

    func testAShakeAtFiveHertzLandsInTheMiddleBand() {
        let shaken = reach(seconds: 2.0, shakeHz: 5, shake: 0.8).kinematics(end: start.addingTimeInterval(2))!
        XCTAssertEqual(shaken.bands.count, 3)
        XCTAssertGreaterThan(shaken.bands[1], shaken.bands[0])
        XCTAssertGreaterThan(shaken.bands[1], shaken.bands[2])
        let steady = reach(seconds: 2.0).kinematics(end: start.addingTimeInterval(2))!
        XCTAssertGreaterThan(steady.bands[0], steady.bands[1], "a smooth reach keeps its power low")
        XCTAssertGreaterThan(shaken.submovements, 1)
    }

    func testTooFewReportsIsNoProfile() {
        var motion = ReachMotion()
        motion.add(dx: 1, dy: 1, at: start)
        motion.add(dx: 1, dy: 1, at: start.addingTimeInterval(0.01))
        XCTAssertNil(motion.kinematics(end: start.addingTimeInterval(0.02)))
    }

    func testTheTrackerFoldsTheProfileIntoTheClick() {
        var tracker = PointerTracker()
        var point = CGPoint(x: 100, y: 100)
        for i in 0..<60 {
            let t = start.addingTimeInterval(Double(i) * 0.008)
            point.x += 3
            tracker.moved(to: point, dx: 3, dy: 0, at: t)
        }
        let click = tracker.down(at: point, at: start.addingTimeInterval(0.5))
        XCTAssertFalse(click.stationary)
        let kin = click.kin!
        XCTAssertEqual(kin.samples, 60)
        XCTAssertEqual(kin.path, 180, accuracy: 1e-9)
        var moments = PointerMoments()
        moments.add(click)
        XCTAssertEqual(moments.kin?.n, 1)
        var other = PointerMoments()
        other.add(click)
        moments.merge(other)
        XCTAssertEqual(moments.kin?.n, 2)
        XCTAssertEqual(moments.kin?.submovementsMean, 1)
    }

    func testMotionUnderAHeldButtonIsADragNotAReach() {
        var tracker = PointerTracker()
        tracker.moved(to: CGPoint(x: 0, y: 0), dx: 1, dy: 0, at: start)
        _ = tracker.down(at: CGPoint(x: 0, y: 0), at: start.addingTimeInterval(0.1))
        for i in 1...10 {
            tracker.moved(to: CGPoint(x: CGFloat(i * 5), y: 0), dx: 5, dy: 0,
                          at: start.addingTimeInterval(0.1 + Double(i) * 0.01))
        }
        let release = tracker.up(at: CGPoint(x: 50, y: 0), at: start.addingTimeInterval(0.3))!
        XCTAssertNotNil(release.drag)
    }
}
