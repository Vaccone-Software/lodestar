import XCTest
@testable import lodestar
@testable import LodestarCore

/// The draft, driven through the tap the way a hand drives it: `lode .`
/// opens it listening, keys land in it while the app underneath keeps
/// its cursor, `⏎` puts the text on the pasteboard and pastes it into
/// whatever is frontmost, and `esc esc` keeps it on the pasteboard.
final class DraftScenarioTests: XCTestCase {
    private func cmd(_ stage: Stage, _ key: String, shift: Bool = false) {
        _ = stage.press(key, shift: shift)
    }

    func testSpeakDoorOpensListeningAndReturnPastesIntoTheFocusedApp() {
        let stage = Stage()
        stage.lode(".")
        XCTAssertTrue(stage.draft.isOpen)
        XCTAssertEqual(stage.draft.mode, .insert)
        XCTAssertEqual(stage.speech.listens, 1)

        stage.speech.hear("hello")
        XCTAssertEqual(stage.draft.buffer.ghost, "hello", "volatile words are the ghost")
        stage.speech.settle("Hello there,")
        XCTAssertEqual(stage.draft.buffer.text, "Hello there,")

        cmd(stage, "space"); cmd(stage, "b"); cmd(stage, "o"); cmd(stage, "b")
        XCTAssertEqual(stage.draft.buffer.text, "Hello there, bob", "typed characters land at the cursor")

        cmd(stage, "return")
        XCTAssertFalse(stage.draft.isOpen)
        XCTAssertEqual(stage.pasteboard, ["Hello there, bob"])
        XCTAssertEqual(stage.posted.map(\.key), ["v"], "⌘V into the app that kept its cursor")
        XCTAssertEqual(stage.speech.stops, 1)
    }

    func testAStandingGhostSettlesAtReturn() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.settle("First")
        stage.speech.hear("second")
        cmd(stage, "return")
        XCTAssertEqual(stage.pasteboard, ["First second"], "the last words are not lost to the paste")
    }

    func testReturnNeverSendsAndShiftReturnIsANewline() {
        let stage = Stage()
        stage.lode(".")
        cmd(stage, "a")
        cmd(stage, "return", shift: true)
        cmd(stage, "b")
        cmd(stage, "return")
        XCTAssertEqual(stage.pasteboard, ["a\nb"])
        XCTAssertEqual(stage.posted.map(\.key), ["v"], "no enter is ever pressed in the app")
    }

    func testBackspaceTakesTheGrainOfTheLastInput() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.settle("one two three")
        cmd(stage, "delete")
        XCTAssertEqual(stage.draft.buffer.text, "one two", "a word after speech")
        cmd(stage, "x")
        cmd(stage, "delete")
        XCTAssertEqual(stage.draft.buffer.text, "one two", "a character after typing")
    }

    func testEscapeGoesToNormalModeAndSilencesTheMicThenEscapeKeepsTheDraft() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.settle("keep this")
        cmd(stage, "escape")
        XCTAssertTrue(stage.draft.isOpen)
        XCTAssertEqual(stage.draft.mode, .normal)
        XCTAssertEqual(stage.speech.pauses, 1, "the mic writes only in insert mode")
        cmd(stage, "escape")
        XCTAssertFalse(stage.draft.isOpen)
        XCTAssertEqual(stage.pasteboard, ["keep this"], "cancelled text survives on the pasteboard")
        XCTAssertTrue(stage.posted.isEmpty, "and nothing was pasted")
        XCTAssertEqual(stage.hud.owner, .flash)
    }

    func testEditDoorOpensInsertAndSilentWithTheFieldPulledIn() {
        let stage = Stage()
        stage.field = DraftController.Field(selection: nil, value: "fix me")
        stage.lode(".", shift: true)
        XCTAssertEqual(stage.draft.mode, .insert, "both doors open typing; vim is one esc away")
        XCTAssertEqual(stage.speech.listens, 0, "and the edit door never asks for the mic")
        XCTAssertEqual(stage.draft.buffer.text, "fix me")
        XCTAssertEqual(stage.draft.buffer.cursor, 6, "at the end, ready to continue")
        cmd(stage, "space"); cmd(stage, "n"); cmd(stage, "o"); cmd(stage, "w")
        cmd(stage, "return")
        XCTAssertEqual(stage.pasteboard, ["fix me now"])
        XCTAssertEqual(stage.posted.map(\.key), ["v"], "the whole field was selected over AX, then replaced")
    }

    func testASelectionIsReplacedOnlyWhileTheOriginIsStillFrontmost() {
        let stage = Stage()
        stage.field = DraftController.Field(selection: "old", value: nil)
        stage.lode(".")
        XCTAssertEqual(stage.draft.buffer.text, "old")
        stage.speech.settle("new")
        // The user switched apps before ⏎: a paste there, not a replacement.
        stage.actions.focused = (pid: 2, name: "Slack")
        cmd(stage, "return")
        XCTAssertEqual(stage.pasteboard, ["old new"])
        XCTAssertEqual(stage.posted.map(\.key), ["v"])
        XCTAssertEqual(stage.lastDraft?.app, "slack")
        XCTAssertEqual(stage.lastDraft?.row, "paste")
    }

    func testTheDestinationIsLiveAndNoFocusMeansTheClipboard() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.settle("anywhere")
        stage.actions.focused = nil
        cmd(stage, "return")
        XCTAssertEqual(stage.pasteboard, ["anywhere"])
        XCTAssertTrue(stage.posted.isEmpty, "nothing to paste into")
        XCTAssertEqual(stage.hud.owner, .flash)
        XCTAssertEqual(stage.lastDraft?.action, "copied")
    }

    func testDoorKeysInsideSetPostureRatherThanReopening() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.settle("said")
        stage.lode(".", shift: true)
        XCTAssertTrue(stage.draft.isOpen)
        XCTAssertEqual(stage.draft.mode, .insert, "the silent posture keeps the mode")
        XCTAssertEqual(stage.draft.buffer.text, "said", "the text survives a posture change")
        XCTAssertEqual(stage.speech.pauses, 1)
        stage.lode(".")
        XCTAssertEqual(stage.speech.resumes, 1)
        XCTAssertEqual(stage.speech.listens, 1, "one session, not a new one per posture")
    }

    func testASummonMidDraftKeepsItUpAndMovesTheDestination() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.settle("for slack")
        stage.lode("s")
        XCTAssertEqual(stage.actions.summoned.map(\.target), [.app("Slack")])
        XCTAssertTrue(stage.draft.isOpen, "a summon is not a bar; the draft rides along")
        stage.actions.focused = (pid: 2, name: "Slack")
        cmd(stage, "return")
        XCTAssertEqual(stage.lastDraft?.app, "slack")
        XCTAssertEqual(stage.pasteboard, ["for slack"])
    }

    func testAnotherBarBorrowsTheKeysAndTheDraftWaits() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.settle("interrupted")
        stage.lode("space")
        XCTAssertTrue(stage.searcher.isVisible)
        XCTAssertTrue(stage.draft.isOpen, "exactly two exits; a bar is not one of them")
        XCTAssertFalse(stage.press("s"), "the letter is the launcher's while it stands")
        stage.searcher.hide()
        cmd(stage, "x")
        XCTAssertEqual(stage.draft.buffer.text, "interruptedx", "keys come back to the draft")
        XCTAssertTrue(stage.pasteboard.isEmpty, "nothing was written by a bar opening")
    }

    func testAChainReleasedOverTheDraftEndsAndTheDraftTakesTheKey() {
        let stage = Stage()
        stage.lode(".")
        stage.lode("b") // a branch: x and g under it
        XCTAssertFalse(stage.engine.isQuiet)
        cmd(stage, "h"); cmd(stage, "i")
        XCTAssertEqual(stage.draft.buffer.text, "hi", "unheld letters over a draft are text, not chain letters")
        XCTAssertTrue(stage.actions.summoned.isEmpty)
    }

    func testAMutedMicsLateFinalLeavesTheCursorWhereTheHandIs() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.hear("hello world")
        stage.draft.toggleMic()
        cmd(stage, "space"); cmd(stage, "m"); cmd(stage, "o"); cmd(stage, "r"); cmd(stage, "e")
        XCTAssertEqual(stage.draft.buffer.text, "hello world more")
        stage.speech.settle("Hello world!")
        XCTAssertEqual(stage.draft.buffer.text, "Hello world! more")
        cmd(stage, ".")
        XCTAssertEqual(stage.draft.buffer.text, "Hello world! more.", "typing continues at the end, not inside the spoken words")
    }

    func testCommandChordsPassThroughExceptTheOnesThatEdit() {
        let stage = Stage()
        stage.lode(".")
        cmd(stage, "a"); cmd(stage, "b")
        XCTAssertFalse(stage.commandPress("tab"), "⌘⇥ reaches the system: it is how the destination changes")
        XCTAssertTrue(stage.commandPress("delete"), "⌘⌫ edits the draft, not the app underneath")
        XCTAssertEqual(stage.draft.buffer.text, "")
        XCTAssertTrue(stage.draft.isOpen)
    }

    func testAnEmptyDraftLeavesNoTrace() {
        let stage = Stage()
        stage.lode(".")
        cmd(stage, "return")
        XCTAssertTrue(stage.pasteboard.isEmpty)
        XCTAssertTrue(stage.posted.isEmpty)
        XCTAssertEqual(stage.lastDraft?.action, "empty")
    }

    func testVocabularyRepairsSettledWords() {
        let stage = Stage()
        stage.draft.words = ["Ghostty"]
        stage.lode(".")
        stage.speech.settle("open ghostie now")
        XCTAssertEqual(stage.draft.buffer.text, "open Ghostty now")
    }

    func testTheRecordCountsAndNeverTheText() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.hear("h")
        stage.speech.settle("hello world")
        cmd(stage, "x")
        cmd(stage, "delete")
        cmd(stage, "escape")
        cmd(stage, "i")
        stage.clock.advance(by: 3)
        cmd(stage, "return")
        let event = stage.lastDraft
        XCTAssertEqual(event?.kind, .draft)
        XCTAssertEqual(event?.source, "speak")
        XCTAssertEqual(event?.action, "pasted")
        XCTAssertEqual(event?.words, 2)
        XCTAssertEqual(event?.typed, 1)
        XCTAssertEqual(event?.backspaces, 1)
        XCTAssertEqual(event?.switches, 2)
        XCTAssertEqual(event?.seconds ?? 0, 3, accuracy: 0.01)
        XCTAssertNotNil(event?.firstWord)
        XCTAssertNotNil(event?.openToFirstKey)
        let line = try! String(contentsOf: stage.eventsFile, encoding: .utf8)
        XCTAssertFalse(line.contains("hello"), "the text is never written down")
    }

    // MARK: - The editor, through the tap

    func testEditDoorVimDeleteWordAndPutBack() {
        let stage = Stage()
        stage.field = DraftController.Field(selection: nil, value: "one two three")
        stage.lode(".", shift: true)
        cmd(stage, "escape")
        XCTAssertEqual(stage.draft.vim.mode, .normal)
        cmd(stage, "g"); cmd(stage, "g")
        cmd(stage, "d"); cmd(stage, "w")
        XCTAssertEqual(stage.draft.buffer.text, "two three")
        cmd(stage, ".")
        XCTAssertEqual(stage.draft.buffer.text, "three")
        cmd(stage, "u")
        XCTAssertEqual(stage.draft.buffer.text, "two three")
        cmd(stage, "return")
        XCTAssertEqual(stage.pasteboard, ["two three"])
        XCTAssertEqual(stage.posted.map(\.key), ["v"])
    }

    func testYankWritesThePasteboardAndDeleteDoesNot() {
        let stage = Stage()
        stage.field = DraftController.Field(selection: nil, value: "alpha beta")
        stage.lode(".", shift: true)
        cmd(stage, "escape"); cmd(stage, "g"); cmd(stage, "g")
        cmd(stage, "d"); cmd(stage, "w")
        XCTAssertTrue(stage.pasteboard.isEmpty, "a delete stays inside the editor")
        cmd(stage, "y"); cmd(stage, "i"); cmd(stage, "w")
        XCTAssertEqual(stage.pasteboard, ["beta"])
        XCTAssertEqual(stage.hud.owner, .flash)
    }

    func testVisualSelectionShowsAndChangeEntersInsertWithTheMicWanted() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.settle("fix the middle word here")
        cmd(stage, "escape")
        XCTAssertEqual(stage.speech.pauses, 1)
        cmd(stage, "0"); cmd(stage, "w"); cmd(stage, "w")
        cmd(stage, "v"); cmd(stage, "e")
        XCTAssertEqual(stage.draft.vim.mode, .visual(line: false))
        XCTAssertEqual(stage.draft.vim.selection(in: stage.draft.buffer), 8..<14)
        cmd(stage, "c")
        XCTAssertEqual(stage.draft.mode, .insert)
        XCTAssertEqual(stage.speech.resumes, 1, "insert mode after the speak door brings the mic back")
        cmd(stage, "n"); cmd(stage, "e"); cmd(stage, "w")
        cmd(stage, "escape")
        XCTAssertEqual(stage.draft.buffer.text, "fix the new word here")
        XCTAssertEqual(stage.speech.pauses, 2)
    }

    func testEscapeClearsAPendingOperatorBeforeItCloses() {
        let stage = Stage()
        stage.field = DraftController.Field(selection: nil, value: "text")
        stage.lode(".", shift: true)
        cmd(stage, "escape")
        cmd(stage, "d")
        cmd(stage, "escape")
        XCTAssertTrue(stage.draft.isOpen, "the first escape only dropped the operator")
        cmd(stage, "escape")
        XCTAssertFalse(stage.draft.isOpen)
        XCTAssertEqual(stage.pasteboard, ["text"])
    }

    func testPutInNormalModeReadsThePasteboard() {
        let stage = Stage()
        stage.field = DraftController.Field(selection: nil, value: "ab")
        stage.pasteboard = ["Z"]
        stage.lode(".", shift: true)
        cmd(stage, "escape"); cmd(stage, "0")
        cmd(stage, "p")
        XCTAssertEqual(stage.draft.buffer.text, "aZb")
    }

    // MARK: - The review's findings, pinned

    func testClosingWhileTheRecognizerIsStillPreparingStopsTheSession() {
        let stage = Stage()
        stage.speech.slowToListen = true
        stage.lode(".")
        XCTAssertEqual(stage.speech.listens, 1)
        cmd(stage, "escape"); cmd(stage, "escape")
        XCTAssertFalse(stage.draft.isOpen)
        XCTAssertEqual(stage.speech.stops, 1, "a session asked for is a session stopped, whatever it reached")
        stage.speech.ready()
        XCTAssertFalse(stage.draft.isOpen, "a late listening state changes nothing")
    }

    func testKeysAreSwallowedWhileTheLastWordsSettle() {
        let stage = Stage()
        stage.speech.slowToStop = true
        stage.lode(".")
        stage.speech.settle("send this")
        cmd(stage, "return")
        XCTAssertTrue(stage.draft.isOpen, "closing, not closed")
        XCTAssertTrue(stage.press("return"), "a held ⏎ never reaches the app ahead of the paste")
        XCTAssertTrue(stage.posted.isEmpty)
        stage.speech.finish()
        XCTAssertFalse(stage.draft.isOpen)
        XCTAssertEqual(stage.posted.map(\.key), ["v"])
    }

    func testAPreviousSessionsWordsNeverLandInANewDraft() {
        let stage = Stage()
        stage.speech.slowToStop = true
        stage.lode(".")
        stage.speech.settle("first draft")
        cmd(stage, "escape"); cmd(stage, "escape")
        XCTAssertFalse(stage.draft.isOpen)
        stage.lode(".")
        XCTAssertTrue(stage.draft.isOpen)
        stage.speech.settleFromPreviousSession("late words from before")
        XCTAssertEqual(stage.draft.buffer.text, "", "the old session's final carries an old number")
        stage.speech.finish()
    }

    func testEscapeSettlesTheGhostAsSeenAndTheFinalReplacesItInPlace() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.settle("keep")
        stage.speech.hear("these words")
        cmd(stage, "escape")
        XCTAssertEqual(stage.draft.mode, .normal)
        XCTAssertEqual(stage.draft.buffer.ghost, "", "no ghost survives into normal mode")
        XCTAssertEqual(stage.draft.buffer.text, "keep these words", "what was seen is text now")
        stage.speech.settle("these words.")
        XCTAssertEqual(stage.draft.buffer.text, "keep these words.", "the final replaced the provisional text in place")
    }

    func testDeletingTheLineUnderAProvisionalGhostDropsTheLateFinal() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.settle("first line")
        cmd(stage, "return", shift: true)
        stage.speech.hear("second line")
        cmd(stage, "escape")
        XCTAssertEqual(stage.draft.buffer.text, "first line\nsecond line")
        cmd(stage, "d"); cmd(stage, "d")
        XCTAssertEqual(stage.draft.buffer.text, "first line", "dd took the line the ghost had become")
        stage.speech.settle("second line")
        XCTAssertEqual(stage.draft.buffer.text, "first line", "a final for text that is gone writes nothing")
        XCTAssertEqual(stage.draft.buffer.ghost, "")
    }

    func testClickingTheMicTogglesIt() {
        let stage = Stage()
        stage.lode(".")
        stage.draft.toggleMic()
        XCTAssertEqual(stage.speech.pauses, 1)
        stage.speech.hear("ignored")
        XCTAssertEqual(stage.draft.buffer.ghost, "", "a muted mic writes nothing")
        stage.draft.toggleMic()
        XCTAssertEqual(stage.speech.resumes, 1)
        XCTAssertEqual(stage.draft.mode, .insert)
        stage.speech.settle("heard")
        XCTAssertEqual(stage.draft.buffer.text, "heard")
    }

    func testChoosingAnInputWritesTheConfigAndRestartsTheSession() {
        let stage = Stage()
        stage.lode(".")
        XCTAssertEqual(stage.speech.lastInput, nil, "system default until chosen")
        stage.draft.selectInput("Other Microphone")
        XCTAssertEqual(stage.chosenInputs, ["Other Microphone"])
        XCTAssertEqual(stage.speech.stops, 1)
        XCTAssertEqual(stage.speech.listens, 2)
        XCTAssertEqual(stage.speech.lastInput, "Other Microphone")
        stage.draft.selectInput(nil)
        XCTAssertEqual(stage.chosenInputs, ["Other Microphone", nil])
        XCTAssertEqual(stage.speech.lastInput, nil)
    }

    func testDotRepeatHearsEveryCharacterAWordDeleteRemoved() {
        let stage = Stage()
        stage.field = DraftController.Field(selection: nil, value: "foo bar baz")
        stage.lode(".", shift: true)
        cmd(stage, "escape"); cmd(stage, "g"); cmd(stage, "g")
        cmd(stage, "c"); cmd(stage, "w")
        cmd(stage, "h"); cmd(stage, "e"); cmd(stage, "l"); cmd(stage, "l"); cmd(stage, "o")
        _ = stage.optionPress("delete")
        XCTAssertEqual(stage.draft.buffer.text, " bar baz")
        cmd(stage, "escape")
        cmd(stage, "w"); cmd(stage, ".")
        XCTAssertEqual(stage.draft.buffer.text, "  baz", "the repeat deletes a word and types nothing, as the hand did")
    }

    func testTheRegisterLineKnowsTheInput() {
        let stage = Stage()
        stage.lode(".")
        XCTAssertEqual(stage.draft.inputName, "Stage Microphone")
        stage.speech.level(0.8)
        XCTAssertTrue(stage.draft.isOpen)
    }

    // MARK: - The second review's findings, pinned

    func testTheWindowChooserOverTheDraftOwnsTheKeys() {
        let stage = Stage()
        stage.lode(".")
        stage.lode("tab")
        XCTAssertTrue(stage.searcher.isVisible, "the chooser opened")
        XCTAssertTrue(stage.draft.isOpen, "the draft waits underneath")
        XCTAssertFalse(stage.press("s"), "the letter goes to the chooser, not the draft")
        XCTAssertEqual(stage.draft.buffer.text, "")
    }

    func testASecondSpeakDoorDuringPrepareStartsNoSecondSession() {
        let stage = Stage()
        stage.speech.slowToListen = true
        stage.lode(".")
        stage.lode(".")
        XCTAssertEqual(stage.speech.listens, 1)
        stage.speech.ready()
        cmd(stage, "escape"); cmd(stage, "escape")
        XCTAssertEqual(stage.speech.openSessions, 0)
    }

    func testWholeFieldReplaceOnlyLandsInTheFieldItCameFrom() {
        let stage = Stage()
        stage.field = DraftController.Field(selection: nil, value: "composer text", cursor: 0, token: "composer")
        stage.lode(".", shift: true)
        cmd(stage, "escape")
        // The user clicked into another field of the same app before ⏎.
        stage.field = DraftController.Field(selection: nil, value: "search", cursor: 0, token: "search")
        cmd(stage, "return")
        XCTAssertEqual(stage.posted.map(\.key), ["v"], "a paste there, no select-all")
        XCTAssertEqual(stage.lastDraft?.row, "paste")
    }

    func testTheDoorKeysAutorepeatIsNotTyping() {
        let stage = Stage()
        stage.lode(".")
        XCTAssertTrue(stage.pressRepeat("."), "swallowed, not passed to the app")
        XCTAssertEqual(stage.draft.buffer.text, "", "no periods typed by a finger that lifted late")
        stage.clock.advance(by: 1)
        stage.pressRepeat("x")
        XCTAssertEqual(stage.draft.buffer.text, "x", "a held key later on is typing")
    }

    func testTheClipboardStripOverTheDraftFeedsIt() {
        let stage = Stage()
        stage.lode(".")
        cmd(stage, "a")
        _ = stage.press("v") // no strip: nothing copied yet on the stage, so the toggle flashes
        XCTAssertTrue(stage.draft.isOpen, "the strip's door never closes the draft")
    }

    func testALateFinalAfterEscapeAndInsertReplacesTheProvisionalTextOnce() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.hear("hello world")
        cmd(stage, "escape")
        XCTAssertEqual(stage.draft.buffer.text, "hello world")
        cmd(stage, "a", shift: true)
        XCTAssertEqual(stage.draft.mode, .insert)
        stage.speech.settle("hello world")
        XCTAssertEqual(stage.draft.buffer.text, "hello world", "replaced in place, never appended twice")
    }

    func testCommandVInNormalModeGoesThroughTheEditor() {
        let stage = Stage()
        stage.field = DraftController.Field(selection: nil, value: "ab", cursor: 0)
        stage.pasteboard = ["Z"]
        stage.lode(".", shift: true)
        cmd(stage, "escape")
        XCTAssertTrue(stage.commandPress("v"))
        XCTAssertEqual(stage.draft.buffer.text, "aZb")
        cmd(stage, "u")
        XCTAssertEqual(stage.draft.buffer.text, "ab", "one undo step")
    }

    // MARK: - The overnight pass

    func testMutingTheMicKeepsTheWordsItShowed() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.settle("keep")
        stage.speech.hear("these too")
        stage.draft.toggleMic()
        XCTAssertEqual(stage.draft.buffer.text, "keep these too", "what was shown is text, not lost")
        XCTAssertEqual(stage.draft.buffer.ghost, "")
        XCTAssertEqual(stage.draft.mode, .insert, "muting does not change the mode")
    }

    func testCommitWaitsForAStillVolatileLastSegment() {
        let stage = Stage()
        stage.speech.slowToStop = true
        stage.lode(".")
        stage.speech.settle("first sentence.")
        stage.speech.hear("second one")
        cmd(stage, "return")
        XCTAssertTrue(stage.draft.isOpen, "closing, waiting for the ghost to settle")
        XCTAssertTrue(stage.posted.isEmpty)
        stage.speech.finish()
        XCTAssertFalse(stage.draft.isOpen)
        XCTAssertEqual(stage.pasteboard.last, "first sentence. second one")
        XCTAssertEqual(stage.posted.map(\.key), ["v"])
    }

    func testCommandZUndoesInNormalMode() {
        let stage = Stage()
        stage.field = DraftController.Field(selection: nil, value: "one two", cursor: 0)
        stage.lode(".", shift: true)
        cmd(stage, "escape")
        cmd(stage, "d"); cmd(stage, "w")
        XCTAssertEqual(stage.draft.buffer.text, "two")
        XCTAssertTrue(stage.commandPress("z"))
        XCTAssertEqual(stage.draft.buffer.text, "one two")
    }

    func testCommandASelectsEverythingInNormalMode() {
        let stage = Stage()
        stage.field = DraftController.Field(selection: nil, value: "a\nb\nc", cursor: 0)
        stage.lode(".", shift: true)
        cmd(stage, "escape")
        XCTAssertTrue(stage.commandPress("a"))
        XCTAssertEqual(stage.draft.vim.mode, .visual(line: true))
        XCTAssertEqual(stage.draft.vim.selection(in: stage.draft.buffer), 0..<5)
        cmd(stage, "d")
        XCTAssertEqual(stage.draft.buffer.text, "")
    }

    func testControlChordsInInsertMode() {
        let stage = Stage()
        stage.lode(".")
        cmd(stage, "a"); cmd(stage, "b"); cmd(stage, "space"); cmd(stage, "c"); cmd(stage, "d")
        XCTAssertTrue(stage.controlPress("w"))
        XCTAssertEqual(stage.draft.buffer.text, "ab ")
        XCTAssertTrue(stage.controlPress("a"))
        XCTAssertEqual(stage.draft.buffer.cursor, 0)
        XCTAssertTrue(stage.controlPress("k"))
        XCTAssertEqual(stage.draft.buffer.text, "")
    }

    func testSpokenCapitalIsLoweredAfterTypedText() {
        let stage = Stage()
        stage.lode(".")
        cmd(stage, "h"); cmd(stage, "i"); cmd(stage, "space")
        stage.speech.settle("There you are.")
        XCTAssertEqual(stage.draft.buffer.text, "hi there you are.")
        stage.speech.settle("Good.")
        XCTAssertEqual(stage.draft.buffer.text, "hi there you are. Good.")
    }

    func testTheDraftVerbsDriveTheSamePaths() {
        let stage = Stage()
        stage.draft.open(door: .speak)
        XCTAssertTrue(stage.draft.isOpen)
        XCTAssertEqual(stage.draft.state["mode"] as? String, "insert")
        _ = stage.draft.handleKey("h", shift: false, command: false, option: false, control: false)
        XCTAssertEqual(stage.draft.state["text"] as? String, "h")
        XCTAssertFalse(stage.draft.feedAudio(path: "/nowhere.aiff"), "the stage's recognizer takes no files")
        stage.draft.cancel(reason: "control")
        XCTAssertEqual(stage.draft.state["open"] as? Bool, false)
        XCTAssertEqual(stage.pasteboard, ["h"])
    }
    /// Dictate, type, dictate: words still a ghost when the hand starts
    /// typing are reserved where they stand, the typed characters land
    /// after them, and the final that arrives later revises the reserved
    /// words in place — the order is the order it happened.
    func testTypingWhileWordsAreStillGhostKeepsTheOrder() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.hear("ship as")
        XCTAssertEqual(stage.draft.buffer.ghost, "ship as")
        cmd(stage, "space"); cmd(stage, "n"); cmd(stage, "o"); cmd(stage, "w")
        XCTAssertEqual(stage.draft.buffer.text, "ship as now",
                       "the ghost became reserved text and the typing landed after it")
        stage.speech.hear("ship it as")
        XCTAssertEqual(stage.draft.buffer.ghost, "",
                       "a cumulative volatile never doubles the reserved words")
        stage.speech.settle("Ship it as")
        XCTAssertEqual(stage.draft.buffer.text, "Ship it as now",
                       "the final revised the reserved words in place, not at the cursor")
        stage.speech.hear("please")
        stage.speech.settle("please")
        cmd(stage, "return")
        XCTAssertEqual(stage.pasteboard, ["Ship it as now please"],
                       "a second utterance lands after the typing, in spoken order")
    }
    /// v0.26.7 crashed on every `j`: the layout seam read the
    /// controller's buffer while the editor held it inout, and Swift's
    /// exclusivity check aborted the process. This walks the real path —
    /// controller, editor, panel layout — so that class of crash kills
    /// the test run instead of the app.
    func testVisualJAndKThroughTheRealPanel() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.settle("one two three")
        cmd(stage, "return", shift: true)
        stage.speech.settle("four five")
        cmd(stage, "escape")
        _ = stage.press("k")
        XCTAssertLessThan(stage.draft.buffer.cursor, 14, "k walks up to the first rendered line")
        _ = stage.press("j")
        XCTAssertGreaterThan(stage.draft.buffer.cursor, 13, "j walks back down")
        XCTAssertTrue(stage.draft.isOpen)
    }
    /// The stash trails the draft by half a second and a clean close
    /// clears it, so anything found at boot is a crash's leavings.
    func testTheStashFollowsTheDraftAndClearsAtClose() {
        let stage = Stage()
        var stashed: [String?] = []
        stage.draft.stash = { stashed.append($0) }
        stage.lode(".")
        stage.speech.settle("keep me safe")
        stage.clock.advance(by: 0.6)
        XCTAssertEqual(stashed.last ?? nil, "keep me safe")
        stage.speech.hear("and the ghost")
        stage.clock.advance(by: 0.6)
        XCTAssertEqual(stashed.last ?? nil, "keep me safe and the ghost",
                       "words still volatile are worth recovering too")
        cmd(stage, "return")
        XCTAssertEqual(stashed.last ?? nil, nil, "a clean close leaves nothing to recover")
    }
}
