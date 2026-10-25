import XCTest
@testable import lodestar

/// A microphone that would not start, or stopped mid-take, is asked for
/// again by the draft itself. Closing the draft and opening it again was
/// the only way to ask, and the hand had to know to do it.
final class DraftMicRetryTests: XCTestCase {
    private func note(_ stage: Stage) -> String {
        DraftPanel.note(for: DraftView(buffer: stage.draft.buffer, mode: stage.draft.mode,
                                       speech: stage.draft.speechState, micOn: true,
                                       retrying: stage.draft.state["retrying"] as? Bool ?? false,
                                       destination: nil, replacing: false))
    }

    func testAFailedStartIsAskedForAgainWithNoHand() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.fail()
        XCTAssertEqual(note(stage), "the microphone could not start, trying again")
        XCTAssertEqual(stage.speech.listens, 1, "not on the spot: the failure is said first")

        stage.clock.advance(by: DraftController.retrySeconds[0])
        XCTAssertEqual(stage.speech.listens, 2, "asked again")
        XCTAssertEqual(stage.speech.openSessions, 1, "the failed session was stopped before the next began")
        XCTAssertEqual(stage.draft.state["listening"] as? Bool, true)
        XCTAssertEqual(stage.draft.state["retrying"] as? Bool, false, "listening ends the asking")
    }

    /// Soon at first, then every few seconds, for as long as the draft is open.
    func testTheAskingBacksOffAndNeverStops() {
        let stage = Stage()
        stage.speech.slowToListen = true
        stage.lode(".")
        var listens = 1
        for wait in DraftController.retrySeconds + Array(repeating: DraftController.retrySeconds.last!, count: 3) {
            stage.speech.fail()
            stage.clock.advance(by: wait - 0.01)
            XCTAssertEqual(stage.speech.listens, listens, "not before \(wait) s")
            stage.clock.advance(by: 0.01)
            listens += 1
            XCTAssertEqual(stage.speech.listens, listens, "asked again after \(wait) s")
            XCTAssertEqual(stage.speech.openSessions, 1)
        }
    }

    /// A take whose microphone stopped keeps every word it had, and the
    /// words after the retry land behind them.
    func testAMicrophoneLostMidTakeKeepsTheWords() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.settle("before the radio")
        stage.speech.hear("still settling")
        stage.speech.fail("the microphone stopped")
        XCTAssertEqual(note(stage), "the microphone stopped, trying again")
        stage.clock.advance(by: DraftController.retrySeconds[0])
        XCTAssertEqual(stage.speech.listens, 2)
        stage.speech.settle("and after")
        let text = stage.draft.buffer.text
        XCTAssertTrue(text.contains("before the radio"), text)
        XCTAssertTrue(text.contains("still settling"), "the words in flight landed as this draft's: \(text)")
        XCTAssertTrue(text.contains("and after"), text)
    }

    /// `lode .` asks at once, without waiting out the retry.
    func testTheDoorAsksAtOnce() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.fail()
        stage.lode(".")
        XCTAssertEqual(stage.speech.listens, 2)
        stage.clock.advance(by: 30)
        XCTAssertEqual(stage.speech.listens, 2, "the scheduled retry was the door's, and is spent")
        XCTAssertEqual(stage.speech.openSessions, 1)
    }

    /// Muted, the draft does not open a microphone on its own; the door does.
    func testAMutedDraftWaitsForTheDoor() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.fail()
        stage.lode(".", shift: true)
        XCTAssertEqual(stage.draft.state["retrying"] as? Bool, false, "nothing is being asked for")
        stage.clock.advance(by: 30)
        XCTAssertEqual(stage.speech.listens, 1)
        stage.lode(".")
        XCTAssertEqual(stage.speech.listens, 2)
    }

    func testClosingTheDraftEndsTheAsking() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.fail()
        _ = stage.press("escape")
        _ = stage.press("escape")
        XCTAssertFalse(stage.draft.isOpen)
        stage.clock.advance(by: 30)
        XCTAssertEqual(stage.speech.listens, 1)
        XCTAssertEqual(stage.speech.openSessions, 0)
    }

    /// What asking cannot fix is not asked again: a refused grant, no
    /// recognizer, a model that would not install (asking would start the
    /// download again).
    func testWhatAskingCannotFixIsNotAsked() {
        for state in [SpeechState.denied, .unavailable, .failed(SpeechState.modelNotInstalled)] {
            XCTAssertFalse(state.retries, "\(state)")
        }
        for why in ["the microphone could not start", "the microphone stopped",
                    "the recognizer could not start", AudioInput.lidClosedWhy] {
            XCTAssertTrue(SpeechState.failed(why).retries, why)
        }
        let stage = Stage()
        stage.lode(".")
        stage.speech.fail(SpeechState.modelNotInstalled)
        XCTAssertEqual(note(stage), SpeechState.modelNotInstalled)
        stage.clock.advance(by: 30)
        XCTAssertEqual(stage.speech.listens, 1)
    }

    /// A retry that is itself silent is watched like the first start was.
    func testARetryThatNeverSpeaksIsCaughtByTheWatchdog() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.slowToListen = true
        stage.speech.fail()
        stage.clock.advance(by: DraftController.retrySeconds[0])
        XCTAssertEqual(stage.speech.listens, 2)
        stage.clock.advance(by: DraftController.listenWatchdogSeconds)
        XCTAssertEqual(stage.speech.stops, 2, "the silent retry was stopped")
        stage.clock.advance(by: DraftController.retrySeconds[1])
        XCTAssertEqual(stage.speech.listens, 3, "and asked again")
    }
}
