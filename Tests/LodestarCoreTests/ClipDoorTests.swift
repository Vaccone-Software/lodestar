import XCTest
@testable import LodestarCore

/// The clip door as the grammar sees it: `E` in a card's actions opens
/// the card in the draft above the strip, the draft owns every unheld
/// key, and every way back returns to the strip or takes it down with
/// the door — never a paste, never the pasteboard.
final class ClipDoorGrammarTests: XCTestCase {
    private var core = EngineCore()
    private var world = WorldStub()

    override func setUp() {
        core = EngineCore()
        world = WorldStub()
    }

    private func press(_ key: String, held: Bool = false, shift: Bool = false,
                       command: Bool = false, option: Bool = false) -> [EngineEffect] {
        core.keyDown(key: key, held: held, shift: shift, command: command,
                     option: option, world: world)
    }

    /// The strip open and card A's actions open — from the row, or from
    /// the search band, where ⌥⌘A is the address.
    private func openPanel(searching: Bool = false) {
        _ = core.openPaste(world: world)
        if searching {
            _ = press("/")
            _ = press("a", command: true, option: true)
        } else {
            _ = press("a", command: true)
        }
    }

    private func openDoor(searching: Bool = false) {
        openPanel(searching: searching)
        _ = press("e")
    }

    func testEditOpensTheDoorAndLeavesTheStripStanding() {
        openPanel()
        XCTAssertEqual(press("e"), [.pastePanelAct(.edit), .pastePanelDismiss])
        XCTAssertEqual(core.state, .pasteDoor(searching: false))
    }

    func testTheDoorRemembersTheSearchItRodeInOn() {
        openPanel(searching: true)
        XCTAssertEqual(core.state, .pastePanel(searching: true))
        _ = press("e")
        XCTAssertEqual(core.state, .pasteDoor(searching: true))
        core.doorClosed()
        XCTAssertEqual(core.state, .paste(searching: true), "back to the search, not out of it")
    }

    func testDoorClosedIsANoOpAnywhereElse() {
        core.doorClosed()
        XCTAssertEqual(core.state, .idle)
        _ = core.openPaste(world: world)
        core.doorClosed()
        XCTAssertEqual(core.state, .paste(searching: false))
        _ = press("a", command: true)
        core.doorClosed()
        XCTAssertEqual(core.state, .pastePanel(searching: false))
    }

    /// The shell feeds the draft before the grammar sees a key; a key
    /// that reaches the grammar anyway is swallowed, not obeyed.
    func testUnheldKeysNeverActOnTheStripWhileTheDoorStands() {
        openDoor()
        for key in ["a", "s", "1", "return", "escape", "/", "space", "v"] {
            XCTAssertEqual(press(key), [], key)
            XCTAssertEqual(press(key, shift: true), [], "⇧\(key)")
            XCTAssertEqual(press(key, command: true), [], "⌘\(key)")
            XCTAssertEqual(core.state, .pasteDoor(searching: false), key)
        }
    }

    func testLodeDotFlashesInsteadOfOpeningAMicrophone() {
        openDoor()
        XCTAssertEqual(press(".", held: true), [.flash("the clipboard view has no microphone")])
        XCTAssertEqual(core.state, .pasteDoor(searching: false), "the door stands")
        XCTAssertEqual(press(".", held: true, shift: true), [],
                       "⇧. asks for the silence the door already has")
        XCTAssertEqual(core.state, .pasteDoor(searching: false))
    }

    func testALodeVerbClosesTheDoorTakesTheStripDownAndExecutes() {
        world.graph["s"] = .leaf
        openDoor()
        let effects = press("s", held: true)
        XCTAssertEqual(Array(effects.prefix(2)), [.pasteDoorClose(reason: "lode"), .exitPaste])
        XCTAssertTrue(effects.contains(.summonGraph(letters: ["s"], beside: false)),
                      "and the summon runs: \(effects)")
        XCTAssertEqual(core.state, .idle)
    }

    func testLodeEscapeClosesTheDoorAndTheStripAndRunsNothing() {
        openDoor()
        XCTAssertEqual(press("escape", held: true), [.pasteDoorClose(reason: "lode"), .exitPaste])
        XCTAssertEqual(core.state, .idle)
    }

    func testTheToggleClosesTheDoorAndTheStripTogether() {
        openDoor()
        XCTAssertEqual(core.openPaste(world: world), [.pasteDoorClose(reason: "toggle"), .exitPaste])
        XCTAssertEqual(core.state, .idle)
    }

    func testAClickElsewhereClosesTheDoorAndTheStrip() {
        openDoor()
        XCTAssertEqual(core.leavePaste(),
                       [.pasteDoorClose(reason: "click"), .pastePanelDismiss, .exitPaste])
        XCTAssertEqual(core.state, .idle)
    }

    func testACommandChordTheDraftDeclinedIsTheStripsRule() {
        openDoor()
        XCTAssertEqual(core.leaveDoor(reason: "command"),
                       [.pasteDoorClose(reason: "command"), .pastePanelDismiss, .exitPaste])
        XCTAssertEqual(core.state, .idle)
        XCTAssertEqual(core.leaveDoor(reason: "command"), [], "nothing to leave from idle")
        _ = core.openPaste(world: world)
        XCTAssertEqual(core.leaveDoor(reason: "command"), [], "and nothing from the strip alone")
        XCTAssertEqual(core.state, .paste(searching: false))
    }

    func testResetEndsTheDoorLikeEverythingElse() {
        openDoor()
        XCTAssertEqual(core.reset(), [.pasteDoorClose(reason: "reset"), .exitPaste])
        XCTAssertEqual(core.state, .idle)
    }

    func testTheOtherPanelKeysStillReturnToTheStrip() {
        openPanel()
        XCTAssertEqual(press("p"), [.pastePanelAct(.pin), .pastePanelDismiss])
        XCTAssertEqual(core.state, .paste(searching: false))
    }

    func testTheDoorIsNotIdleForTheDraftsOwnRouting() {
        openDoor()
        XCTAssertFalse(core.isIdle)
        XCTAssertFalse(core.isChain)
    }
}

/// How the door ends, decided without a store: the text as it was
/// against the text as it is, and which key ended it.
final class ClipDoorEndingTests: XCTestCase {
    func testUnchangedTextWritesNothingWhicheverKeyEndedIt() {
        XCTAssertEqual(Draft.clipOutcome(original: "a\nb", current: "a\nb", commit: true), .unchanged)
        XCTAssertEqual(Draft.clipOutcome(original: "a\nb", current: "a\nb", commit: false), .unchanged)
    }

    func testReturnWithChangedTextSavesToTheCard() {
        XCTAssertEqual(Draft.clipOutcome(original: "a", current: "ab", commit: true), .saved)
    }

    func testEscapeWithChangedTextKeepsItAsANewCard() {
        XCTAssertEqual(Draft.clipOutcome(original: "a", current: "ab", commit: false), .kept)
    }

    func testDeletingEverythingSavesNothing() {
        XCTAssertEqual(Draft.clipOutcome(original: "a", current: "", commit: true), .empty)
        XCTAssertEqual(Draft.clipOutcome(original: "a", current: "  \n", commit: false), .empty)
        XCTAssertEqual(Draft.clipOutcome(original: "", current: "", commit: true), .unchanged,
                       "an empty card left empty is unchanged, not emptied")
    }

    func testWhitespaceIsAChange() {
        XCTAssertEqual(Draft.clipOutcome(original: "a", current: "a ", commit: true), .saved)
    }

    func testTheDoorHasAName() {
        XCTAssertEqual(Draft.Door.clip.rawValue, "clip")
        XCTAssertEqual(Draft.Door(rawValue: "clip"), .clip)
        XCTAssertEqual(Draft.ClipOutcome.kept.rawValue, "kept")
    }
}

/// What a card says about its length, which cards can be opened, and
/// how a replacement lands in the list.
final class ClipboardLengthAndEditTests: XCTestCase {
    private func clip(_ id: String, kind: Clipboard.Kind = .text, preview: String = "x",
                      natives: [String] = [], others: [[String]] = [], pinned: Int? = nil,
                      lines: Int? = nil, characters: Int? = nil) -> Clipboard.Clip {
        Clipboard.Clip(id: id, kind: kind, created: Date(timeIntervalSince1970: 1_000_000),
                       sourceBundleID: "com.example", sourceAppName: "Example",
                       preview: preview, bytes: 10, nativeTypes: natives, otherItemTypes: others,
                       pinnedSlot: pinned, lines: lines, characters: characters)
    }

    func testCountsLinesAndCharacters() {
        XCTAssertEqual(Clipboard.counts(of: "").lines, 1)
        XCTAssertEqual(Clipboard.counts(of: "").characters, 0)
        XCTAssertEqual(Clipboard.counts(of: "a\nb\nc").lines, 3)
        XCTAssertEqual(Clipboard.counts(of: "a\nb\nc").characters, 5)
        XCTAssertEqual(Clipboard.counts(of: "héllo").characters, 5)
        XCTAssertEqual(Clipboard.counts(of: "trailing\n").lines, 2)
    }

    func testACardThatShowsAllOfItselfWearsNoBadge() {
        XCTAssertNil(Clipboard.lengthBadge(lines: 1, characters: 57))
        XCTAssertNil(Clipboard.lengthBadge(lines: 5, characters: 220))
        XCTAssertNil(Clipboard.lengthBadge(lines: nil, characters: nil))
        XCTAssertNil(Clipboard.lengthBadge(lines: 3, characters: nil))
    }

    func testProseAndCodeSayLines() {
        XCTAssertEqual(Clipboard.lengthBadge(lines: 6, characters: 30), "6 lines")
        XCTAssertEqual(Clipboard.lengthBadge(lines: 3, characters: 400), "3 lines")
        XCTAssertEqual(Clipboard.lengthBadge(lines: 1200, characters: 50_000), "1200 lines")
    }

    func testOneLongLineSaysCharacters() {
        XCTAssertEqual(Clipboard.lengthBadge(lines: 1, characters: 221), "221 chars")
        XCTAssertEqual(Clipboard.lengthBadge(lines: 1, characters: 1234), "1.2k chars")
        XCTAssertEqual(Clipboard.lengthBadge(lines: 1, characters: 2000), "2k chars")
        XCTAssertEqual(Clipboard.lengthBadge(lines: 1, characters: 99_949), "99.9k chars")
        XCTAssertEqual(Clipboard.lengthBadge(lines: 1, characters: 417_443), "417k chars")
    }

    func testAnUncountedCardIsJudgedByItsPreview() {
        let long = String(repeating: "word ", count: 100)
        XCTAssertEqual(Clipboard.lengthBadge(for: clip("a", preview: long)), "500 chars")
        XCTAssertNil(Clipboard.lengthBadge(for: clip("b", preview: "short")))
        XCTAssertNil(Clipboard.lengthBadge(for: clip("c", kind: .image, preview: long)),
                     "an image's caption is not its length")
        XCTAssertEqual(Clipboard.lengthBadge(for: clip("d", preview: "short", lines: 9, characters: 40)),
                       "9 lines", "the counts win when the card has them")
    }

    func testOnlyAPlainTextCardCanBeEdited() {
        XCTAssertTrue(clip("t").isEditable)
        XCTAssertTrue(clip("r", natives: ["public.rtf"]).isEditable, "rich text is still text")
        XCTAssertFalse(clip("i", kind: .image, natives: ["public.png"]).isEditable)
        XCTAssertFalse(clip("f", natives: [Clipboard.fileURLType]).isEditable,
                       "a copied file's text is its path")
        XCTAssertFalse(clip("m", others: [[]]).isEditable, "a copy of several things is not one text")
    }

    func testReplacingKeepsThePositionAndTheSlot() {
        let clips = [clip("new"), clip("mid", pinned: 2), clip("old")]
        let out = Clipboard.replacing(clips, id: "mid", with: clip("edited", preview: "edited"))
        XCTAssertEqual(out.map(\.id), ["new", "edited", "old"])
        XCTAssertEqual(out[1].pinnedSlot, 2, "the pin slot is the card's, not the text's")
        XCTAssertEqual(out[1].preview, "edited")
        XCTAssertEqual(out[0].pinnedSlot, nil)
    }

    func testReplacingNeverPinsAnUnpinnedCard() {
        let clips = [clip("a"), clip("b")]
        let out = Clipboard.replacing(clips, id: "b", with: clip("c", pinned: 4))
        XCTAssertNil(out[1].pinnedSlot, "the replacement's own slot is ignored")
    }

    func testReplacingAMissingCardChangesNothing() {
        let clips = [clip("a"), clip("b")]
        XCTAssertEqual(Clipboard.replacing(clips, id: "zzz", with: clip("c")), clips)
    }

    func testAnOldIndexDecodesWithoutTheCounts() throws {
        let json = """
        {"id":"abc","kind":"text","created":1000,"sourceBundleID":null,"sourceAppName":null,
         "preview":"hi","bytes":2,"nativeTypes":[]}
        """
        let decoded = try JSONDecoder().decode(Clipboard.Clip.self, from: Data(json.utf8))
        XCTAssertNil(decoded.lines)
        XCTAssertNil(decoded.characters)
        XCTAssertNil(Clipboard.lengthBadge(for: decoded))
        XCTAssertTrue(decoded.isEditable)
    }

    func testTheCountsRoundTrip() throws {
        let data = try JSONEncoder().encode(clip("a", lines: 7, characters: 300))
        let decoded = try JSONDecoder().decode(Clipboard.Clip.self, from: data)
        XCTAssertEqual(decoded.lines, 7)
        XCTAssertEqual(decoded.characters, 300)
    }
}

/// The search, measured at the strip's exit — never the query.
final class StripSearchMeasureTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func store() throws -> (ObservationStore, EventLog, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-measure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = EventLog(file: directory.appendingPathComponent("events.jsonl"))
        let store = ObservationStore(file: directory.appendingPathComponent("observations.json"), log: log)
        return (store, log, directory)
    }

    func testAPasteFromTheSearchRecordsWhatItAnsweredAndHowDeep() throws {
        let (store, log, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.pasted(app: "Slack", action: "pasted", source: "search", row: "plain",
                     rank: 0, typed: 4, seconds: 3, firstKey: 0.5,
                     matches: 3, visible: 9, recents: 40, depth: 17, at: start)
        let event = try XCTUnwrap(log.readAll().first)
        XCTAssertEqual(event.matches, 3)
        XCTAssertEqual(event.visible, 9)
        XCTAssertEqual(event.recents, 40)
        XCTAssertEqual(event.depth, 17)
        store.flush()
        let line = try String(contentsOf: log.file, encoding: .utf8)
        XCTAssertTrue(line.contains("\"depth\":17"))
        XCTAssertFalse(line.contains("query"), "never the query")
    }

    func testAnAbandonWithoutASearchRecordsNoMatches() throws {
        let (store, log, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.pasted(app: "Slack", action: "abandoned", source: nil, row: nil,
                     rank: nil, typed: 0, seconds: 2, firstKey: nil,
                     visible: 9, recents: 40, at: start)
        let event = try XCTUnwrap(log.readAll().first)
        XCTAssertNil(event.matches)
        XCTAssertNil(event.depth)
        XCTAssertEqual(event.visible, 9)
        XCTAssertEqual(event.recents, 40)
    }

    func testAnOldEventDecodesWithoutTheMeasures() throws {
        let json = """
        {"t":1700000000,"kind":"paste","app":"slack","action":"pasted","rank":0}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let event = try decoder.decode(ObservationEvent.self, from: Data(json.utf8))
        XCTAssertNil(event.matches)
        XCTAssertNil(event.visible)
        XCTAssertEqual(event.rank, 0)
    }
}
