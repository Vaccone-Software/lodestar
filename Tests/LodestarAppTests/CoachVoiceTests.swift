import XCTest
@testable import lodestar
@testable import LodestarCore

/// Lodestar speaking: the chip is a sentence in the voice with the
/// measurements beneath, and a decline is answered in the voice too.
final class CoachVoiceTests: XCTestCase {
    func testTheChipIsASentenceInTheVoice() {
        let stage = Stage()
        stage.raiseChip()
        XCTAssertEqual(stage.hud.owner, .coach)
        let sentence = stage.hud.voiceSentence
        XCTAssertNotNil(sentence)
        XCTAssertFalse(sentence!.hasSuffix("."), "a title never ends with a period: \(sentence!)")
        XCTAssertFalse(sentence!.contains("→"), "the keymap is drawn as keys beneath, never in the sentence")
        XCTAssertFalse(sentence!.contains(" I "), "the house never says I")
        stage.press("escape")
    }

    func testADeclineIsAnsweredInTheVoiceAndThenTheGlassIsClear() {
        let stage = Stage()
        stage.raiseChip()
        XCTAssertTrue(stage.coach.lodeDelete())
        XCTAssertEqual(stage.hud.owner, .flash, "a note, not a standing chip")
        XCTAssertEqual(stage.hud.voiceSentence, Coach.declinedNote)
        XCTAssertFalse(stage.coach.chipVisible)
        stage.clock.advance(by: 4.1)
        XCTAssertEqual(stage.hud.owner, .none, "the note goes on its own")
        XCTAssertNil(stage.hud.voiceSentence)
    }

    func testAKeymapIsParsedIntoKeysAndATarget() {
        XCTAssertEqual(Coach.Keymap.parse("lode F → Figma"), Coach.Keymap(keys: ["lode", "F"], target: "Figma"))
        XCTAssertEqual(Coach.Keymap.parse("lode ' G → Slack + Brave"),
                       Coach.Keymap(keys: ["lode", "'", "G"], target: "Slack + Brave"))
        XCTAssertNil(Coach.Keymap.parse("github.com → brave:xonar"), "a route is not a keymap")
        XCTAssertNil(Coach.Keymap.parse("retire lode Q"), "no arrow, no keymap")
        XCTAssertNil(Coach.Keymap.parse("meetings at the door"))
    }

    /// The voice was the system serif until 21 October 2026 (design/02-type.md):
    /// it is the sans now, at the size Settings speaks in, and the coach's
    /// line is the same voice at the body's size.
    func testTheVoiceIsTheSystemSansLikeEverythingElse() {
        XCTAssertEqual(BarTheme.Role.voice.size, BarTheme.Scale.title, "the size Settings speaks in")
        XCTAssertEqual(BarTheme.Role.quietVoice.size, BarTheme.Scale.body, "the coach's line, a size down")
        for role in [BarTheme.Role.voice, .quietVoice] {
            let font = role.font(night: false)
            XCTAssertFalse(font.fontName.contains("NewYork"), "no serif: \(font.fontName)")
            XCTAssertEqual(font.familyName, NSFont.systemFont(ofSize: 13).familyName)
        }
    }
}
