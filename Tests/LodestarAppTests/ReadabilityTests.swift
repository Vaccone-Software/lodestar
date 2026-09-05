import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// What the eye is given: a cursor it can find, a scale with a floor, and
/// a card that says where it came from. Read from the rendered storage
/// and layers, the way the find lights are, because a state test cannot
/// see a wash that vibrancy ate.
final class ReadabilityTests: XCTestCase {
    private func view(_ text: String, cursor: Int, editor: Vim.Mode) -> DraftView {
        DraftView(buffer: Draft.Buffer(text: text, cursor: cursor), mode: editor == .insert ? .insert : .normal,
                  editor: editor, speech: nil, destination: ("Notes", nil), replacing: false)
    }

    private func color(_ panel: DraftPanel, at index: Int) -> NSColor? {
        panel.textView.textStorage?.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    func testTheBlockCursorIsASolidPlateWithTheGlyphInverted() {
        let panel = DraftPanel()
        defer { panel.hide() }
        panel.show(view("hello", cursor: 1, editor: .normal))
        // The plate is the text's own colour, which on the pinned dark
        // appearance is white at 85 percent — the same white the glyphs
        // are drawn in, not the 35 percent wash it used to be.
        let label = NSColor.labelColor.usingColorSpace(.deviceRGB)!
        let plate = panel.caretColor?.usingColorSpace(.deviceRGB)
        XCTAssertEqual(plate?.alphaComponent ?? 0, label.alphaComponent, accuracy: 0.01, "a plate, not a wash")
        XCTAssertGreaterThan(plate?.alphaComponent ?? 0, 0.8)
        XCTAssertEqual(color(panel, at: 1), DraftPanel.ground, "the glyph under it is cut out in the ground")
        XCTAssertEqual(color(panel, at: 0), .labelColor, "its neighbours are not")
        XCTAssertGreaterThan(panel.caretFrame.width, 4, "the width of the glyph")
    }

    func testTheInsertBarIsTheSystemsInsertionColourAndThreePointsWide() {
        let panel = DraftPanel()
        defer { panel.hide() }
        panel.show(view("hello", cursor: 1, editor: .insert))
        XCTAssertEqual(panel.caretColor?.usingColorSpace(.deviceRGB),
                       NSColor.controlAccentColor.usingColorSpace(.deviceRGB))
        XCTAssertEqual(panel.caretFrame.width, 3, accuracy: 0.01)
        XCTAssertEqual(color(panel, at: 1), .labelColor, "nothing is inverted under a bar")
    }

    func testNoInversionAtTheEndOfTheTextOrOnANewline() {
        let panel = DraftPanel()
        defer { panel.hide() }
        panel.show(view("ab\ncd", cursor: 2, editor: .normal))
        XCTAssertEqual(color(panel, at: 2), .labelColor, "a newline has no glyph to invert")
        panel.show(view("ab", cursor: 2, editor: .normal))
        XCTAssertEqual(color(panel, at: 1), .labelColor)
    }

    func testNoInversionWhileAGhostStands() {
        let panel = DraftPanel()
        defer { panel.hide() }
        var buffer = Draft.Buffer(text: "ab", cursor: 0)
        buffer.showGhost("more")
        panel.show(DraftView(buffer: buffer, mode: .normal, editor: .normal, speech: nil,
                             destination: nil, replacing: false))
        let storage = panel.textView.textStorage!
        for i in 0..<storage.length {
            XCTAssertNotEqual(color(panel, at: i), DraftPanel.ground,
                              "the ghost shifts every position after the cursor, so nothing is inverted")
        }
    }

    func testTheScaleHasAFloorAndThreeSteps() {
        XCTAssertGreaterThanOrEqual(BarTheme.Scale.meta, 13, "nothing on glass below the floor")
        XCTAssertLessThan(BarTheme.Scale.meta, BarTheme.Scale.body)
        XCTAssertLessThan(BarTheme.Scale.body, BarTheme.Scale.title)
        XCTAssertLessThan(BarTheme.Scale.title, BarTheme.Scale.input)
        for font in [BarTheme.secondaryFont, BarTheme.footerFont, BarTheme.chipFont] {
            XCTAssertEqual(font.pointSize, BarTheme.Scale.meta, font.fontName)
        }
        for font in [BarTheme.rowLabelFont, BarTheme.bodyFont] {
            XCTAssertEqual(font.pointSize, BarTheme.Scale.body, font.fontName)
        }
        XCTAssertEqual(BarTheme.titleFont.pointSize, BarTheme.Scale.title)
        XCTAssertEqual(BarTheme.readingMono.pointSize, BarTheme.Scale.body,
                       "the draft is body text, at the size a terminal is set to")
        XCTAssertEqual(BarTheme.readingMonoAccent.pointSize, BarTheme.readingMono.pointSize,
                       "a lit letter must not reflow the line")
    }

    func testACardNamesThePageOrTheApp() {
        let stage = Stage()
        let page = stage.seedClip("from a page", app: "Brave Browser", bundle: "com.brave.Browser", host: "github.com")
        let app = stage.seedClip("from an app", app: "Ghostty", bundle: "com.mitchellh.ghostty")
        let nowhere = stage.seedClip("from nowhere", app: nil, bundle: nil)
        stage.openStrip()
        let sources = stage.engine.strip.shownSources
        XCTAssertEqual(sources[page.id], "github.com", "the page beats the browser's name")
        XCTAssertEqual(sources[app.id], "Ghostty")
        XCTAssertNil(sources[nowhere.id])
        stage.press("escape")
    }

    func testTheAgeSaysAgo() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        func aged(_ seconds: TimeInterval) -> Clipboard.Clip {
            Clipboard.Clip(id: "x", kind: .text, created: base.addingTimeInterval(-seconds),
                           sourceBundleID: nil, sourceAppName: nil, preview: "", bytes: 0)
        }
        XCTAssertEqual(Clipboard.age(of: aged(10), now: base), "just now")
        XCTAssertEqual(Clipboard.age(of: aged(90), now: base), "1m ago")
        XCTAssertEqual(Clipboard.age(of: aged(90_000), now: base), "1d ago")
        XCTAssertTrue(Clipboard.age(of: aged(5000), now: base).hasSuffix(" ago"))
    }
}
