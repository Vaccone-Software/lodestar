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

    func testTheVoiceIsTheSystemSerifAndNothingElseWearsIt() {
        XCTAssertEqual(BarTheme.voiceFont.pointSize, 20)
        let design = BarTheme.voiceFont.fontDescriptor.object(forKey: .init(rawValue: "NSCTFontUIUsageAttribute"))
        XCTAssertNotNil(BarTheme.voiceFont.familyName)
        XCTAssertTrue(BarTheme.voiceFont.familyName?.contains("New York") == true
                      || BarTheme.voiceFont.fontName.contains("NewYork"),
                      "the system serif: \(BarTheme.voiceFont.fontName)")
        _ = design
        XCTAssertFalse(BarTheme.typedFont.fontName.contains("NewYork"), "the hand's words never wear it")
        XCTAssertFalse(BarTheme.bodyFont.fontName.contains("NewYork"), "nor does the interface")
    }
}
