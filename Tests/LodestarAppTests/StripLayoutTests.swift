import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// Where the pins stand, how wide the band may be, and how a caption
/// reads — the strip's arrangement, decided from the screen alone.
final class StripLayoutTests: XCTestCase {
    private let row: CGFloat = 158 + 10
    private let band: CGFloat = 54

    func testTheColumnIsCenteredOnATallScreen() {
        let placed = ClipboardStrip.layout(screenHeight: 1169, drawnSlots: 1)
        // The screen's middle, in the panel's own coordinates, less half a card.
        XCTAssertEqual(placed.columnBottom, 1169 / 2 - 22 - 158 / 2, accuracy: 0.5)
        XCTAssertEqual(placed.bandLeft, 0, "the band takes the full width")
        XCTAssertEqual(placed.height, placed.columnBottom + 158, accuracy: 0.5)
    }

    func testAFullColumnStaysCenteredWhereItFits() {
        let placed = ClipboardStrip.layout(screenHeight: 1600, drawnSlots: 5)
        let column: CGFloat = 5 * 168 - 10
        XCTAssertEqual(placed.columnBottom, 1600 / 2 - 22 - column / 2, accuracy: 0.5)
        XCTAssertEqual(placed.bandLeft, 0)
    }

    /// A short screen: the column would reach into the band's row, so
    /// it stops on that row and the band starts to its right.
    func testOnAShortScreenTheColumnStopsAboveTheRowAndTheBandKeepsClear() {
        let placed = ClipboardStrip.layout(screenHeight: 800, drawnSlots: 5)
        XCTAssertEqual(placed.columnBottom, row, "no lower than the row above the recents")
        XCTAssertEqual(placed.bandLeft, 208 + 10, "the band starts right of the column")
    }

    func testTheBandIsFullWidthOnlyWhenTheColumnCannotReachIt() {
        // The column's bottom lands just inside the band's row: not clear.
        let touching = ClipboardStrip.layout(screenHeight: 2 * (22 + row + band + 5 + 79), drawnSlots: 1)
        XCTAssertLessThan(touching.columnBottom, row + band + 10)
        XCTAssertEqual(touching.bandLeft, 208 + 10)
        // A little taller and it clears.
        let clear = ClipboardStrip.layout(screenHeight: 2 * (22 + row + band + 10 + 79) + 2, drawnSlots: 1)
        XCTAssertGreaterThanOrEqual(clear.columnBottom, row + band + 10)
        XCTAssertEqual(clear.bandLeft, 0)
    }

    func testWithTheColumnHiddenTheRowAndBandAreAllThereIs() {
        let placed = ClipboardStrip.layout(screenHeight: 1169, drawnSlots: 0)
        XCTAssertEqual(placed.bandLeft, 0)
        XCTAssertEqual(placed.height, row + band)
    }

    func testTheColumnIsAlwaysDrawn() {
        XCTAssertEqual(Clipboard.pinSlotsToDraw(taken: []), 1,
                       "one free slot, so a hand that has never pinned learns that it can")
    }

    func testOnTheStageTheBandIsFullWidthAndTheColumnIsCentered() {
        let stage = Stage()
        stage.seedClip("one")
        stage.openStrip()
        stage.press("/")
        let band = stage.engine.strip.bandFrame
        XCTAssertNotNil(band)
        XCTAssertEqual(band?.minX, 0, "clear of the column on this screen")
        stage.press("escape")
        stage.press("escape")
    }

    // MARK: - Captions

    func testACaptionJoinsWhatIsKnownWithAMiddleDot() {
        XCTAssertEqual(Caption.line(["12 lines", "3m ago"]), "12 lines · 3m ago")
        XCTAssertEqual(Caption.line([nil, "3m ago"]), "3m ago")
        XCTAssertEqual(Caption.line(["", "  ", "just now"]), "just now")
        XCTAssertEqual(Caption.line([]), "")
        XCTAssertEqual(Caption.line(["github.com", "just now"]), "github.com · just now")
    }

    func testTheCardsFootIsOneCaption() {
        let stage = Stage()
        let long = stage.seedClip((1...12).map { "line \($0)" }.joined(separator: "\n"))
        let short = stage.seedClip("short")
        stage.openStrip()
        let captions = stage.engine.strip.shownCaptions
        XCTAssertEqual(captions[long.id], "12 lines · just now")
        XCTAssertEqual(captions[short.id], "just now")
        stage.press("escape")
    }

    // MARK: - The mode band

    private func runs(_ line: NSAttributedString) -> [(text: String, font: NSFont, color: NSColor)] {
        var out: [(String, NSFont, NSColor)] = []
        line.enumerateAttributes(in: NSRange(location: 0, length: line.length)) { attributes, range, _ in
            out.append(((line.string as NSString).substring(with: range),
                        attributes[.font] as! NSFont, attributes[.foregroundColor] as! NSColor))
        }
        return out
    }

    private func state(query: String = "", shown: Int = 0, total: Int = 0) -> SelectOverlay.State {
        SelectOverlay.State(appName: "Brave Browser", query: query, typedLabel: "", shown: shown,
                            total: total, capped: false, stage: .start, scanning: false, verb: "selects")
    }

    func testTheInstructionSpeaksInTheBodyVoiceAndTheFactsInTheCaptionVoice() {
        let line = SelectOverlay.bandLine(state: state(), empty: true)
        let parts = runs(line)
        let instruction = parts.first { $0.text == "type what you see" }
        XCTAssertNotNil(instruction)
        XCTAssertEqual(instruction?.font.pointSize, BarTheme.Scale.body)
        XCTAssertEqual(instruction?.color, .labelColor)
        let app = parts.first { $0.text.contains("Brave Browser") }
        XCTAssertEqual(app?.font.pointSize, BarTheme.Scale.meta)
        XCTAssertEqual(app?.color, .secondaryLabelColor)
        XCTAssertTrue(line.string.hasSuffix(" · esc"))
        XCTAssertFalse(app!.font.fontName.lowercased().contains("mono"), "words, not a status line")
    }

    func testTheQueryStaysLoudAndMono() {
        let parts = runs(SelectOverlay.bandLine(state: state(query: "needle", shown: 2, total: 2), empty: false))
        let query = parts.first { $0.text == "needle" }
        XCTAssertEqual(query?.font.pointSize, BarTheme.Scale.title)
        XCTAssertEqual(query?.color, .controlAccentColor)
        XCTAssertTrue(query!.font.fontName.lowercased().contains("mono"), "the hand's own letters, echoed")
    }
}
