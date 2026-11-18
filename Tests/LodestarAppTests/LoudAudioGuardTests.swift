import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The volume-key tap's callback, handed system-defined events the way the
/// window server would. No real tap is made and no volume is touched under
/// test: they would hold the volume of the person at the desk.
final class LoudAudioGuardTests: XCTestCase {
    private let ceiling: Float = 13.0 / 40 // −27 dB on a −40…0 headset

    private func key(_ code: Int, down: Bool = true, fine: Bool = false) throws -> CGEvent {
        let state = down ? 0xA : 0xB
        var flags = NSEvent.ModifierFlags(rawValue: UInt(state << 8))
        if fine { flags.formUnion([.option, .shift]) }
        let event = try XCTUnwrap(NSEvent.otherEvent(
            with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, subtype: 8, data1: (code << 16) | (state << 8), data2: -1)?.cgEvent)
        return event
    }

    private func swallowed(_ guardian: LoudAudioGuard, _ event: CGEvent) -> Bool {
        guardian.handle(CGEventType(rawValue: 14)!, event) == nil
    }

    func testATestRunNeverHoldsTheVolume() {
        let guardian = LoudAudioGuard()
        guardian.configure(level: .standard)
        XCTAssertFalse(guardian.isTapping)
    }

    func testVolumeUpIsSwallowedWhenItsStepWouldCrossTheCeiling() throws {
        let guardian = LoudAudioGuard(live: false)
        guardian.pretendHeld(ceiling: ceiling, volume: 0.3125)
        XCTAssertTrue(swallowed(guardian, try key(LoudAudio.soundUpKey)), "pressed")
        XCTAssertTrue(swallowed(guardian, try key(LoudAudio.soundUpKey, down: false)), "and let go")
    }

    func testVolumeUpUnderTheCeilingPasses() throws {
        let guardian = LoudAudioGuard(live: false)
        guardian.pretendHeld(ceiling: ceiling, volume: 0.25)
        XCTAssertFalse(swallowed(guardian, try key(LoudAudio.soundUpKey)))
    }

    func testAFineStepGetsCloserBeforeItStops() throws {
        let guardian = LoudAudioGuard(live: false)
        guardian.pretendHeld(ceiling: ceiling, volume: 0.296875)
        XCTAssertTrue(swallowed(guardian, try key(LoudAudio.soundUpKey)), "a whole step would cross")
        XCTAssertFalse(swallowed(guardian, try key(LoudAudio.soundUpKey, fine: true)), "a quarter step does not")
    }

    func testVolumeDownAndMuteAlwaysPass() throws {
        let guardian = LoudAudioGuard(live: false)
        guardian.pretendHeld(ceiling: ceiling, volume: 0.9)
        XCTAssertFalse(swallowed(guardian, try key(1)), "volume down")
        XCTAssertFalse(swallowed(guardian, try key(7)), "mute")
    }

    func testNothingHeldSwallowsNothing() throws {
        let guardian = LoudAudioGuard(live: false)
        guardian.pretendHeld(ceiling: nil, volume: 1)
        XCTAssertFalse(swallowed(guardian, try key(LoudAudio.soundUpKey)), "speakers, or off")
    }
}
