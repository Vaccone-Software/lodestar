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
        hud.flash("◎ Breath W saved with 2 windows", seconds: 60)
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

    func testNamesAreSpokenAsAList() {
        XCTAssertEqual(Actions.spoken([]), "")
        XCTAssertEqual(Actions.spoken(["Slack"]), "Slack")
        XCTAssertEqual(Actions.spoken(["Slack", "Brave"]), "Slack and Brave")
        XCTAssertEqual(Actions.spoken(["Slack", "Brave", "Zoom"]), "Slack, Brave and Zoom")
    }
}
