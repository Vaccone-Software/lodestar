import XCTest
@testable import lodestar

/// A press is charged to the keyboard its own type names, and to
/// nobody when the list cannot show that keyboard.
final class KeyboardAttributionTests: XCTestCase {
    private let builtIn = DeviceRoster.Device(
        id: "1452:834:aa", name: "Apple Internal Keyboard / Trackpad", transport: "SPI",
        builtIn: true, keyboardType: 91)
    private let kinesis = DeviceRoster.Device(
        id: "7504:24926:bb", name: "Adv360 Pro", transport: "Bluetooth Low Energy",
        builtIn: false, keyboardType: 40)
    private let keychron = DeviceRoster.Device(
        id: "13364:2064:cc", name: "Keychron Q1 Max", transport: "Bluetooth Low Energy",
        builtIn: false, keyboardType: 40)

    private func charge(_ devices: [DeviceRoster.Device], lid: Bool?, type: Int) -> Int {
        DeviceRoster.attribute(devices, lidClosed: lid, keyboardType: type)
    }

    func testTheLidOpenNoLongerHidesWhichKeyboardTyped() {
        let both = [builtIn, kinesis]
        XCTAssertEqual(charge(both, lid: false, type: 91), 1)
        XCTAssertEqual(charge(both, lid: false, type: 40), 2)
    }

    func testAnExternalPressIsNeverChargedToTheOnlyListedBuiltIn() {
        // The board typed, the list never showed it: 492 windows of this.
        XCTAssertEqual(charge([builtIn], lid: false, type: 40), 0)
        XCTAssertEqual(charge([builtIn], lid: true, type: 40), 0)
        XCTAssertEqual(charge([builtIn], lid: false, type: 91), 1)
    }

    func testTwoBoardsOfOneTypeStayUndecided() {
        XCTAssertEqual(charge([builtIn, kinesis, keychron], lid: true, type: 40), 0)
        XCTAssertEqual(charge([builtIn, kinesis, keychron], lid: false, type: 91), 1)
    }

    func testWithoutATypeTheLidStillDecides() {
        var bare = builtIn
        bare.keyboardType = nil
        var external = kinesis
        external.keyboardType = nil
        XCTAssertEqual(charge([bare, external], lid: true, type: 40), 2)
        XCTAssertEqual(charge([bare, external], lid: false, type: 40), 0)
        XCTAssertEqual(charge([builtIn, kinesis], lid: true, type: 0), 2)
        XCTAssertEqual(charge([builtIn], lid: false, type: 0), 1)
    }
}

/// A device is on the list of what it primarily is, not of every
/// interface it carries (measured: the Adv360 is 1:6 with a 1:2 mouse
/// interface; the ProtoArc and the built-in trackpad are 1:2).
final class RosterMembershipTests: XCTestCase {
    private let desktop = kHIDPage_GenericDesktop
    private let pointers: Set<Int> = [kHIDUsage_GD_Keyboard, kHIDUsage_GD_Keypad]
    private let keyboards: Set<Int> = [kHIDUsage_GD_Mouse, kHIDUsage_GD_Pointer]

    func testAKeyboardWithMouseKeysIsNotAPointer() {
        XCTAssertFalse(DeviceRoster.kept(page: desktop, usage: kHIDUsage_GD_Keyboard, foreign: pointers))
        XCTAssertTrue(DeviceRoster.kept(page: desktop, usage: kHIDUsage_GD_Mouse, foreign: pointers))
    }

    func testAMouseWithKeyButtonsIsNotAKeyboard() {
        XCTAssertFalse(DeviceRoster.kept(page: desktop, usage: kHIDUsage_GD_Mouse, foreign: keyboards))
        XCTAssertTrue(DeviceRoster.kept(page: desktop, usage: kHIDUsage_GD_Keyboard, foreign: keyboards))
    }

    func testADeviceThatSaysNothingStays() {
        XCTAssertTrue(DeviceRoster.kept(page: nil, usage: nil, foreign: pointers))
        XCTAssertTrue(DeviceRoster.kept(page: kHIDPage_Consumer, usage: 1, foreign: keyboards))
    }
}
