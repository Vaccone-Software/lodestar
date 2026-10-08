import XCTest
@testable import lodestar
@testable import LodestarCore

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

/// Exact attribution (`health.exact-keyboards`): a press matched to one
/// physical keyboard's own report is charged to it; anything less falls
/// back to the roster's attribution, unchanged, and that writes zero when
/// it cannot tell either. Never a guess.
final class ExactKeyboardAttributionTests: XCTestCase {
    private let builtIn = DeviceRoster.Device(
        id: "1452:834:aa", name: "Apple Internal Keyboard / Trackpad", transport: "SPI",
        builtIn: true, keyboardType: 91)
    private let kinesis = DeviceRoster.Device(
        id: "7504:24926:bb", name: "Adv360 Pro", transport: "Bluetooth Low Energy",
        builtIn: false, keyboardType: 40)
    private let keychron = DeviceRoster.Device(
        id: "13364:2064:cc", name: "Keychron Q1 Max", transport: "Bluetooth Low Energy",
        builtIn: false, keyboardType: 40)

    private var three: [DeviceRoster.Device] { [builtIn, kinesis, keychron] }

    /// Two Bluetooth boards share a type: the roster writes zero, the
    /// report names the board.
    func testAnExactMatchDecidesWhatTheRosterCouldNot() {
        XCTAssertEqual(DeviceRoster.charge(three, exact: nil, lidClosed: true, keyboardType: 40), 0)
        XCTAssertEqual(DeviceRoster.charge(three, exact: .device(keychron.id), lidClosed: true, keyboardType: 40), 3)
        XCTAssertEqual(DeviceRoster.charge(three, exact: .device(kinesis.id), lidClosed: true, keyboardType: 40), 2)
    }

    func testAnythingLessThanOnePhysicalKeyboardFallsBack() {
        for outcome in [KeyReportMatcher.Match.missing, .ambiguous, .virtual, .unmapped] {
            XCTAssertEqual(DeviceRoster.charge(three, exact: outcome, lidClosed: true, keyboardType: 40), 0, "\(outcome)")
            XCTAssertEqual(DeviceRoster.charge(three, exact: outcome, lidClosed: false, keyboardType: 91), 1, "\(outcome)")
        }
    }

    /// A matched keyboard the roster's list does not show cannot be an
    /// index into it.
    func testAMatchedKeyboardOffTheListFallsBack() {
        XCTAssertEqual(DeviceRoster.charge([builtIn], exact: .device(kinesis.id), lidClosed: false, keyboardType: 40), 0)
    }

    /// Without the setting the press carries no match and nothing changes.
    func testWithoutAMatchItIsExactlyTheRostersAttribution() {
        for (lid, type) in [(true, 40), (false, 91), (false, 40), (nil, 0)] as [(Bool?, Int)] {
            XCTAssertEqual(DeviceRoster.charge(three, exact: nil, lidClosed: lid, keyboardType: type),
                           DeviceRoster.attribute(three, lidClosed: lid, keyboardType: type))
        }
    }

    /// A remapper's keyboard is not a board a hand types on.
    func testARemappersKeyboardIsVirtual() {
        XCTAssertTrue(DeviceRoster.isVirtual(transport: "Virtual", product: "Karabiner DriverKit VirtualHIDKeyboard 1.8.0", flagged: false))
        XCTAssertTrue(DeviceRoster.isVirtual(transport: nil, product: "Karabiner-VirtualHIDKeyboard", flagged: false))
        XCTAssertTrue(DeviceRoster.isVirtual(transport: "USB", product: "Board", flagged: true))
        XCTAssertFalse(DeviceRoster.isVirtual(transport: "Bluetooth Low Energy", product: "Adv360 Pro", flagged: false))
        XCTAssertFalse(DeviceRoster.isVirtual(transport: "SPI", product: "Apple Internal Keyboard / Trackpad", flagged: false))
    }

    /// The era says whether the column was written by exact matches: it is
    /// part of the fingerprint when on, and an era from before reads as off.
    func testTheEraSaysWhetherExactAttributionWasActive() {
        let off = EraInfo(appVersion: "0.46.0", keySchema: 3, pointerSchema: 2)
        var on = off
        on.exactKeyboards = true
        XCTAssertNotEqual(on.fingerprint, off.fingerprint)
        var explicitOff = off
        explicitOff.exactKeyboards = false
        XCTAssertEqual(explicitOff.fingerprint, off.fingerprint)
    }

    /// The live monitor: with exact attribution off (the default), or on
    /// without Input Monitoring, nothing is opened.
    func testOffOrWithoutThePermissionNothingListens() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("exact-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let health = HealthMonitor(directory: directory)
        health.listensToTheMouse = false
        var asked = 0
        health.canListen = { false }
        health.requestListening = { asked += 1 }
        health.setEnabled(true)
        XCTAssertFalse(health.exactActive)
        health.setExactKeyboards(true)
        XCTAssertFalse(health.exactActive, "no permission, no listener")
        XCTAssertEqual(asked, 1, "macOS is asked once, when it is turned on")
        health.setExactKeyboards(true)
        XCTAssertEqual(asked, 1)
        health.setExactKeyboards(false)
        XCTAssertFalse(health.exactActive)
        health.setEnabled(false)
    }
}
