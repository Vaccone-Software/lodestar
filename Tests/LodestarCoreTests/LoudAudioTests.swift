import XCTest
@testable import LodestarCore

final class LoudAudioTests: XCTestCase {
    /// A curve linear in dB from `bottom` to `top`, the way macOS maps both a
    /// Bluetooth headset (−40…0) and the built-in speakers (−63.5…0).
    private func linear(_ bottom: Float, _ top: Float) -> (Float) -> Float? {
        { bottom + (top - bottom) * $0 }
    }

    /// The loudest music on headphones that reach 110 dBA lands at the ear
    /// at 85, 80 or 75: each level 5 dB from the next, and off holds nothing.
    func testEachLevelKeepsTheLoudestMusicOnHundredTenHeadphonesAtItsOwnLimit() {
        XCTAssertEqual(LoudAudio.Level.allCases, [.off, .light, .standard, .strong], "the menu's order")
        XCTAssertNil(LoudAudio.Level.off.ceilingDecibels(fullScaleDBA: 110))
        XCTAssertEqual(LoudAudio.Level.light.ceilingDecibels(fullScaleDBA: 110) ?? 0, -17, accuracy: 0.001)
        XCTAssertEqual(LoudAudio.Level.standard.ceilingDecibels(fullScaleDBA: 110) ?? 0, -22, accuracy: 0.001)
        XCTAssertEqual(LoudAudio.Level.strong.ceilingDecibels(fullScaleDBA: 110) ?? 0, -27, accuracy: 0.001)
        XCTAssertEqual(LoudAudio.Level.standard.limitDBA, 80, "the adult level, 40 hours a week")
        XCTAssertEqual(LoudAudio.Level.strong.limitDBA, 75, "the level for children")
    }

    /// Wired headphones are driven by the Mac, which gets them about 10 dB
    /// louder than Bluetooth ones drive themselves: 1.25 V into earbuds at
    /// 100 to 120 dB a volt. Their ceiling is 10 dB lower for the same ear.
    func testWiredHeadphonesAreHeldTenDecibelsLowerThanBluetooth() {
        XCTAssertEqual(LoudAudio.fullScaleDBA(transport: 0x626C_7565), 110, "Bluetooth")
        XCTAssertEqual(LoudAudio.fullScaleDBA(transport: 0x626C_6561), 110, "Bluetooth LE")
        XCTAssertEqual(LoudAudio.fullScaleDBA(transport: 0x626C_746E), 120, "the built-in jack: bltn")
        XCTAssertEqual(LoudAudio.fullScaleDBA(transport: 0x7573_6220), 120, "USB")
        XCTAssertEqual(LoudAudio.fullScaleDBA(transport: nil), 120, "unknown is taken as the louder")
        let wired = LoudAudio.fullScaleDBA(transport: 0x626C_746E)
        XCTAssertEqual(LoudAudio.Level.strong.ceilingDecibels(fullScaleDBA: wired) ?? 0, -37, accuracy: 0.001)
        XCTAssertEqual(LoudAudio.Level.standard.ceilingDecibels(fullScaleDBA: wired) ?? 0, -32, accuracy: 0.001)
        XCTAssertEqual(LoudAudio.Level.light.ceilingDecibels(fullScaleDBA: wired) ?? 0, -27, accuracy: 0.001)
    }

    func testTheNoteSaysWhyAndWhereItIsSet() {
        XCTAssertEqual(LoudAudio.noticeSentence, "Your volume is held to protect your hearing")
        XCTAssertEqual(LoudAudio.noticeDetail(.strong), "Reduce loud audio is set to Strong in Settings")
        XCTAssertEqual(LoudAudio.Level.allCases.map(\.name), ["Off", "Light", "Standard", "Strong"])
    }

    func testABluetoothHeadsetIsHeldWhereEachLevelSays() throws {
        let headset = linear(-40, 0)
        XCTAssertEqual(try XCTUnwrap(LoudAudio.ceilingScalar(-17, decibels: headset)), 23.0 / 40, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(LoudAudio.ceilingScalar(-22, decibels: headset)), 18.0 / 40, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(LoudAudio.ceilingScalar(-27, decibels: headset)), 13.0 / 40, accuracy: 0.0001)
    }

    func testEachDeviceIsHeldThroughItsOwnCurve() throws {
        let ceiling = try XCTUnwrap(LoudAudio.ceilingScalar(-22, decibels: linear(-63.5, 0)))
        XCTAssertEqual(ceiling, 41.5 / 63.5, accuracy: 0.0001)
    }

    func testADeviceThatNeverReachesTheCeilingIsNotHeldBelowFull() {
        XCTAssertEqual(LoudAudio.ceilingScalar(-22, decibels: linear(-80, -30)), 1)
    }

    /// Holding such a device at silence is what locked the volume at 0 on
    /// 2026-11-19: no real headphone control stops short of the ceiling, so
    /// a curve that does is not believed, and nothing is held.
    func testADeviceWhoseQuietestIsOverTheCeilingIsNotHeld() {
        XCTAssertNil(LoudAudio.ceilingScalar(-22, decibels: linear(-20, 0)))
    }

    /// What AirPods answered in the instant they connected or changed mode
    /// (the log's "ceiling=0.000 volume-db=0.0", 2026-11-19): 0 dB at every
    /// volume. It placed a ceiling of 0 that held the volume at silence.
    func testAFlatCurveFromAHeadsetMidChangeHoldsNothing() {
        XCTAssertNil(LoudAudio.ceilingScalar(-27, decibels: { _ in 0 }))
        XCTAssertNil(LoudAudio.plausibleCurve { _ in 0 })
    }

    func testACurveThatFallsAsTheVolumeRisesHoldsNothing() {
        XCTAssertNil(LoudAudio.ceilingScalar(-27, decibels: linear(0, -40)), "upside down")
        XCTAssertNil(LoudAudio.ceilingScalar(-27, decibels: { $0 == 0.5 ? -60 : -40 + 40 * $0 }), "a dip")
        XCTAssertNil(LoudAudio.ceilingScalar(-27, decibels: { $0 == 0.5 ? .nan : -40 + 40 * $0 }), "a hole")
    }

    func testACurveTooShortToBeAVolumeControlHoldsNothing() {
        XCTAssertNil(LoudAudio.ceilingScalar(-10, decibels: linear(-12, 0)))
        XCTAssertNotNil(LoudAudio.ceilingScalar(-10, decibels: linear(-32, 0)), "a headset in a call")
    }

    /// AirPods Pro report −100…0, and some outputs reach silence at −∞.
    func testEveryCurveMeasuredPlacesACeiling() throws {
        XCTAssertEqual(try XCTUnwrap(LoudAudio.ceilingScalar(-27, decibels: linear(-100, 0))), 0.73, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(LoudAudio.ceilingScalar(-27, decibels: linear(-40, 0))), 13.0 / 40, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(LoudAudio.ceilingScalar(-27, decibels: linear(-32, 0))), 5.0 / 32, accuracy: 0.0001)
        let silentAtZero: (Float) -> Float? = { $0 == 0 ? -.infinity : -40 + 40 * $0 }
        XCTAssertEqual(try XCTUnwrap(LoudAudio.ceilingScalar(-27, decibels: silentAtZero)), 13.0 / 40, accuracy: 0.0001)
    }

    func testADeviceWithNoCurveIsNotHeld() {
        XCTAssertNil(LoudAudio.ceilingScalar(-22, decibels: { _ in nil }))
    }

    func testOnlyWhatSaysHeadphonesIsLimited() {
        XCTAssertTrue(LoudAudio.isHeadphones(terminal: 0x6864_7068, dataSource: nil), "Bluetooth headphones: hdph")
        XCTAssertTrue(LoudAudio.isHeadphones(terminal: 0x301, dataSource: 0x6864_706E), "headphones in the jack: hdpn")
        XCTAssertFalse(LoudAudio.isHeadphones(terminal: 0x301, dataSource: 0x6973_706B), "the built-in speakers: ispk")
        XCTAssertFalse(LoudAudio.isHeadphones(terminal: 0x7370_6B72, dataSource: nil), "a speaker: spkr")
        XCTAssertFalse(LoudAudio.isHeadphones(terminal: 0, dataSource: nil), "a display, unknown")
        XCTAssertFalse(LoudAudio.isHeadphones(terminal: nil, dataSource: nil), "nothing known")
    }

    func testVolumeUpStopsAtTheLastStepUnderTheCeiling() {
        let ceiling: Float = 13.0 / 40
        let step = LoudAudio.keyStep(fine: false)
        XCTAssertFalse(LoudAudio.swallowsVolumeUp(at: 0.25, step: step, ceiling: ceiling), "0.3125 is under")
        XCTAssertTrue(LoudAudio.swallowsVolumeUp(at: 0.3125, step: step, ceiling: ceiling), "0.375 would cross")
        XCTAssertTrue(LoudAudio.swallowsVolumeUp(at: ceiling, step: step, ceiling: ceiling), "at the ceiling")
        XCTAssertTrue(LoudAudio.swallowsVolumeUp(at: 0.9, step: step, ceiling: ceiling), "over it, before the backstop")
    }

    func testAFineStepGoesCloserToTheCeiling() {
        let ceiling: Float = 13.0 / 40
        let fine = LoudAudio.keyStep(fine: true)
        XCTAssertEqual(fine, 1.0 / 64)
        XCTAssertFalse(LoudAudio.swallowsVolumeUp(at: 0.296875, step: fine, ceiling: ceiling), "to 0.3125")
        XCTAssertTrue(LoudAudio.swallowsVolumeUp(at: 0.3125, step: fine, ceiling: ceiling), "0.328 would cross")
    }

    func testAVolumeTheDeviceRoundedIsNotARaise() {
        let ceiling: Float = 13.0 / 40
        XCTAssertFalse(LoudAudio.isOver(ceiling + 0.0003, ceiling: ceiling))
        XCTAssertTrue(LoudAudio.isOver(ceiling + 1.0 / 64, ceiling: ceiling))
    }

    /// Every Bluetooth headset is held at the same place on the slider,
    /// whatever curve it reports: AirPods Pro (−100…0) and a Bose headset
    /// (−40…0) both at 0.325 on Strong, in a call as out of one.
    func testEveryBluetoothHeadsetIsHeldAtTheSamePlaceOnTheSlider() throws {
        XCTAssertTrue(LoudAudio.isBluetooth(transport: 0x626C_7565))
        XCTAssertTrue(LoudAudio.isBluetooth(transport: 0x626C_6561))
        XCTAssertFalse(LoudAudio.isBluetooth(transport: 0x626C_746E), "the built-in jack")
        XCTAssertFalse(LoudAudio.isBluetooth(transport: nil))
        let expected: [LoudAudio.Level: Float] = [.light: 23.0 / 40, .standard: 18.0 / 40, .strong: 13.0 / 40]
        for (level, scalar) in expected {
            let ceiling = try XCTUnwrap(level.ceilingDecibels(fullScaleDBA: LoudAudio.bluetoothFullScaleDBA))
            XCTAssertEqual(try XCTUnwrap(LoudAudio.ceilingScalar(ceiling, decibels: LoudAudio.bluetoothDecibels)),
                           scalar, accuracy: 0.0001, level.name)
        }
        XCTAssertEqual(LoudAudio.bluetoothDecibels(0), -40)
        XCTAssertEqual(LoudAudio.bluetoothDecibels(1), 0)
    }

    func testAPressIsToldFromItsRelease() {
        XCTAssertTrue(LoudAudio.isPress(data1: (0 << 16) | (0xA << 8)))
        XCTAssertTrue(LoudAudio.isPress(data1: (0 << 16) | (0xA << 8) | 1), "a repeat")
        XCTAssertFalse(LoudAudio.isPress(data1: (0 << 16) | (0xB << 8)))
    }

    func testOnlyTheVolumeUpKeyIsRead() {
        XCTAssertTrue(LoudAudio.isVolumeUp(subtype: 8, data1: (0 << 16) | (0xA << 8)), "pressed")
        XCTAssertTrue(LoudAudio.isVolumeUp(subtype: 8, data1: (0 << 16) | (0xB << 8)), "let go")
        XCTAssertFalse(LoudAudio.isVolumeUp(subtype: 8, data1: (1 << 16) | (0xA << 8)), "volume down")
        XCTAssertFalse(LoudAudio.isVolumeUp(subtype: 8, data1: (7 << 16) | (0xA << 8)), "mute")
        XCTAssertFalse(LoudAudio.isVolumeUp(subtype: 7, data1: 0), "another kind of system event")
    }

    /// A call plays speech, levelled by the call and well under the loudest
    /// music, so each level's ceiling sits 12 dB higher on one: Strong on a
    /// Bluetooth headset goes from a third of the slider to about five eighths.
    func testACallRaisesEachCeilingByTheGapBetweenMusicAndSpeech() {
        XCTAssertEqual(LoudAudio.callAllowance, 12, accuracy: 0.001)
        for level in LoudAudio.Level.allCases {
            guard let music = level.ceilingDecibels(fullScaleDBA: 110),
                  let call = level.ceilingDecibels(fullScaleDBA: 110, call: true) else {
                XCTAssertNil(level.ceilingDecibels(fullScaleDBA: 110, call: true), "off holds nothing, on a call too")
                continue
            }
            XCTAssertEqual(call - music, 12, accuracy: 0.001, level.name)
        }
        let strong = LoudAudio.Level.strong.ceilingDecibels(fullScaleDBA: 110, call: true) ?? 0
        let ceiling = LoudAudio.ceilingScalar(strong, decibels: LoudAudio.bluetoothDecibels) ?? 0
        XCTAssertEqual(ceiling, 0.625, accuracy: 0.001)
    }

    /// Calls are told by who holds the microphone: meeting and chat apps,
    /// browsers and the helpers they record from, and the system's calls.
    func testACallIsAMeetingChatOrBrowserAppHoldingTheMicrophone() {
        for id in ["us.zoom.xos", "us.zoom.caphost", "com.apple.FaceTime", "com.apple.avconferenced",
                   "com.brave.Browser.helper", "com.google.Chrome.helper", "com.apple.WebKit.GPU",
                   "com.tinyspeck.slackmacgap", "com.microsoft.teams2", "org.mozilla.firefox"] {
            XCTAssertTrue(LoudAudio.isCall(bundleID: id), id)
        }
    }

    /// Anything else with a microphone is not a call: Lodestar's dictation,
    /// Siri, and a notch app that holds the microphone all day.
    func testOtherAppsHoldingTheMicrophoneAreNotACall() {
        for id in ["com.vaccone.lodestar", "com.henrikruscon.Alcove", "com.apple.CoreSpeech", "com.apple.Siri",
                   "com.apple.VoiceMemos", "com.apple.Music", ""] {
            XCTAssertFalse(LoudAudio.isCall(bundleID: id), id)
        }
    }
}
