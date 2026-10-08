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

    /// The mark on a note is the progress: it lights whole faces only, in
    /// one order that reaches every face, and is whole at the end.
    func testTheMarkFillsFaceByFace() {
        let faces = Mark.faces.count
        XCTAssertEqual(LitMark.litCount(0), 0)
        XCTAssertEqual(LitMark.litCount(1), faces)
        XCTAssertEqual(LitMark.litCount(2), faces, "never more than the whole mark")
        XCTAssertEqual(LitMark.litCount(-1), 0)
        XCTAssertEqual(Set(LitMark.order), Set(Mark.faces.indices), "the order reaches every face once")
        XCTAssertEqual(LitMark.order.count, faces)
        let mark = LitMark(lit: 3)
        XCTAssertEqual(mark.lit, 1, "a share past the end is the whole mark")
    }

    /// Lodestar speaking about itself carries the mark before its words;
    /// every other voice card stays words alone.
    func testANoteAboutLodestarCarriesTheMark() {
        let mark = LitMark(lit: 0.5)
        let card = VoiceCard.build(sentence: "A newer Lodestar is on its way", detail: "0.45.5 · downloading",
                                   rows: [], mark: mark)
        XCTAssertTrue(card.arrangedSubviews.first === mark, "the mark stands first")
        XCTAssertEqual(card.orientation, .horizontal)
        let plain = VoiceCard.build(sentence: "Ready when you are", detail: nil, rows: [])
        XCTAssertFalse(plain.arrangedSubviews.contains { $0 is LitMark })
    }

    /// A download lights the mark on the note standing for it, and a note
    /// without a mark ignores the light.
    func testTheDownloadLightsTheStandingNote() throws {
        let hud = HUD()
        hud.lightMark(0.5)
        hud.showVoice(sentence: "A newer Lodestar is on its way", detail: nil, rows: [], owner: .flash, mark: 0)
        hud.lightMark(0.5)
        XCTAssertEqual(try XCTUnwrap(hud.voiceMark).lit, 0.5)
        hud.showVoice(sentence: "Ready when you are", detail: nil, rows: [], owner: .flash)
        XCTAssertNil(hud.voiceMark, "a note without the mark has nothing to light")
        hud.lightMark(1)
        hud.hide()
    }
}
