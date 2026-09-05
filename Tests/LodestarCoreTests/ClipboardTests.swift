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
    private func press(_ key: String, held: Bool = false, shift: Bool = false,
                       command: Bool = false, option: Bool = false) -> [EngineEffect] {
        core.keyDown(key: key, held: held, shift: shift, command: command,
                     option: option, world: world)
    }

    /// Open the strip and start typing at it — the state most of the
    /// search tests below begin from.
    private func openSearching() {
        open()
        _ = press("/")
    }

    func testTriggerOpensAndTogglesShut() {
        XCTAssertEqual(core.openPaste(world: world), [.hideBars, .enterPaste])
        XCTAssertEqual(core.state, .paste(searching: false))
        XCTAssertEqual(core.openPaste(world: world), [.exitPaste], "⇧⌘V again closes it")
        XCTAssertEqual(core.state, .idle)
    }

    func testTriggerTogglesShutFromACardsPanelToo() {
        open()
        _ = press("a", command: true)
        XCTAssertEqual(core.state, .pastePanel(searching: false))
        XCTAssertEqual(core.openPaste(world: world), [.exitPaste],
                       "the panel is still the strip, so ⇧⌘V still closes it")
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
        XCTAssertEqual(core.state, .pastePanel(searching: false))
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
        XCTAssertEqual(press("delete"), [.pasteSearchDelete(.character)])
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
    /// ⌘C, ⌘X, ⌘Z belong to the app underneath — none of them address a
    /// card, so reaching for one ends the mode and the keystroke lands
    /// where it was aimed. ⌘V is the one exception: a paste into an input
    /// is what ⌘V means everywhere, and the strip's input is its band.
    func testCommandShortcutsOutsideTheAlphabetLeaveTheMode() {
        for key in ["c", "x", "z"] {
            var core = EngineCore()
            _ = core.openPaste(world: world)
            XCTAssertFalse(Clipboard.recentLabels.contains(key), "\(key) must not be a label")
            XCTAssertEqual(core.keyDown(key: key, held: false, shift: false,
                                        command: true, world: world),
                           [.exitPaste], "swallowed, not forwarded")
            XCTAssertTrue(core.isIdle, "and the strip is gone")
        }
        var core = EngineCore()
        _ = core.openPaste(world: world)
        XCTAssertEqual(core.keyDown(key: "v", held: false, shift: false, command: true, world: world),
                       [.pasteSearchBegin, .pasteSearchPaste],
                       "⌘V opens the band with the pasteboard's text")
        XCTAssertEqual(core.state, .paste(searching: true))
    }

    func testNonLabelLettersWithoutCommandAreStillSwallowed() {
        _ = core.openPaste(world: world)
        XCTAssertEqual(core.keyDown(key: "c", held: false, shift: false,
                                    command: false, world: world), [], "mode discipline")
    }

    func testDigitsBeyondThePinsLeaveTheModeWithCommand() {
        _ = core.openPaste(world: world)
        XCTAssertEqual(core.keyDown(key: "7", held: false, shift: false,
                                    command: true, world: world), [.exitPaste])
        XCTAssertTrue(core.isIdle)
    }

    func testDigitsBeyondThePinsAreStillSwallowedWithoutCommand() {
        _ = core.openPaste(world: world)
        XCTAssertEqual(core.keyDown(key: "7", held: false, shift: false,
                                    command: false, world: world), [], "mode discipline")
        XCTAssertEqual(core.state, .paste(searching: false))
    }
}

extension PasteModeTests {
    /// ⌘ on a label with no card behind it leaves rather than opening a
    /// panel that would draw nothing and swallow every label until escape.
    func testPanelWithNoCardBehindItLeavesInstead() {
        _ = core.openPaste(world: world)
        XCTAssertFalse(world.pasteCardExists(address: "l"))
        XCTAssertEqual(core.keyDown(key: "l", held: false, shift: false,
                                    command: true, world: world), [.exitPaste])
        XCTAssertTrue(core.isIdle)
    }

    /// The panel still opens for a label that does have a card.
    func testPanelOpensForALiveLabel() {
        _ = core.openPaste(world: world)
        _ = core.keyDown(key: "a", held: false, shift: false, command: true, world: world)
        XCTAssertEqual(core.state, .pastePanel(searching: false))
        core.dismissPastePanel()
        XCTAssertEqual(core.state, .paste(searching: false), "back to a working strip")
    }

    func testDismissingThePanelIsHarmlessWhenNoPanelIsOpen() {
        _ = core.openPaste(world: world)
        core.dismissPastePanel()
        XCTAssertEqual(core.state, .paste(searching: false))
        core = EngineCore()
        core.dismissPastePanel()
        XCTAssertEqual(core.state, .idle)
    }
}

extension ClipboardTests {
    func testAgeReadsShortAndHonestly() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        func clipAged(_ seconds: TimeInterval) -> Clipboard.Clip {
            Clipboard.Clip(id: "x", kind: .text, created: base.addingTimeInterval(-seconds),
                           sourceBundleID: nil, sourceAppName: nil, preview: "", bytes: 0)
        }
        XCTAssertEqual(Clipboard.age(of: clipAged(5), now: base), "just now")
        XCTAssertEqual(Clipboard.age(of: clipAged(300), now: base), "5m ago")
        XCTAssertEqual(Clipboard.age(of: clipAged(7200), now: base), "2h ago")
        XCTAssertEqual(Clipboard.age(of: clipAged(3 * 86_400), now: base), "3d ago")
        XCTAssertEqual(Clipboard.age(of: clipAged(-10), now: base), "just now", "clock skew is not negative time")
    }
}

extension ClipboardTests {
    func testDroppingLastWordMatchesMacosBehaviour() {
        XCTAssertEqual(Clipboard.droppingLastWord("a big cat"), "a big ")
        XCTAssertEqual(Clipboard.droppingLastWord("a big cat  "), "a big ",
                       "trailing space goes with the word it follows")
        XCTAssertEqual(Clipboard.droppingLastWord("cat"), "")
        XCTAssertEqual(Clipboard.droppingLastWord(""), "")
        XCTAssertEqual(Clipboard.droppingLastWord("   "), "")
    }
}

extension PasteModeTests {
    func testSearchDeletionScopes() {
        _ = core.openPaste(world: world)
        _ = core.keyDown(key: "/", held: false, shift: false, world: world)
        func delete(command: Bool = false, option: Bool = false) -> [EngineEffect] {
            core.keyDown(key: "delete", held: false, shift: false,
                         command: command, option: option, world: world)
        }
        XCTAssertEqual(delete(), [.pasteSearchDelete(.character)])
        XCTAssertEqual(delete(option: true), [.pasteSearchDelete(.word)])
        XCTAssertEqual(delete(command: true), [.pasteSearchDelete(.all)])
        XCTAssertEqual(core.state, .paste(searching: true), "deleting never leaves search")
    }
}

extension PasteModeTests {
    /// Opening a card's actions mid-search and closing them must put you
    /// back in the search you were in, not silently out of it.
    func testPanelOpenedFromSearchReturnsToSearch() {
        _ = core.openPaste(world: world)
        _ = core.keyDown(key: "/", held: false, shift: false, world: world)
        _ = core.keyDown(key: "return", held: false, shift: false, command: true, world: world)
        XCTAssertEqual(core.state, .pastePanel(searching: true))
        _ = core.keyDown(key: "escape", held: false, shift: false, world: world)
        XCTAssertEqual(core.state, .paste(searching: true))
    }

    func testPanelActionFromSearchAlsoReturnsToSearch() {
        _ = core.openPaste(world: world)
        _ = core.keyDown(key: "/", held: false, shift: false, world: world)
        _ = core.keyDown(key: "return", held: false, shift: false, command: true, world: world)
        _ = core.keyDown(key: "d", held: false, shift: false, world: world)
        XCTAssertEqual(core.state, .paste(searching: true))
    }
}

extension PasteModeTests {
    /// Typing a query must not eat the app's own shortcuts — and reaching
    /// for one says the search is over.
    func testCommandLettersLeaveTheModeWhileSearching() {
        _ = core.openPaste(world: world)
        _ = core.keyDown(key: "/", held: false, shift: false, world: world)
        XCTAssertEqual(core.keyDown(key: "c", held: false, shift: false,
                                    command: true, world: world), [.exitPaste])
        XCTAssertTrue(core.isIdle)
    }

    func testPlainLettersAreStillCharactersWhileSearching() {
        _ = core.openPaste(world: world)
        _ = core.keyDown(key: "/", held: false, shift: false, world: world)
        XCTAssertEqual(core.keyDown(key: "c", held: false, shift: false, world: world),
                       [.pasteSearchType("c")], "without ⌘ it is just a character")
    }
}

/// An image into a terminal: ⌘V cannot carry a picture down a pty, so the
/// clip rides as a file and the path is what lands.
final class PasteAsFilePathTests: XCTestCase {
    func testImageIntoTerminalGoesAsAPath() {
        XCTAssertTrue(Clipboard.pastesAsFilePath(
            kind: .image, frontmostBundleID: "com.mitchellh.ghostty"))
        XCTAssertTrue(Clipboard.pastesAsFilePath(
            kind: .image, frontmostBundleID: "com.apple.Terminal"))
    }

    func testTextIntoTerminalPastesNormally() {
        XCTAssertFalse(Clipboard.pastesAsFilePath(
            kind: .text, frontmostBundleID: "com.mitchellh.ghostty"))
    }

    func testImageIntoGraphicalAppKeepsThePicture() {
        XCTAssertFalse(Clipboard.pastesAsFilePath(
            kind: .image, frontmostBundleID: "com.apple.Notes"))
        XCTAssertFalse(Clipboard.pastesAsFilePath(
            kind: .image, frontmostBundleID: nil))
    }

    /// The reader checks the extension before it opens the file, so the name
    /// has to be one it recognises.
    func testPasteExtensionIsRecognisedByReaders() {
        XCTAssertTrue(["png", "jpg", "jpeg", "gif", "webp"]
            .contains(Clipboard.pasteableImageExtension))
    }

    func testBundleIDsAreStoredLowercasedSoTheLookupCanFold() {
        for id in Clipboard.terminalBundleIDs {
            XCTAssertEqual(id, id.lowercased(),
                           "\(id) would never match a folded lookup")
        }
    }
}

/// Leaving clipboard mode for reasons that are not a paste: a click landing
/// somewhere else, or ⌘ reaching for a shortcut the strip has no claim on.
final class PasteModeExitTests: XCTestCase {
    private func opened(_ world: WorldStub) -> EngineCore {
        var core = EngineCore()
        _ = core.openPaste(world: world)
        return core
    }

    func testClickLeavesTheMode() {
        var core = opened(WorldStub())
        let effects = core.leavePaste()
        XCTAssertTrue(core.isIdle)
        XCTAssertTrue(effects.contains(.exitPaste))
        XCTAssertTrue(effects.contains(.pastePanelDismiss))
    }

    func testClickWithNoStripOpenDoesNothing() {
        var core = EngineCore()
        XCTAssertTrue(core.leavePaste().isEmpty)
        XCTAssertTrue(core.isIdle)
    }

    func testCommandWithNoCardBehindItLeavesAndSwallowsTheKey() {
        let world = WorldStub()
        var core = opened(world)
        // "w" addresses nothing on the strip: ⌘W belongs to the app.
        let effects = core.keyDown(key: "w", held: false, shift: false,
                                   command: true, option: false, world: world)
        XCTAssertTrue(core.isIdle)
        XCTAssertEqual(effects, [.exitPaste], "⌘W must not reach the window")
    }

    func testCommandOnAnEmptyPinSlotLeavesToo() {
        let world = WorldStub()
        var core = opened(world)
        // Pin one is filled in the stub; pin four is not.
        let effects = core.keyDown(key: "4", held: false, shift: false,
                                   command: true, option: false, world: world)
        XCTAssertTrue(core.isIdle)
        XCTAssertEqual(effects, [.exitPaste])
    }

    func testCommandOnALiveCardStillOpensItsActions() {
        let world = WorldStub()
        var core = opened(world)
        let effects = core.keyDown(key: "s", held: false, shift: false,
                                   command: true, option: false, world: world)
        XCTAssertFalse(core.isIdle)
        XCTAssertEqual(effects, [.pasteRecent(label: "s", action: .panel), .pastePanelShow])
    }

    func testCommandWhileSearchingLeavesTheMode() {
        let world = WorldStub()
        var core = opened(world)
        _ = core.keyDown(key: "/", held: false, shift: false,
                         command: false, option: false, world: world)
        let effects = core.keyDown(key: "c", held: false, shift: false,
                                   command: true, option: false, world: world)
        XCTAssertTrue(core.isIdle)
        XCTAssertEqual(effects, [.exitPaste])
    }

    /// The editing shortcuts belong to the search field, not to the app.
    func testCommandDeleteAndReturnStillServeTheSearch() {
        let world = WorldStub()
        var core = opened(world)
        _ = core.keyDown(key: "/", held: false, shift: false,
                         command: false, option: false, world: world)
        XCTAssertEqual(core.keyDown(key: "delete", held: false, shift: false,
                                    command: true, option: false, world: world),
                       [.pasteSearchDelete(.all)])
        XCTAssertFalse(core.isIdle)
    }
}

/// The verdict reachable from the type list alone. The caller uses this to
/// refuse a concealed clip without reading a byte of it.
final class RefusalBeforeReadingTests: XCTestCase {
    func testConcealedIsRefusedFromTypesAlone() {
        XCTAssertEqual(
            Clipboard.refusalBeforeReading(types: ["org.nspasteboard.ConcealedType", "public.utf8-plain-text"],
                                           sourceBundleID: "com.1password.1password",
                                           excludedApps: []),
            .concealed("org.nspasteboard.ConcealedType"))
    }

    func testExcludedAppIsRefusedFromItsBundleAlone() {
        XCTAssertEqual(
            Clipboard.refusalBeforeReading(types: ["public.utf8-plain-text"],
                                           sourceBundleID: "com.Example.App",
                                           excludedApps: ["com.example.app"]),
            .excludedApp("com.example.app"))
    }

    func testOrdinaryClipSurvivesTheEarlyGate() {
        XCTAssertNil(
            Clipboard.refusalBeforeReading(types: ["public.utf8-plain-text"],
                                           sourceBundleID: "com.apple.Notes",
                                           excludedApps: []))
    }

    /// The full check must agree with the early one, or a clip could pass
    /// the gate and be refused later — after it had been read.
    func testFullRefusalAgreesWithTheEarlyGate() {
        let types = ["org.nspasteboard.ConcealedType"]
        XCTAssertEqual(
            Clipboard.refusalBeforeReading(types: types, sourceBundleID: nil, excludedApps: []),
            Clipboard.refusal(types: types, sourceBundleID: nil, text: "secret", bytes: 6,
                              excludedApps: [], excludedPatterns: [], maxItemBytes: 100))
    }
}

/// Lodestar's own handover files must not come back as clips.
final class HandoverPathTests: XCTestCase {
    private let temp = "/var/folders/ab/xyz/T"

    func testOurOwnPasteFileIsRecognised() {
        XCTAssertTrue(Clipboard.isOwnHandoverPath(
            "\(temp)/lodestar-deadbeef.png", temporaryDirectory: temp))
    }

    func testTrailingWhitespaceDoesNotHideIt() {
        XCTAssertTrue(Clipboard.isOwnHandoverPath(
            "\(temp)/lodestar-deadbeef.png\n", temporaryDirectory: temp))
    }

    func testSomeoneElsesTempFileIsAnOrdinaryClip() {
        XCTAssertFalse(Clipboard.isOwnHandoverPath(
            "\(temp)/screenshot.png", temporaryDirectory: temp))
    }

    func testAPathOutsideTempIsAnOrdinaryClip() {
        XCTAssertFalse(Clipboard.isOwnHandoverPath(
            "/Users/vac/lodestar-notes.png", temporaryDirectory: temp))
        XCTAssertFalse(Clipboard.isOwnHandoverPath(nil, temporaryDirectory: temp))
    }
}

/// Searching the history: a literal hit is what you meant, the letters in
/// order are how you find what you half remember.
final class ClipboardSearchTests: XCTestCase {
    private func clip(_ id: String, _ text: String, minutesAgo: Double) -> Clipboard.Clip {
        Clipboard.Clip(id: id, kind: .text,
                       created: Date().addingTimeInterval(-60 * minutesAgo),
                       sourceBundleID: nil, sourceAppName: nil,
                       preview: text, bytes: text.utf8.count)
    }

    func testLettersInOrderFindWhatSubstringCannot() {
        let clips = [clip("a", "git commit -m \"the menu\"", minutesAgo: 1)]
        XCTAssertEqual(Clipboard.search(clips, query: "gitcom").map(\.id), ["a"],
                       "gitcom must reach git commit")
        XCTAssertNil(Clipboard.relevance(of: "git commit", to: "zzz"))
    }

    func testALiteralHitOutranksLettersInOrder() {
        let literal = clip("literal", "the release notes", minutesAgo: 90)
        let scattered = clip("scattered", "table of extra elements", minutesAgo: 1)
        // "tle" appears in order in the scattered one, literally in neither;
        // "rel" is literal in the first only.
        let ranked = Clipboard.search([scattered, literal], query: "rel")
        XCTAssertEqual(ranked.first?.id, "literal",
                       "a literal hit beats a newer subsequence match")
    }

    func testAnEarlierHitOutranksALaterOne() {
        let early = clip("early", "lodestar ships tonight", minutesAgo: 200)
        let late = clip("late", "a very long preamble before the word lodestar", minutesAgo: 1)
        XCTAssertEqual(Clipboard.search([late, early], query: "lodestar").map(\.id),
                       ["early", "late"])
    }

    func testOneLetterDoesNotMatchBySubsequence() {
        // Every clip contains an "e" somewhere; that is noise, not a search.
        let clips = [clip("a", "the quick brown fox", minutesAgo: 1),
                     clip("b", "xyz", minutesAgo: 2)]
        XCTAssertEqual(Clipboard.search(clips, query: "e").map(\.id), ["a"],
                       "one letter is substring only")
    }

    func testTiesKeepNewestFirst() {
        let older = clip("older", "same", minutesAgo: 50)
        let newer = clip("newer", "same", minutesAgo: 1)
        XCTAssertEqual(Clipboard.search([newer, older], query: "same").map(\.id),
                       ["newer", "older"])
    }

    func testLengthIsNotHeldAgainstAClip() {
        let long = clip("long", String(repeating: "context ", count: 200) + "needle", minutesAgo: 1)
        let short = clip("short", "nettle", minutesAgo: 2)
        XCTAssertEqual(Clipboard.search([short, long], query: "needle").first?.id, "long",
                       "the clip that actually contains it wins, however long it is")
    }

    /// A single-pointer byte scan cannot do this: the failed third byte has
    /// already eaten the second "a" that the match needed.
    func testASubstringThatRepeatsIsStillFound() {
        let clips = [clip("a", "aaab", minutesAgo: 1)]
        XCTAssertEqual(Clipboard.search(clips, query: "aab").map(\.id), ["a"])
        XCTAssertNotNil(Clipboard.relevance(of: "xxabcabd", to: "abcabd"))
    }

    func testMatchingIsCaseInsensitiveBothWays() {
        XCTAssertNotNil(Clipboard.relevance(of: "The Release Notes", to: "release"))
        XCTAssertNotNil(Clipboard.relevance(of: "SHOUTING CLIP", to: "shout"))
    }

    func testEmptyQueryIsTheOrdinaryStrip() {
        let clips = [clip("a", "one", minutesAgo: 1), clip("b", "two", minutesAgo: 2)]
        XCTAssertEqual(Clipboard.search(clips, query: "   ").map(\.id), ["a", "b"])
    }

    /// This runs on every keystroke while the strip is open, against a
    /// history capped at ten thousand clips. A regression here is felt as
    /// typing lag, so it is measured rather than assumed.
    func testSearchingAFullHistoryStaysInteractive() {
        let filler = String(repeating: "the quick brown fox jumps over it. ", count: 55)
        let clips = (0..<10_000).map { clip("c\($0)", filler + "marker\($0)", minutesAgo: Double($0)) }
        let started = Date()
        let hits = Clipboard.search(clips, query: "marker9999")
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(hits.first?.id, "c9999")
        // The shipped app is optimized; a debug run carries bounds checks and
        // no inlining and lands roughly ten times slower, so the number that
        // matters is the release one.
        #if DEBUG
        let ceiling = 3.0
        #else
        let ceiling = 0.3
        #endif
        XCTAssertLessThan(elapsed, ceiling, "10k long clips searched in \(elapsed)s")
        print("search over 10k × \(filler.count) chars: \(String(format: "%.3f", elapsed))s")
    }
}

extension PasteModeTests {
    /// What people search a clipboard for is file names, identifiers and
    /// commands. A band that took letters and digits alone could not be
    /// typed most of them.
    func testEveryCharacterKeyExtendsTheQuery() {
        openSearching()
        XCTAssertEqual(press("-"), [.pasteSearchType("-")])
        XCTAssertEqual(press("-", shift: true), [.pasteSearchType("_")])
        XCTAssertEqual(press("."), [.pasteSearchType(".")])
        XCTAssertEqual(press("2", shift: true), [.pasteSearchType("@")])
        XCTAssertEqual(press("a", shift: true), [.pasteSearchType("A")])
        XCTAssertEqual(press("space"), [.pasteSearchType(" ")])
        XCTAssertEqual(press("/"), [.pasteSearchType("/")],
                       "the key that opened the search is a character inside it")
        XCTAssertEqual(core.state, .paste(searching: true))
    }

    /// ⌘ still means the app's shortcut rather than a character, whatever
    /// key it is held with.
    func testCommandPunctuationWhileSearchingLeavesTheMode() {
        openSearching()
        XCTAssertEqual(press("[", command: true), [.exitPaste], "⌘[ belongs to the app")
        XCTAssertTrue(core.isIdle)
    }

    /// The chips stay on the cards while you type, and ⌥ is what makes
    /// them true — every match one keystroke away, not an arrow walk.
    func testOptionAddressesACardWhileSearching() {
        openSearching()
        XCTAssertEqual(press("a", option: true),
                       [.pasteRecent(label: "a", action: .plain), .exitPaste])
        XCTAssertTrue(core.isIdle)
    }

    /// The same addressing, so the same verbs ride on it.
    func testOptionCarriesTheStripsOwnVerbs() {
        openSearching()
        XCTAssertEqual(press("s", shift: true, option: true),
                       [.pasteRecent(label: "s", action: .native), .exitPaste])
        openSearching()
        XCTAssertEqual(press("d", command: true, option: true),
                       [.pasteRecent(label: "d", action: .panel), .pastePanelShow])
        XCTAssertEqual(core.state, .pastePanel(searching: true),
                       "and escape from there comes back to the search")
    }

    func testOptionAddressesPinsWhileSearchingToo() {
        openSearching()
        XCTAssertEqual(press("1", option: true),
                       [.pastePinned(slot: 1, action: .plain), .exitPaste])
    }

    /// A mis-hit must not throw away the query, which is the one thing
    /// this mode holds that pressing the key again cannot bring back.
    func testAnAddressWithNothingBehindItKeepsTheSearch() {
        openSearching()
        _ = press("h")
        XCTAssertEqual(press("l", option: true), [], "no card answers to l")
        XCTAssertEqual(press("4", option: true), [], "pin four is empty")
        XCTAssertEqual(core.state, .paste(searching: true))
    }

    /// Nothing changes on the strip itself: there, a letter is already an
    /// address and ⌥ is not what makes it one.
    func testOptionOnTheStripItselfIsStillJustTheLabel() {
        open()
        XCTAssertEqual(press("a", option: true),
                       [.pasteRecent(label: "a", action: .plain), .exitPaste])
    }
}

extension ClipboardTests {
    // MARK: - A copy is its items

    /// The test that must not regress: the index on disk was written
    /// before a copy could be several things, and a clip that will not
    /// decode takes the whole history down with it.
    func testAClipWrittenBeforeMultiItemCaptureStillDecodes() throws {
        let legacy = #"{"bytes":12,"created":760000,"id":"abc","kind":"text","#
            + #""nativeTypes":["public.html"],"preview":"hello"}"#
        let clip = try JSONDecoder().decode(Clipboard.Clip.self, from: Data(legacy.utf8))
        XCTAssertEqual(clip.itemCount, 1)
        XCTAssertEqual(clip.itemTypes, [["public.html"]])
        XCTAssertTrue(clip.hasNativeForm)
        XCTAssertNil(clip.itemsLabel, "one item says nothing")
    }

    /// And the ordinary copy keeps writing what it always wrote: the index
    /// is rewritten for the life of the app, and a key that says nothing
    /// is not worth ten thousand writes.
    func testASingleItemCopyWritesNoKeyItDoesNotNeed() throws {
        let clip = Clipboard.Clip(id: "a", kind: .text, created: Date(),
                                  sourceBundleID: nil, sourceAppName: nil,
                                  preview: "x", bytes: 1, nativeTypes: ["public.html"])
        let json = String(decoding: try JSONEncoder().encode(clip), as: UTF8.self)
        XCTAssertFalse(json.contains("otherItemTypes"))
    }

    func testEveryItemsTypesSurviveTheRoundTrip() throws {
        let clip = Clipboard.Clip(id: "a", kind: .text, created: Date(),
                                  sourceBundleID: nil, sourceAppName: nil,
                                  preview: "x", bytes: 3,
                                  nativeTypes: [Clipboard.fileURLType],
                                  otherItemTypes: [[Clipboard.fileURLType],
                                                   [Clipboard.fileURLType]])
        let decoded = try JSONDecoder().decode(
            Clipboard.Clip.self, from: try JSONEncoder().encode(clip))
        XCTAssertEqual(decoded.itemCount, 3)
        XCTAssertEqual(decoded.itemTypes.count, 3)
        XCTAssertEqual(decoded.itemsLabel, "3 files")
    }

    func testTheCardNamesFilesWhenItHonestlyCan() {
        XCTAssertNil(Clipboard.itemsLabel(itemTypes: [[Clipboard.fileURLType]]))
        XCTAssertEqual(Clipboard.itemsLabel(
            itemTypes: [[Clipboard.fileURLType], [Clipboard.fileURLType]]), "2 files")
        XCTAssertEqual(Clipboard.itemsLabel(
            itemTypes: [[Clipboard.fileURLType], ["public.html"]]), "2 items",
                       "one of them is not a file, so the card does not claim they are")
    }

    /// A re-copy has to land on the card it already has, so the one-item
    /// name is the one every clip on disk was written with.
    func testIdentityIsUnchangedForOneItemAndUnambiguousForSeveral() {
        let ab = Data("ab".utf8)
        let c = Data("c".utf8)
        XCTAssertEqual(Clipboard.identityData(items: [ab]), ab)
        XCTAssertEqual(Clipboard.identityData(items: []), Data())
        XCTAssertNotEqual(Clipboard.identityData(items: [ab, c]),
                          Clipboard.identityData(items: [Data("abc".utf8)]),
                          "two files copied together are not their contents run together")
        XCTAssertNotEqual(Clipboard.identityData(items: [ab, c]),
                          Clipboard.identityData(items: [c, ab]),
                          "order is part of what was copied")
    }

    /// Kept in part is worse than not kept: a card that pastes some of
    /// what you copied looks like it worked.
    func testACopyTooLongToHoldIsRefusedWhole() {
        func verdict(_ count: Int) -> Clipboard.Refusal? {
            Clipboard.refusalBeforeReading(types: ["public.utf8-plain-text"],
                                           sourceBundleID: nil, excludedApps: [],
                                           itemCount: count)
        }
        XCTAssertNil(verdict(Clipboard.maxItemsPerClip))
        XCTAssertEqual(verdict(Clipboard.maxItemsPerClip + 1),
                       .tooManyItems(Clipboard.maxItemsPerClip + 1))
    }

    /// And a concealed item still outranks it — the count is never a
    /// reason to have read one.
    func testConcealedOutranksTheItemCeiling() {
        XCTAssertEqual(
            Clipboard.refusalBeforeReading(types: ["org.nspasteboard.ConcealedType"],
                                           sourceBundleID: nil, excludedApps: [],
                                           itemCount: 9_000),
            .concealed("org.nspasteboard.ConcealedType"))
    }

    // MARK: - A card is found by what it shows and where it came from

    func testAnImageIsFoundByWhatItShows() {
        var image = clip("shot", preview: Clipboard.imagePreview(width: 1200, height: 800))
        image.preview = Clipboard.captioned(image.preview,
                                            with: "Fatal error: index out of range\nat main.swift:42")
        let text = clip("note", preview: "groceries")
        XCTAssertEqual(Clipboard.search([text, image], query: "fatal").map(\.id), ["shot"])
        XCTAssertTrue(image.preview.hasPrefix("image 1200×800\n"), "the size line stays first")
    }

    func testImagePreviewWithoutTextIsTheSizeAlone() {
        XCTAssertEqual(Clipboard.imagePreview(width: 10, height: 20), "image 10×20")
        XCTAssertEqual(Clipboard.imagePreview(width: 10, height: 20, text: "  \n"), "image 10×20")
        XCTAssertEqual(Clipboard.imagePreview(width: 10, height: 20, text: "hello"), "image 10×20\nhello")
    }

    func testCaptionedReplacesAnOlderCaptionRatherThanStacking() {
        let once = Clipboard.captioned("image 1×1", with: "first")
        let twice = Clipboard.captioned(once, with: "second")
        XCTAssertEqual(twice, "image 1×1\nsecond")
        XCTAssertEqual(Clipboard.captioned("image 1×1", with: "  "), "image 1×1",
                       "nothing read, nothing added")
    }

    func testSourceHostIsTheBareHost() {
        XCTAssertEqual(Clipboard.sourceHost(fromURL: "https://www.github.com/x/y?z=1"), "github.com")
        XCTAssertEqual(Clipboard.sourceHost(fromURL: "  https://Docs.Example.org/a  "), "docs.example.org")
        XCTAssertNil(Clipboard.sourceHost(fromURL: "not a url"))
        XCTAssertNil(Clipboard.sourceHost(fromURL: nil))
        XCTAssertNil(Clipboard.sourceHost(fromURL: ""))
        XCTAssertNil(Clipboard.sourceHost(fromURL: "https://www./"))
    }

    func testTheHostIsASecondAddress() {
        var fromGitHub = clip("code", preview: "func foo() {}")
        fromGitHub.sourceHost = "github.com"
        let says = clip("says", preview: "github is down")
        let other = clip("other", preview: "lunch")
        XCTAssertEqual(Clipboard.search([other, fromGitHub, says], query: "github").map(\.id),
                       ["says", "code"],
                       "a literal hit in the text outranks the page; the page still answers")
        XCTAssertEqual(Clipboard.search([other, fromGitHub], query: "hub").map(\.id), ["code"])
    }

    func testARestoreIsRecognizedByItsMarker() {
        XCTAssertTrue(Clipboard.isRestore(types: ["public.utf8-plain-text", "com.raycast.RestoredType"]))
        XCTAssertFalse(Clipboard.isRestore(types: ["public.utf8-plain-text"]))
        XCTAssertFalse(Clipboard.isRestore(types: []))
    }

    func testThePinColumnDrawsThroughTheHighestSlotAndOneFree() {
        XCTAssertEqual(Clipboard.pinSlotsToDraw(taken: []), 1)
        XCTAssertEqual(Clipboard.pinSlotsToDraw(taken: [1]), 2)
        XCTAssertEqual(Clipboard.pinSlotsToDraw(taken: [1, 3]), 4)
        XCTAssertEqual(Clipboard.pinSlotsToDraw(taken: [5]), 5)
        XCTAssertEqual(Clipboard.pinSlotsToDraw(taken: [1, 2, 3, 4, 5]), 5)
    }

    func testAPastedQueryIsOneLineAndBounded() {
        XCTAssertEqual(Clipboard.pastedQuery("  hello\n\n  world\t!  "), "hello world !")
        XCTAssertEqual(Clipboard.pastedQuery(""), "")
        XCTAssertEqual(Clipboard.pastedQuery("   \n "), "")
        XCTAssertEqual(Clipboard.pastedQuery(String(repeating: "a", count: 500)).count, 200)
    }

    func testAClipWithoutAHostStillDecodesAndEncodesWithoutTheKey() throws {
        let old = clip("old")
        let data = try JSONEncoder().encode(old)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("sourceHost"),
                       "absent, not null: the index is rewritten ten thousand times")
        let back = try JSONDecoder().decode(Clipboard.Clip.self, from: data)
        XCTAssertNil(back.sourceHost)
        var hosted = old
        hosted.sourceHost = "example.com"
        let again = try JSONDecoder().decode(Clipboard.Clip.self, from: JSONEncoder().encode(hosted))
        XCTAssertEqual(again.sourceHost, "example.com")
    }
}
