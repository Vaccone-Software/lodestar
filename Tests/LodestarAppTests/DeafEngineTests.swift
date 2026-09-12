import AVFoundation
import XCTest
@testable import lodestar

/// The engine that starts, reports running, and hears nothing.
///
/// This is what an update leaves behind, and the field log has runs of a
/// dozen sessions at `buffers=0 peakDb=-140` after one — going back
/// through a year of releases. The engine was stale by no test the start
/// path had: same device, same format, no error. So it was kept and
/// restarted for every draft after it, and nothing recovered the
/// microphone but time or a relaunch.
final class DeafEngineTests: XCTestCase {
    private let reading: (rate: Double, channels: UInt32) = (16_000, 1)
    private let device: AudioDeviceID = 42

    private func stale(deaf: Bool = false, attempt: Int = 0,
                       builtFor: AudioDeviceID? = 42, target: AudioDeviceID? = 42,
                       now: (rate: Double, channels: UInt32)? = (16_000, 1),
                       built: (rate: Double, channels: UInt32)? = (16_000, 1),
                       hasEngine: Bool = true) -> Bool {
        AudioInput.engineIsStale(hasEngine: hasEngine, builtFor: builtFor, target: target,
                                 attempt: attempt, deaf: deaf, nowReading: now, builtReading: built)
    }

    /// The whole point: everything else about the engine says keep it.
    func testADeafEngineIsStaleEvenWhenNothingElseIs() {
        XCTAssertFalse(stale(), "same device, same format, first attempt: the warm engine serves")
        XCTAssertTrue(stale(deaf: true),
                      "and the same engine, having heard nothing, does not")
    }

    /// Creating one costs a second and starting a kept one costs seventy
    /// milliseconds, so the warm engine has to survive the ordinary case.
    func testTheWarmEngineIsKept() {
        XCTAssertFalse(stale())
    }

    func testTheReasonsItWasAlreadyReplaced() {
        XCTAssertTrue(stale(hasEngine: false), "there is none")
        XCTAssertTrue(stale(attempt: 1), "the last start failed")
        XCTAssertTrue(stale(builtFor: 42, target: 7), "a different device")
        XCTAssertTrue(stale(now: (48_000, 1)), "the same device at a new sample rate")
        XCTAssertTrue(stale(now: (16_000, 2)), "or a new channel count")
    }

    /// An engine whose format cannot be read is not one to trust.
    func testAnUnreadableFormatIsStale() {
        XCTAssertTrue(stale(now: nil))
        XCTAssertTrue(stale(built: nil))
    }

    /// The watch has to be shorter than a hand's patience and longer than
    /// the gap between buffers, which at the size the tap installs is
    /// about sixty-four milliseconds.
    func testTheDeafnessWindowIsSane() {
        XCTAssertGreaterThan(AudioInput.deafnessSeconds, 0.5,
                             "long enough that a slow first buffer is not called deafness")
        XCTAssertLessThan(AudioInput.deafnessSeconds, DraftController.listenWatchdogSeconds,
                          "and short enough to rebuild before the draft gives up on the session")
    }
}
