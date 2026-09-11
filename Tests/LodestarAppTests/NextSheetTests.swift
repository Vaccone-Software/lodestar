import XCTest
@testable import lodestar
@testable import LodestarCore

/// The surfaces that joined the language last: the opening pill, the
/// meeting and the boot ask as voice cards, the lessons in the voice, the
/// chain guide's header as keys, the bars without legends, and one door
/// to the keys.
final class NextSheetTests: XCTestCase {

    // MARK: - The lessons

    func testEveryLessonSpeaksWithoutNamingAKeyInProse() {
        for entry in Curriculum.order {
            let card = WalkController.lessonCard(entry.lesson)
            for text in [card.sentence, card.detail] {
                XCTAssertFalse(text.contains("lode"), "\(entry.lesson): the keys are rows, never prose")
                XCTAssertFalse(text.contains("…"), "\(entry.lesson): nothing trails off")
                XCTAssertFalse(text.hasSuffix("."), "\(entry.lesson): the sentence does not end in a period")
            }
            XCTAssertFalse(card.sentence.hasSuffix("."))
            XCTAssertFalse(card.rows.isEmpty, "\(entry.lesson): every lesson teaches at least one key")
            let (position, total) = Curriculum.position(of: entry.lesson)
            XCTAssertTrue(card.detail.hasSuffix("Lesson \(position) of \(total)"),
                          "the count is quiet in the detail")
        }
    }

    func testTheCurriculumEndsOnTheSheetWithTheClipboardBeforeIt() {
        let lessons = Curriculum.order.map(\.lesson)
        XCTAssertEqual(lessons.first, .inside)
        XCTAssertEqual(lessons.suffix(2), [.clipboard, .sheet],
                       "the one gesture outside lode comes late; the map of everything comes last")
        XCTAssertEqual(Curriculum.order.map(\.day), Curriculum.order.map(\.day).sorted(),
                       "days climb with the order")
    }

    func testTheProvenNoteKnowsWhetherAnotherLessonFollows() {
        XCTAssertEqual(WalkController.provenNote(for: .inside).detail, "The next lesson arrives in a few days")
        XCTAssertEqual(WalkController.provenNote(for: .sheet).detail, "That was the last lesson")
        XCTAssertEqual(WalkController.provenNote(for: .sheet).sentence, "That gesture is learned")
    }

    // MARK: - The sheet

    func testABarGrowsToHoldItsKeysAndShrinksWithoutThem() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 200))
        let rows = NSStackView()
        rows.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: root.topAnchor, constant: 60),
            rows.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            rows.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
        ])
        let keys = BarKeys()
        keys.install(root: root, below: rows)
        XCTAssertEqual(keys.height, 0, "a bar owes its keys nothing while they are away")
        let view = keys.show(HotkeyEngine.askSections)
        XCTAssertNotNil(view)
        XCTAssertEqual(view?.alphaValue, 0, "built invisible; the glass grows first, then the keys fade in")
        XCTAssertTrue(keys.isShown)
        XCTAssertGreaterThan(keys.height, BarKeys.above + ModePill.inset,
                             "the bar grows by the columns and their air")
        let going = keys.hide()
        XCTAssertTrue(going === view, "the same view is handed back to fade out")
        XCTAssertFalse(keys.isShown)
        XCTAssertEqual(keys.height, 0)
    }

    func testThePillGrowsAroundItsUnmovedRow() {
        let pill = ModePill()
        pill.show(.init(mode: .scroll, app: "Slack", icon: nil, listening: false, text: nil))
        let row = pill.frame
        XCTAssertEqual(row.height, ModePill.height)
        XCTAssertFalse(pill.keysShown)
        // Motion is asynchronous on the glass; the reduced-motion path
        // sets the frame at once, so the geometry is checked through it.
        pill.toggleKeys(HotkeyEngine.launcherSections)
        XCTAssertTrue(pill.keysShown)
        let grown = pill.frameForContent()
        XCTAssertGreaterThan(grown.width, row.width, "the glass grows outward around the row")
        XCTAssertGreaterThan(grown.height, row.height)
        pill.hideKeys()
        XCTAssertFalse(pill.keysShown)
        let shrunk = pill.frameForContent()
        XCTAssertEqual(shrunk.size, row.size,
                       "the glass comes back to the row's own size: the departing keys must not hold it wide")
        pill.hide()
        XCTAssertFalse(pill.keysShown, "hidden with the pill")
    }

    func testTheMotionIsTheSystemsOwnAndNeverASpring() {
        XCTAssertLessThanOrEqual(KeysMotion.growSeconds, 0.35)
        XCTAssertLessThan(KeysMotion.shrinkSeconds, KeysMotion.growSeconds, "folding back is quicker")
        XCTAssertLessThan(KeysMotion.revealDelay, KeysMotion.growSeconds, "the glass leads, the words follow")
    }

    func testOneDoorToTheKeys() {
        // No sheet section anywhere offers a plain ? as a key, and every
        // bar's sheet ends on the keys that are the same everywhere.
        for sections in [HotkeyEngine.launcherSections, HotkeyEngine.askSections,
                         HotkeyEngine.commandsSections, HotkeyEngine.settingsSections] {
            for row in sections.flatMap(\.rows) {
                XCTAssertNotEqual(row.keys, ["?"], "a plain ? is a character, never a door")
            }
            XCTAssertEqual(sections.last?.header, "Everywhere")
        }
        XCTAssertTrue(HotkeyEngine.everywhereSection.rows.contains { $0.keys == ["lode", "?"] })
    }

    // MARK: - The pill's opening mode

    func testOpeningIsAModeOfThePill() {
        let state = ModePill.State(mode: .opening, app: "Slack", icon: nil, listening: false, text: nil)
        let pieces = ModePill.layout(for: state)
        XCTAssertEqual(pieces.first, .symbol("arrow.up.forward.app"))
        XCTAssertTrue(pieces.contains(.modeWord("Opening")))
        XCTAssertTrue(pieces.contains(.appWord("Slack")))
        XCTAssertLessThan(Actions.openingPatience, 0.5, "a running app's summon is instant and never shows it")
    }

    // MARK: - The bars

    func testNoBarCarriesALegend() throws {
        let sources = ["SearcherPanel", "WebBar", "CommandsBar"]
        for name in sources {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/lodestar/\(name).swift")
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains("esc close"), "\(name) keeps no legend; the keys are on the sheet")
            XCTAssertFalse(text.contains("FooterFade"), "\(name) has no legend to fade")
        }
    }
}
