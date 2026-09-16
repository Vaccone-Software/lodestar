import XCTest
@testable import lodestar
@testable import LodestarCore

/// The draft's two notes: one when the microphone is live, one when the
/// words land, and neither when nothing happened.
final class DraftSoundTests: XCTestCase {
    private var heard: [Sounds.Cue] = []

    override func setUp() {
        heard = []
        Sounds.play = { [unowned self] cue in self.heard.append(cue) }
    }
    override func tearDown() { Sounds.play = Sounds.playThroughSpeakers }

    func testAliveMicrophonePlaysOnceAndTheLandingAnswersIt() {
        let stage = Stage()
        stage.lode(".")
        XCTAssertEqual(heard, [], "the engine reporting ready is not the microphone being live")
        stage.speech.alive()
        XCTAssertEqual(heard, [.listening])
        stage.speech.alive()
        XCTAssertEqual(heard, [.listening], "once a session")
        stage.speech.settle("Hello")
        stage.press("return")
        XCTAssertEqual(heard, [.listening, .landed])
        XCTAssertFalse(stage.draft.isOpen)
    }

    func testADeafMicrophonePlaysNothing() {
        let stage = Stage()
        stage.lode(".")
        stage.press("escape")
        XCTAssertEqual(heard, [], "silence is the message")
    }

    func testCancelAfterAliveIsSilent() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.alive()
        stage.press("escape")
        XCTAssertEqual(heard, [.listening], "no landing note for words that did not land")
    }

    func testTheSwitchSilencesThePairOnly() {
        let stage = Stage()
        stage.draft.sounds = false
        stage.lode(".")
        stage.speech.alive()
        stage.speech.settle("Hello")
        stage.press("return")
        XCTAssertEqual(heard, [])
        XCTAssertEqual(stage.pasteboard, ["Hello"], "the words still land")
    }

    func testTheNotesShipWithTheApp() {
        XCTAssertNotNil(Sounds.url(for: .listening))
        XCTAssertNotNil(Sounds.url(for: .landed))
    }

    func testTheAlertTravelsWithTheAppSoSoundSettingsCanFindIt() {
        XCTAssertNotNil(AlertSound.bundled, "the strike ships, whether or not anything plays it")
    }
}
