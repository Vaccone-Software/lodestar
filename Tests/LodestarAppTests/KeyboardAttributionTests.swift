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
