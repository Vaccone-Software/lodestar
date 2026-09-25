import AppKit
import LodestarCore

/// The editor, inside the draft. Dictation makes exactly the slips the
/// model catches best — "their" for "they're", a word heard twice — and the
/// draft is where they can be fixed before anything lands in an app.
///
/// The draft is Lodestar's own glass, so nothing here goes through
/// accessibility: the marks are a line drawn by the draft's text, the lens
/// is `lode ⇥` as everywhere, with its chips over the draft, and a fix is
/// one undo step in the draft's own history. The rules are the editor's:
/// spelling and the fixed rules at once, a finished sentence (or one the
/// hand paused in) read by the same model, loaded once for both.
final class DraftEditor: EditorLens {
    weak var draft: DraftController?
    var observations: ObservationStore?
    var learnName: (String) -> Void = { _ in }

    private(set) var enabled = false
    private var engine = EditorEngine.standard
    private var modelReady = false
    private let session = EditorSession()
    private let proofreader: EditorProofreader
    private let clock: Clock

    private var text = ""
    private var caret: Int?
    private var ghost = false
    private var issues: [EditorIssue] = []
    private var queue: [String] = []
    private var inFlight: Set<String> = []
    private var working = false
    private var pauseWork: DispatchWorkItem?
    private var fixes: [(range: NSRange, original: String, replacement: String)] = []

    init(proofreader: EditorProofreader, clock: Clock = .live) {
        self.proofreader = proofreader
        self.clock = clock
    }

    func apply(enabled: Bool, engine: EditorEngine, language: String, vocabulary: [String], modelReady: Bool) {
        self.enabled = enabled
        self.engine = engine
        self.modelReady = engine.usesModel && modelReady
        session.language = language
        session.guards = EditorGuards(vocabulary: Set(vocabulary))
        if !enabled { issues = [] }
        refresh()
    }

    // MARK: - Reading the draft

    /// The draft's settled text changed. Answers with its marks at once.
    func textChanged(_ text: String, caret: Int, ghost: Bool) -> [NSRange] {
        let edited = text != self.text
        self.text = text
        self.caret = caret
        self.ghost = ghost
        guard enabled else { return [] }
        issues = session.issues(text: text, caret: caret)
        if edited { fixes.removeAll { !EditorAX.stillReads(text, range: $0.range, expected: $0.replacement) } }
        ask(paused: false)
        // A pause finishes the sentence the caret is in.
        pauseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.ask(paused: true) }
        pauseWork = work
        clock.after(EditorController.pause, work)
        return ghost ? [] : issues.map(\.range)
    }

    /// Read again: an answer landed, a word was kept, the config changed.
    private func refresh() {
        guard let draft, draft.isOpen else { return }
        issues = enabled ? session.issues(text: text, caret: caret) : []
        draft.setEditorMarks(ghost ? [] : issues.map(\.range))
    }

    private func ask(paused: Bool) {
        guard enabled, modelReady, !ghost else { return }
        for sentence in session.sentencesToCheck(text: text, caret: caret, paused: paused)
        where !inFlight.contains(sentence) {
            inFlight.insert(sentence)
            queue.append(sentence)
        }
        drain()
    }

    private func drain() {
        guard !working, let next = queue.first else { return }
        queue.removeFirst()
        guard text.contains(next) else {
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
            self.session.record(sentence: next, corrected: corrected)
            self.refresh()
            self.drain()
        }
    }

    // MARK: - The lens

    var lensMarks: [EditorController.Mark] {
        guard enabled, !ghost, let draft else { return [] }
        let rects = draft.editorRects(for: issues.map(\.range))
        let marks = zip(issues, rects).compactMap { issue, rect in rect.map { EditorController.Mark(issue: issue, rect: $0) } }
        return EditorController.nearestFirst(marks, caret: caret)
    }

    /// The chips are drawn over the draft, not the app beneath it.
    var lensCanvas: CGRect? { draft?.editorCanvas }

    func fix(_ mark: EditorController.Mark, completion: @escaping (Bool) -> Void) {
        let issue = mark.issue
        guard let draft, draft.editorReplace(issue.range, expected: issue.original, with: issue.replacement) else {
            completion(false)
            return
        }
        fixes.append((NSRange(location: issue.range.location, length: (issue.replacement as NSString).length),
                      issue.original, issue.replacement))
        if fixes.count > 20 { fixes.removeFirst() }
        observations?.edited(action: "applied", kind: issue.kind.rawValue, app: "draft", via: "keys", at: clock.now())
        completion(true)
    }

    func dismiss(_ mark: EditorController.Mark) {
        let issue = mark.issue
        let isName = EditorController.isName(issue, language: session.language)
        if isName {
            learnName(EditorController.word(issue))
        } else {
            session.dismissOnce(issue, in: text)
        }
        observations?.edited(action: "dismissed", kind: isName ? "name" : "sentence", app: "draft", via: "keys",
                             at: clock.now())
        issues.removeAll { $0 == issue }
        draft?.setEditorMarks(issues.map(\.range))
    }

    /// The draft's own spelling keys: `z=` fixes the mark under the
    /// cursor, `zg` keeps its word.
    func spellKey(on range: NSRange, keep: Bool) {
        guard let issue = issues.first(where: { $0.range == range }) else { return }
        let mark = EditorController.Mark(issue: issue, rect: .zero)
        if keep { dismiss(mark) } else { fix(mark) { _ in } }
    }

    func undoLastFix(completion: @escaping (Bool) -> Void) {
        guard let last = fixes.popLast(), let draft,
              draft.editorReplace(last.range, expected: last.replacement, with: last.original) else {
            completion(false)
            return
        }
        observations?.edited(action: "undone", kind: nil, app: "draft", at: clock.now())
        completion(true)
    }
}
