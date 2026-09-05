import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The clip door, driven through the tap the way a hand drives it:
/// `⇧⌘V`, `⌘A`, `E` opens a card in the draft above the strip; `⏎`
/// saves to the card and `esc` steps back; neither touches the
/// pasteboard, and the strip is the only place a paste happens.
final class ClipDoorScenarioTests: XCTestCase {
    /// The strip open, a card's actions open, then the door.
    private func openDoor(_ stage: Stage, address: String = "a") {
        stage.openStrip()
        stage.chord(address, .maskCommand)
        stage.press("e")
    }

    /// The cursor to the end of the line, then a suffix typed.
    private func append(_ stage: Stage, _ keys: [String]) {
        stage.commandPress("right")
        for key in keys { stage.press(key) }
    }

    func testEditOpensTheCardSilentWithTheCursorAtTheTop() {
        let stage = Stage()
        let clip = stage.seedClip("hello\nworld")
        openDoor(stage)
        XCTAssertTrue(stage.draft.isOpen)
        XCTAssertEqual(stage.draft.editingClip?.id, clip.id)
        XCTAssertEqual(stage.draft.buffer.text, "hello\nworld")
        XCTAssertEqual(stage.draft.buffer.cursor, 0, "a card is read from the top")
        XCTAssertEqual(stage.draft.mode, .insert)
        XCTAssertEqual(stage.speech.listens, 0, "no microphone")
        XCTAssertTrue(stage.engine.strip.isVisible, "the strip waits beneath")
        XCTAssertTrue(stage.engine.strip.pinsHidden, "the pin column steps aside")
        XCTAssertEqual(stage.engine.grammarState, .pasteDoor(searching: false))
        XCTAssertEqual(stage.draft.state["door"] as? String, "clip")
    }

    func testReturnWithUnchangedTextWritesNothingAndReturnsToTheStrip() {
        let stage = Stage()
        let clip = stage.seedClip("unchanged")
        openDoor(stage)
        stage.press("return")
        XCTAssertFalse(stage.draft.isOpen)
        XCTAssertEqual(stage.engine.grammarState, .paste(searching: false))
        XCTAssertTrue(stage.engine.strip.isVisible)
        XCTAssertFalse(stage.engine.strip.pinsHidden, "the pins are back")
        XCTAssertEqual(stage.clipboard.history.clips.map(\.id), [clip.id])
        XCTAssertTrue(stage.pasteboard.isEmpty, "the door never touches the pasteboard")
        XCTAssertTrue(stage.posted.isEmpty)
        XCTAssertEqual(stage.stripPastes, 0)
        XCTAssertEqual(stage.lastDraft?.source, "clip")
        XCTAssertEqual(stage.lastDraft?.action, "unchanged")
        XCTAssertEqual(stage.lastDraft?.row, "return")
        XCTAssertEqual(stage.lastDraft?.app, "clipboard")
    }

    func testReturnWithChangedTextReplacesTheCardInPlace() {
        let stage = Stage()
        let older = stage.seedClip("alpha")
        let newer = stage.seedClip("bravo")
        openDoor(stage) // card A is the newest
        append(stage, ["space", "t", "w", "o"])
        stage.press("return")
        let clips = stage.clipboard.history.clips
        XCTAssertEqual(clips.count, 2, "replaced, not added")
        XCTAssertEqual(clips[0].preview, "bravo two")
        XCTAssertNotEqual(clips[0].id, newer.id, "the id is the content")
        XCTAssertEqual(clips[0].created, newer.created, "the same age")
        XCTAssertEqual(clips[0].sourceAppName, "Example", "the same source")
        XCTAssertEqual(clips[1].id, older.id, "the same position, the older card untouched")
        XCTAssertEqual(stage.clipboard.history.plainText(clips[0].id), "bravo two")
        XCTAssertEqual(clips[0].lines, 1)
        XCTAssertEqual(clips[0].characters, 9)
        XCTAssertTrue(stage.pasteboard.isEmpty)
        XCTAssertTrue(stage.posted.isEmpty)
        XCTAssertEqual(stage.engine.grammarState, .paste(searching: false))
        XCTAssertEqual(stage.engine.strip.shownRecents.map(\.preview), ["bravo two", "alpha"],
                       "the strip redrew the card in place")
        XCTAssertEqual(stage.hud.owner, .flash)
        XCTAssertEqual(stage.lastDraft?.action, "saved")
        XCTAssertEqual(stage.lastDraft?.row, "return")
    }

    func testThenTheLetterPastesTheEditedCard() {
        let stage = Stage()
        stage.seedClip("bravo")
        openDoor(stage)
        append(stage, ["x"])
        stage.press("return")
        stage.press("a")
        XCTAssertEqual(stage.stripPastes, 1, "the strip pastes, the door never did")
        XCTAssertEqual(stage.clipboard.pasteboard.string(forType: .string), "bravox")
        XCTAssertEqual(stage.engine.grammarState, .idle)
        XCTAssertEqual(stage.lastPaste?.action, "pasted")
    }

    func testTheReplacementKeepsThePinSlot() {
        let stage = Stage()
        let pinned = stage.seedClip("pinned text")
        XCTAssertTrue(stage.clipboard.history.pin(pinned.id))
        stage.seedClip("a recent")
        openDoor(stage, address: "1")
        append(stage, ["x"])
        stage.press("return")
        let clips = stage.clipboard.history.clips
        XCTAssertEqual(clips.first { $0.pinnedSlot == 1 }?.preview, "pinned textx")
        XCTAssertEqual(Clipboard.recents(clips).map(\.preview), ["a recent"], "no recent gained")
        XCTAssertEqual(clips.count, 2)
    }

    func testEscapeWithChangedTextKeepsANewCardAndLeavesTheOriginal() {
        let stage = Stage()
        let original = stage.seedClip("keep me", host: "github.com")
        openDoor(stage)
        append(stage, ["space", "x"])
        stage.press("escape")
        XCTAssertEqual(stage.draft.mode, .normal, "the first escape is vim's")
        XCTAssertTrue(stage.draft.isOpen)
        stage.press("escape")
        XCTAssertFalse(stage.draft.isOpen)
        let clips = stage.clipboard.history.clips
        XCTAssertEqual(clips.map(\.preview), ["keep me x", "keep me"])
        XCTAssertEqual(clips[1].id, original.id, "the original stands")
        XCTAssertEqual(clips[0].sourceHost, "github.com", "the edit carries where the text came from")
        XCTAssertEqual(stage.clipboard.history.plainText(clips[0].id), "keep me x")
        XCTAssertTrue(stage.pasteboard.isEmpty)
        XCTAssertTrue(stage.posted.isEmpty)
        XCTAssertEqual(stage.engine.grammarState, .paste(searching: false))
        XCTAssertTrue(stage.engine.strip.isVisible)
        XCTAssertEqual(stage.hud.owner, .flash)
        XCTAssertEqual(stage.lastDraft?.action, "kept")
        XCTAssertEqual(stage.lastDraft?.row, "escape")
    }

    func testEscapeWithUnchangedTextLeavesNoTrace() {
        let stage = Stage()
        let clip = stage.seedClip("read only")
        openDoor(stage)
        stage.press("right")
        stage.press("down")
        stage.press("escape")
        stage.press("escape")
        XCTAssertFalse(stage.draft.isOpen)
        XCTAssertEqual(stage.clipboard.history.clips.map(\.id), [clip.id])
        XCTAssertTrue(stage.pasteboard.isEmpty)
        XCTAssertEqual(stage.lastDraft?.action, "unchanged")
        XCTAssertEqual(stage.lastDraft?.row, "escape")
    }

    func testDeletingEverythingSavesNothing() {
        let stage = Stage()
        let clip = stage.seedClip("gone")
        openDoor(stage)
        stage.commandPress("a")
        stage.press("d")
        XCTAssertEqual(stage.draft.buffer.text, "")
        stage.press("return")
        XCTAssertFalse(stage.draft.isOpen)
        XCTAssertEqual(stage.clipboard.history.clips.map(\.id), [clip.id], "the card stands")
        XCTAssertEqual(stage.clipboard.history.plainText(clip.id), "gone")
        XCTAssertEqual(stage.lastDraft?.action, "empty")
        XCTAssertEqual(stage.hud.owner, .flash)
    }

    func testTheVimVerbsWorkOnTheCard() {
        let stage = Stage()
        stage.seedClip("one two three")
        openDoor(stage)
        stage.press("escape")
        stage.press("d")
        stage.press("w")
        XCTAssertEqual(stage.draft.buffer.text, "two three", "dw at the top")
        stage.press("return")
        XCTAssertEqual(stage.clipboard.history.clips.first?.preview, "two three")
        XCTAssertEqual(stage.lastDraft?.action, "saved")
    }

    func testLodeDotFlashesAndOpensNoMicrophone() {
        let stage = Stage()
        stage.seedClip("silent")
        openDoor(stage)
        stage.lode(".")
        XCTAssertTrue(stage.draft.isOpen)
        XCTAssertEqual(stage.draft.editingClip?.preview, "silent")
        XCTAssertEqual(stage.speech.listens, 0)
        XCTAssertEqual(stage.hud.owner, .flash)
        XCTAssertEqual(stage.engine.grammarState, .pasteDoor(searching: false))
        stage.lode(".", shift: true)
        XCTAssertTrue(stage.draft.isOpen)
        XCTAssertEqual(stage.speech.listens, 0)
        XCTAssertEqual(stage.draft.mode, .insert)
    }

    func testALodeVerbClosesTheDoorKeepsTheEditAndExitsTheStrip() {
        let stage = Stage()
        stage.seedClip("before")
        openDoor(stage)
        append(stage, ["space", "s"])
        stage.lode("s")
        XCTAssertFalse(stage.draft.isOpen)
        XCTAssertFalse(stage.engine.strip.isVisible)
        XCTAssertEqual(stage.engine.grammarState, .idle)
        XCTAssertEqual(stage.actions.summoned.map { $0.target.label }, ["Slack"])
        XCTAssertEqual(stage.clipboard.history.clips.map(\.preview), ["before s", "before"],
                       "the edit was kept")
        XCTAssertEqual(stage.lastDraft?.action, "kept")
        XCTAssertEqual(stage.lastDraft?.row, "lode")
        XCTAssertEqual(stage.lastPaste?.action, "acted")
        XCTAssertEqual(stage.lastPaste?.row, "edit")
    }

    func testTheToggleClosesDoorAndStripTogether() {
        let stage = Stage()
        stage.seedClip("toggle")
        openDoor(stage)
        stage.openStrip()
        XCTAssertFalse(stage.draft.isOpen)
        XCTAssertFalse(stage.engine.strip.isVisible)
        XCTAssertEqual(stage.engine.grammarState, .idle)
        XCTAssertEqual(stage.lastDraft?.row, "toggle")
        XCTAssertEqual(stage.clipboard.history.clips.count, 1, "nothing changed, nothing kept")
    }

    func testACommandChordTheDraftDeclinesClosesBothAndIsSwallowed() {
        let stage = Stage()
        stage.seedClip("chord")
        openDoor(stage)
        append(stage, ["x"])
        XCTAssertTrue(stage.commandPress("w"),
                      "swallowed: a ⌘W that reached the app would close its window")
        XCTAssertFalse(stage.draft.isOpen)
        XCTAssertFalse(stage.engine.strip.isVisible)
        XCTAssertEqual(stage.engine.grammarState, .idle)
        XCTAssertEqual(stage.lastDraft?.row, "command")
        XCTAssertEqual(stage.clipboard.history.clips.map(\.preview), ["chordx", "chord"], "kept")
    }

    func testTheEditorsCommandChordsStayInTheDoor() {
        let stage = Stage()
        stage.seedClip("abc")
        openDoor(stage)
        XCTAssertTrue(stage.commandPress("a"))
        XCTAssertEqual(stage.draft.mode, .normal, "⌘A selected all inside the door")
        XCTAssertTrue(stage.draft.isOpen)
        XCTAssertEqual(stage.engine.grammarState, .pasteDoor(searching: false))
        XCTAssertTrue(stage.commandPress("z"))
        XCTAssertTrue(stage.draft.isOpen)
    }

    func testPlainKeysNeverReachTheStripOrTheApp() {
        let stage = Stage()
        stage.seedClip("card")
        stage.seedClip("other")
        openDoor(stage)
        XCTAssertTrue(stage.press("s"), "swallowed")
        XCTAssertEqual(stage.draft.buffer.text, "sother", "typed into the card, not an address")
        XCTAssertEqual(stage.stripPastes, 0)
        XCTAssertTrue(stage.press("1"))
        XCTAssertEqual(stage.stripPastes, 0)
        XCTAssertEqual(stage.engine.grammarState, .pasteDoor(searching: false))
    }

    func testTheDoorOpenedFromASearchReturnsToIt() {
        let stage = Stage()
        stage.seedClip("needle")
        stage.seedClip("haystack")
        stage.openStrip()
        stage.press("/")
        stage.press("n")
        stage.press("e")
        XCTAssertEqual(stage.engine.strip.shownRecents.map(\.preview), ["needle"])
        stage.chord("a", [.maskCommand, .maskAlternate])
        XCTAssertEqual(stage.engine.grammarState, .pastePanel(searching: true))
        stage.press("e")
        XCTAssertEqual(stage.engine.grammarState, .pasteDoor(searching: true))
        XCTAssertEqual(stage.draft.buffer.text, "needle")
        stage.press("return")
        XCTAssertEqual(stage.engine.grammarState, .paste(searching: true),
                       "the search band is back as it was")
        XCTAssertEqual(stage.engine.strip.shownRecents.map(\.preview), ["needle"])
    }

    func testEditIsOfferedForTextCardsOnlyAndSitsWithTheBenignVerbs() {
        func card(_ kind: Clipboard.Kind, natives: [String] = []) -> Clipboard.Clip {
            Clipboard.Clip(id: "x", kind: kind, created: Date(), sourceBundleID: nil,
                           sourceAppName: nil, preview: "x", bytes: 1, nativeTypes: natives)
        }
        XCTAssertEqual(HotkeyEngine.panelActions(for: card(.text)).map(\.key), ["P", "E", "D"])
        XCTAssertEqual(HotkeyEngine.panelActions(for: card(.image, natives: ["public.png"])).map(\.key),
                       ["P", "S", "D"])
        XCTAssertEqual(HotkeyEngine.panelActions(for: card(.text, natives: [Clipboard.fileURLType])).map(\.key),
                       ["P", "D"])
        let edit = HotkeyEngine.panelActions(for: card(.text)).first { $0.key == "E" }
        XCTAssertEqual(edit?.label, "Edit")
        XCTAssertEqual(edit?.isDestructive, false)
    }

    func testTooMuchTextIsRefusedAndTheStripStays() {
        let stage = Stage()
        stage.seedClip(String(repeating: "x", count: DraftController.clipCap + 1))
        openDoor(stage)
        XCTAssertFalse(stage.draft.isOpen)
        XCTAssertEqual(stage.hud.owner, .flash)
        XCTAssertEqual(stage.engine.grammarState, .paste(searching: false))
        XCTAssertTrue(stage.engine.strip.isVisible)
        XCTAssertFalse(stage.engine.strip.pinsHidden)
        stage.press("escape")
        XCTAssertEqual(stage.engine.grammarState, .idle, "and the strip still closes cleanly")
    }

    func testACardAtTheCapOpens() {
        let stage = Stage()
        stage.seedClip(String(repeating: "y", count: DraftController.clipCap))
        openDoor(stage)
        XCTAssertTrue(stage.draft.isOpen)
        XCTAssertEqual(stage.draft.buffer.count, DraftController.clipCap)
        stage.press("escape")
        stage.press("escape")
        XCTAssertFalse(stage.draft.isOpen)
    }

    func testAnOpenDraftRefusesTheDoor() {
        let stage = Stage()
        stage.seedClip("card")
        stage.lode(".")
        XCTAssertTrue(stage.draft.isOpen)
        openDoor(stage)
        XCTAssertNil(stage.draft.editingClip, "the draft that was open stays the draft")
        XCTAssertTrue(stage.draft.isOpen)
        XCTAssertEqual(stage.engine.grammarState, .paste(searching: false))
        XCTAssertEqual(stage.hud.owner, .flash)
    }

    func testTheCardSaysWhenItIsLong() {
        let stage = Stage()
        let long = stage.seedClip((1...12).map { "line \($0)" }.joined(separator: "\n"))
        let wide = stage.seedClip(String(repeating: "w", count: 300))
        let short = stage.seedClip("short")
        let uncounted = stage.seedClip((1...7).map { "l\($0)" }.joined(separator: "\n"), counted: false)
        stage.openStrip()
        let badges = stage.engine.strip.shownBadges
        XCTAssertEqual(badges[long.id], "12 lines")
        XCTAssertEqual(badges[wide.id], "300 chars")
        XCTAssertNil(badges[short.id])
        XCTAssertEqual(badges[uncounted.id], "7 lines", "judged by its preview until counted")
    }

    func testTheStripMeasuresItsSearch() {
        let stage = Stage()
        stage.seedClip("needle")
        stage.seedClip("haystack")
        stage.openStrip()
        stage.press("/")
        stage.press("n")
        stage.press("e")
        stage.press("escape")
        stage.press("escape")
        XCTAssertEqual(stage.engine.grammarState, .idle)
        XCTAssertEqual(stage.lastPaste?.action, "abandoned")
        XCTAssertEqual(stage.lastPaste?.typed, 2)
        XCTAssertEqual(stage.lastPaste?.matches, 1, "what the last query answered")
        XCTAssertEqual(stage.lastPaste?.visible, 2, "what was on show at the end")
        XCTAssertEqual(stage.lastPaste?.recents, 2)
        XCTAssertNil(stage.lastPaste?.depth)
    }

    func testAnAbandonWithoutASearchRecordsNoMatches() {
        let stage = Stage()
        stage.seedClip("one")
        stage.openStrip()
        stage.press("escape")
        XCTAssertEqual(stage.lastPaste?.action, "abandoned")
        XCTAssertNil(stage.lastPaste?.matches)
        XCTAssertEqual(stage.lastPaste?.visible, 1)
        XCTAssertEqual(stage.lastPaste?.recents, 1)
    }

    func testAPasteFromTheSearchRecordsHowDeepTheCardWas() {
        let stage = Stage()
        stage.seedClip("needle")
        stage.seedClip("haystack")
        stage.seedClip("hay")
        stage.openStrip()
        stage.press("/")
        stage.press("n")
        stage.press("e")
        stage.press("return")
        XCTAssertEqual(stage.stripPastes, 1)
        XCTAssertEqual(stage.lastPaste?.action, "pasted")
        XCTAssertEqual(stage.lastPaste?.source, "search")
        XCTAssertEqual(stage.lastPaste?.depth, 2, "third from the top")
        XCTAssertEqual(stage.lastPaste?.matches, 1)
        XCTAssertEqual(stage.lastPaste?.recents, 3)
    }

    func testAPasteFromTheRowRecordsNoDepth() {
        let stage = Stage()
        stage.seedClip("one")
        stage.seedClip("two")
        stage.openStrip()
        stage.press("s")
        XCTAssertEqual(stage.lastPaste?.rank, 1)
        XCTAssertNil(stage.lastPaste?.depth)
        XCTAssertEqual(stage.lastPaste?.visible, 2)
    }

    func testTheDoorStashesNothing() {
        let stage = Stage()
        var stashed: [String?] = []
        stage.draft.stash = { stashed.append($0) }
        stage.seedClip("card")
        openDoor(stage)
        append(stage, ["x"])
        stage.clock.advance(by: 1)
        XCTAssertTrue(stashed.compactMap { $0 }.isEmpty, "a stash would come back through the pasteboard")
        stage.press("return")
    }
}

/// The panel with a card in it: as tall as the text asks up to the
/// display, as wide as its longest line asks, standing above the
/// strip's row, the card on the register line and no microphone.
final class ClipDoorPanelTests: XCTestCase {
    private func view(_ text: String, card: Bool = true, editor: Vim.Mode = .insert) -> DraftView {
        var view = DraftView(buffer: Draft.Buffer(text: text, cursor: 0), mode: .insert,
                             editor: editor, speech: nil,
                             destination: card ? nil : ("Notes", nil), replacing: false)
        if card {
            view.card = DraftView.Card(name: "Brave Browser", icon: nil, detail: "github.com · 3m ago")
            view.standsAbove = ClipboardStrip.rowHeight
        }
        return view
    }

    func testALongCardGrowsThePanelToTheDisplay() {
        let panel = DraftPanel()
        defer { panel.hide() }
        let text = (1...200).map { "line \($0)" }.joined(separator: "\n")
        panel.show(view(text))
        let screen = ActivePolicy.presentationFrame
        XCTAssertGreaterThan(panel.frame.height, screen.height * 0.4 + 60, "past the old forty percent")
        XCTAssertLessThanOrEqual(panel.frame.maxY, screen.maxY - 22 + 1, "and never past the margin")
        XCTAssertEqual(panel.frame.minY, screen.minY + 22 + ClipboardStrip.rowHeight, accuracy: 0.5,
                       "standing above the strip's row")
    }

    func testAShortCardStaysShort() {
        let panel = DraftPanel()
        defer { panel.hide() }
        panel.show(view("two\nlines"))
        XCTAssertLessThan(panel.frame.height, 200)
    }

    func testTheDraftsOwnDoorsGrowTheSameWayFromTheBottomMargin() {
        let panel = DraftPanel()
        defer { panel.hide() }
        let text = (1...200).map { "line \($0)" }.joined(separator: "\n")
        panel.show(view(text, card: false))
        let screen = ActivePolicy.presentationFrame
        XCTAssertGreaterThan(panel.frame.height, screen.height * 0.4 + 60)
        XCTAssertEqual(panel.frame.minY, screen.minY + 22, accuracy: 0.5)
    }

    func testProseKeepsTheDraftsWidthAndCodeWidensToTheScreen() {
        let panel = DraftPanel()
        let screen = ActivePolicy.presentationFrame
        XCTAssertEqual(panel.width(for: "short"), 720)
        XCTAssertEqual(panel.width(for: (1...50).map { "line \($0)" }.joined(separator: "\n")), 720)
        let code = String(repeating: "let value = compute(input) ", count: 4)
        let wide = panel.width(for: code)
        XCTAssertGreaterThan(wide, 720)
        XCTAssertLessThanOrEqual(wide, screen.width - 44)
        XCTAssertEqual(panel.width(for: String(repeating: "x", count: 5000)), screen.width - 44,
                       "never past the screen")
    }

    func testTheWidthAskedForIsTheWidthDrawn() {
        let panel = DraftPanel()
        defer { panel.hide() }
        var wide = view(String(repeating: "let value = compute(input) ", count: 4))
        wide.width = panel.width(for: wide.buffer.text)
        panel.show(wide)
        XCTAssertEqual(panel.frame.width, wide.width!, accuracy: 0.5)
        panel.show(view("short"))
        XCTAssertEqual(panel.frame.width, 720, accuracy: 0.5)
    }

    func testTheRegisterLineNamesTheCardAndDrawsNoMicrophone() {
        let panel = DraftPanel()
        defer { panel.hide() }
        panel.show(view("x"))
        XCTAssertEqual(panel.registerText, "Brave Browser")
        XCTAssertEqual(panel.registerDetail, "github.com · 3m ago")
        XCTAssertFalse(panel.micVisible)
        XCTAssertTrue(panel.footerText.hasPrefix("⏎ save to the card"), panel.footerText)
        panel.show(view("x", editor: .normal))
        XCTAssertTrue(panel.footerText.contains("esc back to the clipboard"), panel.footerText)
        panel.show(view("x", editor: .visual(line: false)))
        XCTAssertTrue(panel.footerText.hasPrefix("⏎ save to the card"), panel.footerText)
    }

    func testTheDraftsOwnDoorsStillSayPaste() {
        let panel = DraftPanel()
        defer { panel.hide() }
        panel.show(view("x", card: false))
        XCTAssertTrue(panel.micVisible)
        XCTAssertEqual(panel.registerText, "Notes")
        XCTAssertTrue(panel.footerText.hasPrefix("⏎ paste"), panel.footerText)
        panel.show(view("x", card: false, editor: .normal))
        XCTAssertTrue(panel.footerText.contains("esc close, kept in the clipboard"), panel.footerText)
    }
}

/// The store's half of the door: a replacement lands on disk before it
/// lands in the index, the old files go, and old cards learn their
/// counts.
final class ClipboardStoreEditTests: XCTestCase {
    private var directory: URL!
    private var store: ClipboardStore!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-store-\(UUID().uuidString)", isDirectory: true)
        store = ClipboardStore(root: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func seed(_ text: String, counted: Bool = true) -> Clipboard.Clip {
        let data = Data(text.utf8)
        let id = ClipboardStore.identity(for: data)
        let counts = counted ? Clipboard.counts(of: text) : nil
        store.record(id: id, kind: .text, items: [.init(plain: data, natives: [])],
                     imageData: nil, preview: Clipboard.preview(of: text),
                     sourceBundleID: "com.example", sourceAppName: "Example", sourceHost: "example.com",
                     lines: counts?.lines, characters: counts?.characters)
        store.flushIO()
        return store.clips.first { $0.id == id }!
    }

    func testReplaceWritesTheFileFirstAndDropsTheOld() {
        let clip = seed("old text")
        let replaced = store.replace(clip, withText: "new text")
        XCTAssertNotNil(replaced)
        XCTAssertEqual(store.plainText(replaced!.id), "new text", "on disk before the index changed")
        XCTAssertEqual(store.clips.map(\.id), [replaced!.id])
        XCTAssertEqual(replaced!.created, clip.created)
        XCTAssertEqual(replaced!.sourceHost, "example.com")
        XCTAssertEqual(replaced!.lines, 1)
        XCTAssertEqual(replaced!.characters, 8)
        XCTAssertEqual(replaced!.bytes, 8)
        store.flushIO()
        XCTAssertNil(store.plainData(clip.id), "the old card's file is gone")
    }

    func testReplaceWithTheSameTextIsANoOp() {
        let clip = seed("same")
        let replaced = store.replace(clip, withText: "same")
        XCTAssertEqual(replaced?.id, clip.id)
        XCTAssertEqual(store.clips.map(\.id), [clip.id])
        XCTAssertEqual(store.plainText(clip.id), "same")
    }

    func testReplaceOfAMissingCardDoesNothing() {
        let clip = seed("here")
        store.delete(clip.id)
        XCTAssertNil(store.replace(clip, withText: "edited"))
        XCTAssertTrue(store.clips.isEmpty)
    }

    func testReplaceKeepsTheSlotAndThePosition() {
        let older = seed("older")
        let pinned = seed("pinned")
        XCTAssertTrue(store.pin(pinned.id))
        let newest = seed("newest")
        let replaced = store.replace(pinned, withText: "pinned edited")!
        XCTAssertEqual(replaced.pinnedSlot, 1)
        XCTAssertEqual(store.clips.map(\.id), [newest.id, replaced.id, older.id])
    }

    func testFileEditPutsANewCardOnTopWithTheOriginalsSource() {
        let original = seed("original")
        let kept = store.fileEdit(from: original, text: "original edited")!
        XCTAssertEqual(store.clips.map(\.id), [kept.id, original.id])
        XCTAssertEqual(kept.sourceHost, "example.com")
        XCTAssertEqual(kept.sourceAppName, "Example")
        XCTAssertNil(kept.pinnedSlot)
        XCTAssertEqual(store.plainText(kept.id), "original edited")
        XCTAssertEqual(store.plainText(original.id), "original", "the original is untouched")
    }

    func testFileEditOfTextAlreadyInTheHistoryPromotesThatCard() {
        let existing = seed("twin")
        let other = seed("other")
        let kept = store.fileEdit(from: other, text: "twin")!
        XCTAssertEqual(kept.id, existing.id, "the id is the content")
        XCTAssertEqual(store.clips.map(\.id), [existing.id, other.id])
    }

    func testFileEditOfNothingKeepsNothing() {
        let clip = seed("x")
        XCTAssertNil(store.fileEdit(from: clip, text: ""))
        XCTAssertEqual(store.clips.count, 1)
    }

    func testOldCardsLearnTheirCounts() {
        let old = seed("a\nb\nc\nd\ne\nf\ng", counted: false)
        XCTAssertNil(store.clips.first?.lines)
        let done = expectation(description: "counted")
        store.backfillCounts { done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(store.clips.first { $0.id == old.id }?.lines, 7)
        XCTAssertEqual(store.clips.first { $0.id == old.id }?.characters, 13)
        XCTAssertEqual(Clipboard.lengthBadge(for: store.clips.first!), "7 lines")
    }

    func testBackfillLeavesCountedCardsAndImagesAlone() {
        seed("counted\nalready")
        let done = expectation(description: "counted")
        store.backfillCounts { done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(store.clips.first?.lines, 2)
    }

    func testTheCountsSurviveAReload() {
        let clip = seed("one\ntwo")
        store.saveNow()
        store.flushIO()
        let reloaded = ClipboardStore(root: directory)
        XCTAssertEqual(reloaded.clips.first { $0.id == clip.id }?.lines, 2)
        XCTAssertEqual(reloaded.clips.first { $0.id == clip.id }?.characters, 7)
    }
}
