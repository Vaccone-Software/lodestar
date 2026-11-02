import XCTest
@testable import lodestar
@testable import LodestarCore

/// What the foot of the draft says about the microphone, and in what order.
final class DraftFootTests: XCTestCase {
    private func note(_ speech: SpeechState?, replacing: Bool = false, silent: Bool = false,
                      input: String? = "Cypress") -> String {
        DraftPanel.note(for: DraftView(buffer: Draft.Buffer(), mode: .insert, speech: speech, input: input,
                                       micOn: true, silent: silent, retrying: false,
                                       destination: nil, replacing: replacing))
    }

    // MARK: - Priority

    func testAFaultInTheMicrophoneOutranksTheReplacesHint() {
        XCTAssertEqual(note(.failed("the microphone could not start"), replacing: true),
                       "the microphone could not start")
        XCTAssertEqual(note(.denied, replacing: true), "microphone not allowed, typing only")
        XCTAssertEqual(note(.unavailable, replacing: true), "no speech recognizer for this language, typing only")
        XCTAssertEqual(note(.listening(input: "Cypress"), replacing: true, silent: true),
                       "hearing nothing on Cypress", "a deaf microphone is the news, not where ⏎ lands")
    }

    func testAHealthyMicrophoneLeavesTheHintsAlone() {
        XCTAssertEqual(note(.listening(input: "Cypress"), replacing: true), "replaces the selection")
        XCTAssertEqual(note(.paused, replacing: true), "replaces the selection")
        XCTAssertEqual(note(nil, replacing: true), "replaces the selection")
        XCTAssertEqual(note(.listening(input: "Cypress")), "")
        XCTAssertEqual(note(.preparing(progress: 0.4)), "preparing speech 40%")
    }

    func testNoFootTextNamesAMacOSVersion() {
        for state in [SpeechState.denied, .unavailable, .failed("the speech model could not be installed"),
                      .preparing(progress: nil), .paused, .listening(input: nil)] {
            XCTAssertFalse(note(state).contains("macOS"), "\(state)")
        }
    }
}
