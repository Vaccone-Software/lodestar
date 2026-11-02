import XCTest
@testable import lodestar
@testable import LodestarCore

/// What the foot of the draft says about the microphone, in what order, and
/// where the hand can go when the answer is no.
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
        XCTAssertEqual(note(.denied, replacing: true), "microphone not allowed, lode . opens Settings")
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

    // MARK: - A denied microphone

    private func deniedStage(granted: Bool) -> (Stage, () -> [URL]) {
        let stage = Stage()
        var opened: [URL] = []
        stage.draft.openSettings = { opened.append($0) }
        stage.draft.microphoneGranted = { granted }
        stage.lode(".")
        stage.speech.deny()
        return (stage, { opened })
    }

    func testLodeDotWithTheMicrophoneDeniedOpensItsPaneInPrivacyAndSecurity() {
        let (stage, opened) = deniedStage(granted: false)
        XCTAssertEqual(stage.draft.speechState, .denied)
        XCTAssertTrue(opened().isEmpty, "nothing opens by itself")
        stage.lode(".")
        XCTAssertEqual(opened().map(\.absoluteString),
                       ["x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"])
        XCTAssertEqual(stage.speech.listens, 1, "asking again would change nothing")
        XCTAssertTrue(stage.draft.isOpen)
        stage.lode(".")
        XCTAssertEqual(opened().count, 2, "and every press goes there")
    }

    func testLodeDotListensAtOnceOnceTheMicrophoneHasBeenSwitchedOn() {
        let (stage, opened) = deniedStage(granted: true)
        stage.lode(".")
        XCTAssertTrue(opened().isEmpty, "allowed now: nothing to open")
        XCTAssertEqual(stage.speech.listens, 2, "the draft listens again")
    }

    func testLodeDotOpensNoSettingsWhileTheMicrophoneWorks() {
        let stage = Stage()
        var opened: [URL] = []
        stage.draft.openSettings = { opened.append($0) }
        stage.draft.microphoneGranted = { false }
        stage.lode(".")
        stage.lode(".")
        XCTAssertTrue(opened.isEmpty)
    }

    func testTheFootOfADeniedDraftSaysWhatTheKeyDoes() {
        let (stage, _) = deniedStage(granted: false)
        let note = DraftPanel.note(for: DraftView(buffer: stage.draft.buffer, mode: stage.draft.mode,
                                                  speech: stage.draft.speechState, micOn: true,
                                                  destination: nil, replacing: false))
        XCTAssertEqual(note, "microphone not allowed, lode . opens Settings")
    }
}
