import CoreGraphics
import StoicJSON
import XCTest
@testable import LodestarCore

/// app.mouse-scrolling: which scrolls are the mouse's, when they are turned
/// over, and that turning one over reaches every field an app reads.
final class MouseScrollTests: XCTestCase {
    private let own: Int64 = 4242

    /// A wheel never phases its scrolls and a touch surface always does;
    /// another app's scroll is a mouse utility's; Lodestar's own is never
    /// the mouse's.
    func testWhichScrollsAreTheMouses() {
        XCTAssertTrue(MouseScroll.isMouse(scrollPhase: 0, momentumPhase: 0, postingPID: 0, ownPID: own), "a wheel")
        XCTAssertFalse(MouseScroll.isMouse(scrollPhase: 2, momentumPhase: 0, postingPID: 0, ownPID: own), "fingers on a trackpad")
        XCTAssertFalse(MouseScroll.isMouse(scrollPhase: 0, momentumPhase: 1, postingPID: 0, ownPID: own), "a trackpad's glide")
        XCTAssertTrue(MouseScroll.isMouse(scrollPhase: 0, momentumPhase: 0, postingPID: 911, ownPID: own),
                      "Logi Options+ posting the wheel's smooth scroll")
        XCTAssertTrue(MouseScroll.isMouse(scrollPhase: 2, momentumPhase: 0, postingPID: 911, ownPID: own),
                      "another app's scroll is the mouse's whatever its phase")
        XCTAssertFalse(MouseScroll.isMouse(scrollPhase: 0, momentumPhase: 0, postingPID: own, ownPID: own),
                       "scroll mode's own scroll already goes the way its key names")
    }

    /// The setting names the result: System never turns anything, and the
    /// other two turn the wheel only when the Mac's direction is the other.
    func testTheSettingNamesTheResultWhicheverWayTheMacPoints() {
        for natural in [true, false] {
            XCTAssertFalse(MouseScroll.reverses(.system, systemNatural: natural))
        }
        XCTAssertFalse(MouseScroll.reverses(.natural, systemNatural: true))
        XCTAssertTrue(MouseScroll.reverses(.natural, systemNatural: false))
        XCTAssertTrue(MouseScroll.reverses(.standard, systemNatural: true))
        XCTAssertFalse(MouseScroll.reverses(.standard, systemNatural: false))
    }

    /// Turning a scroll over negates the line, point and fixed-point deltas
    /// together, keeps a smooth scroll's fraction, and leaves the
    /// sideways axis alone.
    func testTurningAScrollOverReachesEveryVerticalField() throws {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                          wheelCount: 2, wheel1: 3, wheel2: 5, wheel3: 0))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 2.75)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 22)
        let line = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let sideways = (event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
                        event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2),
                        event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))

        MouseScroll.reverseVertical(event)

        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), -line)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -22)
        XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), -2.75, accuracy: 0.001)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis2), sideways.0)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), sideways.1)
        XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2), sideways.2, accuracy: 0.001)
    }

    /// One event's decision reads its own fields.
    func testAnEventsDecisionReadsItsOwnFields() throws {
        let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                          wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0))
        wheel.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        XCTAssertTrue(MouseScroll.reverses(wheel, want: .standard, systemNatural: true, ownPID: own))
        XCTAssertFalse(MouseScroll.reverses(wheel, want: .system, systemNatural: true, ownPID: own))

        wheel.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
        XCTAssertFalse(MouseScroll.reverses(wheel, want: .standard, systemNatural: true, ownPID: own),
                       "a phased scroll is the trackpad's")
    }

    func testTheConfigReadsTheSetting() throws {
        var problems: [String] = []
        let standard = Config.build(from: try Json.parse(#"{"app": {"mouse-scrolling": "standard"}}"#), problems: &problems)
        XCTAssertEqual(standard.mouseScrolling, .standard)
        XCTAssertEqual(problems, [])
        XCTAssertEqual(Config().mouseScrolling, .system, "nothing is turned until it is asked for")

        let wrong = Config.build(from: try Json.parse(#"{"app": {"mouse-scrolling": "reversed"}}"#), problems: &problems)
        XCTAssertEqual(wrong.mouseScrolling, .system)
        XCTAssertTrue(problems.contains { $0.contains("mouse-scrolling") }, "\(problems)")
    }

    /// The row names what System leaves in place, and says when Scroll
    /// Reverser would turn the wheel a second time.
    func testTheSettingsRow() throws {
        func row(_ config: Config = Config(), _ machine: SettingsModel.MachineState = .init()) throws -> SettingsModel.Row {
            try XCTUnwrap(SettingsModel.catalog(config: config, machine: machine)
                .first { $0.name == "General" }?.rows.first { $0.path == "app.mouse-scrolling" })
        }
        let plain = try row()
        XCTAssertEqual(plain.group, "Mouse")
        XCTAssertTrue(plain.isDefault)
        guard case .choice(let options, let labels, let current) = plain.control else { return XCTFail("a choice") }
        XCTAssertEqual(options, ["system", "natural", "standard"])
        XCTAssertEqual(labels, ["System", "Natural", "Standard"])
        XCTAssertEqual(current, "system")

        var machine = SettingsModel.MachineState()
        machine.naturalScrolling = true
        guard case .choice(_, let named, _) = try row(Config(), machine).control else { return XCTFail("a choice") }
        XCTAssertEqual(named.first, "System · Natural")

        machine.scrollReverserRunning = true
        XCTAssertFalse(try row(Config(), machine).detail?.contains("Scroll Reverser") ?? false,
                       "while System is chosen nothing is turned twice")
        var config = Config()
        config.mouseScrolling = .standard
        let twice = try row(config, machine)
        XCTAssertTrue(twice.detail?.contains("Scroll Reverser is running too") ?? false)
        XCTAssertFalse(twice.isDefault)
    }
}
