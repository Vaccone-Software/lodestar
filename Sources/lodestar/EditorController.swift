import AppKit
import LodestarCore

/// What the lens needs from the editor — the seam the scenarios fake.
protocol EditorLens: AnyObject {
    var enabled: Bool { get }
    var lensMarks: [EditorController.Mark] { get }
    /// Where the chips are drawn, in quartz screen coordinates, when not
    /// over the focused window (the draft draws over its own panel).
    var lensCanvas: CGRect? { get }
    func fix(_ mark: EditorController.Mark, completion: @escaping (Bool) -> Void)
    func dismiss(_ mark: EditorController.Mark)
    func undoLastFix(completion: @escaping (Bool) -> Void)
}

extension EditorLens {
    var lensCanvas: CGRect? { nil }
}

/// The editor: reads the field the hand is typing in, marks what reads
/// wrong, and fixes it by key.
///
/// Main thread for its state; every accessibility call on `EditorAX.queue`;
/// the model on its own actor. A mark is drawn only where it is known to
/// be true: the field was read, the sentence was checked, the rectangle
/// placed. Where any of those fails the editor says nothing, and — once per
/// field — says why.
final class EditorController: EditorLens {
    struct Mark: Equatable {
        let issue: EditorIssue
        let rect: CGRect
    }

    /// One fix, kept so the editor can take it back: an app's own ⌘Z
    /// merges it with the hand's last word (Outlook) or loses it (Proton).
    private struct Fix {
        let pid: pid_t
        let element: AXUIElement
        let range: NSRange          // where the replacement now stands
        let original: String
        let replacement: String
    }

    var flash: (String) -> Void = { _ in }
    var observations: ObservationStore?
    /// Writes a name into the shared vocabulary (draft.words).
    var learnName: (String) -> Void = { _ in }

    private(set) var enabled = false
    private var languageSent = false
    private var skipApps: Set<String> = []
    private let session = EditorSession()
    private(set) var engine = EditorEngine.standard

    /// The world the editor reads and writes, each a seam the tests fill:
    /// the field, the queue its calls run on, the model, the pane the
    /// lines are drawn on, the card for the mouse, and the clock a pause
    /// is measured by. `polls` is false when a test hands fields in itself.
    private let source: EditorFieldSource
    private let axQueue: DispatchQueue
    /// Shared with the draft's editor: one model, loaded once for both.
    let proofreader: EditorProofreader
    private let drawing: EditorMarksDrawing
    let hover: EditorHover?
    private let clock: Clock
    private let polls: Bool

    private var timer: DispatchSourceTimer?
    private var pressure: DispatchSourceMemoryPressure?
    private let watch: EditorWatch
    /// A read is on its way: notifications arrive in bursts (a keystroke
    /// is a value change and a caret move), and one read answers them all
    /// — plus one more when any arrived after that read had looked, or the
    /// last keystroke of a burst would wait for the next beat.
    private var readQueued = false
    private var readAgain = false
    /// Is this engine's model here and able to answer? Asked when the
    /// engine changes and when a download finishes, not every beat.
    private let modelReady: (EditorEngine) -> Bool
    private var modelReadyNow = false
    private var lastPrepare = Date.distantPast
    private(set) var field: EditorField?
    private var fieldTextSeen = ""
    private var caretSeen: Int?
    private var lastTextChange = Date.distantPast
    private(set) var issues: [EditorIssue] = []
    private var issuesText = ""
    private var marks: [Mark] = []
    private var inFlight: Set<String> = []
    private var queue: [String] = []
    private var working = false
    private var lastGeometry = Date.distantPast
    private var geometryGeneration = 0
    private var fixes: [Fix] = []
    /// The mark counted as shown once per issue, for the record.
    private var countedShown: Set<String> = []

    /// Longest field read, in UTF-16 units: the editor is for messages
    /// and mail, not for documents.
    static let maxLength = 20_000
    /// A pause this long finishes the sentence the caret is in.
    static let pause: TimeInterval = 1.0
    /// The slow beat under the notifications: apps that announce nothing,
    /// and scrolling, which no app announces. It was every 0.2 seconds
    /// before the editor listened.
    static let beat: TimeInterval = 1.0

    init(source: EditorFieldSource = AXFieldSource(), queue: DispatchQueue = EditorAX.queue,
         proofreader: EditorProofreader = EditorModel(engine: .standard),
         drawing: EditorMarksDrawing = EditorMarks(), hover: EditorHover? = EditorHover(),
         clock: Clock = .live, polls: Bool = true,
         modelReady: @escaping (EditorEngine) -> Bool = EditorModels.isReady) {
        self.source = source
        self.watch = EditorWatch(queue: queue)
        self.modelReady = modelReady
        self.axQueue = queue
        self.proofreader = proofreader
        self.drawing = drawing
        self.hover = hover
        self.clock = clock
        self.polls = polls
        hover?.marks = { [weak self] in self?.marks ?? [] }
        hover?.accept = { [weak self] mark in self?.fix(mark, via: "mouse") { _ in } }
        hover?.keep = { [weak self] mark in self?.dismiss(mark, via: "mouse") }
    }

    // MARK: - Configuration

    func apply(enabled: Bool, engine: EditorEngine, language: String, vocabulary: [String],
               skipApps: Set<String>) {
        if language != session.language || !languageSent {
            languageSent = true
            let proofreader = self.proofreader
            Task { await proofreader.setLanguage(language) }
        }
        session.language = language
        session.guards = EditorGuards(vocabulary: Set(vocabulary))
        self.skipApps = skipApps
        if engine != self.engine {
            self.engine = engine
            let proofreader = self.proofreader
            Task { await proofreader.setEngine(engine) }
            // What was waiting for the old model goes.
            queue = []
            inFlight = []
        }
        modelReadyNow = engine.usesModel && modelReady(engine)
        issuesText = ""   // the guards changed: read again
        if enabled != self.enabled {
            self.enabled = enabled
            enabled ? start() : stop()
        }
    }

    private func start() {
        if polls {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 0.2, repeating: Self.beat, leeway: .milliseconds(200))
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.timer = timer
            watch.changed = { [weak self] name in self?.noticed(name) }
            watch.start()
            let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
            pressure.setEventHandler { [weak self] in self?.memoryPressure() }
            pressure.resume()
            self.pressure = pressure
            hover?.start()
        }
        Log.info("editor", ["enabled": true, "engine": engine.rawValue])
    }

    private func stop() {
        timer?.cancel()
        timer = nil
        watch.stop()
        pressure?.cancel()
        pressure = nil
        clearField()
        queue = []
        hover?.stop()
        let proofreader = self.proofreader
        Task { await proofreader.release(reason: "editor off") }
        Log.info("editor", ["enabled": false])
    }

    /// macOS says memory is short: the model goes now, not in two minutes.
    func memoryPressure() {
        let proofreader = self.proofreader
        Task { await proofreader.release(reason: "memory pressure") }
    }

    // MARK: - The field

    /// An app announced a change. Text and caret changes matter only while
    /// a readable field is focused: a terminal's output announces itself
    /// twice a second (measured, Ghostty), and none of it is the hand
    /// writing. Focus, windows and a new app always read.
    func noticed(_ name: String) {
        if field == nil, name == kAXValueChangedNotification || name == kAXSelectedTextChangedNotification { return }
        poll()
    }

    /// The model just arrived (a download finished, Apple Intelligence
    /// came on): sentences are worth asking about again.
    func refreshModel() {
        modelReadyNow = engine.usesModel && modelReady(engine)
        issuesText = ""
    }

    /// One read: the focused field, off the main thread, taken on it. A
    /// read already on its way answers this call too. Main thread.
    func poll() {
        guard !readQueued else {
            readAgain = true
            return
        }
        readQueued = true
        let source = self.source
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        axQueue.async { [weak self] in
            let read = source.focusedField(frontmost: frontmost)
            DispatchQueue.main.async {
                guard let self else { return }
                self.readQueued = false
                self.receive(read)
                if self.readAgain {
                    self.readAgain = false
                    self.poll()
                }
            }
        }
    }

    /// Nothing to read: every mark and card about the last field goes.
    private func clearField() {
        field = nil
        issues = []
        issuesText = ""
        marks = []
        geometryGeneration += 1
        drawing.hide()
        hover?.hide()
    }

    /// Whether a field is one the editor reads at all: not an app the
    /// hand skipped, and not longer than a message — a reply's quoted
    /// thread does not count against the limit, only the writer's part
    /// above it is read.
    func reads(_ field: EditorField) -> Bool {
        (EditorText.quoteStart(in: field.text) ?? field.text.utf16.count) <= Self.maxLength
            && !skipApps.contains(field.bundleID?.lowercased() ?? "")
            && !skipApps.contains(field.appName.lowercased())
    }

    func receive(_ read: EditorField?) {
        guard enabled else { return }
        if read == nil, field != nil { Log.info("editor", ["field": "none"]) }
        guard var read, reads(read) else {
            if field != nil { clearField() }
            return
        }
        let now = clock.now()
        if field.map({ !$0.isSame(as: read) }) ?? true {
            Log.info("editor", ["field": read.appName, "chars": read.text.utf16.count,
                                "caret": read.caret.map(String.init) ?? "selection",
                                "framed": read.frame != nil, "window": read.windowFrame != nil])
            // A new field: nothing the last one showed applies, and its
            // marks go now rather than when the new ones are placed.
            clearField()
            lastTextChange = now
            countedShown = []
        }
        if read.text != fieldTextSeen {
            lastTextChange = now
            // Typing: load the model now, so the sentence's end does not
            // wait on the load. Loaded, this only keeps it from its idle
            // release.
            if modelReadyNow, now.timeIntervalSince(lastPrepare) > 20 {
                lastPrepare = now
                let proofreader = self.proofreader
                Task { await proofreader.prepare() }
            }
        }
        let paused = now.timeIntervalSince(lastTextChange) >= Self.pause
        let changed = read.text != issuesText || read.caret != caretSeen
        fieldTextSeen = read.text
        caretSeen = read.caret
        read.caret = read.caret.map { min($0, read.text.utf16.count) }
        field = read

        if changed {
            // Typing moves on: a card about the old text goes.
            if read.text != issuesText { hover?.hide() }
            issues = session.issues(text: read.text, caret: read.caret)
            issuesText = read.text
            placeMarks()
        } else if now.timeIntervalSince(lastGeometry) > 0.5 {
            // Nothing typed: follow scrolling and moving windows.
            placeMarks()
        }
        // Spelling reads without a model, and a model still downloading
        // cannot answer: the spell checker and the rules are all of it,
        // and the sentences wait unasked until the model is here.
        guard modelReadyNow else { return }
        for sentence in session.sentencesToCheck(text: read.text, caret: read.caret, paused: paused)
        where !inFlight.contains(sentence) {
            inFlight.insert(sentence)
            queue.append(sentence)
        }
        drain()
    }

    /// One sentence at a time through the model; a sentence no longer in
    /// the field is skipped when its turn comes.
    private func drain() {
        guard !working, let next = queue.first else { return }
        queue.removeFirst()
        guard field?.text.contains(next) == true else {
            inFlight.remove(next)
            drain()
            return
        }
        working = true
        let proofreader = self.proofreader
        Task { @MainActor [weak self] in
            let corrected = await proofreader.correct(next)
            guard let self else { return }
            self.working = false
            self.inFlight.remove(next)
            // No answer is kept too: asked again, it would fail again,
            // every beat. The spell checker still speaks there.
            self.session.record(sentence: next, corrected: corrected)
            self.issuesText = ""   // an answer landed: read again on the next beat
            self.drain()
        }
    }

    private func placeMarks() {
        guard let field else { return }
        lastGeometry = clock.now()
        geometryGeneration += 1
        let expected = geometryGeneration
        let issues = self.issues
        guard !issues.isEmpty else {
            marks = []
            drawing.hide()
            hover?.marksChanged()
            return
        }
        let source = self.source
        axQueue.async { [weak self] in
            let rects = source.rects(for: issues.map(\.range), in: field)
            DispatchQueue.main.async {
                guard let self, self.geometryGeneration == expected, self.enabled else { return }
                self.marks = zip(issues, rects).compactMap { issue, rect in rect.map { Mark(issue: issue, rect: $0) } }
                self.countShown()
                self.hover?.marksChanged()
                self.redraw(over: field)
            }
        }
    }

    /// Telegram's composer names no window: its own frame, widened for the
    /// lines, is canvas enough.
    private func redraw(over field: EditorField) {
        if let canvas = field.windowFrame ?? field.frame?.insetBy(dx: -8, dy: -8), !marks.isEmpty {
            drawing.show(marks.map(\.rect), over: canvas)
        } else {
            drawing.hide()
        }
    }

    private func countShown() {
        guard let field else { return }
        for mark in marks {
            let key = "\(mark.issue.original)→\(mark.issue.replacement)@\(mark.issue.range.location)"
            if countedShown.insert(key).inserted {
                observations?.edited(action: "shown", kind: mark.issue.kind.rawValue, app: field.appName,
                                     at: clock.now())
            }
        }
    }

    // MARK: - The lens

    /// What the lens letters: the marks standing now, nearest the caret
    /// first, since the lens hands out its easiest letters in order.
    var lensMarks: [Mark] { Self.nearestFirst(marks, caret: field?.caret) }

    /// The mark just written is the one most likely wanted, so it gets the
    /// home-row letter: marks by distance from the caret, a tie going to
    /// the one before it (written) over the one after (read), then reading
    /// order. No caret (a selection), reading order.
    static func nearestFirst(_ marks: [Mark], caret: Int?) -> [Mark] {
        guard let caret else { return marks }
        func rank(_ range: NSRange) -> (Int, Int) {
            if caret < range.location { return (range.location - caret, 1) }
            return (max(0, caret - (range.location + range.length)), 0)
        }
        return marks.enumerated().sorted { a, b in
            let (ra, rb) = (rank(a.element.issue.range), rank(b.element.issue.range))
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    /// Apply the fix a letter named. Asynchronous: the text changes, and
    /// the next beat reads it.
    func fix(_ mark: Mark, completion: @escaping (Bool) -> Void) {
        fix(mark, via: "keys", completion: completion)
    }

    func fix(_ mark: Mark, via: String, completion: @escaping (Bool) -> Void) {
        guard let field else { completion(false); return }
        let issue = mark.issue
        let source = self.source
        axQueue.async { [weak self] in
            let done = source.replace(issue.range, expected: issue.original, with: issue.replacement, in: field)
            DispatchQueue.main.async {
                guard let self else { return }
                if done {
                    self.fixes.append(Fix(pid: field.pid, element: field.element,
                                          range: NSRange(location: issue.range.location,
                                                         length: (issue.replacement as NSString).length),
                                          original: issue.original, replacement: issue.replacement))
                    if self.fixes.count > 20 { self.fixes.removeFirst() }
                    self.marks.removeAll { $0.issue == issue }
                    self.hover?.marksChanged()
                    self.redraw(over: field)
                    self.issuesText = ""
                    self.observations?.edited(action: "applied", kind: issue.kind.rawValue, app: field.appName,
                                              via: via, at: self.clock.now())
                } else {
                    self.flash("✕ the text changed under the mark")
                }
                completion(done)
            }
        }
    }

    /// ⇧ and a letter, or Keep as written: the words are right. A word the
    /// dictionary did not know joins the vocabulary the draft shares. A
    /// grammar or punctuation mark goes quiet in its sentence and nothing
    /// is learned: the same change is right in one sentence and wrong in
    /// the next.
    func dismiss(_ mark: Mark) { dismiss(mark, via: "keys") }

    func dismiss(_ mark: Mark, via: String) {
        guard let field else { return }
        let issue = mark.issue
        let isName = Self.isName(issue, language: session.language)
        // The config write says what was learned, in its own flash.
        if isName {
            learnName(Self.word(issue))
        } else {
            session.dismissOnce(issue, in: field.text)
        }
        marks.removeAll { $0.issue == issue }
        hover?.marksChanged()
        redraw(over: field)
        issuesText = ""
        observations?.edited(action: "dismissed", kind: isName ? "name" : "sentence", app: field.appName,
                             via: via, at: clock.now())
    }

    /// The issue's words without the punctuation that rides along.
    static func word(_ issue: EditorIssue) -> String {
        issue.original.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }

    /// Keeping a spelling mark on one word teaches a name — a capital, or
    /// a word the dictionary does not know. Anything else is kept as meant.
    static func isName(_ issue: EditorIssue, language: String) -> Bool {
        let word = self.word(issue)
        return issue.kind == .spelling && !word.contains(" ")
            && (word.first?.isUppercase == true || EditorSpelling.isMisspelled(word, language: language))
    }

    /// ⌫ in the lens: the last fix, taken back.
    func undoLastFix(completion: @escaping (Bool) -> Void) {
        guard let last = fixes.popLast(), let field, field.pid == last.pid else {
            completion(false)
            return
        }
        let source = self.source
        axQueue.async { [weak self] in
            let done = source.replace(last.range, expected: last.replacement, with: last.original, in: field)
            DispatchQueue.main.async {
                guard let self else { return }
                if done { self.observations?.edited(action: "undone", kind: nil, app: field.appName, at: self.clock.now()) }
                self.issuesText = ""
                completion(done)
            }
        }
    }
}
