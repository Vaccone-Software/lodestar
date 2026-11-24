import XCTest
@testable import LodestarCore

/// The edge the shell arms a key on: a single tap, and only a single
/// tap. Everything the detector already refuses as a double — a hold, a
/// key inside the press — is refused as an arm for the same reason.
final class LodeArmTests: XCTestCase {
    func testASingleTapIsTheEdgeAndOnlyOnTheCallThatCompletesIt() {
        var detector = LodeTapDetector()
        XCTAssertFalse(detector.lodeChanged(held: true, at: 0))
        XCTAssertFalse(detector.justTapped, "not on the way down")
        XCTAssertFalse(detector.lodeChanged(held: false, at: 0.1))
        XCTAssertTrue(detector.justTapped, "on the way up, shorter than a peek")
        XCTAssertFalse(detector.lodeChanged(held: true, at: 2.0))
        XCTAssertFalse(detector.justTapped, "the next press clears it")
    }

    func testAHoldIsNotATap() {
        var detector = LodeTapDetector()
        _ = detector.lodeChanged(held: true, at: 0)
        _ = detector.lodeChanged(held: false, at: LodeTapDetector.maxHold + 0.05)
        XCTAssertFalse(detector.justTapped)
    }

    func testAKeyInsideThePressPoisonsTheTap() {
        var detector = LodeTapDetector()
        _ = detector.lodeChanged(held: true, at: 0)
        detector.keyDown()
        _ = detector.lodeChanged(held: false, at: 0.1)
        XCTAssertFalse(detector.justTapped, "lode s is a gesture, not a tap")
    }

    func testTheSecondTapOfADoubleIsAssentNotAnArm() {
        var detector = LodeTapDetector()
        _ = detector.lodeChanged(held: true, at: 0)
        _ = detector.lodeChanged(held: false, at: 0.1)
        XCTAssertTrue(detector.justTapped)
        _ = detector.lodeChanged(held: true, at: 0.3)
        XCTAssertTrue(detector.lodeChanged(held: false, at: 0.4), "the double")
        XCTAssertFalse(detector.justTapped)
    }

    func testAKeyDownClearsAStandingTap() {
        var detector = LodeTapDetector()
        _ = detector.lodeChanged(held: true, at: 0)
        _ = detector.lodeChanged(held: false, at: 0.1)
        XCTAssertTrue(detector.justTapped)
        detector.keyDown()
        XCTAssertFalse(detector.justTapped)
    }
}
