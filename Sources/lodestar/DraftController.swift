import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import LodestarCore
import LodestarEars
import Stoic

/// The draft: `lode .` opens it speaking, `lode ⇧.` opens it editing. It
/// is a bar the way the clipboard strip is a bar — never key, its keys
/// read off the event tap — so the app you were in keeps its cursor and
/// `⏎` is a plain ⌘V into it.
///
/// The destination is live: whatever is frontmost when `⏎` lands, shown
/// on the foot as it changes. Both endings put the text on the
/// pasteboard, so nothing said or typed here is ever lost.
final class DraftController {
    /// Is a field blocking synthetic input (Secure Keyboard Entry)? The
    /// system's answer in the app; the stage's own in the tests, so a
    /// locked screen (loginwindow holds it) cannot fail a paste scenario.
    var secureInput: () -> Bool = { IsSecureEventInputEnabled() }

    // MARK: Seams

    var flash: ((String) -> Void)?
    var observations: ObservationStore?
    /// The user's vocabulary (`draft.words`), put back into settled speech
    /// by sound. The matcher is built off the main thread whenever the
    /// words change: the pronunciation dictionary takes a moment to read.
    var words: [String] = [] {
        didSet { if words != oldValue { rebuildMatcher() } }
    }
    /// Everything a settled result goes through before it lands.
    private var settler = Draft.Settler(isOrdinary: { CommonWords.isCommon($0) },
                                        removesFillers: Locale.current.language.languageCode == .english)
    /// The last result as it landed, for a correction ("no wait, I mean")
    /// that reaches back into it.
    private var lastSpoken: (range: Range<Int>, text: String)?
    /// The hand typed or moved since the last result landed.
    private var handSinceSpeech = false {
        didSet { if !handSinceSpeech { resultStepOpen = true } }
    }
    /// A settled result stands as the last undo step and the hand has not
    /// yet edited after it: the first edit closes that step first, so what
    /// it types or takes back is its own step and ⌘Z leaves the result.
    private var resultStepOpen = false
    /// The text as it stood when the hand began editing, until the edit
    /// ends (speech arrives, a pass rewrites, the draft lands or closes):
    /// what the hand changed between the two is what it corrected.
    private var handBaseline: String?
    /// A word learned from a correction goes into the vocabulary
    /// (`draft.words`), the same list the editor's keep writes to.
    var learnWord: (String) -> Void = { _ in }
    /// The words of the list the matcher put back in a settled result, in
    /// the order they were said: the app keeps which were used lately, to
    /// tell the models those first.
    var onNamesUsed: ([String]) -> Void = { _ in }
    /// Words a pass rewrote — the second ear or the intent pass — as they
    /// now stand, underlined quietly until the hand's next key, so a
    /// change made while the eye was elsewhere can be seen and undone.
    private var revised: [(range: Range<Int>, text: String)] = []
    /// The repository the destination's window is in, when it is a
    /// terminal or an editor: its names are how "draft controller dot
    /// swift" is written. Set by the app; the stage leaves it empty.
    var codeRepository: (Destination) -> URL? = { _ in nil }
    /// Where a repository's names are read: off the main thread in the app.
    var readCodeNames: (URL, @escaping (CodeNames.Index?) -> Void) -> Void = { root, done in
        RepoNames.index(for: root, done: done)
    }
    /// The second recognizer, when this Mac's tier has one loaded: it
    /// hears each settled phrase again from the held audio while the hand
    /// keeps going, and its words replace the live ones in place.
    var ear: SettlingEar?
    /// The speaker's terms the ear leans toward: a short list beats a long
    /// one (measured: 23 names did better than 200 terms, at half the time).
    var earContext: [String] = []
    /// The run being heard again: where in the buffer it begins and when
    /// in the audio. Everything said since the hand last moved, so the ear
    /// hears the whole thought, not the pieces the live recognizer cut it
    /// into at pauses (measured on the maker's voice: 8.7% error and 2 of
    /// 10 pauses read as sentence ends, against 9.1% and 4 phrase by
    /// phrase). At most a minute: past that a new run begins. Kept whether
    /// or not the ear is loaded, with where the last phrase ends in the
    /// buffer and in the audio, so an ear that finishes loading while the
    /// draft is open can hear the run from the audio the draft holds.
    private var run: (start: Int, time: Double, upper: Int, end: Double, heard: Heard)?
    static let runSeconds: Double = 60
    /// Only the newest hearing of the run is taken; an older one finishing
    /// late would put back words a newer one already settled.
    private var earGeneration = 0
    /// One hearing runs on the ear at a time, and one waits behind it: the
    /// newest. A phrase landing while the ear is busy replaces the one
    /// waiting, since the run it describes contains it. (Every final used
    /// to queue a whole run, the stale ones ran, and ⏎ waited for all of
    /// them.)
    private struct EarJob {
        let ear: SettlingEar
        let samples: [Float]
        let context: [String]
        let apple: Heard
        let landed: (range: Range<Int>, text: String)
        let session: Int
        let generation: Int
    }
    private var earRunning = false
    private var earNext: EarJob?
    /// Phrases still being heard again: the one running and the one
    /// waiting, and what waits for them.
    private var earPending: Int { (earRunning ? 1 : 0) + (earNext == nil ? 0 : 1) }
    private var earWaiters: [() -> Void] = []
    /// How long ⏎ waits for the last phrase to be heard again before it
    /// lands what it has.
    static let earWaitSeconds: TimeInterval = 1.0
    /// The dictation journal, when `draft.journal-days` keeps one.
    var journal: DictationJournal?
    /// Phrases the ear changed this session, for the record.
    private(set) var earChanged = 0
    /// What was meant, from what was said (`IntentPass`): the editor's
    /// model asked, set by the app while that model is Standard or Full,
    /// here, and `draft.intent` is on; nil otherwise. The answer is
    /// unchecked: the checker is applied here.
    var intend: ((String) async -> String?)?
    /// The speaker's names, which a rewrite keeps exactly as written.
    var intentNames: [String] = []
    private var intentWanted = false
    private var intentInFlight = false
    /// Which draft an answer is for: a draft that has closed moves it on, so
    /// an answer that comes for the one before is not applied to the next.
    private var intentGeneration = 0
    /// The question under way, where its words stood when it was sent: a
    /// newer question replaces it only if it takes those words in.
    private var intentAsking: (range: Range<Int>, text: String)?
    /// The one question that is ever running. A newer one cancels the older
    /// and only the newest is delivered, so a model busy with an outdated
    /// question is not the one the newer waits behind.
    private let intentSlot = TaskSlot<IntentAnswer, Never>(label: "draft.intent")
    /// What the model said and how it was judged, carried from off the main
    /// thread to where it is applied.
    fileprivate struct IntentAnswer: Sendable {
        let answer: String?
        let text: String?
        let verdict: IntentChecker.Verdict?
        let seconds: Double
    }
    private var intentWaiters: [() -> Void] = []
    /// The pass never reaches before where the hand last wrote: what was
    /// typed is the hand's.
    private var intentFloor = 0
    /// Where the earliest result not yet sent begins.
    private var intentFrom: Int?
    /// Every text sent this session. None is sent twice, so a rewrite
    /// undone is never offered again.
    private var intentSent: Set<String> = []
    /// How long ⏎ waits, after the ear, for a rewrite under way.
    static let intentWaitSeconds: TimeInterval = 0.6
    /// How long the asks this process has made took to be answered, the
    /// last twenty, in memory only. ⏎ waits for an ask under way only if
    /// this record says it can finish inside the wait: the median ask
    /// takes 1.6 s, and a wait of 0.6 s for one that will not make it
    /// only delays the paste and loses anyway.
    var intentTimes: [Double] = []
    static let intentTimesKept = 20
    /// When the ask under way was sent.
    private var intentSentAt: Date?
    /// The most words sent at once: a result and the sentence before it,
    /// as measured, not a paragraph a single refusal would lose.
    static let intentWords = 60
    /// Rewrites that went in this session, for the record.
    private(set) var intentChanged = 0
    /// Counts of what the settler changed this session, for the record.
    private(set) var settled = (names: 0, ellipses: 0, joins: 0, fillers: 0, corrections: 0)
    /// How the next draft is edited (`draft.editing-style`).
    var editingStyle = Draft.EditingStyle.standard
    /// How this draft is edited: the configured style as the door found it,
    /// kept until the draft closes. A config reload mid-draft must not leave
    /// Standard in normal mode, or a Mac selection in a Vim session.
    /// Standard never leaves insert mode and its esc closes.
    private(set) var sessionStyle = Draft.EditingStyle.standard
    /// The microphone to read (`draft.input`), by name; nil follows the
    /// system default.
    var inputDevice: String?
    /// Whatever is frontmost right now — the destination.
    var frontmost: () -> Destination?
    /// Put text on the pasteboard, whichever ending.
    var writePasteboard: (String) -> Void
    /// Post a keystroke to the system (⌘V, ⌘A).
    var postKey: (String, CGEventFlags) -> Void
    /// The field under the cursor in an app: what is selected, and the
    /// whole value when asked. AX in the app; a stub on the stage.
    var readField: (pid_t, Bool) -> Field?
    /// Select a range in the origin field, for a whole-field replacement.
    var selectAll: (pid_t) -> Bool
    /// What the app in front shows as focused, asked just before a paste
    /// is posted into it: AX off the main thread in the app, answered on
    /// the main thread; a stub on the stage.
    var probeTarget: (pid_t, @escaping (Draft.Target) -> Void) -> Void
    /// How long ⏎ waits for that answer before pasting as it always did.
    static let targetWaitSeconds: TimeInterval = 0.5
    /// What `p` pastes: the pasteboard's text.
    var readPasteboard: () -> String?
    /// Settled speech is activity too, for the engine's idle clock.
    var onActivity: (() -> Void)?
    /// Dictation is starting, and when the draft has closed: the settling
    /// ear loads on the first and rests after the second.
    var onListen: (() -> Void)?
    var onClosed: (() -> Void)?
    /// The words placed where the cursor was: pasted or replaced, not left
    /// on the pasteboard.
    var onLanded: (() -> Void)?
    /// The machine's inputs, by name, and the one the system calls
    /// default, delivered on the main thread. Off it in the app: the
    /// enumeration is a CoreAudio roll call, which waits on the HAL while
    /// a Bluetooth radio flips profiles — the moment one draft closes and
    /// the next opens — and the main thread hosts the event tap.
    var enumerateInputs: (@escaping ([String], String?) -> Void) -> Void
    private static let inputQueue = DispatchQueue(label: "com.vaccone.lodestar.draft-inputs",
                                                  qos: .userInitiated)
    /// The user picked an input on the foot; the app writes the
    /// config line (`draft.input`), nil meaning the system default.
    var chooseInput: ((String?) -> Void)?
    /// Whether the microphone is allowed now, read without asking, and where
    /// a refused one is allowed again: the grant is the person's, and its
    /// switch is in Privacy & Security.
    var microphoneGranted: () -> Bool = { AVCaptureDevicePermission.granted }
    var openSettings: (URL) -> Void = { SystemEvents.open($0) }
    static let microphoneSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    /// Music steps aside while the mic is open on a shared Bluetooth
    /// radio; the draft only reports its edges.
    var playback: PlaybackPause?
    /// Where the in-flight words go, half a second behind the hand, and
    /// nil at close: a crash mid-draft then strands at most a moment,
    /// and the next boot returns the rest via the pasteboard.
    var stash: ((String?) -> Void)?
    private var stashWork: DispatchWorkItem?
    /// The clip door's two endings, into the history: the card replaced
    /// in place (`⏎`), or the edit kept as a new card (`esc`, or any
    /// other way out). The door never touches the pasteboard; the strip
    /// is the only paste surface.
    var replaceClip: ((Clipboard.Clip, String) -> Void)?
    var fileClip: ((Clipboard.Clip, String) -> Void)?
    /// The clip door closed, whichever way, and the strip is what the
    /// hand is looking at again.
    var onClipDoorClosed: (() -> Void)?
    let clock: Clock

    struct Destination: Equatable {
        let pid: pid_t
        let name: String
        let bundleID: String?
        var icon: NSImage?
        static func == (a: Destination, b: Destination) -> Bool { a.pid == b.pid }
    }

    struct Field {
        /// The selected text, when the field has a selection.
        var selection: String?
        /// The whole value, when it was asked for and the field gave it.
        var value: String?
        /// The insertion point within the value, when the field said.
        var cursor: Int?
        /// The field itself, so a replacement can check it is still the
        /// one focused and not a neighbor in the same app.
        var token: AnyHashable?
        /// The field said how long it is before it was asked for its
        /// value, and it is past `pullCap`: the value was never pulled.
        var tooLong = false
    }

    // MARK: State

    /// The glass. Internal so the scenarios can aim the mouse at its words.
    let panel = DraftPanel()

    // MARK: - The editor, inside the draft

    /// The settled text changed: (text, caret as UTF-16, ghost standing).
    /// Answers with the marks for it, read at once (spelling, the rules,
    /// sentences already answered); a model's later answers arrive through
    /// setEditorMarks.
    var onTextChange: ((String, Int, Bool) -> [NSRange])?
    /// The editor's marks, UTF-16 ranges of the settled text.
    private(set) var editorMarks: [NSRange] = []
    /// `z=` (keep false) or `zg` (keep true) on the mark at this range.
    var onSpellKey: ((NSRange, Bool) -> Void)?
    private var editorTextSeen = ""
    private var editorGhostCleared = true

    func setEditorMarks(_ marks: [NSRange]) {
        guard marks != editorMarks else { return }
        editorMarks = marks
        render()
    }

    /// Where marks are on screen (quartz), for the lens's chips.
    func editorRects(for ranges: [NSRange]) -> [CGRect?] {
        buffer.ghost.isEmpty ? panel.screenRects(for: ranges) : ranges.map { _ in nil }
    }

    /// The panel, for the lens to draw over.
    var editorCanvas: CGRect? { isOpen ? panel.quartzFrame : nil }

    /// A fix: the range must still read `expected`, and becomes `text` in
    /// one undo step with the cursor where the hand left it.
    @discardableResult
    func editorReplace(_ range: NSRange, expected: String, with text: String) -> Bool {
        guard isOpen, buffer.ghost.isEmpty else { return false }
        let settled = buffer.text
        guard let span = Range(range, in: settled), String(settled[span]) == expected else { return false }
        let lower = settled.distance(from: settled.startIndex, to: span.lowerBound)
        let upper = settled.distance(from: settled.startIndex, to: span.upperBound)
        vim.replaceKeepingCursor(lower..<upper, with: text, buffer: &buffer)
        render()
        return true
    }
    /// `lode ?` while the draft is open: its own keys, in its own glass.
    /// The draft carries no legend now, so this is the only way they are
    /// read — and the only way they are ever asked for.
    var keysShown: Bool { panel.keysShown }
    func toggleKeys(_ sections: [CheatSheet.Section]) { panel.toggleKeys(sections) }
    func hideKeys() { panel.hideKeys() }
    private let speech: SpeechSession
    private(set) var isOpen = false
    private(set) var buffer = Draft.Buffer()
    private(set) var mode: Draft.Mode = .insert
    /// The editor behind normal and visual mode.
    private(set) var vim = Vim()
    private var door: Draft.Door = .speak
    /// The doors set this; the mode gates it. Insert mode with the mic
    /// wanted is the only state in which speech writes.
    private var micWanted = false
    /// What the recognizer last said about itself; nil until it says
    /// anything, which is the state the watchdog exists to end.
    private(set) var speechState: SpeechState?
    /// A recognizer session was asked for; it must be stopped whatever
    /// state it reached, or a draft closed mid-preparation leaves the
    /// microphone running with nothing on screen.
    private var sessionStarted = false
    private var listening = false
    /// The input the session reads, by name, and how loud it is.
    private(set) var inputName: String?
    private var level: Float = 0
    /// Every session has a number; a result carrying an old one is a
    /// previous draft's and never lands in this one.
    private var session = 0
    private var origin: Origin?
    /// The card the clip door is editing, and its text as it was, so the
    /// ending can tell an edit from a read.
    private var clipOrigin: (clip: Clipboard.Clip, original: String)?
    /// The clip door's geometry: the width the text asked for at open,
    /// and what the panel stands above (the strip's row of recents).
    private var doorWidth: CGFloat?
    private var standsAbove: CGFloat = 0
    private var closing = false
    /// ⏎ has been waiting longer than it takes to notice: the foot says
    /// the draft is finishing, so the keys swallowed meanwhile are not a
    /// freeze.
    private var finishing = false
    private var finishingWork: DispatchWorkItem?
    static let finishingShownSeconds: TimeInterval = 0.15
    /// What a second ⏎ runs while the first waits: the ghost settles as
    /// seen and the draft lands with what stands.
    private var landNow: (() -> Void)?
    /// Whether the panel shows the whole text or its last four lines:
    /// `zo` and `zc`, and the voice folds it.
    private var expanded = false
    /// The word that runs if the recognizer never says it is listening:
    /// the light would otherwise stay out forever, and the hand would
    /// talk into nothing. Past this the session is stopped and named
    /// failed, and `lode .` starts a fresh one.
    private var listenWatchdog: DispatchWorkItem?
    /// A backstop, and only that.
    ///
    /// Every step of the start now reports its own failure on its own
    /// deadline — the recognizer's preparation, its start, and each
    /// attempt at the microphone — so a wedge is named in three to nine
    /// seconds by the step that wedged. This has to outlast all of them
    /// put together or it would kill a start that was going to land:
    /// two preparation deadlines and three bounded microphone attempts
    /// with their settles come to 11.8 seconds. `SpeechStartBudgetTests`
    /// holds the arithmetic.
    static let listenWatchdogSeconds: TimeInterval = 13
    /// The landing that runs if the recognizer never says it stopped:
    /// while `closing` stands every key is swallowed, so a stop that
    /// hangs would take the keyboard with it.
    private var landBackstop: DispatchWorkItem?
    /// Drafts esc has closed that are waiting out of sight for their last
    /// words, by session number: the clipboard is written when the stop
    /// completes, or at the bound. A draft opened again meanwhile has its
    /// own number and never meets these. `keep` writes it now, once: a
    /// quit cannot wait for the stop.
    private var departing: [Int: (copy: Departure, keep: () -> Void)] = [:]
    /// How long esc waits for the last words before the clipboard is
    /// given the text as it stood.
    static let departBackstopSeconds: TimeInterval = 1.0
    /// How many drafts have ended, so a departed one can tell whether
    /// another has ended since.
    private var endings = 0
    /// How long `⏎` waits for the recognizer's last words before landing
    /// what it has. The session's own finalize is bounded at 0.7s; this
    /// is the bound on the bound.
    static let landBackstopSeconds: TimeInterval = 2.0
    /// Words that were still a ghost when insert mode ended were settled
    /// on the spot, as seen; the recognizer's final for them, if it still
    /// comes, replaces exactly that text and nothing else.
    ///
    /// `base` is the page as it stood when they were reserved, so the end
    /// of the reservation can be found again after the hand has edited it.
    private var provisional: (range: Range<Int>, text: String, base: [Character])?
    /// The last moment the microphone heard something louder than a
    /// quiet room, and the level that counts as something.
    private var lastVoiceAt: Date?
    static let voiceFloor: Float = 0.08
    /// Where the cursor stood when the hand cut in while words were
    /// still in flight.
    ///
    /// The recognizer runs seconds behind the voice. Speak, then start
    /// typing before the first volatile lands, and there is no ghost to
    /// reserve — so the words arrive later and go in at the cursor,
    /// which is now past what was typed. The order comes out backwards.
    /// This is that reservation, made from the only evidence available
    /// at the time: the microphone was hearing a voice when the key
    /// came down, so whatever it is still chewing on was said first.
    private var speechAnchor: (at: Int, since: Date)?
    /// How recently the voice must have been heard for a key to mean
    /// "I am still finishing what I said".
    static let voiceRecencySeconds: TimeInterval = 1.5
    /// How long an anchor waits for the words it is holding a place for.
    static let speechAnchorSeconds: TimeInterval = 4

    private struct Origin {
        let pid: pid_t
        /// Text was pulled from the field, so ⏎ there replaces it.
        let pulled: Bool
        /// The pull was the whole field, not a selection: replacement
        /// selects everything first.
        let wholeField: Bool
        /// Which field, when the app said.
        let token: AnyHashable?
    }
    /// The inputs, enumerated when the draft opens and when one is
    /// chosen, never per keystroke.
    private var inputs: [String] = []
    private var systemInputName: String?

    // Observation counters for one session.
    private var openedAt = Date.distantPast
    private var typedCharacters = 0
    private var spokenWords = 0
    /// Health's switch: a spoken draft's voice is measured as it closes
    /// (`VoiceStats`) only while it is on.
    var measuresVoice = false
    /// Every microphone this draft listened through: more than one means
    /// the Mac's own stood in while a headset woke.
    private var inputsHeard: Set<String> = []
    /// How many times this draft started listening. A restart (a new
    /// microphone, the watchdog) begins the held audio again, so the words
    /// counted no longer match the audio held: its voice is not measured.
    private var listens = 0
    private var backspaces = 0
    private var modeSwitches = 0
    /// Presses the hand made on the text: how often a draft is pointed at
    /// rather than keyed through.
    private var pointerActs = 0
    private var firstKeyAt: Date?
    private var firstWordAt: Date?
    private var wasWarm = false
    /// The keyboard layout's say in what a key types, with its dead key kept
    /// between presses.
    var layoutTyper = LayoutTyper()

    /// Pulled or pasted text past this is refused: a draft is a message,
    /// not a document, and the panel lays the whole text out on every
    /// key.
    static let pullCap = 20_000
    /// A card past this is refused by the clip door: the editor is a pure
    /// machine over an array of characters and the panel lays the whole
    /// text out, and a quarter of a megabyte is where that stops being a
    /// beat. Three cards in a year's history are past it.
    static let clipCap = 250_000
    /// The card being edited, for the shell and the tests.
    var editingClip: Clipboard.Clip? { clipOrigin?.clip }
    /// A paste was refused for its size; the next flash says so instead
    /// of the editor's "nothing to paste".
    private var pasteRefused = false

    /// The pasteboard as the draft will take it: whole when it fits,
    /// nil past the cap — `p` and ⌘V both read through here.
    private func pasteboardForDraft() -> String? {
        guard let text = readPasteboard() else { return nil }
        guard text.count <= Self.pullCap else {
            pasteRefused = true
            return nil
        }
        return text
    }

    private func flashPasteVerdict(_ text: String) {
        flash?(pasteRefused ? "✕ too much text to paste here" : text)
        pasteRefused = false
    }

    init(speech: SpeechSession, clock: Clock = .live) {
        self.speech = speech
        self.clock = clock
        frontmost = Self.systemFrontmost
        writePasteboard = { text in
            let board = SystemEvents.pasteboard
            board.clearContents()
            board.setString(text, forType: .string)
        }
        postKey = Self.post
        readField = Self.readFieldAX
        selectAll = Self.selectAllAX
        probeTarget = Self.probeTargetAX
        readPasteboard = { SystemEvents.pasteboard.string(forType: .string) }
        enumerateInputs = { done in
            Self.inputQueue.async {
                let names = AudioInput.inputDevices().map(\.name)
                let system = AudioInput.defaultInputName
                DispatchQueue.main.async { done(names, system) }
            }
        }
        panel.onChooseInput = { [weak self] name in self?.selectInput(name) }
        panel.onPointer = { [weak self] event in
            guard let self else { return }
            switch event.kind {
            case .down: self.pointerDown(at: event.point, clicks: event.clicks, shift: event.shift)
            case .dragged: self.pointerDragged(to: event.point)
            case .up: self.pointerUp()
            }
        }
        // The destination follows focus; the foot follows it.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.focusChanged() }
    }

    /// Load the model now, so the first `lode .` of the day is not the one
    /// that pays for it. Called only once the grant already exists.
    func warmSpeech() { speech.warm(input: inputDevice) }

    /// The door key's autorepeat can arrive after lode lifts; for this long
    /// after opening, repeats are not typing.
    func justOpened(_ now: Date) -> Bool { now.timeIntervalSince(openedAt) < 0.75 }

    /// The draft as data, for `lodestar draft state`.
    /// The ink still drying: words the second ear or the intent pass may
    /// yet change — everything said since the hand last moved, while
    /// either is at work. Nil when nothing is being checked, and always
    /// nil on a Mac with neither pass.
    var wetRange: Range<Int>? {
        guard earPending > 0 || intentInFlight, let last = lastSpoken,
              last.range.upperBound <= buffer.count, buffer.slice(last.range) == last.text else { return nil }
        var start = last.range.lowerBound
        if let run, run.start <= start { start = run.start }
        return start..<last.range.upperBound
    }

    /// The rewritten words that still stand where they were written.
    var revisedRanges: [Range<Int>] {
        revised.compactMap { mark in
            mark.range.upperBound <= buffer.count && buffer.slice(mark.range) == mark.text ? mark.range : nil
        }
    }

    /// The hand's edit has ended: whatever it respelled that the
    /// recognizer misheard is learned, at once and without asking — a
    /// mishearing is told from a change of mind by sound (`Corrections`).
    /// Only in a draft that heard speech, and never in the clip door,
    /// where the text was copied, not heard.
    private func learnFromTheHand() {
        guard let before = handBaseline else { return }
        handBaseline = nil
        guard spokenWords > 0, clipOrigin == nil, before != buffer.text else { return }
        let after = buffer.text
        let known = Set(words)
        // Off the main thread: the first lesson on a Mac with no words yet
        // reads the whole pronunciation dictionary, and the main thread is
        // the one the key tap shares — every key on the Mac would wait.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let learned = Corrections.learned(
                before: before, after: after, known: known, pronouncer: DictationLexicon.pronouncer,
                isCommon: { CommonWords.isCommon($0) }, isFrequent: { CommonWords.isFrequent($0) })
            guard !learned.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                for word in learned {
                    Log.info("draft", ["learned": word.count])
                    self.journal?.note("learned", before: "", after: word, at: self.clock.now())
                    self.learnWord(word)
                }
            }
        }
    }

    /// A pass replaced `old` at `start` with `new`: underline the words
    /// that differ, not the whole phrase, widened to whole words.
    private func markRevision(at start: Int, old: String, new: String) {
        let a = Array(old), b = Array(new)
        var prefix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let shift = b.count - a.count
        // Marks after the replaced words moved; marks inside it are gone.
        revised = revised.compactMap { mark in
            if mark.range.upperBound <= start + prefix { return mark }
            if mark.range.lowerBound >= start + a.count - suffix {
                return ((mark.range.lowerBound + shift)..<(mark.range.upperBound + shift), mark.text)
            }
            return nil
        }
        var lower = start + prefix, upper = start + b.count - suffix
        let chars = buffer.characters
        if upper <= lower {
            // A deletion, a take-back's usual shape ("the red one, actually
            // no, the blue one" is "the blue one"): nothing new to mark, so
            // the word the cut now sits against is marked instead, or the
            // change would leave no trace at all.
            if lower < chars.count, !chars[lower].isWhitespace {
                upper = lower + 1
            } else {
                var before = lower
                while before > 0, chars[before - 1].isWhitespace { before -= 1 }
                guard before > 0 else { return }
                lower = before - 1
                upper = before
            }
        }
        while lower > 0, !chars[lower - 1].isWhitespace { lower -= 1 }
        while upper < chars.count, !chars[upper].isWhitespace, !".,;:!?".contains(chars[upper]) { upper += 1 }
        while lower < upper, chars[lower].isWhitespace { lower += 1 }
        revised.append((lower..<upper, buffer.slice(lower..<upper)))
    }

    var state: [String: Any] {
        var out: [String: Any] = ["open": isOpen]
        guard isOpen else { return out }
        out["text"] = buffer.text
        out["cursor"] = buffer.cursor
        out["ghost"] = buffer.ghost
        out["mode"] = mode == .insert ? "insert" : "normal"
        out["door"] = door.rawValue
        out["style"] = sessionStyle.rawValue
        switch vim.mode {
        case .insert: out["editor"] = "insert"
        case .normal: out["editor"] = "normal"
        case .visual(let line): out["editor"] = line ? "visual-line" : "visual"
        }
        out["listening"] = listening
        out["silent"] = hearsNothing
        out["retrying"] = retrying
        out["finishing"] = finishing
        out["mic"] = micWanted
        if let inputName { out["input"] = inputName }
        out["expanded"] = expanded
        if let wet = wetRange { out["wet"] = buffer.slice(wet) }
        out["revised"] = revisedRanges.map { buffer.slice($0) }
        out["words"] = spokenWords
        out["typed"] = typedCharacters
        return out
    }

    /// An audio file in place of the microphone, for a functional test
    /// of dictation on a machine with no live mic. The recognizer sees
    /// the file's buffers exactly as it would the tap's.
    func feedAudio(path: String) -> Bool {
        guard isOpen, sessionStarted else { return false }
        return speech.feed(file: URL(fileURLWithPath: path))
    }

    // MARK: - Doors

    func open(door: Draft.Door) {
        guard !isOpen else { posture(door: door); return }
        isOpen = true
        closing = false
        self.door = door
        sessionStyle = editingStyle
        buffer = Draft.Buffer()
        vim = Vim()
        // Four lines from every door, so the work behind stays in view;
        // the clipboard's card opens whole (`openClip`), because opening a
        // card is asking to read it.
        expanded = false
        revised = []
        handBaseline = nil
        // `j` and `k` walk the lines the eye sees; the panel's layout is
        // the only honest source of where those lines break. The buffer
        // arrives by value from the editor — reading `self.buffer` here
        // would collide with the `inout` hold `vim.key` has on it and
        // abort the process.
        vim.visualLine = { [weak self] buffer, index, down in
            self?.panel.visualMove(from: index, down: down, in: buffer)
        }
        speechState = nil
        listening = false
        provisional = nil
        openedAt = clock.now()
        typedCharacters = 0; spokenWords = 0; backspaces = 0; modeSwitches = 0; pointerActs = 0
        firstKeyAt = nil; firstWordAt = nil; peakDb = nil; inputsHeard = []; listens = 0; retries = 0
        resetMicrophoneRecord()
        resetPointer()
        layoutTyper.reset()

        // What is under the cursor: a selection through either door, the
        // whole field through edit.
        let front = frontmost()
        var pulled = false
        var whole = false
        var fieldToken: AnyHashable?
        if let front, let field = readField(front.pid, door == .edit) {
            fieldToken = field.token
            if let selection = field.selection, !selection.isEmpty {
                buffer = Draft.Buffer(text: selection)
                pulled = true
            } else if door == .edit, field.tooLong {
                flash?("✕ too much text to edit here")
            } else if door == .edit, let value = field.value, !value.isEmpty {
                if value.count > Self.pullCap {
                    flash?("✕ too much text to edit here")
                } else {
                    // The editor opens where the field's cursor was, or at
                    // the end, ready to continue.
                    buffer = Draft.Buffer(text: value, cursor: field.cursor ?? value.count)
                    pulled = true
                    whole = true
                }
            }
        }
        origin = front.map { Origin(pid: $0.pid, pulled: pulled, wholeField: whole, token: fieldToken) }
        refreshInputs()

        // Both doors open in insert mode — the difference is the mic and
        // what comes along: speak listens into an empty buffer, edit is
        // silent with the field pulled in. Vim is one esc away either way.
        mode = .insert
        vim.startInsert(buffer)
        switch door {
        case .speak:
            micWanted = true
            startListening()
        case .edit, .clip:
            // The clip door never opens here — it has its own opening,
            // with a card's text — but it is silent all the same.
            micWanted = false
        }
        Log.info("draft", ["open": door.rawValue, "pulled": pulled, "whole": whole])
        render()
    }

    /// The clip door: a card's whole text, silent, the cursor at the top,
    /// standing above the strip's row of recents. There is no microphone
    /// here — opening one flips a Bluetooth headset to its telephone
    /// profile and pauses music, and a stray `lode .` over something
    /// being read must never do that. `⏎` saves to the card, `esc` steps
    /// back to the strip, and neither touches the pasteboard.
    func openClip(_ clip: Clipboard.Clip, text: String, standsAbove: CGFloat) {
        guard !isOpen else { return }
        isOpen = true
        closing = false
        door = .clip
        sessionStyle = editingStyle
        clipOrigin = (clip, text)
        buffer = Draft.Buffer(text: text, cursor: 0)
        vim = Vim()
        // A card is opened to be read: whole.
        expanded = true
        revised = []
        handBaseline = nil
        vim.visualLine = { [weak self] buffer, index, down in
            self?.panel.visualMove(from: index, down: down, in: buffer)
        }
        speechState = nil
        listening = false
        provisional = nil
        origin = nil
        micWanted = false
        self.standsAbove = standsAbove
        doorWidth = panel.width(for: text, style: sessionStyle)
        openedAt = clock.now()
        typedCharacters = 0; spokenWords = 0; backspaces = 0; modeSwitches = 0; pointerActs = 0
        firstKeyAt = nil; firstWordAt = nil; peakDb = nil; inputsHeard = []; listens = 0
        resetMicrophoneRecord()
        resetPointer()
        layoutTyper.reset()
        mode = .insert
        vim.startInsert(buffer)
        Log.info("draft", ["open": Draft.Door.clip.rawValue, "characters": text.count])
        render()
    }

    /// The door keys inside the bar set posture, idempotently.
    ///
    /// Not while the draft is ending: the posture it ends in is the one
    /// its words were said into. A mic asked for then would outlive the
    /// panel, and a mute would drop the finals the stop still owes.
    func posture(door: Draft.Door) {
        guard isOpen else { open(door: door); return }
        guard !closing else { return }
        // The clip door has no microphone to set: `lode .` says so, and
        // `lode ⇧.` asks for the silence it already has.
        if self.door == .clip {
            if door == .speak { flash?("the clipboard view has no microphone") }
            return
        }
        switch door {
        case .speak:
            micWanted = true
            // A session that has itself failed is asked again now; one
            // still starting after a retry is left to land, though the
            // line still shows the failure before it.
            // A refused microphone is not asked again, since asking changes
            // nothing: `lode .` opens the setting that does, and once it has
            // been switched on the same key listens.
            if speechState == .denied, !microphoneGranted() {
                openSettings(Self.microphoneSettings)
            } else if !sessionStarted || speechState == .denied || (sessionSpoke && speechState?.asksAgain == true) {
                listenAgain()
            }
            if mode != .insert { setMode(.insert) } else { resumeIfWanted() }
        case .edit, .clip:
            // The silent posture: the mic stops writing, the mode stays.
            micWanted = false
            pauseSpeech()
            settleGhostAsSeen()
        }
        render()
    }

    /// Words still a ghost when the mic stops writing — insert mode ends,
    /// or the mic is muted — were seen, so they are text now, and the
    /// editor works on text. The final that may still arrive replaces
    /// exactly these characters.
    private func settleGhostAsSeen() {
        guard !buffer.ghost.isEmpty else { return }
        let ghost = buffer.ghost
        let start = buffer.cursor
        buffer.settle(ghost)
        let text = buffer.slice(start..<buffer.cursor)
        provisional = (start..<buffer.cursor, text, buffer.characters)
        vim.typed(text)
    }

    private func setMode(_ next: Draft.Mode) {
        if next == .normal { settleGhostAsSeen() }
        // The editor and the mic agree on which mode this is.
        switch next {
        case .insert: vim.startInsert(buffer)
        case .normal: vim.leaveInsert(&buffer)
        }
        guard mode != next else { return }
        mode = next
        modeSwitches += 1
        if next == .normal { pauseSpeech() } else { resumeIfWanted() }
    }

    // MARK: - The mouse

    /// What a press has made of the text and what it will make of a drag:
    /// the unit it took, and how it grows.
    private struct Press {
        /// The unit the press took, as insertion points: empty at a point,
        /// the word or the line under the pointer for a double or a triple
        /// click. A drag grows it, and keeps it whole either way.
        var range: Range<Int>
        var grain: Draft.Pointer.Grain
        /// A shift-click in the editor reaches from a character, inclusive,
        /// and its drags go on from that same character.
        var character: Int? = nil
        /// The editor was in its line form when a shift-click reached from it.
        var line = false
    }

    /// The press in progress, from the button going down to its release.
    private var press: Press?
    /// The grain of the last press, which a shift-click extends by: after a
    /// double click, whole words. Any key puts it back to a character.
    private var grain = Draft.Pointer.Grain.character
    /// The word or line that press took, which a shift-click keeps whole as
    /// it extends: double-click a word, shift-click three words on, shift-click
    /// a word before it, and the word double-clicked is still the anchor.
    private var pressedUnit: Range<Int>?
    /// Where the pointer last was while the button was down, and what it
    /// was over, for the autoscroll to go on from.
    private var dragPoint: NSPoint?
    private var dragHit: Draft.Pointer.Hit?
    private var autoscroll: Timer?
    /// The caret moved in insert mode since the last edit, by the pointer or
    /// by a key: the next editing key or paste starts a new undo step. See
    /// `markCaretBoundary`.
    private var caretMoved = false

    /// Seconds between the lines a drag past the text box takes.
    static let autoscrollInterval: TimeInterval = 0.06

    private func resetPointer() {
        stopAutoscroll()
        press = nil
        grain = .character
        pressedUnit = nil
        dragPoint = nil
        dragHit = nil
        caretMoved = false
    }

    /// Whether a drag past the text box is taking lines on its own.
    var autoscrolling: Bool { autoscroll != nil }

    /// A press on the text. The same ground rules as a key: words still
    /// being heard become text where they stand, since a hand that points
    /// at the draft has read it and the ghost is part of what it read, and
    /// the hand has acted. The glass is drawn again before the point is
    /// read, so the characters under the pointer are the characters the
    /// buffer holds. Nothing here touches the microphone or the mode,
    /// except where a drag, a double click or a triple click makes a
    /// selection in the editor, which is visual mode and wakes it as any
    /// selection does.
    func pointerDown(at point: NSPoint, clicks: Int, shift: Bool) {
        guard isOpen, !closing else { return }
        pointerActs += 1
        layoutTyper.reset()
        settleGhostAsSeen()
        handActed()
        // The window as the hand left it, before it can be taken back.
        panel.adoptVisibleWindow()
        render()
        let hit = panel.hit(atWindowPoint: point)
        if !shift { grain = Draft.Pointer.Grain(clicks: clicks) }
        var began = Press(range: hit.insertion..<hit.insertion, grain: grain)
        // What a shift-click by words or lines reaches from: the unit that
        // was pressed, while the selection still holds it, else the whole
        // selection, else the caret.
        let reached: Range<Int>? = {
            let current = sessionStyle == .standard ? buffer.selection : vim.selection(in: buffer)
            guard let unit = pressedUnit, let current,
                  current.lowerBound <= unit.lowerBound, unit.upperBound <= current.upperBound else { return current }
            return unit
        }()
        if sessionStyle == .standard {
            if shift {
                // The anchor stays; with no selection it is where the caret was.
                if grain == .character {
                    let held = buffer.anchor ?? buffer.cursor
                    began.range = held..<held
                } else {
                    began.range = reached ?? buffer.cursor..<buffer.cursor
                }
            } else {
                began.range = Draft.Pointer.range(at: hit, grain: grain, in: buffer)
            }
        } else if shift {
            if mode == .insert {
                // The caret is where the selection begins, as a drag from it.
                began.range = buffer.cursor..<buffer.cursor
            } else if grain == .character {
                if case .visual(let linewise) = vim.mode {
                    began.character = vim.visualAnchor
                    began.line = linewise
                } else {
                    began.character = buffer.cursor
                }
            } else {
                began.range = reached ?? buffer.cursor..<buffer.cursor + 1
            }
        } else {
            began.range = Draft.Pointer.range(at: hit, grain: grain, in: buffer)
        }
        if !shift { pressedUnit = grain == .character ? nil : began.range }
        press = began
        dragHit = hit
        dragPoint = point
        if sessionStyle == .vim, !shift, grain == .character {
            // A click: the cursor onto the character, a caret in insert.
            // Whatever visual selection stood is over.
            vim.point(at: mode == .insert ? hit.insertion : hit.character, buffer: &buffer)
            matchSpeechToSelection()
        } else {
            extend(to: hit)
        }
        if mode == .insert { caretMoved = true }
        render()
    }

    /// The pointer moved with the button down: the selection follows it,
    /// and past the text box above or below, the autoscroll takes over.
    func pointerDragged(to point: NSPoint) {
        guard isOpen, !closing, press != nil else { return }
        dragPoint = point
        if panel.edge(atWindowPoint: point) != nil, autoscroll != nil { return }
        let hit = panel.hit(atWindowPoint: point)
        dragHit = hit
        extend(to: hit)
        render()
        if panel.edge(atWindowPoint: point) != nil { startAutoscroll() } else { stopAutoscroll() }
    }

    /// The button came up.
    func pointerUp() {
        press = nil
        dragPoint = nil
        dragHit = nil
        stopAutoscroll()
    }

    /// The selection a press and the pointer's present place make, in the
    /// style's own terms. The Standard style's is the Mac's: the anchor is
    /// where the press began and the caret goes with the pointer. The
    /// editor's is visual mode over the same span, inclusive of the
    /// character the pointer is over, as vim's own mouse makes it
    /// (`set mouse=a`); a drag out of insert leaves it first, by the path
    /// a key takes, so the microphone and the mode agree.
    private func extend(to hit: Draft.Pointer.Hit) {
        guard let press else { return }
        if sessionStyle == .standard {
            let s = Draft.Pointer.selection(press: press.range, to: hit, grain: press.grain, in: buffer)
            buffer.select(anchor: s.anchor, cursor: s.head)
            return
        }
        let line = press.line || press.grain == .line
        if let held = press.character {
            let last = max(0, buffer.count - 1)
            leaveInsertForPointer()
            vim.visual(anchor: held, cursor: min(hit.character, last), line: line, buffer: &buffer)
            matchSpeechToSelection()
            return
        }
        let s = Draft.Pointer.selection(press: press.range, to: hit, grain: press.grain, in: buffer)
        guard let span = Draft.Pointer.visualSpan(anchor: s.anchor, head: s.head) else {
            // Back where it began, or a unit with nothing in it: only a point.
            if case .visual = vim.mode { vim.point(at: hit.character, buffer: &buffer) }
            matchSpeechToSelection()
            return
        }
        leaveInsertForPointer()
        vim.visual(anchor: span.anchor, cursor: span.cursor, line: line, buffer: &buffer)
        matchSpeechToSelection()
    }

    private func leaveInsertForPointer() {
        if mode == .insert { setMode(.normal) }
    }

    // MARK: Autoscroll

    /// A drag with the pointer above or below the text takes a line at a
    /// time toward that edge until it comes back or the button is
    /// released. A timer on the main run loop in the common modes, and
    /// never a tracking loop inside the press: the key tap runs on this
    /// run loop, and a loop that held it would starve every key until the
    /// button came up.
    private func startAutoscroll() {
        guard autoscroll == nil else { return }
        let timer = Timer(timeInterval: Self.autoscrollInterval, repeats: true) { [weak self] _ in
            self?.autoscrollStep()
        }
        RunLoop.main.add(timer, forMode: .common)
        autoscroll = timer
    }

    private func stopAutoscroll() {
        autoscroll?.invalidate()
        autoscroll = nil
    }

    /// One line toward the edge the pointer is past, from where the last
    /// step left the selection.
    func autoscrollStep() {
        guard isOpen, !closing, press != nil, let point = dragPoint,
              let edge = panel.edge(atWindowPoint: point), let from = dragHit else {
            stopAutoscroll()
            return
        }
        // Words heard since the press stand as a ghost, which shifts every
        // position past the cursor, and the layout cannot say where a line
        // up or down lands until they settle: the step waits a tick rather
        // than taking the fallback, which is the text's far end.
        guard buffer.ghost.isEmpty else { return }
        let down = edge == .below
        let index = panel.visualMove(from: from.character, down: down, in: buffer)
            ?? (down ? buffer.count : 0)
        let hit = Draft.Pointer.Hit(at: index)
        dragHit = hit
        extend(to: hit)
        render()
    }

    /// A move of the caret in insert mode ends the typing run, as in any
    /// Mac field: type "abc", click at the start, type "x", and ⌘Z takes
    /// back "x" alone. The boundary is marked at the next editing key and
    /// not at the move, because a snapshot that differed from the text only
    /// by where the cursor stood would make ⌘Z a cursor move.
    private func markCaretBoundary() {
        guard caretMoved else { return }
        caretMoved = false
        vim.markInsertBoundary(buffer)
    }

    /// An input was chosen on the foot. The config line is the
    /// app's to write; the session restarts on the new device at once.
    func selectInput(_ name: String?) {
        inputDevice = name
        chooseInput?(name)
        refreshInputs()
        guard isOpen, !closing, sessionStarted else { render(); return }
        speech.stop {}
        listening = false
        speechState = nil
        inputName = nil
        startListening()
        render()
    }

    /// The inputs, enumerated off the main thread; the foot
    /// redraws when they land.
    private func refreshInputs() {
        enumerateInputs { [weak self] names, system in
            guard let self, self.isOpen else { return }
            self.inputs = names
            self.systemInputName = system
            self.render()
        }
    }

    /// The dictation pair, under `app.sounds`: a note when the microphone
    /// is live, another when the words land. Not the alert.
    var sounds = true
    /// Whether this session's microphone delivered signal: the listening
    /// note plays once on it, and the landing note only after it.
    private var heardAlive = false
    /// The loudest the microphone read this draft, in dBFS: kept past
    /// `close()` for the record, so an empty draft can say whether the
    /// device was deaf (-140) or the room was only quiet.
    private var peakDb: Double?
    /// What the end line says about the microphone, beside `peakDb` and
    /// kept past `close()` the same way, so a draft that ended empty says
    /// which empty it was: heard nothing, heard sound and no words, a mic
    /// that was muted, or one that never started. Reset when a draft opens.
    ///
    /// Seconds of sound above `voiceFloor`: each reading that is above it
    /// counts the time since the one before, up to `levelStep`, so a pause
    /// in the readings (a paused mic, a restart) is not counted as sound.
    private var voiceSeconds: TimeInterval = 0
    private var lastLevelAt: Date?
    static let levelStep: TimeInterval = 0.25
    /// Whether the mic was paused (muted, or in normal mode) for as long as
    /// `pauseNote` at any point. Leaving a draft pauses it too, a moment
    /// before it closes, and that is not a mic that was off while the
    /// draft was in use, so a shorter pause does not count.
    private var micWasPaused = false
    private var pausedSince: Date?
    static let pauseNote: TimeInterval = 1
    /// The last start failure the session said, as the line shows it (the
    /// app's own words, never the person's), or nil if none did.
    private var lastStartFailure: String?
    /// The kind of the last input heard (built-in, bluetooth, usb or
    /// other), as the voice record names it and never its name. Found off
    /// the main thread, since CoreAudio is asked for it and is what a
    /// wedged audio stack stops answering; read when the draft ends.
    private(set) var inputClassName: String?
    var classifyInput: @Sendable (String) -> String? = { AudioInput.transportClass(named: $0) }
    private static let classQueue = DispatchQueue(label: "lodestar.draft.input-class", qos: .utility)
    /// Listening this long with nothing but zeros is said on the register
    /// line: "hearing nothing on <input>". Three seconds is past the
    /// engine's own watch on a wired input and inside a hand's patience;
    /// the sessions that ended in nothing waited five at the median.
    static let silenceNoteSeconds: TimeInterval = 3
    private(set) var hearsNothing = false
    private var silenceWatch: DispatchWorkItem?
    /// A microphone that would not start, or stopped, is asked for again
    /// while the draft wants it, without a hand doing anything: soon at
    /// first, since most failures are a radio changing profile, then
    /// every few seconds for as long as the draft stays open. The words
    /// already in the draft stay where they are. `lode .` asks at once.
    static let retrySeconds: [TimeInterval] = [1, 2, 4, 5]
    private var retries = 0
    private var retryWork: DispatchWorkItem?
    /// Whether the line says the draft is asking again: a failure the
    /// draft retries, while the mic is wanted, from the first failure
    /// until a session listens.
    private var retrying: Bool { retries > 0 && micWanted && speechState?.retries == true }
    /// Whether this session has said anything about itself. The last
    /// session's failure stays on the line while the next one starts, so
    /// the watchdog asks this rather than whether a state is set.
    private var sessionSpoke = false

    // MARK: - Speech

    private func notePause() {
        if pausedSince == nil { pausedSince = clock.now() }
    }

    /// The mic is on again, or the draft has ended: a pause that lasted
    /// `pauseNote` is kept.
    private func noteResume() {
        guard let since = pausedSince else { return }
        pausedSince = nil
        if clock.now().timeIntervalSince(since) >= Self.pauseNote { micWasPaused = true }
    }

    private func resetMicrophoneRecord() {
        voiceSeconds = 0; lastLevelAt = nil; micWasPaused = false; pausedSince = nil
        lastStartFailure = nil; inputClassName = nil
    }

    /// The input's kind, asked of CoreAudio on a queue of its own and kept
    /// for this draft's end line; a draft that has ended meanwhile drops it.
    private func classify(_ input: String) {
        let ending = endings
        let classify = classifyInput
        Self.classQueue.async { [weak self] in
            let kind = classify(input)
            DispatchQueue.main.async {
                guard let self, self.endings == ending else { return }
                self.inputClassName = kind
            }
        }
    }

    private func startListening() {
        guard speech.isAvailable else {
            Log.info("draft", ["speech": "unavailable on this machine"])
            speechState = .unavailable
            return
        }
        wasWarm = AVCaptureDevicePermission.granted
        session += 1
        let mine = session
        sessionStarted = true
        retryWork?.cancel()
        retryWork = nil
        sessionSpoke = false
        listening = false
        heardAlive = false
        hearsNothing = false
        silenceWatch?.cancel()
        onListen?()
        // Once a draft: a session started again inside it, on a new input
        // or after a failure, keeps what the journal has so far.
        if listens == 0 { journal?.begin(app: frontmost()?.name, at: clock.now()) }
        settler.reset()
        run = nil
        earNext = nil
        lastSpoken = nil
        handSinceSpeech = false
        resetIntent()
        settler.codeNames = nil
        if let destination = frontmost(), let root = codeRepository(destination) {
            readCodeNames(root) { [weak self] index in
                guard let self, self.session == mine else { return }
                self.settler.codeNames = index
            }
        }
        listens += 1
        speech.listen(input: inputDevice, onState: { [weak self] state in
            guard let self, self.isOpen, self.session == mine else { return }
            let was = self.speechState
            self.speechState = state
            self.sessionSpoke = true
            if case .failed(let why) = state { self.lastStartFailure = why }
            if state == .wedged { self.lastStartFailure = "the audio system is not answering" }
            if state.retries { self.scheduleRetry(session: mine) }
            if state == .wedged {
                // The timer must not rebuild the recognizer against it: a
                // retry already waiting is let go, and the door asks.
                self.retryWork?.cancel()
                self.retryWork = nil
                if was != .wedged {
                    Log.error("draft", ["speech": "audio is wedged, not asking again on a timer",
                                        "retries": self.retries, "listens": self.listens])
                }
            }
            if case .listening(let input) = state {
                self.retries = 0
                self.retryWork?.cancel()
                self.retryWork = nil
                // Said twice when the Mac's microphone stands in for a
                // waking headset: first for the bridge, then for the
                // headset. The wait the hand felt is the first.
                let first = !self.listening
                self.listening = true
                self.inputName = input
                if let input {
                    self.inputsHeard.insert(input)
                    self.classify(input)
                }
                self.watchForSilence(session: mine)
                // The device actually read, when the session named it:
                // a pinned input that fell back gates on what is open.
                self.playback?.dictationBegan(input: input ?? self.inputDevice)
                if first {
                    self.observations?.latency(surface: "draft-listen",
                                               seconds: self.clock.now().timeIntervalSince(self.openedAt))
                }
                if self.mode == .normal || !self.micWanted { self.notePause(); self.speech.pause() }
            }
            self.render()
        }, onLevel: { [weak self] level, db in
            guard let self, self.isOpen, self.session == mine else { return }
            self.level = level
            if db.isFinite { self.peakDb = max(self.peakDb ?? db, db) }
            let now = self.clock.now()
            if level > Self.voiceFloor {
                self.lastVoiceAt = now
                if let before = self.lastLevelAt {
                    self.voiceSeconds += min(max(0, now.timeIntervalSince(before)), Self.levelStep)
                }
            }
            self.lastLevelAt = now
            self.panel.setLevel(level)
        }, onAlive: { [weak self] in
            guard let self, self.isOpen, self.session == mine, !self.heardAlive else { return }
            self.heardAlive = true
            Log.info("draft", ["microphone": "alive"])
            if self.sounds && self.micWanted { Sounds.play(.listening) }
            if self.hearsNothing {
                self.hearsNothing = false
                self.render()
            }
        }, onVolatile: { [weak self] text in
            guard let self, self.isOpen, self.session == mine, self.mode == .insert, self.micWanted,
                  // Reserved words await their final; a cumulative volatile
                  // would show them twice. The final revises them in place.
                  self.provisional == nil,
                  // A selection waits for the final that replaces it: a ghost
                  // at the cursor would hide the highlight it is about to take.
                  self.buffer.selection == nil else { return }
            if self.firstWordAt == nil {
                self.firstWordAt = self.clock.now()
                self.observations?.latency(surface: "draft-first-word",
                                           seconds: self.firstWordAt!.timeIntervalSince(self.openedAt))
            }
            self.buffer.showGhost(text)
            self.onActivity?()
            self.render()
        }, onSettled: { [weak self] heard in
            guard let self else { return }
            // Finals for a draft esc has closed go to the copy of its text
            // that waits for them.
            if let leaving = self.departing[mine] { leaving.copy.take(heard); return }
            guard self.isOpen, self.session == mine else { return }
            self.settle(heard)
        })
        listenWatchdog?.cancel()
        let watchdog = DispatchWorkItem { [weak self] in
            // Preparing (a model download) reports itself and is not a
            // silence; anything else this long is a session that will
            // never speak — v0.28.0's wedged audio queue looked exactly
            // like this from the foot.
            guard let self, self.isOpen, self.session == mine, !self.listening,
                  !self.sessionSpoke else { return }
            Log.info("draft", ["speech": "no listening state", "seconds": Int(Self.listenWatchdogSeconds)])
            self.speechState = .failed("the microphone did not start")
            self.lastStartFailure = "the microphone did not start"
            self.speech.stop {}
            self.sessionStarted = false
            self.scheduleRetry(session: mine)
            self.render()
        }
        listenWatchdog = watchdog
        clock.after(Self.listenWatchdogSeconds, watchdog)
    }

    /// Ask for the microphone again after the next wait, if the draft
    /// still wants it then. A failure only ever schedules: the asking is
    /// `listenAgain`, which waits for the failed session's last words.
    private func scheduleRetry(session mine: Int) {
        guard isOpen, !closing, door != .clip, retryWork == nil else { return }
        let wait = Self.retrySeconds[min(retries, Self.retrySeconds.count - 1)]
        retries += 1
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryWork = nil
            guard self.isOpen, !self.closing, self.session == mine else { return }
            // Muted meanwhile: the failure stands, and `lode .` asks.
            guard self.micWanted else { self.render(); return }
            Log.info("draft", ["speech": "trying the microphone again", "attempt": self.retries])
            self.listenAgain()
        }
        retryWork = work
        Log.info("draft", ["speech": "retry scheduled", "seconds": wait])
        clock.after(wait, work)
    }

    /// A fresh session in the same draft. The old one is stopped first
    /// and the new one starts when it has, so words the recognizer was
    /// still settling when the microphone went land in this draft rather
    /// than being dropped as a previous session's.
    private func listenAgain() {
        retryWork?.cancel()
        retryWork = nil
        guard sessionStarted else { startListening(); return }
        let mine = session
        sessionStarted = false
        listening = false
        speech.stop { [weak self] in
            guard let self, self.isOpen, !self.closing, self.session == mine, !self.sessionStarted else { return }
            // Muted while the old session stopped: the door asks.
            guard self.micWanted else { self.render(); return }
            self.startListening()
            self.render()
        }
    }

    /// The foot says when the microphone has been open this
    /// long and delivered nothing but zeros. A deaf device reports
    /// listening as happily as a live one, and the only other cue was
    /// the meter not moving, which is what a quiet room looks like too.
    private func watchForSilence(session mine: Int) {
        silenceWatch?.cancel()
        let watch = DispatchWorkItem { [weak self] in
            guard let self, self.isOpen, self.session == mine, self.listening,
                  !self.heardAlive, !self.hearsNothing else { return }
            self.hearsNothing = true
            Log.info("draft", ["microphone": "hearing nothing", "input": self.inputName ?? "unknown",
                               "seconds": Int(Self.silenceNoteSeconds)])
            self.render()
        }
        silenceWatch = watch
        clock.after(Self.silenceNoteSeconds, watch)
    }

    /// Where the matcher is built: off the main thread in the app, since
    /// the dictionary takes a moment to read the first time; at once on
    /// the stage.
    var buildMatcher: (@escaping () -> NameMatcher?, @escaping (NameMatcher?) -> Void) -> Void = { build, done in
        DispatchQueue.global(qos: .utility).async {
            let matcher = build()
            DispatchQueue.main.async { done(matcher) }
        }
    }

    private func rebuildMatcher() {
        let words = self.words
        buildMatcher({
            words.isEmpty ? nil : NameMatcher(
                terms: words.map { NameMatcher.Term($0) }, pronouncer: DictationLexicon.pronouncer,
                isCommon: { CommonWords.isCommon($0) }, isFrequent: { CommonWords.isFrequent($0) })
        }, { [weak self] matcher in
            guard let self, self.words == words else { return }
            self.settler.matcher = matcher
        })
    }

    /// One settled result, through the settler, landed where it belongs:
    /// over the words it settles early, at the anchor the hand left, or at
    /// the cursor. What the settler decided about the text before it — a
    /// pause's period dropped, a trailed-off end given one — is done
    /// there too, and a correction that reaches back replaces the last
    /// result with it.
    private func landing(_ heard: Heard, at point: Int) -> Draft.Settler.Landing {
        let before = buffer.slice(max(0, point - 200)..<point)
        let reachBack = lastSpoken.map { last in
            !handSinceSpeech && last.range.upperBound <= point
                && buffer.slice(last.range) == last.text
                && buffer.slice(last.range.upperBound..<point).allSatisfy(\.isWhitespace)
        } ?? false
        let landing = settler.land(heard, after: before, typedBetween: handSinceSpeech, canReachBack: reachBack)
        settled.names += landing.names
        if !landing.terms.isEmpty { onNamesUsed(landing.terms) }
        settled.ellipses += landing.ellipses
        settled.joins += landing.joins
        settled.fillers += landing.fillers
        settled.corrections += landing.corrections
        return landing
    }

    /// The text just before `point` changed as the settler decided.
    /// Returns how many characters `point` moved by.
    private func applyBefore(_ change: Draft.Settler.Landing.Before, at point: Int) -> Int {
        buffer.applyBefore(change, at: point)
    }

    /// `beyondEdit` is a final's remainder placed after reserved words the
    /// hand has since edited: it lands at the anchor set for it and is
    /// never the voice taking a selection.
    private func settle(_ heard: Heard, beyondEdit: Bool = false) {
        learnFromTheHand()
        let writing = mode == .insert && micWanted
        // Speaking over a selection, visual or a Mac's, is `c` with the
        // voice: the words take the selection's place and insert opens
        // where they end. Behind one undo step, so ⌘Z brings the selection
        // back as it stood. Not while words are reserved: that final is
        // theirs, and revises them in place below, taking any selection
        // with it.
        if micWanted, listening, provisional == nil, !beyondEdit,
           let range = vim.selection(in: buffer), !heard.text.trimmingCharacters(in: .whitespaces).isEmpty {
            settler.handInterrupted()
            let repaired = settler.land(heard, after: "", canReachBack: false).text
            spokenWords += repaired.split(whereSeparator: \.isWhitespace).count
            if firstWordAt == nil { firstWordAt = clock.now() }
            onActivity?()
            provisional = nil
            lastSpoken = nil
            vim.speakOver(range, with: repaired, buffer: &buffer)
            // Speech that takes the selection a drag is still making ends
            // the drag, as a key would: the range it grows from is gone.
            if press != nil { pointerUp() }
            setMode(.insert)
            render()
            return
        }
        // A reservation the hand has since edited: the final is for words
        // that no longer stand as they did, and inserting it would put
        // the whole utterance back on top of the edit. Delete a word from
        // what you just said and the recognizer's final would paste the
        // entire session in again, so the edit stands as the hand left it.
        // What the final carries past the reserved words was never drawn,
        // and lands after the edit's end, through the settler like any
        // landing; a final that does not begin with them is dropped.
        if let standing = provisional, buffer.slice(standing.range) != standing.text {
            buffer.clearGhost()
            provisional = nil
            speechAnchor = nil
            if writing, let rest = Draft.Reserved.remainder(of: heard, after: standing.text) {
                let end = Draft.Reserved.end(of: standing.range, was: standing.base, now: buffer.characters)
                Log.info("draft", ["speech": "final kept past the edit", "words": rest.text.split(whereSeparator: \.isWhitespace).count])
                speechAnchor = (end, clock.now())
                settle(rest, beyondEdit: true)
                return
            }
            Log.info("draft", ["speech": "final dropped", "reason": "reserved words were edited"])
            render()
            return
        }
        if let standing = provisional, buffer.slice(standing.range) == standing.text {
            // The final for words settled early: it replaces them in place,
            // cased for where it lands, if they are still there untouched.
            let landing = self.landing(heard, at: standing.range.lowerBound)
            journal?.heard(heard, landed: landing.text, at: clock.now())
            spokenWords += landing.text.split(whereSeparator: \.isWhitespace).count
            let cursor = buffer.cursor
            var range = standing.range
            let shift = applyBefore(landing.before, at: range.lowerBound)
            range = (range.lowerBound + shift)..<(range.upperBound + shift)
            let lead = Draft.separator(after: buffer.characters[..<range.lowerBound], before: landing.text)
            let replacement = lead + landing.text
            buffer.replace(range, with: replacement)
            // The cursor stays where the hand left it: before the range,
            // untouched; after it, moved by the change in length; inside
            // it, at the range's new end.
            let delta = replacement.count - range.count
            let moved = cursor + shift
            if moved <= range.lowerBound {
                buffer.setCursor(moved)
            } else if moved >= range.upperBound {
                buffer.setCursor(moved + delta)
            } else {
                buffer.setCursor(range.lowerBound + replacement.count)
            }
            if mode == .normal { vim.enterNormal(&buffer) }
            provisional = nil
            lastSpoken = (range.lowerBound..<(range.lowerBound + replacement.count), replacement)
            handSinceSpeech = false
            if let landed = lastSpoken {
                rehear(heard, landed: landed)
                // Reserved because the hand cut in: the hand's text is close.
                wantIntent(from: landed.range.lowerBound, handActed: true)
            }
        } else if writing {
            provisional = nil
            let handActed = handSinceSpeech
            if firstWordAt == nil { firstWordAt = clock.now() }
            onActivity?()
            // Each settled result is its own step to take back. Marked
            // before the words land, so ⌘Z reaches the buffer as it
            // stood when the recognizer began this one.
            vim.markInsertBoundary(buffer)
            // Words said before the hand cut in go where the hand cut in,
            // not at the cursor it has since moved.
            let anchor = freshSpeechAnchor()
            var resume = buffer.cursor
            var point = anchor ?? buffer.cursor
            let cursorAfterPoint = resume >= point
            let landing = self.landing(heard, at: point)
            journal?.heard(heard, landed: landing.text, at: clock.now())
            spokenWords += landing.text.split(whereSeparator: \.isWhitespace).count
            if landing.replacesLast, let last = lastSpoken {
                // A correction reached back: the last result and this one
                // become what was meant.
                let removed = point - last.range.lowerBound
                buffer.replace(last.range.lowerBound..<point, with: "")
                if resume >= point { resume -= removed }
                point = last.range.lowerBound
            } else {
                let shift = applyBefore(landing.before, at: point)
                if resume >= point { resume += shift }
                point += shift
            }
            buffer.setCursor(point)
            let start = buffer.cursor
            let before = buffer.count
            buffer.settle(landing.text, isOrdinary: { CommonWords.isCommon($0) })
            var grew = buffer.count - before
            // The editor hears what speech typed, so `.` can say it again.
            vim.typed(buffer.slice(buffer.cursor - grew..<buffer.cursor))
            lastSpoken = (start..<buffer.cursor, buffer.slice(start..<buffer.cursor))
            if anchor == nil, let landed = lastSpoken {
                rehear(heard, landed: landed)
                wantIntent(from: landed.range.lowerBound, handActed: handActed)
            }
            if anchor != nil {
                // The words went in ahead of what the hand typed, and the
                // joining rule only ever puts a space on the near side of
                // what it inserts. Without this the two run together:
                // "Hello there" ahead of "ok" reads "Hello thereok".
                let at = buffer.cursor
                if at < buffer.count, !buffer.characters[at].isWhitespace {
                    buffer.replace(at..<at, with: " ")
                    grew += 1
                }
                buffer.setCursor(min(buffer.count, cursorAfterPoint ? resume + grew : resume))
                lastSpoken = nil
            }
            handSinceSpeech = false
            speechAnchor = nil
        } else {
            // Spoken while silent and never shown, or shown and since edited
            // away: it does not write.
            buffer.clearGhost()
            provisional = nil
            speechAnchor = nil
        }
        render()
    }

    /// Whether the microphone is writing right now, so a selection
    /// opening or closing moves it once instead of on every key that
    /// leaves the selection standing.
    private var micRunning = false

    /// The standing anchor, if it is still worth honouring: a reservation
    /// older than the words it waits for is a reservation for words that
    /// are not coming.
    private func freshSpeechAnchor() -> Int? {
        guard let anchor = speechAnchor else { return nil }
        guard clock.now().timeIntervalSince(anchor.since) <= Self.speechAnchorSeconds,
              anchor.at <= buffer.count else {
            speechAnchor = nil
            return nil
        }
        return anchor.at
    }

    private func pauseSpeech() {
        guard listening else { return }
        micRunning = false
        notePause()
        speech.pause()
    }

    private func resumeIfWanted() {
        guard listening, micWanted else { return }
        // The mic writes in insert, and over a visual selection, where
        // speaking replaces what is selected. Everywhere else it waits.
        guard mode == .insert || vim.selection(in: buffer) != nil else { return }
        micRunning = true
        noteResume()
        speech.resume()
    }

    /// After a normal-mode key: a selection opening wakes the microphone,
    /// and a selection closing puts it back to sleep.
    private func matchSpeechToSelection() {
        guard isOpen, micWanted, listening, mode != .insert else { return }
        let wanted = vim.selection(in: buffer) != nil
        guard wanted != micRunning else { return }
        if wanted { resumeIfWanted() } else { pauseSpeech() }
    }

    // MARK: - Keys, from the tap

    /// A key while the draft is up and lode is not held. True when the
    /// draft took it; false hands it to the system. ⌘ chords belong to
    /// the system — ⌘⇥ is how the destination changes — except the few
    /// that edit text, which would land in the app underneath and edit
    /// the wrong thing. `keycode` is the key as the keyboard sent it, which
    /// the layout types ⌥ characters and dead keys from; a key without one
    /// is a name only, typed as the key tables type it. `repeating` is a
    /// held key's autorepeat, which never counts as a second ⏎.
    func handleKey(_ key: String, shift: Bool, command: Bool, option: Bool, control: Bool,
                   keycode: Int64? = nil, repeating: Bool = false) -> Bool {
        guard isOpen else { return false }
        // While the last words settle, keys are swallowed, not passed on: a
        // held ⏎ would reach the app ahead of the paste and send. A second
        // ⏎, struck afresh and not repeated by a held key, lands now with
        // what stands.
        if closing {
            if key == "return", !shift, !repeating, !command, !option, !control, let landNow { landNow() }
            return true
        }
        pasteRefused = false
        // A key ends the pointer's grain: a shift-click after one extends by
        // characters again. A key struck with the button still down ends
        // the press too: the drag that follows would grow a range read off
        // text the key has since changed.
        grain = .character
        pressedUnit = nil
        if press != nil { pointerUp() }
        // Standard's selection keys, ⌘ or not.
        if sessionStyle == .standard, mode == .insert, !control {
            // Words still being heard become text before a selection can
            // be drawn across them. Any shifted key settles them, as typing
            // it would.
            if shift { settleGhostAsSeen() }
            if Draft.Standard.move(key, shift: shift, option: option, command: command, lines: eyeLines, in: &buffer) {
                handActed()
                caretMoved = true
                render()
                return true
            }
        }
        if command {
            layoutTyper.reset()
            // In normal mode the chords are the editor's own verbs, so
            // they are one undo step each and `.` knows them.
            if mode == .normal, let keys = Self.normalModeChord(key, shift: shift) {
                for k in keys { _ = vim.key(k, buffer: &buffer, pasteboard: pasteboardForDraft) }
                render()
                return true
            }
            switch key {
            case "delete":
                if mode == .insert {
                    // An edit like ⌥⌫: words still a ghost were said before
                    // the key, so they are text where they stand and go with
                    // the line, and the final that follows finds them edited
                    // and is dropped rather than put back.
                    handActed()
                    settleGhostAsSeen()
                    markSelectionStep(); buffer.deleteToVisualLineStart(panelLines); backspaces += 1
                }
                render(); return true
            case "left":
                buffer.moveVisualLineStart(eyeLines); caretMoved = mode == .insert || caretMoved; render(); return true
            case "right":
                buffer.moveVisualLineEnd(eyeLines); caretMoved = mode == .insert || caretMoved; render(); return true
            case "v":
                if mode == .normal {
                    // Through the editor, so it is one undo step and `.` knows it.
                    let effects = vim.key(.char("p"), buffer: &buffer, pasteboard: pasteboardForDraft)
                    for case .flash(let text) in effects { flashPasteVerdict(text) }
                } else if let text = pasteboardForDraft() {
                    settleGhostAsSeen()
                    markSelectionStep()
                    buffer.type(text); vim.typed(text); typedCharacters += text.count
                } else if pasteRefused {
                    flashPasteVerdict("")
                }
                render()
                return true
            case "c":
                if let selection = buffer.selection {
                    writePasteboard(buffer.slice(selection)); flash?("⌂ copied")
                } else {
                    writePasteboard(buffer.text); flash?("⌂ draft copied")
                }
                return true
            case "z":
                // Insert mode speaks the dialect every macOS field speaks,
                // and every field answers ⌘Z: here it is the editor's undo
                // of the insert run so far, without leaving the mode or
                // silencing the mic. ⌘⇧Z is its redo.
                settleGhostAsSeen()
                let effects = vim.undoInsertRun(&buffer, redo: shift)
                for case .flash(let text) in effects { flash?(text) }
                render()
                return true
            case "a":
                if sessionStyle == .standard {
                    settleGhostAsSeen()
                    buffer.selectAll()
                    render()
                    return true
                }
                // Select all: the whole buffer as the editor's selection,
                // which is what d, c, y and ⌘C then act on.
                setMode(.normal)
                for k in [Vim.Key.char("g"), .char("g"), .char("V"), .char("G")] {
                    _ = vim.key(k, buffer: &buffer, pasteboard: pasteboardForDraft)
                }
                render()
                return true
            case "x":
                guard let selection = buffer.selection else {
                    // Nothing is selected; say what would be.
                    flash?("nothing selected, ⌘A selects all")
                    return true
                }
                markSelectionStep()
                writePasteboard(buffer.slice(selection))
                buffer.deleteSelection()
                render()
                return true
            default:
                return false
            }
        }
        if firstKeyAt == nil, Keys.character(for: key, shift: shift) != nil { firstKeyAt = clock.now() }
        switch mode {
        case .insert: return insertKey(key, shift: shift, option: option, control: control, keycode: keycode)
        case .normal: return normalKey(key, shift: shift, option: option, control: control)
        }
    }

    /// The ⌘ chords normal mode answers, as the editor's keys.
    private static func normalModeChord(_ key: String, shift: Bool) -> [Vim.Key]? {
        switch key {
        case "z": return shift ? [.control("r")] : [.char("u")]
        case "a": return [.char("g"), .char("g"), .char("V"), .char("G")]
        case "left": return [.char("0")]
        case "right": return [.char("$")]
        case "delete": return [.char("d"), .char("0")]
        default: return nil
        }
    }

    /// The hand acted on the text: the revisions underlined for it are
    /// seen, the text as it stood is kept to learn what the hand corrects,
    /// and what the recognizer says next is no longer the last result's
    /// continuation.
    private func handActed() {
        revised = []
        if handBaseline == nil { handBaseline = buffer.text }
        handSinceSpeech = true
        run = nil
        settler.handInterrupted()
    }

    /// The lines the panel draws, which a dictated paragraph breaks into
    /// though it is one logical line. The buffer arrives by value, as it
    /// does for the editor's `j` and `k`: reading `self.buffer` from here
    /// would collide with the `inout` hold the move has on it.
    private var panelLines: Draft.Lines {
        Draft.Lines(
            move: { [weak self] buffer, index, down in self?.panel.caretMove(from: index, down: down, in: buffer) },
            bounds: { [weak self] buffer, index in self?.panel.lineBounds(containing: index, in: buffer) })
    }

    /// The same, for the Mac's keys that walk by lines in insert mode, in
    /// either style: under Vim they are insert mode's arrows, and the
    /// draft already walks `j` and `k` by the eye's lines, because draft
    /// prose makes a logical line an accident of width. Normal mode's own
    /// motions (`0`, `$`, `dd`) keep the file's lines, as vim's do.
    private var eyeLines: Draft.Lines? { panelLines }

    /// A Mac selection about to be replaced or deleted is its own undo
    /// step, so ⌘Z brings the text back. So is an edit made after the caret
    /// moved, and the first edit after a settled result, which would
    /// otherwise join the result's step and take it back with it.
    private func markSelectionStep() {
        if resultStepOpen {
            resultStepOpen = false
            vim.markInsertBoundary(buffer)
        }
        markCaretBoundary()
        if buffer.selection != nil { vim.markInsertBoundary(buffer) }
    }

    private func insertKey(_ key: String, shift: Bool, option: Bool, control: Bool, keycode: Int64?) -> Bool {
        handActed()
        // A dead key waits for the key that completes it, and nothing else
        // completes it: a move, a delete or a return lets it go.
        if control || Keys.character(for: key, shift: false) == nil { layoutTyper.reset() }
        // Words still a ghost when the hand starts writing become text
        // on the spot, reserved where they stand: dictate, type, dictate
        // lands in the order it happened, and the final that arrives
        // later revises the reserved words in place (`provisional`), not
        // at the cursor. Moves and the commit leave the ghost to its own
        // rules.
        let moves = ["escape", "left", "right", "up", "down", "home", "end", "pageup", "pagedown"]
        let editingControl = control && ["h", "w", "u", "k", "d"].contains(key)
        let editingKey = !control && !moves.contains(key) && !(key == "return" && !shift)
        if editingControl || editingKey {
            markSelectionStep()
            if !buffer.ghost.isEmpty {
                settleGhostAsSeen()
            } else if speechAnchor == nil, provisional == nil, micWanted, listening,
                      let heard = lastVoiceAt,
                      clock.now().timeIntervalSince(heard) <= Self.voiceRecencySeconds {
                // Nothing shown yet, but the microphone was hearing a
                // voice a moment ago: whatever it is still working on
                // was said before this key, and belongs before it.
                speechAnchor = (buffer.cursor, clock.now())
            }
        }
        // The control chords every macOS field answers: line ends, a
        // character or a line either way, a word or a line back, the
        // rest of the line forward, the next character.
        if control {
            switch key {
            case "a": buffer.moveVisualLineStart(eyeLines); caretMoved = true
            case "e": buffer.moveVisualLineEnd(eyeLines); caretMoved = true
            case "f": buffer.moveRight(); caretMoved = true
            case "b": buffer.moveLeft(); caretMoved = true
            case "n": buffer.moveVisualDown(eyeLines); caretMoved = true
            case "p": buffer.moveVisualUp(eyeLines); caretMoved = true
            case "d": buffer.deleteForward()
            case "h":
                backspaces += 1
                let before = buffer.count
                buffer.deleteBackward()
                for _ in 0..<(before - buffer.count) { vim.insertBackspace() }
            case "w":
                backspaces += 1
                let before = buffer.count
                buffer.deleteWordBackward()
                for _ in 0..<(before - buffer.count) { vim.insertBackspace() }
            case "u":
                backspaces += 1
                let before = buffer.count
                buffer.deleteToLineStart()
                for _ in 0..<(before - buffer.count) { vim.insertBackspace() }
            case "k":
                buffer.deleteToLineEnd()
            default: return true
            }
            render()
            return true
        }
        switch key {
        case "escape":
            // Standard has no normal mode to step into: esc closes, as a
            // bare esc in normal mode does.
            if sessionStyle == .standard { cancel(reason: "escape"); return true }
            setMode(.normal)
        case "return":
            if shift { buffer.newline(); vim.typed("\n"); typedCharacters += 1 } else { commit(); return true }
        case "delete":
            backspaces += 1
            let before = buffer.count
            if option { buffer.deleteWordBackward() } else { buffer.backspace() }
            // The editor hears one backspace per character removed.
            for _ in 0..<(before - buffer.count) { vim.insertBackspace() }
        case "forwarddelete":
            buffer.deleteForward()
        case "left":
            if option { buffer.moveWordLeft() } else { buffer.moveLeft() }
            caretMoved = true
        case "right":
            if option { buffer.moveWordRight() } else { buffer.moveRight() }
            caretMoved = true
        case "up":
            buffer.moveVisualUp(eyeLines)
            caretMoved = true
        case "down":
            buffer.moveVisualDown(eyeLines)
            caretMoved = true
        case "tab":
            buffer.type("\t"); vim.typed("\t"); typedCharacters += 1
        default:
            guard !control, var typed = Keys.character(for: key, shift: shift) else { return true }
            // Through the layout when ⌥ is held, a dead key is waiting or
            // this key is one: ⌥e is an accent, ⌥⇧- a dash, and the key
            // after a dead one completes it. Every other key is typed as
            // the key tables type it.
            if let keycode, let laid = layoutTyper.type(keycode: keycode, shift: shift, option: option) {
                guard !laid.isEmpty else { render(); return true }
                typed = laid
            }
            // The editor hears exactly what the buffer took, separator
            // and all, or `.` would replay a word without its space.
            vim.typed(buffer.type(typed, joining: true))
            typedCharacters += 1
        }
        render()
        return true
    }

    /// Normal and visual mode: the editor decides, the shell keeps the
    /// two keys the bar owns. `⏎` commits in every mode; a bare `esc` —
    /// nothing pending, no selection — closes.
    private func normalKey(_ key: String, shift: Bool, option: Bool, control: Bool) -> Bool {
        handActed()
        if key == "return" { commit(); return true }
        let vimKey: Vim.Key
        switch key {
        case "escape": vimKey = .escape
        case "delete": vimKey = .delete
        case "left": vimKey = .left
        case "right": vimKey = .right
        case "up": vimKey = .up
        case "down": vimKey = .down
        default:
            guard let typed = Keys.character(for: key, shift: shift), let c = typed.first else { return true }
            vimKey = control ? .control(c) : .char(c)
        }
        // The editor's marks as the editor keys see them: character ranges.
        let settled = buffer.text
        vim.spellMarks = editorMarks.compactMap { mark -> Range<Int>? in
            guard let span = Range(mark, in: settled) else { return nil }
            let lower = settled.distance(from: settled.startIndex, to: span.lowerBound)
            return lower..<(lower + settled[span].count)
        }
        let marksAtKey = editorMarks
        let effects = vim.key(vimKey, buffer: &buffer, pasteboard: pasteboardForDraft)
        for effect in effects {
            switch effect {
            case .enterInsert:
                setMode(.insert)
            case .yank(let text):
                writePasteboard(text)
                flash?("⌂ copied")
            case .flash(let text):
                flashPasteVerdict(text)
            case .spellFix(let index), .spellKeep(let index):
                if marksAtKey.indices.contains(index) {
                    var keep = false
                    if case .spellKeep = effect { keep = true }
                    onSpellKey?(marksAtKey[index], keep)
                }
            case .view(let whole):
                expanded = whole
            case .unhandled:
                if vimKey == .escape { cancel(reason: "escape"); return true }
            }
        }
        matchSpeechToSelection()
        render()
        return true
    }

    // MARK: - Endings

    /// `⏎`: the last words settle, the text goes to the pasteboard, and
    /// then it lands wherever is frontmost — replacing what was pulled
    /// if that is still the origin, pasting anywhere else, staying on
    /// the pasteboard when there is nowhere to paste.
    func commit() {
        guard isOpen, !closing else { return }
        closing = true
        if clipOrigin != nil { landClip(exit: "return", commit: true); return }
        // The wait is named once it is long enough to be noticed.
        let showing = DispatchWorkItem { [weak self] in
            guard let self, self.isOpen, self.closing else { return }
            self.finishing = true
            self.render()
        }
        finishingWork = showing
        clock.after(Self.finishingShownSeconds, showing)
        // Every path ends in one landing, once: the waits that outlive it
        // find it done.
        var landedOnce = false
        let land = { [weak self] in
            guard !landedOnce else { return }
            landedOnce = true
            self?.land()
        }
        let finish = { [weak self] in self?.afterEars { self?.afterIntent { land() } } }
        // A second ⏎ ends every wait: the ghost lands as seen, and so does
        // whatever the ear and the pass have not yet answered.
        var stopped = false
        landNow = { [weak self] in
            guard let self else { return }
            if !stopped {
                stopped = true
                if !self.buffer.ghost.isEmpty { self.settle(Heard(self.buffer.ghost)) }
            }
            Log.info("draft", ["commit": "landed by a second return"])
            land()
        }
        if sessionStarted, listening, mode == .insert, micWanted {
            // ⏎ lands when the stop completes, not on the first final: the
            // stop drains the finals the recognizer still owes before it
            // reports done, so each has settled by then. Landing on the
            // first one left a second, outstanding, to be dropped.
            var landed = false
            speech.stop { [weak self] in
                guard let self, !landed, !stopped else { return }
                landed = true
                // A ghost with no final behind it settles as what it was.
                if !self.buffer.ghost.isEmpty { self.settle(Heard(self.buffer.ghost)) }
                finish()
            }
            // The recognizer's stop is bounded, but a bound that is never
            // reached — a wedged analyzer, a task that never resumes —
            // would leave `closing` standing and every key swallowed.
            // Past this, the ghost lands as seen and the draft closes.
            let backstop = DispatchWorkItem { [weak self] in
                guard let self, !landed, !stopped else { return }
                landed = true
                Log.info("draft", ["commit": "landed by backstop", "ghost": !self.buffer.ghost.isEmpty])
                if !self.buffer.ghost.isEmpty { self.settle(Heard(self.buffer.ghost)) }
                finish()
            }
            landBackstop = backstop
            clock.after(Self.landBackstopSeconds, backstop)
        } else {
            if sessionStarted { speech.stop {} }
            // A ghost standing between sessions (a new input not yet
            // listening) has no final coming: it lands as seen, as esc
            // would keep it. Only then: a session still listening (muted,
            // or in normal mode) may yet deliver the final for those words,
            // and settling them here as well would land them twice.
            if !listening, !buffer.ghost.isEmpty { settle(Heard(buffer.ghost)) }
            finish()
        }
    }

    // MARK: - The settling ear

    /// The phrase that just landed, heard again by the ear from the held
    /// audio, off the main thread.
    private func rehear(_ heard: Heard, landed: (range: Range<Int>, text: String)) {
        guard let start = heard.start, let end = heard.end, end > start else { return }
        // The run: begun by this phrase, or carried on from the ones before
        // it while the hand stayed off the keys. Kept while the ear is
        // cold too, so the ear can catch up when it has loaded.
        if let current = run, current.start <= landed.range.lowerBound, end - current.time <= Self.runSeconds {
            run = (current.start, current.time, landed.range.upperBound, end, heard)
        } else {
            run = (landed.range.lowerBound, start, landed.range.upperBound, end, heard)
        }
        guard let ear, ear.isLoaded else { return }
        hearRun(with: ear)
    }

    /// The second ear finished loading with the draft open: the run
    /// stands as the live recognizer wrote it, and the audio is still
    /// held, so it hears the run now, through the same path and with the
    /// same guards as any phrase. Nothing is heard if the hand has touched
    /// the words since (the run ends with the hand) or the run is gone.
    func earLoaded() {
        guard isOpen, sessionStarted, let ear, ear.isLoaded, run != nil else { return }
        hearRun(with: ear)
    }

    /// The run so far, heard again from the held audio, off the main thread.
    private func hearRun(with ear: SettlingEar) {
        guard let run, run.upper <= buffer.count else { return }
        let range = run.start..<run.upper
        let whole = (range: range, text: buffer.slice(range))
        let samples = speech.held.slice(from: max(0, run.time - 0.2), to: run.end + 0.3)
        // Under half a second is a word or a breath: not worth a second ear.
        guard samples.count >= 8_000 else { return }
        earGeneration += 1
        let job = EarJob(ear: ear, samples: samples, context: earContext, apple: run.heard, landed: whole,
                         session: session, generation: earGeneration)
        // The ear is busy: this one waits, and takes the place of any that
        // was waiting. The one running cannot be recalled, but its answer
        // is stale now and is not taken (the generation moved on).
        if earRunning { earNext = job } else { launch(job) }
    }

    private func launch(_ job: EarJob) {
        earRunning = true
        // Not detached: a detached task starts without Stoic's ambient context
        // (its events, clock and task ledger), so nothing this work records
        // would reach the log. It runs off the main thread all the same: the
        // controller is not an actor, so the task inherits none. The priority
        // is the one a detached task has, named: an ordinary task would take
        // the main thread's (measured: 25, user initiated, against 21).
        Task(priority: .medium) { [weak self] in
            let began = ContinuousClock.now
            let again = try? await job.ear.transcribe(job.samples, context: job.context)
            let seconds = began.secondsElapsed
            await MainActor.run {
                self?.earHeard(again, apple: job.apple, landed: job.landed, session: job.session,
                               generation: job.generation, seconds: seconds)
            }
        }
    }

    private func earHeard(_ again: Heard?, apple: Heard, landed: (range: Range<Int>, text: String),
                          session mine: Int, generation: Int, seconds: Double) {
        earRunning = false
        defer {
            // The newest waiting hearing starts as this one ends, unless
            // the draft it was for has gone.
            if let next = earNext {
                earNext = nil
                if isOpen, next.session == session { launch(next) }
            }
            if earPending == 0 {
                // The ear is done: the pass reads its words, and starts
                // before ⏎'s wait for the ear lets go.
                startIntentIfReady()
                let waiters = earWaiters
                earWaiters = []
                waiters.forEach { $0() }
                // The ink dries whether or not the ear changed a word.
                render()
            }
        }
        guard session == mine, isOpen, generation == earGeneration, let again, landed.range.upperBound <= buffer.count,
              buffer.slice(landed.range) == landed.text else { return }
        let lead = String(landed.text.prefix { $0.isWhitespace })
        let core = String(landed.text.dropFirst(lead.count))
        let before = buffer.slice(max(0, landed.range.lowerBound - 200)..<landed.range.lowerBound) + lead
        let resettled = settler.resettled(again, landed: core, after: before, context: earContext)
        journal?.earHeard(ear?.name ?? "ear", heard: again.text, stood: core,
                          placed: resettled == core ? nil : resettled, seconds: seconds, at: clock.now())
        guard let text = resettled, text != core else { return }
        let replacement = lead + text
        learnFromTheHand()
        vim.replaceKeepingCursor(landed.range, with: replacement, buffer: &buffer)
        markRevision(at: landed.range.lowerBound, old: landed.text, new: replacement)
        earChanged += 1
        if let last = lastSpoken, last.range.upperBound == landed.range.upperBound {
            // The last phrase is now the end of the settled run.
            let newEnd = landed.range.lowerBound + replacement.count
            lastSpoken = (min(last.range.lowerBound, newEnd)..<newEnd,
                          buffer.slice(min(last.range.lowerBound, newEnd)..<newEnd))
        }
        Log.info("draft", ["ear": ear?.name ?? "?", "changed": true, "ms": Int(seconds * 1000)])
        render()
    }

    /// ⏎ waits for the phrases still being heard again, at most a second.
    private func afterEars(_ then: @escaping () -> Void) {
        guard earPending > 0 else { then(); return }
        var done = false
        let go = {
            guard !done else { return }
            done = true
            then()
        }
        earWaiters.append(go)
        clock.after(Self.earWaitSeconds, DispatchWorkItem { go() })
    }

    // MARK: - The intent pass

    private func resetIntent() {
        intentGeneration += 1
        intentInFlight = false
        intentAsking = nil
        intentWanted = false
        intentFrom = nil
        intentFloor = 0
        intentSent = []
        let waiters = intentWaiters
        intentWaiters = []
        waiters.forEach { $0() }
    }

    /// A result landed at `from`: once the ear has heard it again, the
    /// pass may read it. Where the hand wrote just before it, nothing
    /// before it is read.
    private func wantIntent(from: Int, handActed: Bool) {
        guard intend != nil else { return }
        if handActed { intentFloor = max(intentFloor, from) }
        intentFrom = min(intentFrom ?? from, from)
        intentWanted = true
        startIntentIfReady()
    }

    /// Where the sentence holding the character before `point` begins,
    /// never before `floor`.
    private func sentenceStart(before point: Int, floor: Int) -> Int {
        let chars = buffer.characters
        var i = point
        while i > floor {
            let c = chars[i - 1]
            if c == "\n" { break }
            if c.isWhitespace, i - 1 > floor, ".!?".contains(chars[i - 2]) { break }
            i -= 1
        }
        while i < point, chars[i].isWhitespace { i += 1 }
        return i
    }

    /// Ask, when there is something to ask about and nothing else is
    /// moving: the ear has finished, no reservation or anchor stands, the
    /// draft is writing, and the speech is English (the rules are).
    private func startIntentIfReady() {
        guard intentWanted, earPending == 0, let intend, isOpen, settler.removesFillers,
              mode == .insert, provisional == nil, speechAnchor == nil,
              let last = lastSpoken, last.range.upperBound <= buffer.count, buffer.slice(last.range) == last.text
        else { return }
        let end = last.range.upperBound
        let floor = min(intentFloor, end)
        // The new results' sentences, and the sentence before them: a
        // take-back reaches into it ("…Monday." "No wait, Tuesday").
        var from = sentenceStart(before: min(max(intentFrom ?? last.range.lowerBound, floor), end), floor: floor)
        var back = from
        while back > floor, buffer.characters[back - 1].isWhitespace { back -= 1 }
        if back > floor { from = sentenceStart(before: back - 1, floor: floor) }
        // At most so many words, cut where a word begins.
        var words = 0
        var i = end
        while i > from {
            if !buffer.characters[i - 1].isWhitespace, i - 1 == from || buffer.characters[i - 2].isWhitespace {
                words += 1
                if words == Self.intentWords { from = i - 1; break }
            }
            i -= 1
        }
        let range = from..<end
        let sent = buffer.slice(range)
        let lead = String(sent.prefix { $0.isWhitespace })
        let core = String(sent.dropFirst(lead.count))
        if intentInFlight {
            // A question is under way. Only one that is worth asking, and
            // that takes in the older one's words (or whose words have been
            // changed, so its answer would be refused), replaces it. Any
            // other waits for the older to answer, as it always did, and
            // nothing it holds is spent.
            guard IntentPass.wants(core), !intentSent.contains(core), replaces(intentAsking, with: range) else { return }
        }
        intentWanted = false
        intentFrom = nil
        guard IntentPass.wants(core), !intentSent.contains(core) else { return }
        intentSent.insert(core)
        intentInFlight = true
        intentAsking = (range, sent)
        intentSentAt = clock.now()
        intentGeneration += 1
        let generation = intentGeneration
        let mine = session
        let ears = earGeneration
        let names = intentNames
        // The slot runs on the main actor, where the draft is only ever
        // touched, so its check that nothing newer was asked and its
        // delivery are one step. The model's wait and the checking of its
        // answer are not: they run off the main thread.
        MainActor.assumeIsolated {
            intentSlot.run(for: self) { [weak self] in
                await Self.ask(intend, core: core, names: names) { seconds in
                    await MainActor.run { self?.noteAsk(seconds) }
                }
            } deliver: { @MainActor draft, result in
                let heard = result.get()
                draft.intentHeard(heard.answer, judged: (heard.text, heard.verdict), sent: (range, sent), lead: lead,
                                  session: mine, generation: generation, ears: ears, seconds: heard.seconds)
            }
        }
    }

    /// Whether a question over `range` may take the place of the one under
    /// way: it holds the older's words, or the older's words are no longer
    /// where they were sent from.
    private func replaces(_ asking: (range: Range<Int>, text: String)?, with range: Range<Int>) -> Bool {
        guard let asking else { return true }
        guard asking.range.upperBound <= buffer.count, buffer.slice(asking.range) == asking.text else { return true }
        return range.lowerBound <= asking.range.lowerBound && range.upperBound >= asking.range.upperBound
    }

    /// The model asked, and its answer judged, off the main thread. Every
    /// answer says how long an ask takes, here and not where it is applied:
    /// a question that was replaced, or whose draft has gone, never reaches
    /// the delivery, and the ask that outran ⏎'s wait is the one the record
    /// most needs.
    @concurrent
    private static func ask(_ intend: @escaping (String) async -> String?, core: String, names: [String],
                            took: @escaping @Sendable (Double) async -> Void) async -> IntentAnswer {
        let began = ContinuousClock.now
        let answer = await intend(core)
        let judged = IntentPass.judge(said: core, answer: answer ?? "", names: names)
        let seconds = began.secondsElapsed
        if answer != nil { await took(seconds) }
        return IntentAnswer(answer: answer, text: judged.text, verdict: judged.verdict, seconds: seconds)
    }

    private func noteAsk(_ seconds: Double) {
        intentTimes.append(seconds)
        if intentTimes.count > Self.intentTimesKept { intentTimes.removeFirst(intentTimes.count - Self.intentTimesKept) }
    }

    private func intentHeard(_ answer: String?, judged: (text: String?, verdict: IntentChecker.Verdict?),
                             sent: (range: Range<Int>, text: String), lead: String, session mine: Int,
                             generation: Int, ears: Int, seconds: Double) {
        guard generation == intentGeneration else { return }
        intentInFlight = false
        intentAsking = nil
        defer {
            startIntentIfReady()
            if !intentInFlight {
                let waiters = intentWaiters
                intentWaiters = []
                waiters.forEach { $0() }
            }
            // Dry, changed or not.
            render()
        }
        let core = String(sent.text.dropFirst(lead.count))
        // Applied only to the words as they were sent: nothing typed,
        // heard again or reserved since.
        let stands = session == mine && isOpen && ears == earGeneration && earPending == 0 && mode == .insert
            && provisional == nil && speechAnchor == nil && sent.range.upperBound <= buffer.count
            && buffer.slice(sent.range) == sent.text
        let refused = judged.verdict.flatMap { $0.ok ? nil : $0.reason }
        guard stands, let meant = judged.text else {
            journal?.intent(sent: core, answer: answer, placed: nil, refused: refused ?? (stands ? nil : "moved on"),
                            seconds: seconds, at: clock.now())
            Log.info("intent", ["changed": false, "ms": Int(seconds * 1000),
                                "why": refused ?? (answer == nil ? "no answer" : stands ? "same" : "moved on")])
            return
        }
        let before = buffer.slice(max(0, sent.range.lowerBound - 200)..<sent.range.lowerBound) + lead
        let replacement = lead + settler.reshaped(meant, like: core, after: before)
        learnFromTheHand()
        vim.replaceKeepingCursor(sent.range, with: replacement, buffer: &buffer)
        markRevision(at: sent.range.lowerBound, old: sent.text, new: replacement)
        intentChanged += 1
        journal?.intent(sent: core, answer: answer, placed: replacement, refused: nil, seconds: seconds, at: clock.now())
        Log.info("intent", ["changed": true, "ms": Int(seconds * 1000),
                            "edits": judged.verdict?.edits.map(\.kind).joined(separator: ",") ?? ""])
        // What reached back into the words they were no longer holds:
        // the settler's last result, the ear's run (which would hear the
        // rewrite away again), the last phrase's place.
        lastSpoken = nil
        settler.handInterrupted()
        run = nil
        render()
    }

    /// ⏎ waits for a rewrite under way, a little: only when the record of
    /// answers says it can finish inside the wait. Otherwise it lands now,
    /// and the answer, if it comes, finds the draft gone. With no record
    /// yet, it waits as it always did.
    private func afterIntent(_ then: @escaping () -> Void) {
        guard intentInFlight else { then(); return }
        if let median = Self.median(intentTimes) {
            let elapsed = intentSentAt.map { clock.now().timeIntervalSince($0) } ?? 0
            if median - elapsed > Self.intentWaitSeconds {
                Log.info("draft", ["intent wait": "skipped", "median ms": Int(median * 1000),
                                   "elapsed ms": Int(elapsed * 1000)])
                then()
                return
            }
        }
        var done = false
        let go = {
            guard !done else { return }
            done = true
            then()
        }
        intentWaiters.append(go)
        clock.after(Self.intentWaitSeconds, DispatchWorkItem { go() })
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    private func land() {
        guard isOpen else { return }
        learnFromTheHand()
        let text = buffer.text
        let destination = frontmost()
        let ending = Draft.ending(
            hasDestination: destination != nil,
            destinationIsOrigin: destination?.pid == origin?.pid,
            pulledFromOrigin: origin?.pulled ?? false)
        // A plain paste into another app is the one ending that can land
        // on nothing: the app may have no focused element, or a list. It is
        // asked off the main thread before the key is posted; a replace
        // goes back into the field the words came from and needs no asking.
        if !text.isEmpty, ending == .paste, let pid = destination?.pid {
            var answered = false
            let answer: (Draft.Target) -> Void = { [weak self] target in
                guard !answered else { return }
                answered = true
                self?.finishLanding(text: text, destination: destination, ending: ending, target: target)
            }
            probeTarget(pid, answer)
            // An answer that never comes is an uncertain one.
            clock.after(Self.targetWaitSeconds, DispatchWorkItem { answer(.unknown) })
            return
        }
        finishLanding(text: text, destination: destination, ending: ending, target: nil)
    }

    private func finishLanding(text: String, destination: Destination?, ending: Draft.Ending,
                               target: Draft.Target?) {
        guard isOpen else { return }
        var action = "empty"
        var row: String? = nil
        if !text.isEmpty {
            writePasteboard(text)
            // Nothing may be selected or posted into a field that blocks
            // synthetic input; the text is on the pasteboard, and that is
            // the whole ending.
            let secure = ending != .clipboard && secureInput()
            switch ending {
            case .clipboard:
                flash?("⌂ copied, nothing to paste into")
                action = "copied"; row = "clipboard"
            case _ where secure:
                flash?("press ⌘V to paste, this field blocks synthetic input")
                action = "copied"; row = "secure"
            case .paste where target.map({ !Draft.pastes(into: $0) }) ?? false:
                // The app is there and nothing in it takes text: a paste
                // would be a key struck into the air, with the confirming
                // sound over it. The words are on the pasteboard, and the
                // flash says where they went.
                flash?("⌂ copied, no field there takes a paste")
                action = "copied"; row = "no field"
            case .replace where origin?.wholeField == true
                && origin.flatMap({ readField($0.pid, false) })?.token != origin?.token:
                // The same app, a different field: a paste there, and the
                // field the text came from is left alone.
                paste()
                action = "pasted"; row = "paste"
            case .replace:
                if origin?.wholeField == true, let pid = origin?.pid, !selectAll(pid) {
                    postKey("a", .maskCommand)
                }
                paste()
                action = "replaced"; row = "replace"
            case .paste:
                paste()
                action = "pasted"; row = "paste"
            }
        }
        close()
        record(action: action, row: row, destination: destination)
        if action == "pasted" || action == "replaced" { onLanded?() }
    }

    private func paste() {
        // Landed: the confirmation for the eye that is on the destination.
        if sounds && heardAlive { Sounds.play(.landed) }
        postKey("v", .maskCommand)
    }

    /// Anything but `⏎`: the text stays on the pasteboard, the draft
    /// goes away. `reason` is for the log and the record only.
    func cancel(reason: String) {
        // A quit waits for nothing, a draft esc has already closed
        // included: what it holds goes to the pasteboard now, ahead of a
        // draft still open, which is the newer.
        if reason == "quit" {
            for mine in departing.keys.sorted() { departing[mine]?.keep() }
        }
        guard isOpen, !closing else { return }
        closing = true
        learnFromTheHand()
        if clipOrigin != nil { landClip(exit: reason, commit: false); return }
        let text = buffer.text + (buffer.ghost.isEmpty ? "" : Draft.separator(after: buffer.characters, before: buffer.ghost) + buffer.ghost)
        let destination = frontmost()
        // A quit waits for nothing: the process is going.
        if sessionStarted, listening, mode == .insert, micWanted, reason != "quit" {
            // The panel closes now; the last second of speech is still in
            // the recognizer, and the clip is written once the stop has
            // delivered it, into a copy of the text.
            let mine = session
            let endedBefore = endings
            let leaving = Departure(buffer: buffer, settler: settler, provisional: provisional,
                                    anchor: freshSpeechAnchor())
            var kept = false
            let keep = { [weak self] in
                guard let self, !kept else { return }
                kept = true
                self.departing[mine] = nil
                self.keepDeparted(leaving.text, reason: reason, endedBefore: endedBefore)
            }
            departing[mine] = (leaving, keep)
            speech.stop { keep() }
            clock.after(Self.departBackstopSeconds, DispatchWorkItem { keep() })
        } else {
            if sessionStarted { speech.stop {} }
            if !text.isEmpty {
                writePasteboard(text)
                if reason == "escape" { flash?("⌂ draft kept in the clipboard") }
            }
        }
        close()
        record(action: text.isEmpty ? "empty" : "cancelled", row: reason, destination: destination)
    }

    /// The clipboard given a departed draft's text, with its flash.
    /// Skipped when a later draft has already ended: its landing is the
    /// newer thing on the pasteboard and this would take it back.
    private func keepDeparted(_ text: String, reason: String, endedBefore: Int) {
        guard !text.isEmpty else { return }
        guard endings <= endedBefore + 1 else {
            Log.info("draft", ["cancel": "clip not written", "reason": "a later draft has ended"])
            return
        }
        writePasteboard(text)
        if reason == "escape" { flash?("⌂ draft kept in the clipboard") }
    }

    /// The clip door's ending, into the history and never the pasteboard.
    /// `⏎` with changed text replaces the card in place; any other way
    /// out with changed text keeps the edit as a new card, because an
    /// edit lost to a reflexive escape is the worse failure; unchanged
    /// text writes nothing either way.
    private func landClip(exit: String, commit: Bool) {
        guard let origin = clipOrigin else { return }
        let text = buffer.text
        let outcome = Draft.clipOutcome(original: origin.original, current: text, commit: commit)
        switch outcome {
        case .unchanged: break
        case .saved: replaceClip?(origin.clip, text)
        case .kept: fileClip?(origin.clip, text)
        case .empty: flash?("✕ an empty card is not saved, the card is unchanged")
        }
        close()
        record(action: outcome.rawValue, row: exit, destination: nil)
        Log.info("draft", ["clip": outcome.rawValue, "exit": exit])
        onClipDoorClosed?()
    }

    private func close() {
        defer { onClosed?() }
        endings += 1
        isOpen = false
        finishing = false
        finishingWork?.cancel()
        finishingWork = nil
        landNow = nil
        clipOrigin = nil
        doorWidth = nil
        standsAbove = 0
        landBackstop?.cancel()
        landBackstop = nil
        listenWatchdog?.cancel()
        listenWatchdog = nil
        silenceWatch?.cancel()
        silenceWatch = nil
        hearsNothing = false
        retryWork?.cancel()
        retryWork = nil
        retries = 0
        stashWork?.cancel()
        stashWork = nil
        stash?(nil)
        playback?.dictationEnded()
        listening = false
        sessionStarted = false
        inputName = nil
        level = 0
        provisional = nil
        speechAnchor = nil
        lastVoiceAt = nil
        session += 1
        earNext = nil
        run = nil
        resetIntent()
        resetPointer()
        panel.hide()
    }

    private func record(action: String, row: String?, destination: Destination?) {
        let now = clock.now()
        noteResume()
        journal?.finish(action, text: buffer.text, at: now)
        observations?.drafted(
            app: destination?.name ?? "clipboard", door: door.rawValue, action: action, row: row,
            seconds: now.timeIntervalSince(openedAt), typed: typedCharacters, words: spokenWords,
            backspaces: backspaces, switches: modeSwitches, pointerActs: pointerActs,
            firstKey: firstKeyAt.map { $0.timeIntervalSince(openedAt) },
            firstWord: firstWordAt.map { $0.timeIntervalSince(openedAt) },
            warm: wasWarm, peakDb: peakDb.map { $0.rounded() }, editing: sessionStyle, at: now)
        Log.info("draft", ["end": action, "words": spokenWords, "typed": typedCharacters,
                           "seconds": Int(now.timeIntervalSince(openedAt)),
                           "peakDb": peakDb.map { Int($0) } ?? "none",
                           "voiceSeconds": Self.tenths(voiceSeconds),
                           "firstWord": firstWordAt.map { Self.tenths($0.timeIntervalSince(openedAt)) } ?? "none",
                           "paused": micWasPaused,
                           "startFailure": lastStartFailure ?? "none",
                           "input": inputsHeard.isEmpty ? "none" : (inputClassName ?? "unknown")])
        measureVoice(app: destination?.name ?? "clipboard")
    }

    /// Seconds to a tenth, for the end line.
    private static func tenths(_ seconds: TimeInterval) -> Double { (seconds * 10).rounded() / 10 }

    /// The draft's voice, measured off the main thread from the audio the
    /// session holds, before the next session drops it. Only the numbers
    /// are kept.
    private func measureVoice(app: String) {
        guard measuresVoice, spokenWords > 0, listens == 1, let observations else { return }
        let held = speech.held
        let samples = held.slice(from: 0, to: held.seconds)
        let words = spokenWords
        let start = openedAt
        let inputs = inputsHeard
        let last = inputName
        DispatchQueue.global(qos: .utility).async {
            let mic = last.flatMap(AudioInput.transportClass(named:))
            guard let stats = VoiceStats.analyse(samples, words: words, mic: mic,
                                                 mixed: inputs.count > 1 ? true : nil) else { return }
            DispatchQueue.main.async { observations.voice(stats, app: app, at: start) }
        }
    }

    // MARK: - Drawing

    private func render() {
        guard isOpen else { return }
        // The editor reads the settled text as it changes; a ghost still
        // standing is words the recognizer may yet rewrite.
        let text = buffer.text
        if text != editorTextSeen || buffer.ghost.isEmpty != editorGhostCleared {
            editorTextSeen = text
            editorGhostCleared = buffer.ghost.isEmpty
            let caret = (String(buffer.characters[..<buffer.cursor]) as NSString).length
            if let marks = onTextChange?(text, caret, !buffer.ghost.isEmpty) { editorMarks = marks }
        }
        // The clip door stashes nothing: its text is already a card, and a
        // stash returned via the pasteboard at the next boot would put it
        // there, which the door promises never to do.
        // At most half a second behind, however long the words keep coming.
        // It was a debounce — every render cancelled the pending write — so
        // continuous dictation or typing wrote nothing until a pause, and an
        // app that died mid-sentence (a watchdog abort is a stall, which is
        // exactly a moment with no pause) had stashed nothing of it. The
        // pending write reads the buffer as it is when it runs.
        if stash != nil, clipOrigin == nil, stashWork == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.stashWork = nil
                guard self.isOpen else { return }
                let ghost = self.buffer.ghost
                self.stash?(self.buffer.text + (ghost.isEmpty ? "" : " " + ghost))
            }
            stashWork = work
            clock.after(0.5, work)
        }
        // The voice folds it: words arriving mean the eye is elsewhere.
        if !buffer.ghost.isEmpty { expanded = false }
        let front = frontmost()
        let card: DraftView.Card? = clipOrigin.map { origin in
            let detail = Caption.line([origin.clip.sourceHost, Clipboard.age(of: origin.clip)])
            return DraftView.Card(name: origin.clip.sourceAppName ?? "Clipboard",
                                  icon: origin.clip.sourceBundleID.flatMap(Self.appIcon),
                                  detail: detail)
        }
        panel.show(DraftView(
            buffer: buffer, mode: mode, editor: vim.mode, selection: vim.selection(in: buffer),
            findTargets: vim.pendingFind.map { Vim.findTargets(kind: $0, in: buffer) } ?? [],
            editorMarks: buffer.ghost.isEmpty ? editorMarks : [],
            pending: vim.isPending, speech: speechState, input: inputName, level: level,
            inputs: inputs, systemInput: systemInputName, chosenInput: inputDevice,
            micOn: micWanted, silent: hearsNothing, retrying: retrying, finishing: finishing,
            destination: card == nil ? front.map { ($0.name, $0.icon) } : nil,
            replacing: (origin?.pulled ?? false) && front?.pid == origin?.pid,
            card: card, width: doorWidth, standsAbove: standsAbove, expanded: expanded,
            wet: wetRange, revised: revisedRanges, style: sessionStyle))
    }

    private static func appIcon(_ bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// The destination follows focus; redraw when it moves.
    func focusChanged() {
        guard isOpen else { return }
        render()
    }

    // MARK: - The system

    private static func systemFrontmost() -> Destination? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return Destination(pid: app.processIdentifier,
                           name: app.localizedName ?? "app",
                           bundleID: app.bundleIdentifier, icon: app.icon)
    }

    private static func post(_ key: String, _ flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let code = Keys.codes[key] else { return }
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: false)
        down?.flags = flags
        up?.flags = flags
        // A beat for the pasteboard to settle: some apps read it lazily.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            SystemEvents.post(down, tap: .cgSessionEventTap)
            SystemEvents.post(up, tap: .cgSessionEventTap)
        }
    }

    /// Every AX call here blocks the main thread on the app's event
    /// loop, and the tap lives on that thread: the process-wide timeout
    /// is a second per call, five calls deep here, so the draft's own
    /// elements get a shorter one. A hung app fails the first call and
    /// the rest are never made.
    private static let axTimeout: Float = 0.3

    private static func readFieldAX(pid: pid_t, wholeValue: Bool) -> Field? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axTimeout)
        guard let focused = AX.element(app, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(focused, axTimeout)
        var field = Field()
        field.token = focused
        field.selection = AX.string(focused, kAXSelectedTextAttribute)
        if wholeValue {
            var settable: DarwinBoolean = false
            if AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &settable) == .success,
               settable.boolValue {
                // The length first, where the field reports one: a
                // document's worth of value is refused before it is
                // copied across the process boundary, not after.
                if let length = AX.int(focused, kAXNumberOfCharactersAttribute as String), length > pullCap {
                    field.tooLong = true
                    return field
                }
                field.value = AX.string(focused, kAXValueAttribute)
                // The insertion point, in UTF-16 units the way AX counts,
                // converted to characters the way the buffer counts.
                if let value = field.value, let boxed = AX.copy(focused, kAXSelectedTextRangeAttribute),
                   CFGetTypeID(boxed) == AXValueGetTypeID() {
                    var range = CFRange()
                    if AXValueGetValue(boxed as! AXValue, .cfRange, &range) {
                        let utf16 = (value as NSString)
                        let clamped = max(0, min(range.location, utf16.length))
                        field.cursor = utf16.substring(to: clamped).count
                    }
                }
            }
        }
        return field
    }

    private static let targetQueue = DispatchQueue(label: "com.vaccone.lodestar.draft-target", qos: .userInitiated)

    /// Ask the app what has the focus, off the main thread, and answer on
    /// it. Positive only when the app answered "nothing" and still speaks
    /// Accessibility; an error, a timeout or an app that does not answer
    /// is `.unknown`, and the paste is posted as it always was.
    private static func probeTargetAX(pid: pid_t, done: @escaping (Draft.Target) -> Void) {
        targetQueue.async {
            // A web engine builds its tree only when asked and tears it down
            // when idle, and in between answers "nothing has the focus" with
            // its composer focused: Slack, Brave and Claude would be refused
            // a paste. Its answer is never positive, so it is not asked.
            if let bundle = NSRunningApplication(processIdentifier: pid)?.bundleURL, hostsWebEngine(bundle) {
                DispatchQueue.main.async { done(.unknown) }
                return
            }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, axTimeout)
            var target = Draft.Target.unknown
            var ref: CFTypeRef?
            switch AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &ref) {
            case .success:
                if let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() {
                    let focused = ref as! AXUIElement
                    AXUIElementSetMessagingTimeout(focused, axTimeout)
                    if let role = AX.string(focused, kAXRoleAttribute) {
                        var settable: DarwinBoolean = false
                        let takesValue = AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &settable) == .success
                            && settable.boolValue
                        let hasCaret = AX.copy(focused, kAXSelectedTextRangeAttribute) != nil
                        target = .focus(role: role, text: takesValue || hasCaret)
                    }
                }
            case .noValue:
                if AX.string(app, kAXRoleAttribute) != nil { target = .noFocus }
            default:
                break
            }
            DispatchQueue.main.async { done(target) }
        }
    }

    /// Electron, a Chromium browser or a Gecko one (Firefox, Mullvad):
    /// each keeps its accessibility tree lazily.
    static func hostsWebEngine(_ bundle: URL) -> Bool {
        let frameworks = bundle.appendingPathComponent("Contents/Frameworks")
        if FileManager.default.fileExists(atPath: frameworks.appendingPathComponent("Electron Framework.framework").path)
            || FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/MacOS/XUL").path) {
            return true
        }
        return AXWarmer.isChromiumBrowser(bundle)
    }

    private static func selectAllAX(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axTimeout)
        guard let focused = AX.element(app, kAXFocusedUIElementAttribute) else { return false }
        AXUIElementSetMessagingTimeout(focused, axTimeout)
        guard let value = AX.string(focused, kAXValueAttribute) else { return false }
        var range = CFRange(location: 0, length: (value as NSString).length)
        guard let boxed = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, boxed) == .success
    }
}

/// The microphone grant, read without asking.
enum AVCaptureDevicePermission {
    static var granted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
}
