import XCTest
@testable import LodestarCore

final class LoudAudioTests: XCTestCase {
    /// A curve linear in dB from `bottom` to `top`, the way macOS maps both a
    /// Bluetooth headset (−40…0) and the built-in speakers (−63.5…0).
    private func linear(_ bottom: Float, _ top: Float) -> (Float) -> Float? {
        { bottom + (top - bottom) * $0 }
    }

    func testTheCeilingIsSeventyFiveAtTheEarFromTheLoudestMusicOnHundredTenHeadphones() {
        XCTAssertEqual(LoudAudio.ceilingDecibels, -27, accuracy: 0.001)
    }

    func testABluetoothHeadsetIsHeldAtMinusTwentySeven() throws {
        let ceiling = try XCTUnwrap(LoudAudio.ceilingScalar(decibels: linear(-40, 0)))
        XCTAssertEqual(ceiling, 13.0 / 40, accuracy: 0.0001, "−27 on a −40…0 scale")
    }

    func testEachDeviceIsHeldThroughItsOwnCurve() throws {
        let ceiling = try XCTUnwrap(LoudAudio.ceilingScalar(decibels: linear(-63.5, 0)))
        XCTAssertEqual(ceiling, 36.5 / 63.5, accuracy: 0.0001)
    }

    func testADeviceThatNeverReachesTheCeilingIsNotHeldBelowFull() {
        XCTAssertEqual(LoudAudio.ceilingScalar(decibels: linear(-80, -30)), 1)
    }

    func testADeviceWhoseQuietestIsOverTheCeilingIsHeldAtSilence() {
        XCTAssertEqual(LoudAudio.ceilingScalar(decibels: linear(-20, 0)), 0)
    }

    func testADeviceWithNoCurveIsNotHeld() {
        XCTAssertNil(LoudAudio.ceilingScalar(decibels: { _ in nil }))
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

    func testOnlyTheVolumeUpKeyIsRead() {
        XCTAssertTrue(LoudAudio.isVolumeUp(subtype: 8, data1: (0 << 16) | (0xA << 8)), "pressed")
        XCTAssertTrue(LoudAudio.isVolumeUp(subtype: 8, data1: (0 << 16) | (0xB << 8)), "let go")
        XCTAssertFalse(LoudAudio.isVolumeUp(subtype: 8, data1: (1 << 16) | (0xA << 8)), "volume down")
        XCTAssertFalse(LoudAudio.isVolumeUp(subtype: 8, data1: (7 << 16) | (0xA << 8)), "mute")
        XCTAssertFalse(LoudAudio.isVolumeUp(subtype: 7, data1: 0), "another kind of system event")
    }
}
