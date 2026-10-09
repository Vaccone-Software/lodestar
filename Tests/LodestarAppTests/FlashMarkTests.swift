import XCTest
@testable import lodestar

/// Every flash is one family with the pill: the glyph it opened with
/// becomes a symbol in the pill's configuration, and the line opens with
/// a capital. Breaths wear wind.
final class FlashMarkTests: XCTestCase {
    func testTheGlyphBecomesTheMarkAndTheLineOpensWithACapital() {
        let refused = FlashMark.parse("✕ no focused window")
        XCTAssertEqual(refused.symbol, "xmark")
        XCTAssertEqual(refused.text, "No focused window")
        let breath = FlashMark.parse("◎ Breath W saved with 2 windows")
        XCTAssertEqual(breath.symbol, BarTheme.breathSymbol)
        XCTAssertEqual(BarTheme.breathSymbol, "wind")
        XCTAssertEqual(breath.text, "Breath W saved with 2 windows")
        XCTAssertEqual(FlashMark.parse("⌂ pinned").symbol, "doc.on.clipboard")
        XCTAssertEqual(FlashMark.parse("⚠ Lodestar lost its keyboard access").symbol, "exclamationmark.triangle")
        XCTAssertNil(FlashMark.parse("… launching Slack").symbol,
                     "no flash trails off any more: a launch is the pill's opening mode")
        XCTAssertEqual(FlashMark.parse("⟲ layout").symbol, "rectangle.3.group")
        XCTAssertEqual(FlashMark.parse("⌖ gestures restored").symbol, "checkmark")
    }

    func testALineWithoutAGlyphKeepsItsWordsAndTakesNoMark() {
        let plain = FlashMark.parse("press ⌘V to paste, this field blocks synthetic input")
        XCTAssertNil(plain.symbol)
        XCTAssertEqual(plain.text, "press ⌘V to paste, this field blocks synthetic input", "untouched: the words are the site's to fix")
    }

    func testTheGuideAndTheFlashDrawTheMark() {
        let hud = HUD()
        hud.flash("◎ Breath W saved with 2 windows")
        XCTAssertEqual(hud.titleSymbol, "wind")
        XCTAssertEqual(hud.titleText, "Breath W saved with 2 windows")
        hud.showGuide(mark: BarTheme.breathSymbol, keys: ["lode", "'", "W"],
                      rows: [GuideRow(key: "A", label: "Slack")])
        XCTAssertEqual(hud.titleSymbol, "wind")
        XCTAssertEqual(hud.titleText, "lode ' W", "the header is the chain so far, as keys")
        hud.showGuide(keys: ["lode"], rows: [])
        XCTAssertNil(hud.titleSymbol, "the graph's guide has no mark; its header is the keys alone")
        hud.hide()
    }

    /// The fact, then the way under it, its keys drawn: one string at the
    /// call site, split at the newline.
    func testAFlashCarriesItsWayOnASecondLine() {
        let hud = HUD()
        hud.flash("⌂ This field only takes a paste you press\n[⌘][V] pastes it")
        XCTAssertEqual(hud.titleSymbol, "doc.on.clipboard")
        XCTAssertEqual(hud.titleText, "This field only takes a paste you press")
        XCTAssertEqual(hud.titleWay, "[⌘][V] pastes it")
        hud.flash("⟲ Layout redone")
        XCTAssertNil(hud.titleWay, "a fact with no way is one line")
        hud.hide()
    }

    func testNamesAreSpokenAsAList() {
        XCTAssertEqual(Actions.spoken([]), "")
        XCTAssertEqual(Actions.spoken(["Slack"]), "Slack")
        XCTAssertEqual(Actions.spoken(["Slack", "Brave"]), "Slack and Brave")
        XCTAssertEqual(Actions.spoken(["Slack", "Brave", "Zoom"]), "Slack, Brave and Zoom")
    }
}

/// A breath may be saved at any letter. B was reserved while breaths lived
/// on `lode B`; they moved to `lode '`, and the reservation outlived them.
final class BreathPathTests: XCTestCase {
    func testEveryLetterIsABreathPathBIncluded() {
        XCTAssertNil(Actions.breathPathRefusal("b"))
        XCTAssertNil(Actions.breathPathRefusal("gb"))
        XCTAssertNotNil(Actions.breathPathRefusal(""))
    }
}

/// The coach's compact card: the names it shows and the record it whispers.
final class CoachCardTests: XCTestCase {
    func testAppNamesGetTheirCapitalsBack() {
        XCTAssertEqual(CoachCard.displayName("brave browser"), "Brave Browser")
        XCTAssertEqual(CoachCard.displayName("Figma"), "Figma")
        XCTAssertEqual(CoachCard.displayName("iTerm2"), "iTerm2", "a name with its own casing is left alone")
    }

    func testTheWhisperIsTheRecordsFirstClause() {
        XCTAssertEqual(CoachCard.record(from: "You searched for it 31 times across 6 weeks · about 40 seconds a week"),
                       "You searched for it 31 times across 6 weeks")
    }

    func testTheCardIsAReadableGroup() {
        let card = CoachCard.build(.init(sentence: "Notes could be one key away", icons: [], name: "Notes",
                                         address: ["lode", "N"], record: "31 searches", accept: {}, decline: {}))
        XCTAssertEqual(card.accessibilityRole(), .group)
        XCTAssertEqual(card.accessibilityLabel(), "Notes could be one key away. 31 searches")
    }
}

/// A flash that needs you stays until your next key, not for a time chosen
/// for you; every other flash goes after its words are read.
final class HeldFlashTests: XCTestCase {
    func testAFlashThatNeedsYouWaitsForAKey() {
        let stage = Stage()
        stage.hud.flash("⚠ Lodestar lost its keyboard access\nTurn it back on in Privacy & Security, under Accessibility")
        XCTAssertEqual(stage.hud.owner, .flash)
        stage.clock.advance(by: 10)
        XCTAssertEqual(stage.hud.owner, .flash, "still there after ten seconds")
        stage.hud.keyStruck()
        XCTAssertEqual(stage.hud.owner, .none, "the next key takes it down")
    }

    func testAKeyTooSoonDoesNotSweepItAway() {
        let stage = Stage()
        stage.hud.flash("⚠ Move Lodestar to Applications\nThen open it again")
        stage.hud.keyStruck()
        XCTAssertEqual(stage.hud.owner, .flash, "a key already on its way when it appeared is not an answer")
    }

    func testAnOrdinaryFlashIsNotHeld() {
        let stage = Stage()
        stage.hud.flash("✕ Nothing to undo")
        stage.clock.advance(by: 5)
        XCTAssertEqual(stage.hud.owner, .none, "four seconds at most")
    }
}
