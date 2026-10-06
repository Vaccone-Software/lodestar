import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// Keep's arrangement, decided from the screen alone: every card over the
/// key that pastes it, the keepsakes over the numbers, the bar over the
/// right hand, at the bars' height.
final class StripLayoutTests: XCTestCase {
    private let wide = NSRect(x: 0, y: 0, width: 1728, height: 1117)
    private let narrow = NSRect(x: 0, y: 0, width: 1280, height: 800)

    /// The keyboard's order, left to right: A S D F, the gutter at G,
    /// then J K L ;.
    func testEveryCardStandsOverItsKeyInTheKeyboardsOrder() {
        let placed = ClipboardStrip.layout(in: wide)
        let xs = ["a", "s", "d", "f", "j", "k", "l", ";"].map { placed.places[$0]!.minX }
        XCTAssertEqual(xs, xs.sorted(), "in the keys' order")
        let gutter = placed.places["j"]!.minX - placed.places["f"]!.maxX
        XCTAssertGreaterThan(gutter, ClipboardStrip.gap, "the hands kept apart at G")
        XCTAssertEqual(placed.places["1"]!.minX, placed.places["a"]!.minX, "1 over A")
        XCTAssertEqual(placed.places["4"]!.minX, placed.places["f"]!.minX, "4 over F")
    }

    /// The newest leads by a step: J tallest, each to its right a little
    /// shorter, the left hand's level and shorter still.
    func testTheRightHandStepsAndTheLeftIsLevel() {
        let placed = ClipboardStrip.layout(in: wide)
        let right = ["j", "k", "l", ";"].map { placed.places[$0]!.height }
        XCTAssertEqual(right, right.sorted(by: >))
        XCTAssertEqual(Set(right).count, 4, "four steps")
        let left = Set(["a", "s", "d", "f"].map { placed.places[$0]!.height })
        XCTAssertEqual(left.count, 1, "level")
        XCTAssertLessThan(left.first!, right.last!)
        XCTAssertLessThan(right.first! / left.first!, 1.3, "a step, never a leap")
        let bottoms = Set(["a", "s", "d", "f", "j", "k", "l", ";"].map { placed.places[$0]!.minY })
        XCTAssertEqual(bottoms.count, 1, "one baseline")
    }

    /// The keepsakes' tops and the bar's are one line, the bars' own.
    func testTheKeepsakesAndTheBarShareTheBarsLine() {
        let placed = ClipboardStrip.layout(in: wide)
        let tops = Set((1...4).map { placed.places["\($0)"]!.maxY })
        XCTAssertEqual(tops.count, 1)
        XCTAssertEqual(tops.first!, placed.bar.maxY)
        XCTAssertEqual(placed.bar.maxY, floor(wide.height * ClipboardStrip.topLine))
        XCTAssertEqual(placed.bar.minX, placed.places["j"]!.minX, "over the right hand")
        XCTAssertEqual(placed.bar.maxX, placed.places[";"]!.maxX)
        XCTAssertGreaterThan(placed.places["1"]!.minY, placed.places["a"]!.maxY, "over the older clips")
    }

    /// J stands over H and J on a screen wide enough for nine readable
    /// cards; on a narrower one it gives up its second key, and no card
    /// falls below the width a command needs.
    func testJGivesUpItsSecondKeyBeforeAnyCardGetsTooNarrow() {
        let roomy = ClipboardStrip.layout(in: wide)
        XCTAssertTrue(roomy.wideJ)
        XCTAssertEqual(roomy.places["j"]!.width, roomy.module * 2 + ClipboardStrip.gap)
        let tight = ClipboardStrip.layout(in: narrow)
        XCTAssertFalse(tight.wideJ)
        XCTAssertEqual(tight.places["j"]!.width, tight.module)
        XCTAssertGreaterThanOrEqual(tight.module, ClipboardStrip.minModule - 10)
        XCTAssertLessThanOrEqual(ClipboardStrip.layout(in: NSRect(x: 0, y: 0, width: 5120, height: 2880)).module,
                                 ClipboardStrip.maxModule, "never wider than a card reads")
    }

    func testKeepIsCenteredOnItsScreen() {
        let screen = NSRect(x: 1728, y: 200, width: 1920, height: 1080)
        let placed = ClipboardStrip.layout(in: screen)
        let left = placed.places["a"]!.minX, right = placed.places[";"]!.maxX
        XCTAssertEqual((left + right) / 2, screen.midX, accuracy: 1)
    }

    /// While searching every match wears the chord that takes it, and the
    /// best match wears ⏎; in Keep the cards wear their bare letters.
    func testSearchingShowsTheChordThatTakesEachMatch() {
        let stage = Stage()
        let older = stage.seedClip("build one")
        let newer = stage.seedClip("build two")
        let kept = stage.seedClip("kept text")
        XCTAssertTrue(stage.clipboard.history.pin(kept.id))
        stage.openStrip()
        XCTAssertEqual(stage.engine.strip.shownKeys[newer.id], "J")
        XCTAssertEqual(stage.engine.strip.shownKeys[kept.id], "4")
        stage.press("/")
        stage.press("b")
        XCTAssertEqual(stage.engine.strip.shownKeys[newer.id], "⏎", "the best match")
        XCTAssertEqual(stage.engine.strip.shownKeys[older.id], "⌥K")
        XCTAssertEqual(stage.engine.strip.shownKeys[kept.id], "⌥4", "a keepsake too")
        stage.press("escape")
        stage.press("escape")
    }

    /// Bring types in pieces an app will take whole, never splitting a
    /// character, and the pieces put back together are the text.
    func testBringTypesInPiecesThatKeepEveryCharacter() {
        let text = "web/src/bar.ts:42:17 👩🏽‍💻 café " + String(repeating: "x", count: 40)
        let pieces = BringTyping.pieces(of: text)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= BringTyping.piece })
        XCTAssertEqual(pieces.map { String(utf16CodeUnits: $0, count: $0.count) }.joined(), text,
                       "no character cut in two")
    }

    func testOnTheStageTheBarStandsOverTheRightHand() {
        let stage = Stage()
        stage.seedClip("one")
        stage.openStrip()
        stage.press("/")
        let band = stage.engine.strip.bandFrame
        XCTAssertNotNil(band)
        XCTAssertEqual(band?.minX, stage.engine.strip.lastLayout?.places["j"]?.minX)
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
        // Five hours, not six: under six the voice counts hours whatever the
        // day, and six hours ago after midnight is rightly "Yesterday evening".
        let unix = stage.seedClip(String(Int(Date().timeIntervalSince1970) - 5 * 3600))
        let text = stage.seedClip("just some words")
        let phone = stage.seedClip("2125551234")
        let sentence = stage.seedClip("deployed at 1790342057")
        stage.openStrip()
        let notes = stage.engine.strip.shownNotes
        let note = try XCTUnwrap(notes[unix.id])
        XCTAssertEqual(note.first, "5 hours ago", "the voice first")
        XCTAssertTrue(note.contains { $0.contains("Tokyo") }, "the kept zone: \(note)")
        // Measured from each card's top edge: the right hand's cards stand
        // at different heights on purpose.
        let inset = { (clip: Clipboard.Clip) -> CGFloat? in
            guard let card = stage.engine.strip.shownCards[clip.id], let frame = self.textFrame(stage, clip)
            else { return nil }
            return card.frame.height - frame.maxY
        }
        XCTAssertEqual(inset(unix), inset(text), "the clip starts where every card's text starts")
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

/// A card holding a secret draws its middle as blocks, and is still found
/// by what it holds.
final class StripSecretTests: XCTestCase {
    func testASecretDrawsItsEndsAndIsFoundByItsMiddle() {
        let stage = Stage()
        let key = stage.seedClip("export OPENAI_API_KEY=sk-proj-" + "AbCdEf1234567890GhIjKlMnOpQr")
        let plain = stage.seedClip("de595f9a1b2c3d4e5f60718293a4b5c6d7e8f901")
        stage.openStrip()
        let b = ClipSecret.blocks
        XCTAssertEqual(stage.engine.strip.shownMasked[key.id], "export OPENAI_API_KEY=sk-proj-\(b)OpQr")
        XCTAssertNil(stage.engine.strip.shownMasked[plain.id], "a commit is pasted as it is")

        stage.press("/")
        for character in "1234567890gh" { stage.press(String(character)) }
        XCTAssertEqual(stage.engine.strip.shownRecents.map(\.id), [key.id],
                       "the search reads the whole clip, the middle included")
        XCTAssertEqual(stage.engine.strip.shownMasked[key.id], "export OPENAI_API_KEY=sk-proj-\(b)OpQr",
                       "and the card it finds stays masked")
        stage.press("escape")
        stage.press("escape")
    }

    /// A secret pasted back is marked concealed, so other clipboard tools
    /// look away; an ordinary clip is not.
    func testASecretPastesBackConcealed() {
        let stage = Stage()
        stage.seedClip("de595f9a1b2c3d4e5f60718293a4b5c6d7e8f901")
        stage.seedClip("export OPENAI_API_KEY=sk-proj-" + "AbCdEf1234567890GhIjKlMnOpQr")
        stage.openStrip()
        stage.press("j")
        let concealed = NSPasteboard.PasteboardType(ClipboardController.concealed)
        XCTAssertEqual(stage.clipboard.pasteboard.types?.contains(concealed), true)
        XCTAssertTrue(stage.clipboard.pasteboard.string(forType: .string)?.hasSuffix("OpQr") == true,
                      "pasted whole")
        stage.openStrip()
        stage.press("k")
        XCTAssertEqual(stage.clipboard.pasteboard.types?.contains(concealed), false, "a commit is not a secret")
    }
}
