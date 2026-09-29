import CoreGraphics
import XCTest
@testable import lodestar
@testable import LodestarCore

/// A pointer act is charged to the kind of device the event names, and to
/// the one device of that kind on the list.
final class PointerAttributionTests: XCTestCase {
    private let trackpad = DeviceRoster.Device(id: "1452:834:aa", name: "Apple Internal Keyboard / Trackpad",
                                               transport: "SPI", builtIn: true)
    private let protoArc = DeviceRoster.Device(id: "9639:64160:bb", name: "ProtoArc EM11 NL",
                                               transport: "Bluetooth Low Energy", builtIn: false)
    private let logitech = DeviceRoster.Device(id: "1133:45105:cc", name: "MX Master 3S",
                                               transport: "Bluetooth Low Energy", builtIn: false)
    private let magic = DeviceRoster.Device(id: "76:613:dd", name: "Magic Trackpad",
                                            transport: "Bluetooth", builtIn: false)

    func testTheEventSaysWhichOfTwoAttachedDevicesMadeIt() {
        let both = [trackpad, protoArc]
        XCTAssertEqual(HealthMonitor.pointerDevice(touch: true, devices: both).kind, .trackpad)
        XCTAssertEqual(HealthMonitor.pointerDevice(touch: true, devices: both).index, 1)
        XCTAssertEqual(HealthMonitor.pointerDevice(touch: false, devices: both).kind, .mouse)
        XCTAssertEqual(HealthMonitor.pointerDevice(touch: false, devices: both).index, 2,
                       "a reach on the mouse is the mouse's, with the trackpad attached")
    }

    func testTwoOfOneKindNameTheKindAndNoDevice() {
        let result = HealthMonitor.pointerDevice(touch: false, devices: [trackpad, protoArc, logitech])
        XCTAssertEqual(result.kind, .mouse)
        XCTAssertEqual(result.index, 0)
        let pads = HealthMonitor.pointerDevice(touch: true, devices: [trackpad, magic])
        XCTAssertEqual(pads.kind, .trackpad)
        XCTAssertEqual(pads.index, 0)
    }

    func testTheSignalIsReadOffTheEvent() throws {
        let move = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                         mouseCursorPosition: .zero, mouseButton: .left))
        XCTAssertFalse(HealthMonitor.MouseReport(type: .mouseMoved, event: move).touch, "a mouse's move")
        move.setIntegerValueField(.mouseEventSubtype, value: 3)
        XCTAssertTrue(HealthMonitor.MouseReport(type: .mouseMoved, event: move).touch, "a touch surface's")

        let scroll = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                           wheel1: -3, wheel2: 0, wheel3: 0))
        scroll.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        XCTAssertFalse(HealthMonitor.MouseReport(type: .scrollWheel, event: scroll).touch,
                       "continuous without phases: the ProtoArc's")
        scroll.setIntegerValueField(.scrollWheelEventScrollPhase, value: 2)
        XCTAssertTrue(HealthMonitor.MouseReport(type: .scrollWheel, event: scroll).touch, "phased: the trackpad's")
    }
}
