import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import LodestarCore

/// The draft: `lode .` opens it speaking, `lode ⇧.` opens it editing. It
/// is a bar the way the clipboard strip is a bar — never key, its keys
/// read off the event tap — so the app you were in keeps its cursor and
/// `⏎` is a plain ⌘V into it.
///
/// The destination is live: whatever is frontmost when `⏎` lands, shown
/// on the register line as it changes. Both endings put the text on the
/// pasteboard, so nothing said or typed here is ever lost.
final class DraftController {
    // MARK: Seams

    var flash: ((String) -> Void)?
    var observations: ObservationStore?
    /// The user's vocabulary (`draft.words`), repaired into settled speech.
    var words: [String] = []
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
    /// What `p` pastes: the pasteboard's text.
    var readPasteboard: () -> String?
    /// Settled speech is activity too, for the engine's idle clock.
    var onActivity: (() -> Void)?
    /// The machine's inputs, by name, and the one the system calls
    /// default, delivered on the main thread. Off it in the app: the
    /// enumeration is a CoreAudio roll call, which waits on the HAL while
    /// a Bluetooth radio flips profiles — the moment one draft closes and
    /// the next opens — and the main thread hosts the event tap.
    var enumerateInputs: (@escaping ([String], String?) -> Void) -> Void
    private static let inputQueue = DispatchQueue(label: "com.vaccone.lodestar.draft-inputs",
                                                  qos: .userInitiated)
    /// The user picked an input on the register line; the app writes the
    /// config line (`draft.input`), nil meaning the system default.
    var chooseInput: ((String?) -> Void)?
    /// Music steps aside while the mic is open on a shared Bluetooth
    /// radio; the draft only reports its edges.
    var playback: PlaybackPause?
    /// Where the in-flight words go, half a second behind the hand, and
    /// nil at close: a crash mid-draft then strands at most a moment,
    /// and the next boot returns the rest via the pasteboard.
    var stash: ((String?) -> Void)?
    private var stashWork: DispatchWorkItem?
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

    private let panel = DraftPanel()
    /// The panel's footer fade, exposed for the wiring that owns the
    /// observations.
    var footerDelay: () -> TimeInterval {
        get { panel.footerDelay }
        set { panel.footerDelay = newValue }
    }
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
    private var speechState: SpeechState?
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
    private var closing = false
    private var pendingSettle: (() -> Void)?
    /// The word that runs if the recognizer never says it is listening:
    /// the register line would otherwise say "opening the microphone"
    /// forever, and the hand would talk into nothing. Past this the
    /// session is stopped and named failed, and `lode .` or the mic
    /// glyph starts a fresh one.
    private var listenWatchdog: DispatchWorkItem?
    static let listenWatchdogSeconds: TimeInterval = 8
    /// The landing that runs if the recognizer never says it stopped:
    /// while `closing` stands every key is swallowed, so a stop that
    /// hangs would take the keyboard with it.
    private var landBackstop: DispatchWorkItem?
    /// How long `⏎` waits for the recognizer's last words before landing
    /// what it has. The session's own finalize is bounded at 0.7s; this
    /// is the bound on the bound.
    static let landBackstopSeconds: TimeInterval = 2.0
    /// Words that were still a ghost when insert mode ended were settled
    /// on the spot, as seen; the recognizer's final for them, if it still
    /// comes, replaces exactly that text and nothing else.
    private var provisional: (range: Range<Int>, text: String)?

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
    private var backspaces = 0
    private var modeSwitches = 0
    private var firstKeyAt: Date?
    private var firstWordAt: Date?
    private var wasWarm = false

    /// Pulled or pasted text past this is refused: a draft is a message,
    /// not a document, and the panel lays the whole text out on every
    /// key.
    static let pullCap = 20_000
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
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(text, forType: .string)
        }
        postKey = Self.post
        readField = Self.readFieldAX
        selectAll = Self.selectAllAX
        readPasteboard = { NSPasteboard.general.string(forType: .string) }
        enumerateInputs = { done in
            Self.inputQueue.async {
                let names = AudioInput.inputDevices().map(\.name)
                let system = AudioInput.defaultInputName
                DispatchQueue.main.async { done(names, system) }
            }
        }
        panel.onToggleMic = { [weak self] in self?.toggleMic() }
        panel.onChooseInput = { [weak self] name in self?.selectInput(name) }
        // The destination follows focus; the register line follows it.
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
    var state: [String: Any] {
        var out: [String: Any] = ["open": isOpen]
        guard isOpen else { return out }
        out["text"] = buffer.text
        out["cursor"] = buffer.cursor
        out["ghost"] = buffer.ghost
        out["mode"] = mode == .insert ? "insert" : "normal"
        switch vim.mode {
        case .insert: out["editor"] = "insert"
        case .normal: out["editor"] = "normal"
        case .visual(let line): out["editor"] = line ? "visual-line" : "visual"
        }
        out["listening"] = listening
        out["mic"] = micWanted
        if let inputName { out["input"] = inputName }
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
        buffer = Draft.Buffer()
        vim = Vim()
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
        typedCharacters = 0; spokenWords = 0; backspaces = 0; modeSwitches = 0
        firstKeyAt = nil; firstWordAt = nil

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
        case .edit:
            micWanted = false
        }
        Log.info("draft", ["open": door.rawValue, "pulled": pulled, "whole": whole])
        render()
    }

    /// The door keys inside the bar set posture, idempotently.
    func posture(door: Draft.Door) {
        guard isOpen else { open(door: door); return }
        switch door {
        case .speak:
            micWanted = true
            if !sessionStarted { startListening() }
            if mode != .insert { setMode(.insert) } else { resumeIfWanted() }
        case .edit:
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
        provisional = (start..<buffer.cursor, text)
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

    /// The mic glyph was clicked. Off is off in any mode; on means insert
    /// mode with the mic writing, which is what the speak door means.
    func toggleMic() {
        guard isOpen, !closing else { return }
        if micWanted {
            micWanted = false
            pauseSpeech()
            settleGhostAsSeen()
        } else {
            posture(door: .speak)
            return
        }
        render()
    }

    /// An input was chosen on the register line. The config line is the
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

    /// The inputs, enumerated off the main thread; the register line
    /// redraws when they land.
    private func refreshInputs() {
        enumerateInputs { [weak self] names, system in
            guard let self, self.isOpen else { return }
            self.inputs = names
            self.systemInputName = system
            self.render()
        }
    }

    // MARK: - Speech

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
        speech.listen(words: words, input: inputDevice, onState: { [weak self] state in
            guard let self, self.isOpen, self.session == mine else { return }
            self.speechState = state
            if case .listening(let input) = state {
                self.listening = true
                self.inputName = input
                // The device actually read, when the session named it:
                // a pinned input that fell back gates on what is open.
                self.playback?.dictationBegan(input: input ?? self.inputDevice)
                self.observations?.latency(surface: "draft-listen",
                                           seconds: self.clock.now().timeIntervalSince(self.openedAt))
                if self.mode == .normal || !self.micWanted { self.speech.pause() }
            }
            self.render()
        }, onLevel: { [weak self] level in
            guard let self, self.isOpen, self.session == mine else { return }
            self.level = level
            self.panel.setLevel(level)
        }, onVolatile: { [weak self] text in
            guard let self, self.isOpen, self.session == mine, self.mode == .insert, self.micWanted,
                  // Reserved words await their final; a cumulative volatile
                  // would show them twice. The final revises them in place.
                  self.provisional == nil else { return }
            if self.firstWordAt == nil {
                self.firstWordAt = self.clock.now()
                self.observations?.latency(surface: "draft-first-word",
                                           seconds: self.firstWordAt!.timeIntervalSince(self.openedAt))
            }
            self.buffer.showGhost(text)
            self.onActivity?()
            self.render()
        }, onSettled: { [weak self] text in
            guard let self, self.isOpen, self.session == mine else { return }
            self.settle(text)
            self.pendingSettle?()
            self.pendingSettle = nil
        })
        listenWatchdog?.cancel()
        let watchdog = DispatchWorkItem { [weak self] in
            // Preparing (a model download) reports itself and is not a
            // silence; anything else this long is a session that will
            // never speak — v0.28.0's wedged audio queue looked exactly
            // like this from the register line.
            guard let self, self.isOpen, self.session == mine, !self.listening,
                  self.speechState == nil else { return }
            Log.info("draft", ["speech": "no listening state", "seconds": Int(Self.listenWatchdogSeconds)])
            self.speechState = .failed("the microphone did not start")
            self.speech.stop {}
            self.sessionStarted = false
            self.render()
        }
        listenWatchdog = watchdog
        clock.after(Self.listenWatchdogSeconds, watchdog)
    }

    private func settle(_ text: String) {
        let repaired = Draft.Vocabulary.apply(text, words: words)
        let count = repaired.split(whereSeparator: \.isWhitespace).count
        let writing = mode == .insert && micWanted
        if let standing = provisional, buffer.slice(standing.range) == standing.text {
            // The final for words settled early: it replaces them in place,
            // if they are still there untouched; edited or gone, it is dropped.
            spokenWords += count
            let lead = Draft.separator(after: buffer.characters[..<standing.range.lowerBound], before: repaired)
            let cursor = buffer.cursor
            let replacement = lead + repaired
            buffer.replace(standing.range, with: replacement)
            // The cursor stays where the hand left it: before the range,
            // untouched; after it, moved by the change in length; inside
            // it, at the range's new end.
            let delta = replacement.count - standing.range.count
            if cursor <= standing.range.lowerBound {
                buffer.setCursor(cursor)
            } else if cursor >= standing.range.upperBound {
                buffer.setCursor(cursor + delta)
            } else {
                buffer.setCursor(standing.range.lowerBound + replacement.count)
            }
            if mode == .normal { vim.enterNormal(&buffer) }
            provisional = nil
        } else if writing {
            provisional = nil
            spokenWords += count
            if firstWordAt == nil { firstWordAt = clock.now() }
            onActivity?()
            let before = buffer.count
            buffer.settle(repaired)
            // The editor hears what speech typed, so `.` can say it again.
            vim.typed(buffer.slice(buffer.cursor - (buffer.count - before)..<buffer.cursor))
        } else {
            // Spoken while silent and never shown, or shown and since edited
            // away: it does not write.
            buffer.clearGhost()
            provisional = nil
        }
        render()
    }

    private func pauseSpeech() {
        guard listening else { return }
        speech.pause()
    }

    private func resumeIfWanted() {
        guard listening, micWanted, mode == .insert else { return }
        speech.resume()
    }

    // MARK: - Keys, from the tap

    /// A key while the draft is up and lode is not held. True when the
    /// draft took it; false hands it to the system. ⌘ chords belong to
    /// the system — ⌘⇥ is how the destination changes — except the few
    /// that edit text, which would land in the app underneath and edit
    /// the wrong thing.
    func handleKey(_ key: String, shift: Bool, command: Bool, option: Bool, control: Bool) -> Bool {
        guard isOpen else { return false }
        // While the last words settle, keys are swallowed, not passed on: a
        // held ⏎ would reach the app ahead of the paste and send.
        if closing { return true }
        pasteRefused = false
        if command {
            // In normal mode the chords are the editor's own verbs, so
            // they are one undo step each and `.` knows them.
            if mode == .normal, let keys = Self.normalModeChord(key, shift: shift) {
                for k in keys { _ = vim.key(k, buffer: &buffer, pasteboard: pasteboardForDraft) }
                render()
                return true
            }
            switch key {
            case "delete":
                if mode == .insert { buffer.deleteToLineStart(); backspaces += 1 }
                render(); return true
            case "left":
                buffer.moveLineStart(); render(); return true
            case "right":
                buffer.moveLineEnd(); render(); return true
            case "v":
                if mode == .normal {
                    // Through the editor, so it is one undo step and `.` knows it.
                    let effects = vim.key(.char("p"), buffer: &buffer, pasteboard: pasteboardForDraft)
                    for case .flash(let text) in effects { flashPasteVerdict(text) }
                } else if let text = pasteboardForDraft() {
                    settleGhostAsSeen()
                    buffer.type(text); vim.typed(text); typedCharacters += text.count
                } else if pasteRefused {
                    flashPasteVerdict("")
                }
                render()
                return true
            case "c":
                writePasteboard(buffer.text); flash?("⌂ draft copied"); return true
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
                // Select all: the whole buffer as the editor's selection,
                // which is what d, c, y and ⌘C then act on.
                setMode(.normal)
                for k in [Vim.Key.char("g"), .char("g"), .char("V"), .char("G")] {
                    _ = vim.key(k, buffer: &buffer, pasteboard: pasteboardForDraft)
                }
                render()
                return true
            case "x":
                // Nothing is selected in insert mode; say what would be.
                flash?("nothing selected, ⌘A selects all")
                return true
            default:
                return false
            }
        }
        if firstKeyAt == nil, Keys.character(for: key, shift: shift) != nil { firstKeyAt = clock.now() }
        switch mode {
        case .insert: return insertKey(key, shift: shift, option: option, control: control)
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

    private func insertKey(_ key: String, shift: Bool, option: Bool, control: Bool) -> Bool {
        // Words still a ghost when the hand starts writing become text
        // on the spot, reserved where they stand: dictate, type, dictate
        // lands in the order it happened, and the final that arrives
        // later revises the reserved words in place (`provisional`), not
        // at the cursor. Moves and the commit leave the ghost to its own
        // rules.
        if !buffer.ghost.isEmpty {
            let moves = ["escape", "left", "right", "up", "down"]
            let editingControl = control && ["h", "w", "u", "k"].contains(key)
            let editingKey = !control && !moves.contains(key) && !(key == "return" && !shift)
            if editingControl || editingKey { settleGhostAsSeen() }
        }
        // The control chords every macOS field answers: line ends, a word
        // or a line back, the rest of the line forward.
        if control {
            switch key {
            case "a": buffer.moveLineStart()
            case "e": buffer.moveLineEnd()
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
            setMode(.normal)
        case "return":
            if shift { buffer.newline(); vim.typed("\n"); typedCharacters += 1 } else { commit(); return true }
        case "delete":
            backspaces += 1
            let before = buffer.count
            if option { buffer.deleteWordBackward() } else { buffer.backspace() }
            // The editor hears one backspace per character removed.
            for _ in 0..<(before - buffer.count) { vim.insertBackspace() }
        case "left":
            if option { buffer.moveWordLeft() } else { buffer.moveLeft() }
        case "right":
            if option { buffer.moveWordRight() } else { buffer.moveRight() }
        case "up":
            buffer.moveUp()
        case "down":
            buffer.moveDown()
        case "tab":
            buffer.type("\t"); vim.typed("\t"); typedCharacters += 1
        default:
            guard !control, let typed = Keys.character(for: key, shift: shift) else { return true }
            buffer.type(typed)
            vim.typed(typed)
            typedCharacters += 1
        }
        render()
        return true
    }

    /// Normal and visual mode: the editor decides, the shell keeps the
    /// two keys the bar owns. `⏎` commits in every mode; a bare `esc` —
    /// nothing pending, no selection — closes.
    private func normalKey(_ key: String, shift: Bool, option: Bool, control: Bool) -> Bool {
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
            case .unhandled:
                if vimKey == .escape { cancel(reason: "escape"); return true }
            }
        }
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
        let finish = { [weak self] in self?.land() }
        if sessionStarted, listening, mode == .insert, micWanted {
            // A ghost with no final behind it settles as what it was.
            var landed = false
            pendingSettle = { [weak self] in
                // A final for an earlier segment is not the end: words still
                // volatile settle on the stop, and the paste waits for them.
                guard !landed, self?.buffer.ghost.isEmpty ?? true else { return }
                landed = true
                finish()
            }
            speech.stop { [weak self] in
                guard let self, !landed else { return }
                landed = true
                if !self.buffer.ghost.isEmpty { self.settle(self.buffer.ghost) }
                finish()
            }
            // The recognizer's stop is bounded, but a bound that is never
            // reached — a wedged analyzer, a task that never resumes —
            // would leave `closing` standing and every key swallowed.
            // Past this, the ghost lands as seen and the draft closes.
            let backstop = DispatchWorkItem { [weak self] in
                guard let self, !landed else { return }
                landed = true
                Log.info("draft", ["commit": "landed by backstop", "ghost": !self.buffer.ghost.isEmpty])
                if !self.buffer.ghost.isEmpty { self.settle(self.buffer.ghost) }
                finish()
            }
            landBackstop = backstop
            clock.after(Self.landBackstopSeconds, backstop)
        } else {
            if sessionStarted { speech.stop {} }
            finish()
        }
    }

    private func land() {
        guard isOpen else { return }
        let text = buffer.text
        let destination = frontmost()
        let ending = Draft.ending(
            hasDestination: destination != nil,
            destinationIsOrigin: destination?.pid == origin?.pid,
            pulledFromOrigin: origin?.pulled ?? false)
        var action = "empty"
        var row: String? = nil
        if !text.isEmpty {
            writePasteboard(text)
            // Nothing may be selected or posted into a field that blocks
            // synthetic input; the text is on the pasteboard, and that is
            // the whole ending.
            let secure = ending != .clipboard && IsSecureEventInputEnabled()
            switch ending {
            case .clipboard:
                flash?("⌂ copied, nothing to paste into")
                action = "copied"; row = "clipboard"
            case _ where secure:
                flash?("press ⌘V to paste, this field blocks synthetic input")
                action = "copied"; row = "secure"
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
    }

    private func paste() {
        postKey("v", .maskCommand)
    }

    /// Anything but `⏎`: the text stays on the pasteboard, the draft
    /// goes away. `reason` is for the log and the record only.
    func cancel(reason: String) {
        guard isOpen, !closing else { return }
        closing = true
        if sessionStarted { speech.stop {} }
        let text = buffer.text + (buffer.ghost.isEmpty ? "" : Draft.separator(after: buffer.characters, before: buffer.ghost) + buffer.ghost)
        let destination = frontmost()
        if !text.isEmpty {
            writePasteboard(text)
            if reason == "escape" { flash?("⌂ draft kept in the clipboard") }
        }
        close()
        record(action: text.isEmpty ? "empty" : "cancelled", row: reason, destination: destination)
    }

    private func close() {
        isOpen = false
        landBackstop?.cancel()
        landBackstop = nil
        listenWatchdog?.cancel()
        listenWatchdog = nil
        stashWork?.cancel()
        stashWork = nil
        stash?(nil)
        playback?.dictationEnded()
        listening = false
        sessionStarted = false
        inputName = nil
        level = 0
        provisional = nil
        session += 1
        pendingSettle = nil
        panel.hide()
    }

    private func record(action: String, row: String?, destination: Destination?) {
        let now = clock.now()
        observations?.drafted(
            app: destination?.name ?? "clipboard", door: door.rawValue, action: action, row: row,
            seconds: now.timeIntervalSince(openedAt), typed: typedCharacters, words: spokenWords,
            backspaces: backspaces, switches: modeSwitches,
            firstKey: firstKeyAt.map { $0.timeIntervalSince(openedAt) },
            firstWord: firstWordAt.map { $0.timeIntervalSince(openedAt) },
            warm: wasWarm, at: now)
        Log.info("draft", ["end": action, "words": spokenWords, "typed": typedCharacters,
                           "seconds": Int(now.timeIntervalSince(openedAt))])
    }

    // MARK: - Drawing

    private func render() {
        guard isOpen else { return }
        if stash != nil {
            stashWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isOpen else { return }
                let ghost = self.buffer.ghost
                self.stash?(self.buffer.text + (ghost.isEmpty ? "" : " " + ghost))
            }
            stashWork = work
            clock.after(0.5, work)
        }
        let front = frontmost()
        panel.show(DraftView(
            buffer: buffer, mode: mode, editor: vim.mode, selection: vim.selection(in: buffer),
            findTargets: vim.pendingFind.map { Vim.findTargets(kind: $0, in: buffer) } ?? [],
            pending: vim.isPending, speech: speechState, input: inputName, level: level,
            inputs: inputs, systemInput: systemInputName, chosenInput: inputDevice,
            micOn: micWanted,
            destination: front.map { ($0.name, $0.icon) },
            replacing: (origin?.pulled ?? false) && front?.pid == origin?.pid))
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
            down?.post(tap: .cgSessionEventTap)
            up?.post(tap: .cgSessionEventTap)
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
