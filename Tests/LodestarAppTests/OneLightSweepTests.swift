import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The October sweep, held by behaviour rather than by reading sources:
/// the mark's pool is the person's accent, every size read is on the
/// scale, every card that asks lights its answer, and the pill says what
/// ⏎ takes before it is pressed. Nothing here is put on screen.
final class OneLightSweepTests: XCTestCase {
    private var savedAccent: (() -> NSColor)!

    override func setUp() {
        super.setUp()
        savedAccent = BarTheme.accentColor
    }

    override func tearDown() {
        BarTheme.accentColor = savedAccent
        super.tearDown()
    }

    // MARK: - The pool is the mark's own light

    private func components(_ color: CGColor) -> [CGFloat] {
        let srgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)
        return srgb?.components ?? []
    }

    func testThePoolTakesTheAccentNotAFixedOrange() throws {
        for accent in [NSColor(srgbRed: 0.1, green: 0.4, blue: 0.9, alpha: 1),
                       NSColor(srgbRed: 0.2, green: 0.6, blue: 0.3, alpha: 1)] {
            BarTheme.accentColor = { accent }
            let pool = MarkPool(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
            let centre = try XCTUnwrap(pool.colors.first)
            let c = components(centre)
            XCTAssertEqual(c[0], accent.redComponent, accuracy: 0.01, "the centre is the accent")
            XCTAssertEqual(c[1], accent.greenComponent, accuracy: 0.01)
            XCTAssertEqual(c[2], accent.blueComponent, accuracy: 0.01)
            XCTAssertEqual(c[3], 0.13, accuracy: 0.001, "faint, as the fixed pool was")
            XCTAssertEqual(components(try XCTUnwrap(pool.colors.last))[3], 0, "and it fades to nothing")
        }
    }

    // MARK: - Every size read is on the scale

    func testTheMeetingStubReadsOnTheScale() {
        let scale: Set<CGFloat> = [BarTheme.Scale.meta, BarTheme.Scale.body, BarTheme.Scale.title]
        for (name, font) in [("count", BarTheme.stubCountFont), ("word", BarTheme.stubWordFont),
                             ("unit", BarTheme.stubUnitFont), ("name", BarTheme.stubTitleFont),
                             ("line", BarTheme.stubDetailFont)] {
            XCTAssertTrue(scale.contains(font.pointSize), "the stub's \(name) is \(font.pointSize) point")
        }
        XCTAssertEqual(BarTheme.stubCountFont.pointSize, BarTheme.Scale.title)
        XCTAssertEqual(BarTheme.stubTitleFont.pointSize, BarTheme.Scale.body)
    }

    // MARK: - Grey matter in two steps

    func testWellAndHairlineAreTwoStepsOfOneInk() throws {
        let well = try XCTUnwrap(BarTheme.well.usingColorSpace(.sRGB))
        let hairline = try XCTUnwrap(BarTheme.hairline.usingColorSpace(.sRGB))
        XCTAssertEqual(well.alphaComponent, 0.05, accuracy: 0.001)
        XCTAssertEqual(hairline.alphaComponent, 0.12, accuracy: 0.001)
    }

    // MARK: - Every card that asks lights its answer

    func testTheEditorsConsentLightsAccept() throws {
        let consent = EditorConsent()
        var rows: [GuideRow] = []
        consent.present = { _, _, shown in rows = shown }
        consent.ask(detail: "")
        XCTAssertEqual(rows.filter(\.lit).map(\.label), ["Accept"], "one light, on the answer")
    }

    func testEveryLessonLightsWhatItAsksAndNotLater() {
        for lesson in Curriculum.Lesson.allCases {
            let card = WalkController.lessonCard(lesson)
            let rows = WalkController.lessonRows(card, answerable: lesson == .editor, answer: {}, later: {})
            XCTAssertEqual(rows.first?.lit, true, "\(lesson) lights the thing it teaches")
            XCTAssertEqual(rows.filter(\.lit).count, 1, "\(lesson) has one light")
            XCTAssertEqual(rows.last?.label, "Later")
            XCTAssertEqual(rows.last?.lit, false, "Later is the way out, never lit")
            XCTAssertNotNil(rows.last?.action, "Later is pressable")
        }
    }

    func testTheEditorLessonsAnswerIsPressable() {
        let card = WalkController.lessonCard(.editor)
        var answered = false
        let rows = WalkController.lessonRows(card, answerable: true, answer: { answered = true }, later: {})
        rows.first?.action?()
        XCTAssertTrue(answered)
    }

    // MARK: - Words, not glyphs

    func testTheWalksHeadingIsWords() {
        let heading = WalkController.heading(door: "Switch", position: 2, total: 5)
        XCTAssertEqual(heading, "Switch · 2 of 5")
        XCTAssertFalse(heading.contains("⌖"), "a typed glyph sat at a weight and baseline of its own")
    }

    func testTheMenuOpensWithTheNameAndTheVersionOnly() {
        XCTAssertEqual(AppDelegate.menuHeader, "Lodestar \(Lodestar.version)")
    }

    // MARK: - The pill says what ⏎ takes

    func testThePillSaysHowManyFixesReturnTakes() {
        XCTAssertNil(SelectController.fixAllOffer(count: 0), "nothing to offer, no key")
        XCTAssertEqual(SelectController.fixAllOffer(count: 1)?.words, "Fix")
        XCTAssertEqual(SelectController.fixAllOffer(count: 4)?.words, "Fix all 4")
        XCTAssertEqual(SelectController.fixAllOffer(count: 4)?.key, "⏎")
        XCTAssertEqual(SelectController.fixAllOffer(count: 4)?.lit, true, "⏎ is the light")
        XCTAssertEqual(SelectController.undoOffer.key, "⌫")
        XCTAssertFalse(SelectController.undoOffer.lit, "the way back is quiet")
    }

    func testTheOfferStandsBetweenTheCaretAndTheApp() {
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        let offer = ModePill.Offer(key: "⏎", words: "Fix all 2", lit: true)
        let state = ModePill.State(mode: .editor, app: "Mail", icon: icon, listening: true, text: nil, offer: offer)
        let pieces = ModePill.layout(for: state)
        XCTAssertEqual(Array(pieces.suffix(3)), [.offer(offer), .appWord("Mail"), .appIcon])
        XCTAssertEqual(pieces.firstIndex(of: .caret).map { $0 + 1 }, pieces.firstIndex(of: .offer(offer)))
        let plain = ModePill.State(mode: .editor, app: "Mail", icon: icon, listening: true, text: nil)
        XCTAssertFalse(ModePill.layout(for: plain).contains { if case .offer = $0 { return true }; return false },
                       "no offer, no key on the pill")
        XCTAssertNotEqual(state, plain, "a changed offer redraws the pill")
    }
}
