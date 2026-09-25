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
}

/// A clip that is only a color is drawn as the color.
final class StripColorTests: XCTestCase {
    func testAColorClipIsASwatchAndTextStaysText() {
        let stage = Stage()
        let hex = stage.seedClip("#FF4F00")
        let figma = stage.seedClip("FF4F00", app: "Figma", bundle: "com.figma.Desktop")
        let css = stage.seedClip("rgb(255 79 0 / 50%)")
        let issue = stage.seedClip("#123")
        let word = stage.seedClip("facade")
        stage.openStrip()
        let swatches = stage.engine.strip.shownSwatches
        XCTAssertEqual(swatches[hex.id], "#FF4F00")
        XCTAssertEqual(swatches[figma.id], "#FF4F00")
        XCTAssertEqual(swatches[css.id], "#FF4F0080")
        XCTAssertNil(swatches[issue.id], "an issue number stays text")
        XCTAssertNil(swatches[word.id], "a word stays text")
        stage.press("escape")
    }
}

final class StripTimeTests: XCTestCase {
    /// The frame a card's text is drawn in.
    private func textFrame(_ stage: Stage, _ clip: Clipboard.Clip) -> NSRect? {
        stage.engine.strip.shownCards[clip.id]?.subviews
            .compactMap { $0 as? NSTextField }.first { $0.stringValue == clip.preview }?.frame
    }

    /// The clip stays where every card keeps its text; Lodestar's note sits
    /// beneath it, its voice first: how long ago, then the clock and the
    /// zones.
    func testATimestampKeepsItsPlaceAndGetsANote() throws {
        let stage = Stage()
        var config = stage.engine.config
        config.clipboardTimeZones = ["Asia/Tokyo"]
        stage.engine.config = config
        let unix = stage.seedClip(String(Int(Date().timeIntervalSince1970) - 6 * 3600))
        let text = stage.seedClip("just some words")
        let phone = stage.seedClip("2125551234")
        let sentence = stage.seedClip("deployed at 1790342057")
        stage.openStrip()
        let notes = stage.engine.strip.shownNotes
        let note = try XCTUnwrap(notes[unix.id])
        XCTAssertEqual(note.first, "6 hours ago", "the voice first")
        XCTAssertTrue(note.contains { $0.contains("Tokyo") }, "the kept zone: \(note)")
        XCTAssertEqual(textFrame(stage, unix)?.maxY, textFrame(stage, text)?.maxY,
                       "the clip starts where every card's text starts")
        XCTAssertEqual(textFrame(stage, unix)?.minX, textFrame(stage, text)?.minX)
        XCTAssertNil(notes[text.id])
        XCTAssertNil(notes[phone.id], "a phone number is not a time")
        XCTAssertNil(notes[sentence.id], "a time inside a sentence is text")
        stage.press("escape")
    }

    /// However many zones are kept, the note stays below the clip: the
    /// zones take the rows there are and no more.
    func testMoreZonesThanRoomStayBelowTheClip() throws {
        let stage = Stage()
        var config = stage.engine.config
        config.clipboardTimeZones = ["Asia/Tokyo", "Europe/London", "Australia/Sydney", "America/Los_Angeles"]
        stage.engine.config = config
        let clip = stage.seedClip("2026-09-25T13:14:17.123+09:00")
        stage.openStrip()
        let note = try XCTUnwrap(stage.engine.strip.shownNotes[clip.id])
        let card = try XCTUnwrap(stage.engine.strip.shownCards[clip.id])
        let clipFrame = try XCTUnwrap(textFrame(stage, clip))
        for label in card.subviews.compactMap({ $0 as? NSTextField }) where note.contains(label.stringValue) {
            XCTAssertLessThanOrEqual(label.frame.maxY, clipFrame.minY, "\(label.stringValue) climbs into the clip")
        }
        stage.press("escape")
    }
}

final class StripColorNoteTests: XCTestCase {
    func testAColorIsNamedBeneathTheClip() throws {
        let stage = Stage()
        let hex = stage.seedClip("#FF4F00")
        stage.openStrip()
        XCTAssertEqual(stage.engine.strip.shownNotes[hex.id], ["International Orange", "rgb(255, 79, 0)"])
        stage.press("escape")
    }
}

final class StripReadNoteTests: XCTestCase {
    /// A measurement in the other system is read into yours; one in yours
    /// stays a plain card. Arithmetic is read as its answer.
    func testMeasurementsAndSums() throws {
        let stage = Stage()
        var config = stage.engine.config
        config.units = "imperial"
        stage.engine.config = config
        let km = stage.seedClip("5 km")
        let miles = stage.seedClip("3 mi")
        let sum = stage.seedClip("1234 * 1.08")
        stage.openStrip()
        let notes = stage.engine.strip.shownNotes
        XCTAssertEqual(notes[km.id], ["3.11 mi"])
        XCTAssertNil(notes[miles.id], "already in your units")
        XCTAssertEqual(notes[sum.id], ["1,332.72"])
        stage.press("escape")
    }
}

/// No card cuts its words off, except where cutting off is the design: a
/// clip's own text trails off on its last line, and a long source name
/// gives way to the chip. Every other label — a note's voice, its exact
/// lines, a color's notation, the foot — must fit the frame it is drawn
/// in, on every kind of card. Two cut-offs were found by eye before this
/// existed (rgb(52 199… and a zone ending Tok…).
final class StripNoCutOffTests: XCTestCase {
    private static let batches: [[String]] = [
        ["#FF4F00", "rgb(52 199 89 / 50%)", "hsl(280deg 60% 55%)", "#34C75980", "#BCF5A6"],
        ["1790342057", "1790342057000", "2026-09-25T13:14:17.123+09:00", "Fri, 25 Sep 2026 13:14:17 +0000", "2026-10-02"],
        ["1000000000", "5 km", "180 cm", "500 mL", "100 km/h"],
        ["1234 * 1.08", "2^64", "(12 + 7) / 3", "72°F",
         "A clip long enough to run past the five lines a card draws, so its last line trails off the way every long card's does, which is the one cut-off the strip is built to make on purpose."],
    ]

    func testNoLabelIsCutOff() throws {
        for batch in Self.batches {
            let stage = Stage()
            var config = stage.engine.config
            config.units = "imperial"
            config.clipboardTimeZones = ["Asia/Tokyo", "Europe/London", "America/Los_Angeles"]
            stage.engine.config = config
            let clips = batch.map { stage.seedClip($0, app: "Visual Studio Code", bundle: "com.microsoft.VSCode") }
            stage.openStrip()
            let strip = stage.engine.strip
            for clip in clips {
                let card = try XCTUnwrap(strip.shownCards[clip.id], "\(clip.preview) has no card")
                for label in card.subviews.compactMap({ $0 as? NSTextField }) {
                    if label.stringValue == String(clip.preview.prefix(220)) || label.stringValue == strip.shownSources[clip.id] {
                        continue
                    }
                    let text = label.attributedStringValue
                    let room = label.frame.width - 4
                    if label.cell?.wraps == true {
                        let needed = text.boundingRect(with: NSSize(width: room, height: .greatestFiniteMagnitude),
                                                       options: [.usesLineFragmentOrigin, .usesFontLeading]).height
                        XCTAssertLessThanOrEqual(needed, label.frame.height + 1,
                                                 "'\(label.stringValue)' on \(clip.preview) needs more lines than it has")
                    } else {
                        XCTAssertLessThanOrEqual(text.size().width, room + 1,
                                                 "'\(label.stringValue)' on \(clip.preview) is cut off")
                    }
                    XCTAssertTrue(card.bounds.insetBy(dx: -0.5, dy: -0.5).contains(label.frame),
                                  "'\(label.stringValue)' on \(clip.preview) leaves its card")
                }
            }
            stage.press("escape")
        }
    }
}
