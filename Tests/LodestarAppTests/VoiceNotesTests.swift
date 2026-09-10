import XCTest
@testable import lodestar
@testable import LodestarCore

/// The four things Lodestar says about itself, and the way it says them:
/// no I, no trailing period, its own name only where it is the subject.
final class VoiceNotesTests: XCTestCase {
    private func check(_ words: (String, String?)) {
        let (sentence, detail) = words
        XCTAssertFalse(sentence.hasSuffix("."), sentence)
        XCTAssertFalse(sentence.contains(" I "), sentence)
        XCTAssertFalse(sentence.hasPrefix("I "), sentence)
        XCTAssertFalse(sentence.contains("we "), sentence)
        if let detail { XCTAssertFalse(detail.hasSuffix("."), detail) }
    }

    func testTheUpdateNotes() {
        let found = UpdateController.Voice.found("v0.30.31")
        XCTAssertEqual(found.0, "A newer Lodestar is on its way")
        XCTAssertEqual(found.1, "0.30.31 · downloading", "the tag loses its v")
        let newest = UpdateController.Voice.newest("0.30.30")
        XCTAssertEqual(newest.0, "This is the newest Lodestar"); XCTAssertEqual(newest.1, "0.30.30")
        let taking = UpdateController.Voice.takingOver("0.30.31")
        XCTAssertEqual(taking.0, "The new Lodestar takes over in a moment"); XCTAssertEqual(taking.1, "0.30.31 · downloaded and verified")
        let updated = UpdateController.Voice.updated("0.30.31")
        XCTAssertEqual(updated.0, "Lodestar has updated"); XCTAssertEqual(updated.1, "Now 0.30.31")
        for words in [found, UpdateController.Voice.newest("1"), UpdateController.Voice.takingOver("1"), UpdateController.Voice.updated("1")] {
            check(words)
            XCTAssertTrue(words.0.contains("Lodestar"), "an update is about the app, so the app is named")
        }
    }

    func testReadyIsAboutYouAndTheWayInIsAKeymap() {
        XCTAssertEqual(AppDelegate.readyNote, "Ready when you are")
        XCTAssertFalse(AppDelegate.readyNote.contains("Lodestar"), "readiness is about you, not the app")
        check((AppDelegate.readyNote, nil))
        XCTAssertEqual(AppDelegate.readyKeymap, Coach.Keymap(keys: ["lode", "␣"], target: "Launcher"))
    }
}
