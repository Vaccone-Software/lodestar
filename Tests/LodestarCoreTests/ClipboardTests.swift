import XCTest
@testable import LodestarCore

final class ClipboardTests: XCTestCase {
    private func clip(_ id: String, minutesAgo: Int = 0, bytes: Int = 100,
                      preview: String = "", pinned: Int? = nil) -> Clipboard.Clip {
        Clipboard.Clip(id: id, kind: .text,
                       created: Date(timeIntervalSince1970: 1_000_000 - Double(minutesAgo) * 60),
                       sourceBundleID: "com.example", sourceAppName: "Example",
                       preview: preview.isEmpty ? id : preview, bytes: bytes, pinnedSlot: pinned)
    }

    private func refusal(types: [String] = [], app: String? = nil, text: String? = "hello",
                        bytes: Int = 10, apps: Set<String> = [], patterns: [String] = [],
                        maxItemBytes: Int = 20_000_000) -> Clipboard.Refusal? {
        Clipboard.refusal(types: types, sourceBundleID: app, text: text, bytes: bytes,
                          excludedApps: apps, excludedPatterns: patterns,
                          maxItemBytes: maxItemBytes)
    }

    // MARK: - What may be recorded

    /// The one test that must never regress: a password manager marks its
    /// clip concealed so tools like this look away. Recording it once is a
    /// breach that cannot be taken back.
    func testConcealedContentIsNeverRecorded() {
        for marker in Clipboard.refusedTypes {
            XCTAssertEqual(refusal(types: ["public.utf8-plain-text", marker]),
                           .concealed(marker), "\(marker) must be refused")
        }
    }

    func testConcealedIsJudgedBeforeAnythingElse() {
        // Even when every other rule would have admitted it.
        XCTAssertEqual(refusal(types: ["org.nspasteboard.ConcealedType"], text: "fine", bytes: 1),
                       .concealed("org.nspasteboard.ConcealedType"))
    }

    func testExcludedAppsAreRefusedCaseInsensitively() {
        XCTAssertEqual(refusal(app: "com.Example.Bank", apps: ["com.example.bank"]),
                       .excludedApp("com.example.bank"))
        XCTAssertNil(refusal(app: "com.example.notes", apps: ["com.example.bank"]))
    }

    func testExcludedPatternsMatchSubstringsCaseInsensitively() {
        XCTAssertEqual(refusal(text: "https://www.instagram.com/reel/abc123", patterns: ["instagram.com"]),
                       .excludedPattern("instagram.com"))
        XCTAssertEqual(refusal(text: "HTTPS://INSTAGRAM.COM/reel", patterns: ["instagram.com"]),
                       .excludedPattern("instagram.com"))
        XCTAssertNil(refusal(text: "https://example.com", patterns: ["instagram.com"]),
                     "an unrelated site from the same browser still records")
    }

    func testOversizeAndEmptyAreRefused() {
        XCTAssertEqual(refusal(bytes: 50_000_000, maxItemBytes: 20_000_000), .tooLarge(50_000_000))
        XCTAssertEqual(refusal(text: "   \n ", bytes: 0), .empty)
        XCTAssertNil(refusal(text: "   ", bytes: 4096), "whitespace with real bytes is an image or a native form")
    }

    func testPreviewCollapsesAndBounds() {
        XCTAssertEqual(Clipboard.preview(of: "  hello\r\nworld  "), "hello\nworld")
        XCTAssertEqual(Clipboard.preview(of: String(repeating: "x", count: 5000)).count, 2000)
    }

    // MARK: - Pins are slots, not a list

    func testNewPinTakesTheLowestFreeSlot() {
        XCTAssertEqual(Clipboard.lowestFreeSlot(taken: []), 1)
        XCTAssertEqual(Clipboard.lowestFreeSlot(taken: [1]), 2)
        XCTAssertEqual(Clipboard.lowestFreeSlot(taken: [1, 3]), 2, "the hole is refilled before the end")
        XCTAssertNil(Clipboard.lowestFreeSlot(taken: Set(1...Clipboard.pinSlots)), "full")
    }

    /// The property the whole pin design rests on: unpinning must not
    /// renumber the survivors, or a trained gesture silently changes meaning.
    func testUnpinningLeavesAHoleAndNeverRenumbers() {
        let clips = [clip("a", pinned: 1), clip("b", pinned: 2), clip("c", pinned: 3)]
        let afterUnpinningTwo = clips.filter { $0.id != "b" }
        XCTAssertEqual(Clipboard.pins(afterUnpinningTwo).map(\.pinnedSlot), [1, 3])
        XCTAssertEqual(Clipboard.lowestFreeSlot(taken: [1, 3]), 2)
    }

    func testPinsSortBySlotAndLeaveTheRecentsAlone() {
        let clips = [clip("loose"), clip("c", pinned: 3), clip("a", pinned: 1)]
        XCTAssertEqual(Clipboard.pins(clips).map(\.id), ["a", "c"])
        XCTAssertEqual(Clipboard.recents(clips).map(\.id), ["loose"],
                       "a pinned clip never also occupies a recent card")
    }

    // MARK: - Copies reorder; pastes do not

    func testCopyingTheSameContentAgainMovesItToTheTop() {
        let existing = [clip("new", minutesAgo: 0), clip("old", minutesAgo: 10)]
        let merged = Clipboard.merging(existing, with: clip("old", minutesAgo: -1))
        XCTAssertEqual(merged.map(\.id), ["old", "new"])
        XCTAssertEqual(merged.count, 2, "a re-copy collapses, it does not duplicate")
    }

    func testRecopyingAPinnedClipKeepsItsSlot() {
        let existing = [clip("sig", pinned: 2)]
        let merged = Clipboard.merging(existing, with: clip("sig", minutesAgo: -1))
        XCTAssertEqual(merged.first?.pinnedSlot, 2, "a re-copy must not silently unpin")
    }

    // MARK: - Retention

    func testTrimDropsOldestUntilUnderTheByteCeiling() {
        let clips = [clip("new", minutesAgo: 0, bytes: 400),
                     clip("mid", minutesAgo: 10, bytes: 400),
                     clip("old", minutesAgo: 20, bytes: 400)]
        XCTAssertEqual(Clipboard.trim(clips, maxBytes: 900, maxItems: 100), ["old"])
        XCTAssertEqual(Clipboard.trim(clips, maxBytes: 500, maxItems: 100), ["old", "mid"])
        XCTAssertEqual(Clipboard.trim(clips, maxBytes: 5000, maxItems: 100), [])
    }

    func testPinsAreNeverTrimmedButStillCountTowardTheCeiling() {
        let clips = [clip("pin", minutesAgo: 99, bytes: 800, pinned: 1),
                     clip("loose", minutesAgo: 0, bytes: 400)]
        let doomed = Clipboard.trim(clips, maxBytes: 900, maxItems: 100)
        XCTAssertEqual(doomed, ["loose"], "the loose clip absorbs the overage the pin caused")
        XCTAssertFalse(doomed.contains("pin"))
    }

    func testItemGuardrailTrimsEvenWhenBytesAreFine() {
        let clips = (0..<10).map { clip("c\($0)", minutesAgo: $0, bytes: 1) }
        let doomed = Clipboard.trim(clips, maxBytes: 1_000_000, maxItems: 4)
        XCTAssertEqual(doomed, ["c4", "c5", "c6", "c7", "c8", "c9"], "oldest first")
    }

    // MARK: - Search

    func testSearchMatchesPreviewSubstringsAndSkipsPins() {
        let clips = [clip("a", preview: "Hello World"), clip("b", preview: "goodbye"),
                     clip("p", preview: "Hello pinned", pinned: 1)]
        XCTAssertEqual(Clipboard.search(clips, query: "hello").map(\.id), ["a"])
        XCTAssertEqual(Clipboard.search(clips, query: "  ").map(\.id), ["a", "b"], "empty query is the plain list")
    }
}

/// The paste-mode grammar: a mode, not a hold — the cards on screen are what
/// make it unforgettable, and paging or searching needs both hands free.
final class PasteModeTests: XCTestCase {
    var core = EngineCore()
    var world = WorldStub()

    override func setUp() {
        core = EngineCore()
        world = WorldStub()
    }

    private func open() { _ = core.openPaste(world: world) }
    private func press(_ key: String, held: Bool = false,
                       shift: Bool = false, command: Bool = false) -> [EngineEffect] {
        core.keyDown(key: key, held: held, shift: shift, command: command, world: world)
    }

    func testTriggerOpensAndTogglesShut() {
        XCTAssertEqual(core.openPaste(world: world), [.hideBars, .enterPaste])
        XCTAssertEqual(core.state, .paste(searching: false))
        XCTAssertEqual(core.openPaste(world: world), [.exitPaste], "⇧⌘V again closes it")
        XCTAssertEqual(core.state, .idle)
    }

    func testNothingCopiedYetStaysIdle() {
        world.pasteAvailable = false
        XCTAssertEqual(core.openPaste(world: world), [.flash("⌂ nothing copied yet")])
        XCTAssertEqual(core.state, .idle)
    }

    /// The label names the card; the modifier names the verb.
    func testLabelPastesPlainAndShiftPastesAsCopied() {
        open()
        XCTAssertEqual(press("a"), [.pasteRecent(label: "a", action: .plain), .exitPaste])
        XCTAssertEqual(core.state, .idle)
        open()
        XCTAssertEqual(press("f", shift: true), [.pasteRecent(label: "f", action: .native), .exitPaste])
    }

    func testDigitsAddressPinsAndOnlyTheSlotsThatExist() {
        open()
        XCTAssertEqual(press("2"), [.pastePinned(slot: 2, action: .plain), .exitPaste])
        open()
        XCTAssertEqual(press("9"), [], "there are only \(Clipboard.pinSlots) pins")
        XCTAssertEqual(core.state, .paste(searching: false), "and an unknown key does not close the strip")
    }

    /// The panel leaves the strip up — it is the rare half of a card's life.
    func testCommandOpensThePanelWithoutPasting() {
        open()
        XCTAssertEqual(press("a", command: true),
                       [.pasteRecent(label: "a", action: .panel), .pastePanelShow])
        XCTAssertEqual(core.state, .pastePanel)
        XCTAssertEqual(press("p"), [.pastePanelAct(.pin), .pastePanelDismiss])
        XCTAssertEqual(core.state, .paste(searching: false), "back to the strip, not out")
    }

    func testEscapeStepsBackOneThingAtATime() {
        open()
        XCTAssertEqual(press("/"), [.pasteSearchBegin])
        XCTAssertEqual(press("escape"), [.pasteSearchEnd])
        XCTAssertEqual(core.state, .paste(searching: false), "search closes, mode stays")
        XCTAssertEqual(press("escape"), [.exitPaste])
        XCTAssertEqual(core.state, .idle)
    }

    func testSearchTypesAndCommits() {
        open()
        _ = press("/")
        XCTAssertEqual(press("h"), [.pasteSearchType("h")])
        XCTAssertEqual(press("delete"), [.pasteSearchBackspace])
        XCTAssertEqual(press("right"), [.pasteSearchMove(delta: 1)])
        XCTAssertEqual(press("return"), [.pasteSearchCommit(action: .plain), .exitPaste])
        XCTAssertEqual(core.state, .idle)
    }

    /// Same bargain scroll and hints already make.
    func testALodeGestureExitsAndExecutes() {
        open()
        world.graph = ["s": .leaf]
        let effects = press("s", held: true)
        XCTAssertEqual(effects.first, .exitPaste)
        XCTAssertTrue(effects.contains(.summonGraph(letters: ["s"], beside: false)))
        XCTAssertEqual(core.state, .idle)
    }

    func testPlainTypingIsSwallowedSoNothingLeaks() {
        open()
        XCTAssertEqual(press("space"), [], "mode discipline")
        XCTAssertEqual(core.state, .paste(searching: false))
    }
}

extension PasteModeTests {
    /// ⌘C while the strip is up must still copy. The alphabet has no c, x,
    /// v or z, so the app's own shortcuts pass straight through and the new
    /// clip simply appears as the first card.
    func testCommandShortcutsOutsideTheAlphabetPassThrough() {
        _ = core.openPaste(world: world)
        for key in ["c", "x", "v", "z"] {
            XCTAssertFalse(Clipboard.recentLabels.contains(key), "\(key) must not be a label")
            XCTAssertEqual(core.keyDown(key: key, held: false, shift: false,
                                        command: true, world: world), [.passThrough])
            XCTAssertEqual(core.state, .paste(searching: false), "and the strip stays up")
        }
    }

    func testNonLabelLettersWithoutCommandAreStillSwallowed() {
        _ = core.openPaste(world: world)
        XCTAssertEqual(core.keyDown(key: "c", held: false, shift: false,
                                    command: false, world: world), [], "mode discipline")
    }

    func testDigitsBeyondThePinsPassThroughWithCommand() {
        _ = core.openPaste(world: world)
        XCTAssertEqual(core.keyDown(key: "7", held: false, shift: false,
                                    command: true, world: world), [.passThrough])
        XCTAssertEqual(core.keyDown(key: "7", held: false, shift: false,
                                    command: false, world: world), [])
    }
}
