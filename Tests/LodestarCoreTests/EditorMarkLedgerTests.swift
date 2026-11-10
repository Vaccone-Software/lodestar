import XCTest
@testable import LodestarCore

final class EditorMarkLedgerTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func typo(at location: Int, kind: EditorIssue.Kind = .spelling) -> EditorIssue {
        EditorIssue(range: NSRange(location: location, length: 7), original: "recieve", replacement: "receive", kind: kind)
    }

    /// Place one standing mark in "We need to recieve them." at second 0.
    private func ledgerWithMark(text: String = "We need to recieve them.") -> (EditorMarkLedger, EditorIssue) {
        var ledger = EditorMarkLedger()
        let issue = typo(at: (text as NSString).range(of: "recieve").location)
        let result = ledger.sync(drawn: [issue], all: [issue], text: text, caret: text.utf16.count, quiet: true, at: at(0))
        XCTAssertEqual(result.appeared, 1)
        return (ledger, issue)
    }

    func testTypingBeforeAMarkMovesItAndDoesNotMakeAnother() {
        var (ledger, _) = ledgerWithMark()
        let before = "We need to recieve them.", after = "So we need to recieve them."
        ledger.edit(from: before, to: after, at: at(2))
        let moved = typo(at: 14)
        let result = ledger.sync(drawn: [moved], all: [moved], text: after, caret: after.utf16.count, quiet: true, at: at(2.5))
        XCTAssertEqual(result.appeared, 0, "the same mark, a few characters on")
        XCTAssertTrue(result.endings.isEmpty)
        XCTAssertEqual(ledger.count, 1)
    }

    func testDeletingBeforeAMarkAndTypingAfterItLeaveItAlone() {
        var (ledger, _) = ledgerWithMark()
        var text = "We need to recieve them."
        for next in ["e need to recieve them.", "e need to recieve them. Ok", "e need to recieve them. Ok, "] {
            ledger.edit(from: text, to: next, at: at(2))
            text = next
        }
        let moved = typo(at: 10)
        let result = ledger.sync(drawn: [moved], all: [moved], text: text, caret: text.utf16.count, quiet: true, at: at(3))
        XCTAssertEqual(result.appeared, 0)
        XCTAssertEqual(ledger.count, 1)
    }

    func testASpaceAfterTheWordIsNotAnEditOfIt() {
        var (ledger, issue) = ledgerWithMark(text: "We need to recieve")
        ledger.edit(from: "We need to recieve", to: "We need to recieve ", at: at(2))
        let result = ledger.sync(drawn: [issue], all: [issue], text: "We need to recieve ", caret: 19, quiet: true, at: at(3))
        XCTAssertEqual(result.appeared, 0)
        XCTAssertTrue(result.endings.isEmpty)
    }

    func testAMarkGoneInUnderASecondIsNeverShown() {
        var (ledger, _) = ledgerWithMark()
        let fixed = "We need to receive them."
        ledger.edit(from: "We need to recieve them.", to: fixed, at: at(0.4))
        let result = ledger.sync(drawn: [], all: [], text: fixed, caret: fixed.utf16.count, quiet: true, at: at(1.6))
        XCTAssertTrue(result.endings.isEmpty, "stood 0.4 s before the hand fixed it: never read")
        XCTAssertEqual(ledger.count, 0)
    }

    func testAMarkTheHandFixedAfterItStoodIsFixedByHand() throws {
        var (ledger, _) = ledgerWithMark()
        let fixed = "We need to receive them."
        ledger.edit(from: "We need to recieve them.", to: fixed, at: at(3))
        // Still typing: judged only when the text is quiet.
        XCTAssertTrue(ledger.sync(drawn: [], all: [], text: fixed, caret: fixed.utf16.count, quiet: false, at: at(3.2)).endings.isEmpty)
        let ending = try XCTUnwrap(ledger.sync(drawn: [], all: [], text: fixed, caret: fixed.utf16.count, quiet: true, at: at(5)).endings.first)
        XCTAssertEqual(ending.outcome, .byHand)
        XCTAssertEqual(ending.stood, 3, accuracy: 0.001, "up to the hand's first keystroke in the word")
        XCTAssertTrue(ending.shown)
    }

    func testAWordNoLongerMarkedIsFixedByHandButGrammarNeedsTheFix() throws {
        // Spelling: rewritten as another word the checker accepts.
        var (spelling, _) = ledgerWithMark()
        let other = "We need to relieve them."
        spelling.edit(from: "We need to recieve them.", to: other, at: at(2))
        XCTAssertEqual(spelling.sync(drawn: [], all: [], text: other, caret: other.utf16.count, quiet: true, at: at(4)).endings.first?.outcome, .byHand)

        // Grammar: the model has not read the new sentence, so only the fix counts.
        var grammar = EditorMarkLedger()
        let text = "Their going to push it."
        let issue = EditorIssue(range: NSRange(location: 0, length: 5), original: "Their", replacement: "They're", kind: .grammar)
        _ = grammar.sync(drawn: [issue], all: [issue], text: text, caret: 23, quiet: true, at: at(0))
        let edited = "Thier going to push it."
        grammar.edit(from: text, to: edited, at: at(2))
        XCTAssertEqual(grammar.sync(drawn: [], all: [], text: edited, caret: 23, quiet: true, at: at(4)).endings.first?.outcome, .edited)
    }

    func testAnEditThatLeavesTheWordStillWrongIsEdited() throws {
        var (ledger, _) = ledgerWithMark()
        let text = "We need to recieved them."
        ledger.edit(from: "We need to recieve them.", to: text, at: at(2))
        let still = EditorIssue(range: NSRange(location: 11, length: 8), original: "recieved", replacement: "received", kind: .spelling)
        let ending = try XCTUnwrap(ledger.sync(drawn: [still], all: [still], text: text, caret: text.utf16.count, quiet: true, at: at(4)).endings.first)
        XCTAssertEqual(ending.outcome, .edited)
        XCTAssertEqual(ledger.count, 1, "the new spelling is a mark of its own")
    }

    func testTheWordTheCaretIsInIsNotJudgedWhileItIsUnfinished() {
        var (ledger, _) = ledgerWithMark()
        let text = "We need to recive them."
        ledger.edit(from: "We need to recieve them.", to: text, at: at(2))
        let caret = 16   // inside the word
        XCTAssertTrue(ledger.sync(drawn: [], all: [], text: text, caret: caret, quiet: true, at: at(4)).endings.isEmpty)
        XCTAssertEqual(ledger.sync(drawn: [], all: [], text: text, caret: 24, quiet: true, at: at(5)).endings.count, 1)
    }

    func testAMarkTheEditorDropsItselfIsWithdrawnAfterTheAbsenceAndNotShown() throws {
        var (ledger, _) = ledgerWithMark()
        let text = "We need to recieve them."
        let caret = text.utf16.count
        XCTAssertTrue(ledger.sync(drawn: [], all: [], text: text, caret: caret, quiet: true, at: at(2)).endings.isEmpty, "given time to come back")
        XCTAssertTrue(ledger.sync(drawn: [], all: [], text: text, caret: caret, quiet: true, at: at(4)).endings.isEmpty)
        let ending = try XCTUnwrap(ledger.sync(drawn: [], all: [], text: text, caret: caret, quiet: true, at: at(5.5)).endings.first)
        XCTAssertEqual(ending.outcome, .withdrawn)
        XCTAssertFalse(ending.shown, "never the hand's to judge")
    }

    func testAMarkThatComesBackIsNotWithdrawn() {
        var (ledger, issue) = ledgerWithMark()
        let text = "We need to recieve them."
        _ = ledger.sync(drawn: [], all: [], text: text, caret: 24, quiet: true, at: at(2))
        let back = ledger.sync(drawn: [issue], all: [issue], text: text, caret: 24, quiet: true, at: at(3))
        XCTAssertEqual(back.appeared, 0)
        XCTAssertTrue(back.endings.isEmpty)
        XCTAssertTrue(ledger.sync(drawn: [issue], all: [issue], text: text, caret: 24, quiet: true, at: at(9)).endings.isEmpty)
    }

    func testAMarkScrolledOutOfViewIsNotWithdrawn() {
        var (ledger, issue) = ledgerWithMark()
        let text = "We need to recieve them."
        let result = ledger.sync(drawn: [], all: [issue], text: text, caret: 24, quiet: true, at: at(9))
        XCTAssertTrue(result.endings.isEmpty, "the editor still reports it; it only has no place on screen")
        XCTAssertEqual(ledger.count, 1)
    }

    func testAnAnswerIsShownHoweverBrieflyTheMarkStood() {
        var (ledger, issue) = ledgerWithMark()
        let ending = ledger.answer(issue, .fixed(via: "keys"), at: at(0.3))
        XCTAssertEqual(ending.outcome, .fixed(via: "keys"))
        XCTAssertTrue(ending.shown)
        XCTAssertEqual(ending.stood, 0.3, accuracy: 0.001)
        XCTAssertEqual(ledger.count, 0)
    }

    func testLeavingTheFieldEndsEveryMarkStandingAsAway() {
        var (ledger, issue) = ledgerWithMark()
        let text = "We need to recieve them."
        XCTAssertEqual(ledger.clear(text: text, all: [issue], at: at(30)),
                       [EditorMarkLedger.Ending(kind: .spelling, outcome: .away, stood: 30)])
        XCTAssertEqual(ledger.count, 0)

        var brief = EditorMarkLedger()
        _ = brief.sync(drawn: [issue], all: [issue], text: text, caret: 24, quiet: true, at: at(0))
        XCTAssertTrue(brief.clear(text: text, all: [issue], at: at(0.5)).isEmpty, "stood half a second: never read")
    }

    // MARK: - A mark stands only while it is drawn

    func testAMarkHiddenSoonAfterItWasDrawnWritesNothingWhenItIsCleared() {
        var (ledger, issue) = ledgerWithMark()
        ledger.hide(at: at(0.3))
        let endings = ledger.clear(text: "We need to recieve them.", all: [issue], at: at(2.3))
        XCTAssertTrue(endings.isEmpty, "it stood 0.3 s on the screen, and the other two seconds it was hidden")
    }

    func testTheTimeAMarkWasHiddenIsLeftOutOfHowLongItStood() throws {
        var (ledger, issue) = ledgerWithMark()
        ledger.hide(at: at(1.5))
        ledger.show(at: at(3.5))
        let ending = try XCTUnwrap(ledger.clear(text: "We need to recieve them.", all: [issue], at: at(4)).first)
        XCTAssertEqual(ending.stood, 2.0, accuracy: 0.001, "1.5 s before it was hidden and 0.5 s after it came back")
        XCTAssertEqual(ending.outcome, .away)
    }

    func testAnEndingGivenTheMomentTheMarksCameDownStopsTheClockThere() throws {
        // The ledger was not told of the hiding.
        var (ledger, issue) = ledgerWithMark()
        let ending = try XCTUnwrap(ledger.clear(text: "We need to recieve them.", all: [issue], at: at(3.5), until: at(1.5)).first)
        XCTAssertEqual(ending.stood, 1.5, accuracy: 0.001, "not 3.5")

        // And one it heard of later than the moment it was cleared to.
        var (later, laterIssue) = ledgerWithMark()
        _ = later.sync(drawn: [laterIssue], all: [laterIssue], text: "We need to recieve them.", caret: 24, quiet: true, at: at(2.5))
        let ended = try XCTUnwrap(later.clear(text: "We need to recieve them.", all: [laterIssue], at: at(3.5), until: at(1.5)).first)
        XCTAssertEqual(ended.stood, 1.5, accuracy: 0.001, "what it counted after the marks came down is taken back")
    }

    func testAMarkClearedSaysHowItWasLeft() throws {
        let text = "We need to recieve them."
        var (away, issue) = ledgerWithMark()
        let ended = try XCTUnwrap(away.clear(text: text, all: [issue], at: at(2)).first)
        XCTAssertEqual(ended.outcome, .away, "the hand went elsewhere, unless said otherwise")
        XCTAssertTrue(ended.shown)

        var (written, other) = ledgerWithMark()
        let replaced = try XCTUnwrap(written.clear(text: "", all: [other], at: at(2), how: .replaced).first)
        XCTAssertEqual(replaced.outcome, .replaced)
        XCTAssertEqual(replaced.stood, 2, accuracy: 0.001)
        XCTAssertTrue(replaced.shown)
    }

    func testAMarkAnsweredWhileTheMarksAreHiddenDidNotStandThroughTheHiding() throws {
        var (ledger, issue) = ledgerWithMark()
        ledger.hide(at: at(0.4))
        let ending = ledger.answer(issue, .fixed(via: "keys"), at: at(5))
        XCTAssertEqual(ending.stood, 0.4, accuracy: 0.001)
    }

    func testTheFixAllBatchDoesNotEndTheMarksBetweenItsEdits() throws {
        // Two fixes at either end of the text, a mark left standing between them.
        let text = "Teh cat sat on recieve mat adn went."
        let ns = text as NSString
        let first = EditorIssue(range: ns.range(of: "Teh"), original: "Teh", replacement: "The", kind: .spelling)
        let middle = typo(at: ns.range(of: "recieve").location)
        let last = EditorIssue(range: ns.range(of: "adn"), original: "adn", replacement: "and", kind: .spelling)
        var ledger = EditorMarkLedger()
        _ = ledger.sync(drawn: [first, middle, last], all: [first, middle, last], text: text, caret: 0, quiet: true, at: at(0))
        _ = ledger.answer(first, .fixed(via: "all"), at: at(2))
        _ = ledger.answer(last, .fixed(via: "all"), at: at(2))
        let after = "The cat sat on recieve mat and went."
        ledger.edit(from: text, to: after, at: at(2.1))
        let found = EditorIssue(range: (after as NSString).range(of: "recieve"), original: "recieve", replacement: "receive", kind: .spelling)
        let result = ledger.sync(drawn: [found], all: [found], text: after, caret: 0, quiet: true, at: at(4))
        XCTAssertEqual(result.appeared, 0, "the mark between the two edits is the same mark")
        XCTAssertTrue(result.endings.isEmpty)
    }
}

final class EditorRecordTests: XCTestCase {
    private func event(_ action: String, kind: String? = "spelling", app: String = "slack",
                       via: String? = nil, seconds: Double? = nil, source: String? = nil, at t: TimeInterval) -> ObservationEvent {
        var event = ObservationEvent(t: Date(timeIntervalSinceReferenceDate: 800_000_000 + t), kind: .editor)
        event.action = action
        event.rec = kind
        event.app = app
        event.seconds = seconds
        event.row = via
        event.source = source
        return event
    }

    func testTheOldEraIsKeptApartAndTheNewOneCountsOutcomes() throws {
        var events: [ObservationEvent] = []
        // Before: counted on placement.
        for t in 0..<10 { events.append(event("shown", at: Double(t))) }
        events.append(event("applied", via: "keys", at: 11))
        events.append(event("dismissed", kind: "name", at: 12))
        // After: one mark each way.
        events.append(event("stood", at: 100)); events.append(event("applied", via: "keys", seconds: 5, at: 100))
        events.append(event("stood", at: 101)); events.append(event("byhand", seconds: 2, at: 101))
        events.append(event("stood", kind: "grammar", at: 102)); events.append(event("changed", kind: "grammar", seconds: 40, at: 102))
        events.append(event("stood", at: 103)); events.append(event("left", seconds: 9, at: 103))
        events.append(event("stood", at: 104)); events.append(event("dismissed", kind: "sentence", via: "keys", seconds: 3, source: "spelling", at: 104))
        events.append(event("withdrawn", at: 105))
        let record = EditorRecord(events: events.shuffled())

        XCTAssertEqual(record.legacy.shown, 10)
        XCTAssertEqual(record.legacy.applied, 1)
        XCTAssertEqual(record.legacy.learned, 1)
        let t = record.total
        XCTAssertEqual(t.shown, 5, "the old shown events are not in it")
        XCTAssertEqual(t.applied, 1)
        XCTAssertEqual(t.byHand, 1)
        XCTAssertEqual(t.edited, 1)
        XCTAssertEqual(t.left, 1)
        XCTAssertEqual(t.kept, 1)
        XCTAssertEqual(t.withdrawn, 1)
        XCTAssertEqual(try XCTUnwrap(t.share(t.useful)), 0.4, accuracy: 0.0001, "fixed and fixed by hand, over shown")
        XCTAssertEqual(record.byKind["grammar"]?.edited, 1)
        XCTAssertEqual(record.byKind["spelling"]?.kept, 1, "a dismissal is of the kind of mark it answered")
        XCTAssertEqual(record.byApp["slack"]?.shown, 5)
        XCTAssertEqual(record.handStood, [1, 0, 1], "two seconds, and forty")
    }

    func testTheReportKeepsTheErasApartAndLabelsThem() {
        var events: [ObservationEvent] = []
        for t in 0..<8 { events.append(event("shown", at: Double(t))) }
        events.append(event("applied", via: "keys", at: 9))
        events.append(event("stood", at: 100)); events.append(event("applied", via: "keys", seconds: 5, at: 100))
        events.append(event("stood", at: 101)); events.append(event("byhand", seconds: 2, at: 101))
        events.append(event("stood", kind: "grammar", at: 102)); events.append(event("left", kind: "grammar", seconds: 9, at: 102))
        events.append(event("stood", at: 103)); events.append(event("changed", seconds: 9, at: 103))
        events.append(event("applied", app: "draft", at: 104))
        let lines = EditorRecord(events: events).report()
        XCTAssertTrue(lines.contains { $0.contains("4 marks shown · 50% useful (25% fixed by Lodestar + 25% fixed by hand)") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("grammar") && $0.contains("1 shown") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("counted when placed, not comparable with the above before") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("8 marks · 1 fixed") }, "the old era keeps its own numbers: \(lines)")
        XCTAssertTrue(lines.contains { $0.contains("the draft, apart: 1 fixed") }, "\(lines)")
        XCTAssertEqual(EditorRecord(events: []).report(), [])
    }

    // MARK: - How a mark was left

    func testHowAMarkWasLeftIsCountedApartAndTheOlderLeftStaysItsOwn() {
        let events = [event("stood", at: 100), event("left", seconds: 9, at: 100),
                      event("stood", at: 101), event("replaced", seconds: 4, at: 101),
                      event("stood", kind: "grammar", at: 102), event("away", kind: "grammar", seconds: 3, at: 102),
                      event("stood", at: 103), event("away", seconds: 2, at: 103)]
        let t = EditorRecord(events: events.shuffled()).total
        XCTAssertEqual(t.shown, 4)
        XCTAssertEqual(t.left, 1, "as older builds wrote it: not told apart")
        XCTAssertEqual(t.replaced, 1)
        XCTAssertEqual(t.away, 2)
        XCTAssertEqual(t.standing, 4, "left standing, however it was recorded")
    }

    /// A small record, as the report prints it: two eras of "left" in it.
    private var small: [ObservationEvent] {
        var events: [ObservationEvent] = []
        func mark(_ outcome: String, kind: String, app: String, t: TimeInterval, seconds: Double = 5) {
            events.append(event("stood", kind: kind, app: app, at: t))
            events.append(event(outcome, kind: kind, app: app, seconds: seconds, at: t))
        }
        var t = 100.0
        for outcome in ["applied", "applied", "byhand", "away", "away", "left"] { mark(outcome, kind: "spelling", app: "telegram", t: t); t += 1 }
        for outcome in ["replaced", "away"] { mark(outcome, kind: "grammar", app: "telegram", t: t); t += 1 }
        for outcome in ["applied", "away"] { mark(outcome, kind: "grammar", app: "slack", t: t); t += 1 }
        return events
    }

    func testTheReportSaysHowMarksWereLeftAndNeverMixesTheKindsSilently() throws {
        let lines = EditorRecord(events: small).report()
        func line(_ prefix: String) throws -> String { try XCTUnwrap(lines.first { $0.hasPrefix(prefix) }, "\(lines)") }
        XCTAssertTrue(try line("  edited into something else").contains("left standing 60%"), "\(lines)")
        XCTAssertEqual(try line("  left standing:"), "  left standing: text replaced 10% · went elsewhere 40% · not recorded 10%")
        XCTAssertEqual(try line("  grammar"), "  grammar   4 shown    25% useful  fixed 25% · by hand 0% · edited 0% · left 75% · kept 0%")
        XCTAssertEqual(try line("  by app"), "  by app, spelling and grammar together:")
        XCTAssertEqual(try line("  telegram"), "  telegram              8 marks    38% useful  2 fixed · 1 by hand · 0 edited · 5 left (3 spelling, 2 grammar) · 0 kept")
        XCTAssertEqual(try line("  slack"), "  slack                 2 marks    50% useful  1 fixed · 0 by hand · 0 edited · 1 left (1 grammar) · 0 kept")
        let widest = lines.map(\.count).max() ?? 0
        XCTAssertLessThanOrEqual(widest, 125, "the width the report already uses: \(lines)")
    }

    func testTheLeftLineIsLeftOutWhenTheRecordHasNoNewOutcomes() {
        let events = [event("stood", at: 100), event("left", seconds: 9, at: 100)]
        let lines = EditorRecord(events: events).report()
        XCTAssertFalse(lines.contains { $0.hasPrefix("  left standing:") }, "older records say nothing more than left: \(lines)")
        XCTAssertTrue(lines.contains { $0.contains("left standing 100%") }, "\(lines)")
    }

    /// The log moves lines as the bytes they are and reads only their stamp,
    /// so an outcome it has no name for is carried through a compaction. A
    /// record from before the outcomes were told apart and one from after
    /// fold into one count.
    func testAnOlderMonthWithLeftAndANewerWithReplacedAndAwayFoldTogetherThroughACompaction() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("record-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = SealedFixture.eventLog(directory.appendingPathComponent("events.jsonl"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func stamped(_ action: String, kind: String? = "spelling", at date: Date, seconds: Double? = nil) -> [ObservationEvent] {
            var shown = ObservationEvent(t: date, kind: .editor)
            shown.action = "stood"
            shown.rec = kind
            shown.app = "telegram"
            var ended = ObservationEvent(t: date, kind: .editor)
            ended.action = action
            ended.rec = kind
            ended.app = "telegram"
            ended.seconds = seconds
            return [shown, ended]
        }
        let older = now.addingTimeInterval(-70 * 86_400), newer = now.addingTimeInterval(-3600)
        for e in stamped("left", at: older, seconds: 9) + stamped("left", kind: "grammar", at: older, seconds: 4)
            + stamped("replaced", at: newer, seconds: 3) + stamped("away", kind: "grammar", at: newer, seconds: 6)
            + stamped("away", at: newer, seconds: 2) { log.append(e) }
        log.flush()
        log.compact(now: now)
        let live = SealedFixture.text(of: log.file)
        XCTAssertFalse(live.contains("\"left\""), "the older month has moved to its shard")
        XCTAssertTrue(live.contains("replaced"), "and the newer month has stayed")

        let back = SealedFixture.eventLog(log.file).readAll()
        XCTAssertEqual(back.filter { $0.action == "left" }.count, 2, "the old outcome is kept, not dropped")
        XCTAssertEqual(back.filter { $0.action == "replaced" }.count, 1)
        XCTAssertEqual(back.filter { $0.action == "away" }.count, 2, "and so is the new one, after the compaction")
        let record = EditorRecord(events: back)
        XCTAssertEqual(record.total.shown, 5)
        XCTAssertEqual(record.total.left, 2)
        XCTAssertEqual(record.total.replaced, 1)
        XCTAssertEqual(record.total.away, 2)
        XCTAssertEqual(record.byKind["spelling"]?.standing, 3)
        XCTAssertEqual(record.byKind["grammar"]?.standing, 2)
        XCTAssertEqual(record.byAppKind["telegram"]?["grammar"]?.standing, 2)
    }

    func testFixesTakenBackAreNotFixed() {
        let events = [event("stood", at: 0), event("applied", at: 0), event("stood", at: 1), event("applied", at: 1),
                      event("undone", at: 2)]
        let t = EditorRecord(events: events).total
        XCTAssertEqual(t.applied, 2)
        XCTAssertEqual(t.fixed, 1)
        XCTAssertEqual(t.useful, 1)
    }

    func testTheDraftIsALineOfItsOwnInEitherEra() {
        let events = [event("applied", app: "draft", at: 0), event("applied", app: "draft", at: 1),
                      event("undone", app: "draft", at: 2), event("dismissed", kind: "name", app: "draft", at: 3),
                      event("shown", at: 4), event("applied", at: 5),
                      event("stood", at: 100), event("applied", at: 100), event("applied", app: "draft", at: 101)]
        let record = EditorRecord(events: events)
        XCTAssertEqual(record.draft.fixed, 2)
        XCTAssertEqual(record.draft.kept, 1)
        XCTAssertEqual(record.legacy.applied, 1, "the draft's fixes are not over the field's denominator")
        XCTAssertEqual(record.total.applied, 1)
        XCTAssertNil(record.byApp["draft"])
    }

    func testNoStoodEventMeansEverythingIsTheOldEra() {
        let record = EditorRecord(events: [event("shown", at: 0), event("applied", at: 1)])
        XCTAssertNil(record.since)
        XCTAssertEqual(record.total.shown, 0)
        XCTAssertEqual(record.legacy.shown, 1)
    }
}
