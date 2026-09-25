import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

// MARK: - Fakes

/// A field the test types into. Rects are laid out on a grid of seven
/// points a unit; a replace checks the words first, the way accessibility
/// does, and can be told to stall like an app that stopped answering.
final class FakeFieldSource: EditorFieldSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _field: EditorField?
    private var _stall: TimeInterval = 0
    private var _reads = 0

    var field: EditorField? {
        get { lock.withLock { _field } }
        set { lock.withLock { _field = newValue } }
    }
    var stall: TimeInterval {
        get { lock.withLock { _stall } }
        set { lock.withLock { _stall = newValue } }
    }
    var reads: Int { lock.withLock { _reads } }
    var text: String? { field?.text }

    private func wait() {
        let seconds = stall
        if seconds > 0 { Thread.sleep(forTimeInterval: seconds) }
    }

    func focusedField(frontmost: pid_t?) -> EditorField? {
        wait()
        lock.withLock { _reads += 1 }
        return field
    }

    func rects(for ranges: [NSRange], in field: EditorField) -> [CGRect?] {
        wait()
        return ranges.map { CGRect(x: 100 + CGFloat($0.location) * 7, y: 200, width: CGFloat($0.length) * 7, height: 16) }
    }

    func replace(_ range: NSRange, expected: String, with text: String, in field: EditorField) -> Bool {
        wait()
        return lock.withLock {
            guard var current = _field, current.pid == field.pid,
                  EditorAX.stillReads(current.text, range: range, expected: expected) else { return false }
            current.text = (current.text as NSString).replacingCharacters(in: range, with: text)
            _field = current
            return true
        }
    }
}

/// A model the test answers for. `held` keeps every question waiting
/// until the test lets it go.
final class FakeProofreader: EditorProofreader, @unchecked Sendable {
    private let lock = NSLock()
    private var _answers: [String: String] = [:]
    private var _asked: [String] = []
    private var _concurrent = 0
    private var _maxConcurrent = 0
    private var _released: [String] = []
    private var _engines: [EditorEngine] = []
    private var _held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    var asked: [String] { lock.withLock { _asked } }
    var maxConcurrent: Int { lock.withLock { _maxConcurrent } }
    var released: [String] { lock.withLock { _released } }
    var engines: [EditorEngine] { lock.withLock { _engines } }
    var waitingCount: Int { lock.withLock { waiting.count } }

    func answer(_ sentence: String, _ corrected: String) { lock.withLock { _answers[sentence] = corrected } }
    func hold() { lock.withLock { _held = true } }

    /// Let every waiting question answer, and the ones after it too.
    func letGo() {
        let resumed: [CheckedContinuation<Void, Never>] = lock.withLock {
            _held = false
            defer { waiting = [] }
            return waiting
        }
        resumed.forEach { $0.resume() }
    }

    /// Let the one waiting question answer; the next waits again.
    func letOneGo() {
        let one: CheckedContinuation<Void, Never>? = lock.withLock { waiting.isEmpty ? nil : waiting.removeFirst() }
        one?.resume()
    }

    func correct(_ sentence: String) async -> String? {
        let held: Bool = lock.withLock {
            _asked.append(sentence)
            _concurrent += 1
            _maxConcurrent = max(_maxConcurrent, _concurrent)
            return _held
        }
        if held { await withCheckedContinuation { continuation in lock.withLock { waiting.append(continuation) } } }
        return lock.withLock {
            _concurrent -= 1
            return _answers[sentence]
        }
    }

    func setEngine(_ engine: EditorEngine) async { lock.withLock { _engines.append(engine) } }
    private var _prepared = 0
    var prepared: Int { lock.withLock { _prepared } }
    func prepare() async { lock.withLock { _prepared += 1 } }
    func release(reason: String) async { lock.withLock { _released.append(reason) } }
}

/// The marks pane as a ledger.
final class FakeMarksDrawing: EditorMarksDrawing {
    private(set) var shown: [CGRect] = []
    private(set) var hides = 0
    func show(_ rects: [CGRect], over window: CGRect) { shown = rects }
    func hide() { shown = []; hides += 1 }
}

/// Everything the editor controller is built from, faked, with a store of
/// its own on disk.
final class EditorRig {
    let source = FakeFieldSource()
    let reader = FakeProofreader()
    let drawing = FakeMarksDrawing()
    let clock = VirtualClock()
    let queue = DispatchQueue(label: "test.editor.ax")
    let directory: URL
    let observations: ObservationStore
    let controller: EditorController
    var flashes: [String] = []
    var names: [String] = []

    init(hover: Bool = false, skipApps: Set<String> = []) {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        observations = ObservationStore(file: directory.appendingPathComponent("observations.json"),
                                        log: EventLog(file: directory.appendingPathComponent("events.jsonl")))
        controller = EditorController(source: source, queue: queue, proofreader: reader, drawing: drawing,
                                      hover: hover ? EditorHover(clock: clock.clock) : nil,
                                      clock: clock.clock, polls: false, modelReady: { $0.usesModel })
        controller.observations = observations
        controller.flash = { [unowned self] in self.flashes.append($0) }
        controller.learnName = { [unowned self] in self.names.append($0) }
        controller.apply(enabled: true, engine: .standard, language: "en_US", vocabulary: [],
                         skipApps: skipApps)
    }

    deinit {
        controller.hover?.panel?.close()
        try? FileManager.default.removeItem(at: directory)
    }

    static func field(_ text: String, caret: Int? = nil, pid: pid_t = 4242, app: String = "TextEdit",
                      bundle: String = "com.apple.TextEdit") -> EditorField {
        EditorField(element: AXUIElementCreateApplication(pid), pid: pid, appName: app, bundleID: bundle,
                    text: text, caret: caret ?? (text as NSString).length,
                    frame: CGRect(x: 80, y: 180, width: 800, height: 400),
                    windowFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))
    }

    /// The hand typed: the field now reads `text`, and the editor's beat
    /// sees it.
    func type(_ text: String, caret: Int? = nil, pid: pid_t = 4242, app: String = "TextEdit",
              bundle: String = "com.apple.TextEdit") {
        let field = Self.field(text, caret: caret, pid: pid, app: app, bundle: bundle)
        source.field = field
        controller.receive(field)
    }

    /// Another beat on the same field.
    func beat() { controller.receive(source.field) }

    /// Spin the main queue until `condition` holds, or fail after a bound
    /// of wall time: the fakes answer on a real queue.
    func settle(_ what: String = "condition", within seconds: TimeInterval = 3,
                file: StaticString = #filePath, line: UInt = #line, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { XCTFail("never settled: \(what)", file: file, line: line); return }
            Stage.pump()
        }
    }

    /// The queue's work done and its hops home run.
    func drain() {
        queue.sync {}
        Stage.pump()
    }

    var events: [ObservationEvent] {
        observations.flush()
        return observations.log.recent(days: 30, now: clock.now.addingTimeInterval(1)).filter { $0.kind == .editor }
    }
}

// MARK: - The controller

final class EditorControllerTests: XCTestCase {
    func testAMistakeIsMarkedWhereItStands() {
        let rig = EditorRig()
        rig.type("We need to recieve them.")
        rig.settle("the mark") { rig.controller.lensMarks.count == 1 }
        let mark = rig.controller.lensMarks[0]
        XCTAssertEqual(mark.issue.replacement, "receive")
        XCTAssertEqual(mark.rect.minX, 100 + 11 * 7, "the fake's rect for the word's own range")
        XCTAssertEqual(rig.drawing.shown, [mark.rect], "the line is drawn under it")
    }

    func testANewFieldClearsTheOldMarksAtOnce() {
        let rig = EditorRig()
        rig.type("We need to recieve them.")
        rig.settle("the mark") { !rig.controller.lensMarks.isEmpty }
        rig.source.stall = 0.3
        rig.type("All is well here.", pid: 5151, app: "Notes", bundle: "com.apple.Notes")
        XCTAssertTrue(rig.controller.lensMarks.isEmpty, "the old field's marks go before the new ones are placed")
        XCTAssertTrue(rig.drawing.shown.isEmpty)
        rig.drain()
    }

    func testASkippedAppIsNeverRead() {
        for skip in ["com.tinyspeck.slackmacgap", "slack"] {
            let rig = EditorRig(skipApps: [skip])
            rig.type("Their going to recieve it. Ok.", app: "Slack", bundle: "com.tinyspeck.slackmacgap")
            rig.drain()
            XCTAssertNil(rig.controller.field, "skipped by \(skip)")
            XCTAssertTrue(rig.controller.lensMarks.isEmpty)
            XCTAssertTrue(rig.reader.asked.isEmpty, "the model never saw it")
        }
    }

    func testPasswordsSearchBoxesAndTerminalsAreNeverRead() {
        XCTAssertTrue(EditorAX.isReadable(role: "AXTextArea", subrole: "", valueSettable: true, rangeSettable: true))
        XCTAssertTrue(EditorAX.isReadable(role: "AXTextField", subrole: "", valueSettable: false, rangeSettable: true))
        XCTAssertFalse(EditorAX.isReadable(role: "AXTextField", subrole: "AXSecureTextField",
                                           valueSettable: true, rangeSettable: true), "a password")
        XCTAssertFalse(EditorAX.isReadable(role: "AXTextField", subrole: "AXSearchField",
                                           valueSettable: true, rangeSettable: true), "a search box")
        XCTAssertFalse(EditorAX.isReadable(role: "AXTextArea", subrole: "", valueSettable: false, rangeSettable: false),
                       "a terminal's screen")
        XCTAssertFalse(EditorAX.isReadable(role: "AXButton", subrole: "", valueSettable: true, rangeSettable: true))
    }

    func testADocumentIsNotReadButAQuotedThreadDoesNotCount() {
        let rig = EditorRig()
        let long = String(repeating: "We ship the build today. ", count: 900) + "We need to recieve them."
        rig.type(long)
        rig.drain()
        XCTAssertNil(rig.controller.field, "past twenty thousand units: a document")
        XCTAssertTrue(rig.reader.asked.isEmpty)

        let reply = "We need to recieve them.\n\nOn Tue, Sep 23, 2026 at 9:00 AM Sam Lee wrote:\n"
            + String(repeating: "> We ship the build today.\n", count: 1200)
        XCTAssertGreaterThan((reply as NSString).length, EditorController.maxLength)
        rig.type(reply)
        rig.settle("the reply's mark") { rig.controller.lensMarks.count == 1 }
        XCTAssertEqual(rig.controller.lensMarks.first?.issue.original, "recieve", "only the writer's part is read")
    }

    func testTheSentenceAtTheCaretWaitsForAPause() {
        let rig = EditorRig()
        rig.type("Their going to push it. Let me know if your")
        rig.settle("the finished sentence asked") { rig.reader.asked.count == 1 }
        XCTAssertEqual(rig.reader.asked, ["Their going to push it."])
        rig.clock.advance(by: 0.5)
        rig.beat()
        rig.drain()
        XCTAssertEqual(rig.reader.asked.count, 1, "half a second is still typing")
        rig.clock.advance(by: 0.6)
        rig.beat()
        rig.settle("the paused sentence asked") { rig.reader.asked.count == 2 }
        XCTAssertEqual(rig.reader.asked.last, "Let me know if your")
    }

    func testTheModelIsAskedOneSentenceAtATime() {
        let rig = EditorRig()
        rig.reader.hold()
        rig.type("One two three. Four five six. Seven eight nine. Ten.")
        rig.settle("the first question") { rig.reader.waitingCount == 1 }
        for _ in 0..<5 { Stage.pump() }
        XCTAssertEqual(rig.reader.asked.count, 1, "the rest wait their turn")
        rig.reader.letOneGo()
        rig.settle("the second question") { rig.reader.waitingCount == 1 && rig.reader.asked.count == 2 }
        rig.reader.letGo()
        rig.settle("every sentence asked") { rig.reader.asked.count == 3 }
        XCTAssertEqual(rig.reader.maxConcurrent, 1)
        XCTAssertFalse(rig.reader.asked.contains("Ten."), "one word is not a sentence to read")
    }

    func testASentenceGoneBeforeItsTurnIsNotAsked() {
        let rig = EditorRig()
        rig.reader.hold()
        rig.type("One two three. Four five six. Seven eight nine.")
        rig.settle("the first question") { rig.reader.waitingCount == 1 }
        rig.type("One two three. Four five six.")
        rig.reader.letGo()
        rig.settle("the second answered") { rig.reader.asked.count == 2 }
        for _ in 0..<10 { Stage.pump() }
        XCTAssertEqual(rig.reader.asked, ["One two three.", "Four five six."])
    }

    func testAnAnswerForAnEditedSentenceMarksNothing() {
        let rig = EditorRig()
        rig.reader.hold()
        rig.reader.answer("Their going to push it.", "They're going to push it.")
        rig.type("Their going to push it.")
        rig.settle("asked") { rig.reader.waitingCount == 1 }
        rig.type("They are going to push it.")
        rig.reader.letGo()
        rig.settle("both asked") { rig.reader.asked.count == 2 }
        rig.drain()
        rig.beat()
        rig.drain()
        XCTAssertTrue(rig.controller.lensMarks.isEmpty, "the answer was for words no longer there")
    }

    func testAnUnansweredSentenceIsNotAskedEveryBeat() {
        let rig = EditorRig()
        rig.type("Their going to push it.")
        rig.settle("asked") { rig.reader.asked.count == 1 }
        rig.drain()
        for _ in 0..<5 { rig.clock.advance(by: 0.2); rig.beat() }
        rig.drain()
        XCTAssertEqual(rig.reader.asked.count, 1, "no answer reads as the sentence unchanged")
    }

    func testAModelAnswerBecomesAMarkAndAFix() {
        let rig = EditorRig()
        rig.reader.answer("Their going to push it.", "They're going to push it.")
        rig.type("Their going to push it.")
        rig.settle("the answer") { rig.reader.asked.count == 1 }
        rig.drain()
        rig.beat()
        rig.settle("the mark") { rig.controller.lensMarks.count == 1 }
        let mark = rig.controller.lensMarks[0]
        XCTAssertEqual(mark.issue.shown, "They're")
        var done: Bool?
        rig.controller.fix(mark) { done = $0 }
        rig.settle("the fix") { done != nil }
        XCTAssertEqual(done, true)
        XCTAssertEqual(rig.source.text, "They're going to push it.")
        XCTAssertTrue(rig.controller.lensMarks.isEmpty)
    }

    func testAFixAndItsUndo() {
        let rig = EditorRig()
        rig.type("We need to recieve them.")
        rig.settle("the mark") { rig.controller.lensMarks.count == 1 }
        var fixed: Bool?
        rig.controller.fix(rig.controller.lensMarks[0]) { fixed = $0 }
        rig.settle("the fix") { fixed != nil }
        XCTAssertEqual(rig.source.text, "We need to receive them.")
        var undone: Bool?
        rig.controller.undoLastFix { undone = $0 }
        rig.settle("the undo") { undone != nil }
        XCTAssertEqual(undone, true)
        XCTAssertEqual(rig.source.text, "We need to recieve them.", "⌫ takes the fix back")
        var again: Bool?
        rig.controller.undoLastFix { again = $0 }
        rig.settle("nothing left") { again != nil }
        XCTAssertEqual(again, false, "one undo per fix")
        XCTAssertEqual(rig.events.map(\.action), ["shown", "applied", "undone"])
    }

    func testAFixWhoseWordsMovedIsRefused() {
        let rig = EditorRig()
        rig.type("We need to recieve them.")
        rig.settle("the mark") { rig.controller.lensMarks.count == 1 }
        // The hand typed before the mark; the editor has not read it yet.
        rig.source.field?.text = "So we need to recieve them."
        var done: Bool?
        rig.controller.fix(rig.controller.lensMarks[0]) { done = $0 }
        rig.settle("the refusal") { done != nil }
        XCTAssertEqual(done, false)
        XCTAssertEqual(rig.source.text, "So we need to recieve them.", "nothing overwritten")
        XCTAssertEqual(rig.flashes, ["✕ the text changed under the mark"])
    }

    func testStillReadsChecksTheWordsAndTheBounds() {
        XCTAssertTrue(EditorAX.stillReads("We need it.", range: NSRange(location: 3, length: 4), expected: "need"))
        XCTAssertFalse(EditorAX.stillReads("We need it.", range: NSRange(location: 3, length: 4), expected: "feed"))
        XCTAssertFalse(EditorAX.stillReads("We", range: NSRange(location: 1, length: 4), expected: "e"), "past the end")
        XCTAssertTrue(EditorAX.stillReads("🎉 ok", range: NSRange(location: 3, length: 2), expected: "ok"))
    }

    func testTheCaretComesBackWhereTheHandLeftIt() {
        let fixed = NSRange(location: 10, length: 7)   // "recieve" → "receive"
        XCTAssertEqual(EditorAX.restoredCaret(before: NSRange(location: 4, length: 0), fixed: fixed, replacementLength: 7),
                       NSRange(location: 4, length: 0), "before the fix: untouched")
        XCTAssertEqual(EditorAX.restoredCaret(before: NSRange(location: 30, length: 0), fixed: fixed, replacementLength: 9),
                       NSRange(location: 32, length: 0), "after the fix: moved by the change in length")
        XCTAssertEqual(EditorAX.restoredCaret(before: NSRange(location: 17, length: 0), fixed: fixed, replacementLength: 4),
                       NSRange(location: 14, length: 0), "at the fix's end: moves with it")
        XCTAssertEqual(EditorAX.restoredCaret(before: NSRange(location: 20, length: 5), fixed: fixed, replacementLength: 0),
                       NSRange(location: 13, length: 5), "a selection keeps its length")
    }

    func testKeepingAWordTeachesItAndKeepingGrammarQuietsOnlyItsSentence() throws {
        let rig = EditorRig()
        rig.reader.answer("Their going to lodestr it.", "They're going to lodestr it.")
        rig.type("Their going to lodestr it. We need to recieve them.")
        rig.settle("both answered") { rig.reader.asked.count == 2 }
        rig.drain()
        rig.beat()
        // The model read the first sentence: its mark replaces the spell
        // checker's there.
        rig.settle("the model's mark") { rig.controller.lensMarks.map(\.issue.original) == ["Their", "recieve"] }
        let marks = rig.controller.lensMarks
        rig.controller.dismiss(try XCTUnwrap(marks.first { $0.issue.original == "Their" }, "\(marks.map(\.issue))"))
        rig.controller.dismiss(try XCTUnwrap(marks.first { $0.issue.original == "recieve" }, "\(marks.map(\.issue))"))
        XCTAssertEqual(rig.names, ["recieve"], "a spelling kept is the hand's word: draft.words")
        XCTAssertTrue(rig.controller.lensMarks.isEmpty)
        XCTAssertEqual(rig.events.filter { $0.action == "dismissed" }.map(\.rec), ["sentence", "name"])

        // The grammar mark stays quiet while its sentence stands...
        rig.clock.advance(by: 0.6)
        rig.beat()
        rig.drain()
        XCTAssertFalse(rig.controller.lensMarks.contains { $0.issue.original == "Their" }, "kept in its sentence")
        // ...and nothing was learned: the same change in another sentence
        // is marked.
        rig.reader.answer("Their going to ship it.", "They're going to ship it.")
        rig.type("Their going to lodestr it. Their going to ship it.")
        rig.settle("the other sentence's mark") {
            rig.beat()
            return rig.controller.lensMarks.map(\.issue.range.location) == [27]
        }
    }

    func testAMarkIsCountedShownOnce() {
        let rig = EditorRig()
        rig.type("We need to recieve them.")
        rig.settle("the mark") { rig.controller.lensMarks.count == 1 }
        for _ in 0..<4 {
            rig.clock.advance(by: 0.6)
            rig.beat()
            rig.drain()
        }
        XCTAssertEqual(rig.events.filter { $0.action == "shown" }.count, 1)
    }

    /// Spelling asks no model: the spell checker and the rules mark, and
    /// the proofreader is never asked.
    func testSpellingAsksNoModel() {
        let rig = EditorRig()
        rig.controller.apply(enabled: true, engine: .spelling, language: "en_US", vocabulary: [], skipApps: [])
        rig.type("We need to to recieve them. Their going now.")
        rig.settle("the marks") { rig.controller.lensMarks.count == 2 }
        rig.clock.advance(by: 2)
        rig.beat()
        rig.drain()
        XCTAssertTrue(rig.reader.asked.isEmpty)
        XCTAssertEqual(rig.controller.lensMarks.map(\.issue.replacement), ["to", "receive"],
                       "the doubled word and the typo; the grammar waits for a model")
    }

    func testTheModelIsToldOfEnginesPressureAndOff() {
        let rig = EditorRig()
        rig.controller.apply(enabled: true, engine: .full, language: "en_US", vocabulary: [], skipApps: [])
        rig.controller.memoryPressure()
        rig.controller.apply(enabled: false, engine: .full, language: "en_US", vocabulary: [], skipApps: [])
        rig.settle("all three told") { rig.reader.released.count == 2 && !rig.reader.engines.isEmpty }
        XCTAssertEqual(rig.reader.engines, [.full])
        XCTAssertEqual(Set(rig.reader.released), ["memory pressure", "editor off"])
        XCTAssertNil(rig.controller.field)
    }
}

// MARK: - Privacy

final class EditorPrivacyTests: XCTestCase {
    /// The writer's words never reach the record or the log: counts,
    /// kinds, app names, never the text.
    func testNoRecordOrLogLineCarriesTheWords() {
        var lines: [String] = []
        let lock = NSLock()
        Log.listener = { line in lock.withLock { lines.append(line) } }
        defer { Log.listener = nil }

        let rig = EditorRig()
        rig.reader.answer("Their zeppelin will leave soon.", "They're zeppelin will leave soon.")
        rig.type("Their zeppelin will leave soon. We need to recieve marmalade.")
        rig.settle("answered") { rig.reader.asked.count == 2 }
        rig.drain()
        rig.beat()
        rig.settle("the marks") { rig.controller.lensMarks.map(\.issue.original) == ["Their", "recieve"] }
        var done: Bool?
        rig.controller.fix(rig.controller.lensMarks[1]) { done = $0 }
        rig.settle("the fix") { done != nil }
        rig.controller.dismiss(rig.controller.lensMarks[0])
        rig.type("Hello there, all good.", pid: 777, app: "Notes", bundle: "com.apple.Notes")
        rig.drain()

        rig.observations.flush()
        let events = (try? String(contentsOf: rig.directory.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        XCTAssertFalse(events.isEmpty, "the flow was recorded")
        let logged = lock.withLock { lines.joined() }
        XCTAssertTrue(logged.contains("editor"), "the flow was logged")
        for word in ["zeppelin", "marmalade", "recieve", "receive", "Their", "They're", "Hello"] {
            XCTAssertFalse(events.contains(word), "the record carries \(word)")
            XCTAssertFalse(logged.contains(word), "the log carries \(word)")
        }
    }
}

// MARK: - A stalled app

final class EditorStallTests: XCTestCase {
    /// An app that stops answering accessibility costs the editor a beat
    /// and the main thread nothing: every call is on the editor's queue.
    func testAStalledAppNeverHoldsTheMainThread() {
        let rig = EditorRig()
        rig.type("We need to recieve them.")          // the spell checker's first-use cost, paid here
        rig.settle("the mark") { rig.controller.lensMarks.count == 1 }
        let mark = rig.controller.lensMarks[0]
        rig.source.stall = 1.5

        func mainFree(_ what: String, _ work: () -> Void) {
            let started = Date()
            work()
            var ran = false
            DispatchQueue.main.async { ran = true }
            while !ran { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005)) }
            XCTAssertLessThan(Date().timeIntervalSince(started), 0.25, "\(what) held the main thread")
        }
        mainFree("a poll") { rig.controller.poll() }
        mainFree("a beat's geometry") { rig.type("We need to recieve them now.") }
        mainFree("a fix") { rig.controller.fix(mark) { _ in } }
        mainFree("an undo") { rig.controller.undoLastFix { _ in } }
        rig.source.stall = 0
        rig.drain()
    }
}

// MARK: - The model runtime

final class EditorModelTests: XCTestCase {
    /// A backend that echoes, or sleeps first.
    private struct Echo: EditorBackend {
        var delay: TimeInterval = 0
        func respond(to sentence: String) async throws -> String {
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            return sentence.replacingOccurrences(of: "Their", with: "They're")
        }
    }

    private final class Ledger: @unchecked Sendable {
        let lock = NSLock()
        var loads: [EditorEngine] = []
        var clears = 0
    }

    private func model(_ engine: EditorEngine = .standard, idle: TimeInterval = 60, deadline: TimeInterval = 8,
                       delay: TimeInterval = 0, fails: Bool = false) -> (EditorModel, Ledger) {
        let ledger = Ledger()
        let model = EditorModel(
            engine: engine, idleRelease: idle, answerDeadline: deadline,
            loader: { engine in
                ledger.lock.withLock { ledger.loads.append(engine) }
                if fails { throw EditorModelError.missing(engine) }
                return Echo(delay: delay)
            },
            clearCache: { ledger.lock.withLock { ledger.clears += 1 } })
        return (model, ledger)
    }

    /// Typing loads the model early; the first sentence, arriving while
    /// it loads, waits on that load rather than starting a second.
    func testAnEarlyLoadAndTheFirstQuestionShareOneLoad() async {
        let (model, ledger) = model(delay: 0)
        let slow = EditorModel(engine: .standard, loader: { engine in
            ledger.lock.withLock { ledger.loads.append(engine) }
            try await Task.sleep(for: .seconds(0.3))
            return Echo()
        }, clearCache: {})
        _ = model
        async let early: Void = slow.prepare()
        async let answer = slow.correct("Their going.")
        _ = await early
        let answered = await answer
        XCTAssertEqual(answered, "They're going.")
        XCTAssertEqual(ledger.loads.count, 1, "one load for both")
    }

    func testTheModelLoadsOnceAndLetsGoWhenIdle() async throws {
        let (model, ledger) = model(idle: 0.15)
        let first = await model.correct("Their going.")
        XCTAssertEqual(first, "They're going.")
        _ = await model.correct("Their here.")
        XCTAssertEqual(ledger.loads, [.standard], "loaded once for both")
        let ready = await model.state
        XCTAssertEqual(ready, .ready)
        try await Task.sleep(for: .seconds(0.4))
        let idle = await model.state
        XCTAssertEqual(idle, .unloaded, "two idle minutes, here a fraction of a second")
        XCTAssertEqual(ledger.clears, 1, "MLX's memory handed back")
        _ = await model.correct("Their back.")
        XCTAssertEqual(ledger.loads.count, 2, "the next sentence loads it again")
    }

    func testUseKeepsTheModelLoaded() async throws {
        let (model, ledger) = model(idle: 0.3)
        for _ in 0..<4 {
            _ = await model.correct("Their going.")
            try await Task.sleep(for: .seconds(0.15))
        }
        let state = await model.state
        XCTAssertEqual(state, .ready)
        XCTAssertEqual(ledger.loads.count, 1)
    }

    func testAnEngineChangeLetsTheOldModelGo() async {
        let (model, ledger) = model()
        _ = await model.correct("Their going.")
        await model.setEngine(.full)
        let state = await model.state
        XCTAssertEqual(state, .unloaded)
        _ = await model.correct("Their going.")
        XCTAssertEqual(ledger.loads, [.standard, .full])
    }

    func testPressureLetsGoAtOnce() async {
        let (model, ledger) = model()
        _ = await model.correct("Their going.")
        await model.release(reason: "memory pressure")
        let state = await model.state
        XCTAssertEqual(state, .unloaded)
        XCTAssertEqual(ledger.clears, 1)
    }

    func testAStuckAnswerIsAbandoned() async {
        let (model, _) = model(deadline: 0.2, delay: 30)
        let started = Date()
        let answer = await model.correct("Their going.")
        XCTAssertNil(answer)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "abandoned at the deadline, not after thirty seconds")
    }

    func testAMissingModelAnswersNothing() async {
        let (model, _) = model(fails: true)
        let answer = await model.correct("Their going.")
        XCTAssertNil(answer)
        let state = await model.state
        XCTAssertEqual(state, .failed("the standard model is not on this Mac"))
    }

    func testMinimalHoldsNoMLXMemory() async {
        let (model, ledger) = model(.minimal)
        _ = await model.correct("Their going.")
        await model.release(reason: "memory pressure")
        XCTAssertEqual(ledger.clears, 0)
    }
}

// MARK: - The card for the mouse

final class EditorHoverTests: XCTestCase {
    private func mark(_ original: String, _ replacement: String, x: CGFloat, kind: EditorIssue.Kind = .grammar,
                      note: String? = nil) -> EditorController.Mark {
        EditorController.Mark(issue: EditorIssue(range: NSRange(location: Int(x), length: original.count),
                                                 original: original, replacement: replacement, kind: kind, note: note),
                              rect: CGRect(x: x, y: 300, width: 60, height: 18))
    }

    func testThePointerFindsTheWordAndItsLine() {
        let marks = [mark("Their", "They're", x: 100), mark("recieve", "receive", x: 300)]
        XCTAssertEqual(EditorHover.mark(at: CGPoint(x: 130, y: 309), in: marks)?.issue.original, "Their")
        XCTAssertEqual(EditorHover.mark(at: CGPoint(x: 330, y: 322), in: marks)?.issue.original, "recieve",
                       "on the line below the word")
        XCTAssertEqual(EditorHover.mark(at: CGPoint(x: 99, y: 309), in: marks)?.issue.original, "Their", "a little wide")
        XCTAssertNil(EditorHover.mark(at: CGPoint(x: 220, y: 309), in: marks), "between the words")
        XCTAssertNil(EditorHover.mark(at: CGPoint(x: 130, y: 340), in: marks), "a line below")
    }

    func testTheCardSaysWhatChanges() {
        XCTAssertEqual(EditorHover.words(for: mark("recieve", "receive", x: 0, kind: .spelling).issue).title,
                       "recieve → receive")
        XCTAssertEqual(EditorHover.words(for: mark("recieve", "receive", x: 0, kind: .spelling).issue).detail, "Spelling")
        XCTAssertEqual(EditorHover.words(for: mark("Their", "They're", x: 0).issue).detail, "Grammar")
        let comma = EditorHover.words(for: mark("small,", "small", x: 0, note: "remove comma").issue)
        XCTAssertEqual(comma.title, "Remove comma", "a change the words alone would not show says what it does")
        XCTAssertEqual(comma.detail, "small, → small")
    }

    private func hover(_ marks: [EditorController.Mark], at point: CGPoint) -> (EditorHover, VirtualClock) {
        let clock = VirtualClock()
        let hover = EditorHover(clock: clock.clock)
        hover.marks = { marks }
        hover.pointer = { point }
        addTeardownBlock { hover.panel?.close() }
        return (hover, clock)
    }

    func testRestingOnAMarkOpensItsCard() {
        let m = mark("Their", "They're", x: 100)
        let (hover, clock) = hover([m], at: CGPoint(x: 120, y: 308))
        hover.moved()
        clock.advance(by: EditorHover.dwell - 0.05)
        XCTAssertNil(hover.shown, "not yet: a pointer passing by is not a question")
        clock.advance(by: 0.1)
        XCTAssertEqual(hover.shown, m)
        XCTAssertEqual(hover.panel?.isVisible, true)
        XCTAssertNotEqual(hover.panel?.isKeyWindow, true, "the field keeps its caret")
    }

    func testAPointerPassingThroughOpensNothing() {
        let m = mark("Their", "They're", x: 100)
        let clock = VirtualClock()
        let hover = EditorHover(clock: clock.clock)
        addTeardownBlock { hover.panel?.close() }
        hover.marks = { [m] }
        var point = CGPoint(x: 120, y: 308)
        hover.pointer = { point }
        hover.moved()
        clock.advance(by: EditorHover.dwell / 2)
        point = CGPoint(x: 600, y: 600)
        hover.moved()
        clock.advance(by: 1)
        XCTAssertNil(hover.shown)
    }

    func testTheCardOpensQuickly() {
        XCTAssertLessThanOrEqual(EditorHover.dwell, 0.15, "resting on a word should feel like the word answered")
    }

    /// Crossing from one mark to the next before the first opened: the
    /// second opens, on its own beat.
    func testTheDwellFollowsThePointerToTheNextMark() {
        let first = mark("Their", "They're", x: 100), second = mark("recieve", "receive", x: 300)
        let clock = VirtualClock()
        let hover = EditorHover(clock: clock.clock)
        addTeardownBlock { hover.panel?.close() }
        hover.marks = { [first, second] }
        var point = CGPoint(x: 120, y: 308)
        hover.pointer = { point }
        hover.moved()
        clock.advance(by: EditorHover.dwell / 2)
        point = CGPoint(x: 320, y: 308)
        hover.moved()
        clock.advance(by: EditorHover.dwell + 0.01)
        XCTAssertEqual(hover.shown, second)
    }

    /// With a card open, the next mark takes it over without a wait.
    func testAnOpenCardMovesToTheNextMarkAtOnce() {
        let first = mark("Their", "They're", x: 100), second = mark("recieve", "receive", x: 300)
        let clock = VirtualClock()
        let hover = EditorHover(clock: clock.clock)
        addTeardownBlock { hover.panel?.close() }
        hover.marks = { [first, second] }
        var point = CGPoint(x: 120, y: 308)
        hover.pointer = { point }
        hover.moved()
        clock.advance(by: EditorHover.dwell + 0.01)
        XCTAssertEqual(hover.shown, first)
        point = CGPoint(x: 320, y: 308)
        hover.moved()
        XCTAssertEqual(hover.shown, second, "no second wait")
    }

    func testTheCardCarriesNoKeymap() throws {
        let m = mark("Their", "They're", x: 100)
        let hover = EditorHover(clock: VirtualClock().clock)
        addTeardownBlock { hover.panel?.close() }
        hover.show(m)
        func texts(_ view: NSView) -> [String] {
            ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(texts)
        }
        let shown = texts(try XCTUnwrap(hover.panel?.contentView))
        XCTAssertFalse(shown.contains("lode"), "\(shown)")
        XCTAssertFalse(shown.contains { $0.contains("every mark") }, "\(shown)")
        XCTAssertTrue(shown.contains("Accept"))
    }

    func testLeavingTheWordAndTheCardClosesIt() {
        let m = mark("Their", "They're", x: 100)
        let clock = VirtualClock()
        let hover = EditorHover(clock: clock.clock)
        addTeardownBlock { hover.panel?.close() }
        hover.marks = { [m] }
        var point = CGPoint(x: 120, y: 308)
        hover.pointer = { point }
        hover.moved()
        clock.advance(by: EditorHover.dwell + 0.05)
        XCTAssertEqual(hover.shown, m)
        // Down onto the card: it stays.
        point = CGPoint(x: 140, y: 340)
        hover.moved()
        clock.advance(by: 1)
        XCTAssertEqual(hover.shown, m, "the way to the card does not close it")
        point = CGPoint(x: 900, y: 900)
        hover.moved()
        clock.advance(by: EditorHover.linger - 0.05)
        XCTAssertEqual(hover.shown, m, "a moment's grace")
        clock.advance(by: 0.1)
        XCTAssertNil(hover.shown)
        XCTAssertEqual(hover.panel?.isVisible, false)
    }

    func testAMarkThatGoesTakesItsCard() {
        let m = mark("Their", "They're", x: 100)
        var marks = [m]
        let hover = EditorHover(clock: VirtualClock().clock)
        addTeardownBlock { hover.panel?.close() }
        hover.marks = { marks }
        hover.show(m)
        marks = []
        hover.marksChanged()
        XCTAssertNil(hover.shown)
    }

    /// Press a cap the way a mouse does: down and up at its middle,
    /// through the panel's own event handling.
    private func click(_ view: NSView?, file: StaticString = #filePath, line: UInt = #line) {
        guard let view, let window = view.window else { XCTFail("no caps", file: file, line: line); return }
        window.layoutIfNeeded()
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: 1) else { continue }
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
    }

    func testTheCardsCapsAnswer() {
        let m = mark("Their", "They're", x: 100)
        let hover = EditorHover(clock: VirtualClock().clock)
        addTeardownBlock { hover.panel?.close() }
        hover.marks = { [m] }
        var accepted: [EditorController.Mark] = []
        var kept: [EditorController.Mark] = []
        hover.accept = { accepted.append($0) }
        hover.keep = { kept.append($0) }
        hover.show(m)
        click(hover.acceptCaps)
        XCTAssertEqual(accepted, [m])
        XCTAssertNil(hover.shown, "an answer closes the card")
        hover.show(m)
        click(hover.keepCaps)
        XCTAssertEqual(kept, [m])
        XCTAssertEqual(accepted.count, 1)
    }

    func testTheMouseRoadFixesAndIsRecordedAsTheMouse() {
        let rig = EditorRig(hover: true)
        rig.type("We need to recieve them. And their here.")
        rig.settle("the mark") { rig.controller.lensMarks.count == 1 }
        let hover = rig.controller.hover!
        hover.show(rig.controller.lensMarks[0])
        click(hover.acceptCaps)
        rig.settle("the fix") { rig.source.text?.hasPrefix("We need to receive") == true }
        rig.settle("recorded") { rig.events.contains { $0.action == "applied" } }
        XCTAssertEqual(rig.events.first { $0.action == "applied" }?.row, "mouse")
    }
}

// MARK: - Which engines a Mac may run

final class EditorEngineTests: XCTestCase {
    private func why(_ engine: EditorEngine, _ gb: Double, ai: Bool = true) -> String? {
        EditorEngine.unavailable(engine, memoryGB: gb, appleIntelligence: ai)
    }

    func testEachEngineNeedsItsMemory() {
        XCTAssertNil(why(.minimal, 8))
        XCTAssertEqual(why(.standard, 8), "needs 16 GB")
        XCTAssertEqual(why(.full, 8), "needs 64 GB")
        XCTAssertNil(why(.standard, 16), "a 16 GB Mac reports 16.0")
        XCTAssertNil(why(.standard, 15.9), "and a rounding does not refuse it")
        XCTAssertEqual(why(.full, 32), "needs 64 GB")
        XCTAssertNil(why(.full, 64))
        XCTAssertEqual(why(.minimal, 64, ai: false), "needs Apple Intelligence")
        XCTAssertNil(why(.spelling, 4, ai: false), "Spelling runs on every Mac")
    }

    func testAnEightGigabyteMacGetsApplesModelOrSpelling() {
        XCTAssertEqual(EditorEngine.resolved("", memoryGB: 8, appleIntelligence: true), .minimal)
        XCTAssertEqual(EditorEngine.resolved("", memoryGB: 8, appleIntelligence: false), .spelling,
                       "never a model that cannot run")
        XCTAssertEqual(EditorEngine.resolved("minimal", memoryGB: 8, appleIntelligence: false), .spelling)
        XCTAssertEqual(EditorEngine.resolved("full", memoryGB: 8, appleIntelligence: false), .spelling)
        XCTAssertEqual(EditorEngine.resolved("spelling", memoryGB: 64, appleIntelligence: true), .spelling,
                       "chosen, it stands on any Mac")
    }

    func testAnEngineTooBigFallsBackToOneThatFits() {
        XCTAssertEqual(EditorEngine.resolved("full", memoryGB: 16, appleIntelligence: true), .standard)
        XCTAssertEqual(EditorEngine.resolved("full", memoryGB: 8, appleIntelligence: true), .minimal)
        XCTAssertEqual(EditorEngine.resolved("standard", memoryGB: 8, appleIntelligence: true), .minimal)
        XCTAssertEqual(EditorEngine.resolved("full", memoryGB: 64, appleIntelligence: true), .full)
        XCTAssertEqual(EditorEngine.resolved("minimal", memoryGB: 64, appleIntelligence: true), .minimal)
    }

    func testNothingNamedPicksStandardWhereItFitsAndNeverFull() {
        XCTAssertEqual(EditorEngine.resolved("", memoryGB: 128, appleIntelligence: true), .standard)
        XCTAssertEqual(EditorEngine.resolved("", memoryGB: 8, appleIntelligence: true), .minimal)
        XCTAssertEqual(EditorEngine.resolved("apple", memoryGB: 32, appleIntelligence: true), .standard,
                       "an unknown name is no name")
    }

    func testTheNamesSettingsShows() {
        XCTAssertEqual(EditorEngine.allCases.map(\.name), ["Spelling", "Minimal", "Standard", "Full"])
        XCTAssertFalse(EditorEngine.spelling.usesModel)
    }
}

// MARK: - Asking first, and a model that is not here yet

final class EditorReadinessTests: XCTestCase {
    /// A model still downloading cannot answer: nothing is asked, spelling
    /// and the rules mark, and once it arrives the sentences are asked.
    func testNothingIsAskedUntilTheModelIsHere() {
        var here = false
        let queue = DispatchQueue(label: "test.editor.ready")
        let source = FakeFieldSource(), reader = FakeProofreader(), clock = VirtualClock()
        let controller = EditorController(source: source, queue: queue, proofreader: reader,
                                          drawing: FakeMarksDrawing(), hover: nil, clock: clock.clock,
                                          polls: false, modelReady: { _ in here })
        controller.apply(enabled: true, engine: .standard, language: "en_US", vocabulary: [], skipApps: [])
        let field = EditorRig.field("Their going to push it. We need to recieve them.")
        source.field = field
        controller.receive(field)
        for _ in 0..<10 { Stage.pump() }
        queue.sync {}
        XCTAssertTrue(reader.asked.isEmpty, "downloading: nothing asked")
        XCTAssertEqual(controller.lensMarks.map(\.issue.original), ["recieve"], "spelling marks meanwhile")
        here = true
        controller.refreshModel()
        controller.receive(field)
        let deadline = Date().addingTimeInterval(3)
        while reader.asked.count < 2, Date() < deadline { Stage.pump() }
        XCTAssertEqual(reader.asked.count, 2, "arrived: both sentences asked")
    }

    /// Typing loads the model ahead of the first sentence's end, at most
    /// once every twenty seconds.
    func testTypingLoadsTheModelEarly() {
        let rig = EditorRig()
        rig.type("We ship")
        rig.type("We ship it")
        let deadline = Date().addingTimeInterval(2)
        while rig.reader.prepared == 0, Date() < deadline { Stage.pump() }
        XCTAssertEqual(rig.reader.prepared, 1)
        rig.clock.advance(by: 21)
        rig.type("We ship it now")
        let later = Date().addingTimeInterval(2)
        while rig.reader.prepared < 2, Date() < later { Stage.pump() }
        XCTAssertEqual(rig.reader.prepared, 2)
    }

    /// Notifications come in bursts; one read answers a burst.
    func testABurstOfNotificationsIsOneRead() {
        let rig = EditorRig()
        rig.source.field = EditorRig.field("Hello there.")
        rig.source.stall = 0.2
        for _ in 0..<8 { rig.controller.poll() }
        rig.settle("the read") { rig.controller.field != nil }
        rig.drain()
        XCTAssertEqual(rig.source.reads, 1)
    }

    /// A terminal's output is not the hand writing: with no readable
    /// field focused, text announcements are not reads; focus always is.
    func testOnlyAFieldsOwnChangesAreRead() {
        let rig = EditorRig()
        rig.source.field = nil
        for _ in 0..<5 { rig.controller.noticed(kAXValueChangedNotification) }
        rig.drain()
        XCTAssertEqual(rig.source.reads, 0, "no field: output announcements are ignored")
        rig.controller.noticed(kAXFocusedUIElementChangedNotification)
        rig.settle("the focus read") { rig.source.reads == 1 }
        rig.type("We ship it.")
        rig.controller.noticed(kAXValueChangedNotification)
        rig.settle("a field's own change is read") { rig.source.reads == 2 }
    }

    func testTheBeatIsSlowBecauseTheAppsAnnounce() {
        XCTAssertGreaterThanOrEqual(EditorController.beat, 1.0)
        XCTAssertTrue(EditorWatch.notifications.contains(kAXValueChangedNotification))
        XCTAssertTrue(EditorWatch.notifications.contains(kAXFocusedUIElementChangedNotification))
    }
}

final class EditorConsentTests: XCTestCase {
    private final class Glass {
        var shown: (sentence: String, detail: String, rows: [GuideRow])?
        var accepted = 0, declined = 0
    }

    private func consent() -> (EditorConsent, Glass) {
        let consent = EditorConsent(), glass = Glass()
        consent.present = { glass.shown = ($0, $1, $2) }
        consent.isShowing = { glass.shown != nil }
        consent.clear = { glass.shown = nil }
        consent.accepted = { glass.accepted += 1 }
        consent.declined = { glass.declined += 1 }
        return (consent, glass)
    }

    func testTheCardSaysWhatIsReadAndOffersBothAnswers() throws {
        let (consent, glass) = consent()
        consent.ask(detail: "Standard · a 3.6 GB download")
        let shown = try XCTUnwrap(glass.shown)
        XCTAssertTrue(shown.sentence.contains("every app"))
        XCTAssertTrue(shown.sentence.contains("never kept"))
        XCTAssertEqual(shown.rows.map(\.label), ["Accept", "Decline"])
        XCTAssertEqual(shown.rows.map(\.keys), [["lode", "lode"], ["lode", "⌫"]])
    }

    func testLodeLodeAcceptsOnlyTheCardThatIsShowing() {
        let (consent, glass) = consent()
        XCTAssertFalse(consent.assent(), "no card, no answer")
        consent.ask(detail: "")
        XCTAssertTrue(consent.assent())
        XCTAssertEqual(glass.accepted, 1)
        XCTAssertNil(glass.shown)
        XCTAssertFalse(consent.assent(), "answered once")
    }

    func testDeclineTurnsTheEditorBackOff() {
        let (consent, glass) = consent()
        consent.ask(detail: "")
        XCTAssertTrue(consent.dismiss())
        XCTAssertEqual(glass.declined, 1)
        XCTAssertEqual(glass.accepted, 0)
    }

    func testTheMouseAnswersTheSame() throws {
        let (consent, glass) = consent()
        consent.ask(detail: "")
        try XCTUnwrap(glass.shown?.rows.first?.action)()
        XCTAssertEqual(glass.accepted, 1)
    }

    func testTheHUDKnowsWhichCardIsUp() {
        let clock = VirtualClock()
        let hud = HUD(clock: clock.clock)
        hud.showVoice(sentence: "asking", detail: nil, rows: [], tag: EditorConsent.tag)
        XCTAssertEqual(hud.voiceTag, EditorConsent.tag)
        hud.flash("✓ something else")
        XCTAssertNil(hud.voiceTag, "another drawing: the card is gone, so is its answer")
        hud.showVoice(sentence: "asking", detail: nil, rows: [], tag: EditorConsent.tag)
        hud.showVoice(sentence: "a coach chip", detail: nil, rows: [])
        XCTAssertNil(hud.voiceTag)
        hud.hide()
        withExtendedLifetime(clock) {}
    }

    func testConsentIsRememberedOnThisMac() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("state-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = StateStore(file: file)
        XCTAssertFalse(store.editorConsented)
        store.setEditorConsent(Date())
        let again = StateStore(file: file)
        again.load()
        XCTAssertTrue(again.editorConsented)
    }
}

final class EditorWakeTests: XCTestCase {
    /// Which apps get VoiceOver's flag: Chromium browsers, not Electron
    /// apps (they answer the warmer's), not native apps.
    func testOnlyChromiumBrowsersAreWokenWithTheEnhancedFlag() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wake-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func app(_ name: String, framework: String?, helper: Bool) throws -> URL {
            let bundle = root.appendingPathComponent("\(name).app")
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"),
                                                    withIntermediateDirectories: true)
            if let framework {
                let helpers = bundle.appendingPathComponent("Contents/Frameworks/\(framework).framework/Versions/1.0/Helpers")
                try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
                if helper {
                    try FileManager.default.createDirectory(
                        at: helpers.appendingPathComponent("\(name) Helper (Renderer).app"), withIntermediateDirectories: true)
                }
            }
            return bundle
        }
        XCTAssertTrue(EditorAX.isChromiumBrowser(try app("Brave Browser", framework: "Brave Browser Framework", helper: true)))
        XCTAssertFalse(EditorAX.isChromiumBrowser(try app("Slack", framework: "Electron Framework", helper: true)))
        XCTAssertFalse(EditorAX.isChromiumBrowser(try app("TextEdit", framework: nil, helper: false)))
        if FileManager.default.fileExists(atPath: "/Applications/Brave Browser.app") {
            XCTAssertTrue(EditorAX.isChromiumBrowser(URL(fileURLWithPath: "/Applications/Brave Browser.app")))
        }
        if FileManager.default.fileExists(atPath: "/Applications/Slack.app") {
            XCTAssertFalse(EditorAX.isChromiumBrowser(URL(fileURLWithPath: "/Applications/Slack.app")))
        }
    }
}
