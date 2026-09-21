import XCTest
@testable import LodestarCore

/// The instrument writing itself down: an era survives the ring as JSON,
/// its fingerprint changes with the build, the formats, the settings,
/// the screens and the layout, and not with the devices that come and
/// go on a radio.
final class EraTests: XCTestCase {
    private func era() -> EraInfo {
        EraInfo(appVersion: "0.35.0", keySchema: 2, pointerSchema: 1, layout: "com.apple.keylayout.US",
                keyboards: ["kb"], pointers: ["pad"],
                displays: [DisplayInfo(width: 1728, height: 1117, scale: 2, mmWidth: 344, mmHeight: 222, main: true)],
                settings: InputSettings(keyRepeat: 2, initialKeyRepeat: 15, mouseScaling: 1.5,
                                        trackpadScaling: 1, naturalScroll: true, tapToClick: true, forceClick: true),
                lid: false)
    }

    func testAnEraSurvivesTheRingAsJSON() throws {
        var event = ObservationEvent(t: Date(timeIntervalSince1970: 1_700_000_000), kind: .era)
        event.era = era()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let back = try decoder.decode(ObservationEvent.self, from: encoder.encode(event))
        XCTAssertEqual(back.kind, .era)
        XCTAssertEqual(back.era, era())
        XCTAssertEqual(back.era?.displays.first?.mmWidth, 344)
        XCTAssertEqual(back.era?.settings.tapToClick, true)
    }

    func testTheFingerprintFollowsTheInstrumentNotTheDevices() {
        let base = era()
        var devices = base
        devices.keyboards = ["kb", "another"]
        devices.pointers = []
        devices.lid = true
        XCTAssertEqual(devices.fingerprint, base.fingerprint, "a radio dropping is not an era")
        var build = base
        build.appVersion = "0.36.0"
        XCTAssertNotEqual(build.fingerprint, base.fingerprint)
        var schema = base
        schema.keySchema = 3
        XCTAssertNotEqual(schema.fingerprint, base.fingerprint)
        var settings = base
        settings.settings.mouseScaling = 2
        XCTAssertNotEqual(settings.fingerprint, base.fingerprint)
        var screens = base
        screens.displays[0].scale = 1
        XCTAssertNotEqual(screens.fingerprint, base.fingerprint)
        var layout = base
        layout.layout = "com.apple.keylayout.Dvorak"
        XCTAssertNotEqual(layout.fingerprint, base.fingerprint)
        // A declared key placement changes what the finger column means;
        // nothing declared is the era the record already had.
        var fingers = base
        fingers.fingerMap = "kb=enter:right thumb"
        XCTAssertNotEqual(fingers.fingerprint, base.fingerprint)
        var none = base
        none.fingerMap = ""
        XCTAssertEqual(none.fingerprint, base.fingerprint)
        var before = base
        before.fingerMap = nil
        XCTAssertEqual(before.fingerprint, base.fingerprint, "an era written before the map existed")
    }

    func testTheHealthKindsAreThePulseTheWindowAndTheEra() {
        XCTAssertEqual(ObservationEvent.healthKinds, [.pulse, .window, .era])
    }
}
