import AppKit
import LodestarCore

/// One machine, two doors. Text addressed by its own content: type a few
/// characters of what you can see; matches highlight and wear capital
/// chips; a capital picks. At the `/` door a pick anchors — the start lit
/// as a whole word, which ⌘C alone will take, a second search and capital
/// for the far end. At the `;` door a pick clicks (⌃⇧ right-clicks), the
/// tree-named pressables wear chips before any typing, and the mouse's
/// last territory is annexed by reading. The entry key declares the verb,
/// the way ⇧ declares beside; everything below the verb is shared.
///
/// The mode always ends the same way: **the span is highlighted, and the
/// next verb is yours.** Text whose selection is settable gets a real
/// `AXSelectedTextRange` — the app's own highlight, so copy, replace, and
/// delete all work natively. Read-only text gets a highlight Lodestar
/// itself holds after the mode ends: ⌘C copies the span (served from the
/// harvested text), and any other key, click, or escape dissolves it.
/// One outcome, one ⌘C that always works, no flashes.
///
/// Fragmented text — a paragraph shattered across dozens of static-text
/// leaves, which is how web and Electron views render prose — is stitched
/// into runs (`SelectRuns`) before matching, so phrases match across
/// styling boundaries and a span may cross fragments; its highlight is
/// then several honest rectangles. A span may also cross whole runs, in
/// reading order and down the column its two ends share, which is what
/// lets it run down a page whose every line is its own run without
/// taking the sidebar beside it: the pieces it covers are gathered into
/// one copy and one highlight, so what lights up is exactly what ⌘C serves.
final class SelectController {
    /// One searchable unit: an editable element standing alone, or a run
    /// of stitched read-only fragments.
    private struct Unit {
        /// Where this unit's rectangles come from.
        enum Geometry {
            /// Per-range `AXBoundsForRange` on each fragment's leaf.
            case ax
            /// Proportional interpolation inside the element frame — an
            /// editable field whose geometry API does not answer.
            case interpolated(CGRect)
            /// Line arithmetic inside the element frame — a terminal grid
            /// whose text is readable but placeless. Rows are honest;
            /// columns would be a guess, so highlights are whole lines.
            case lines(CGRect)
            /// The pixel sensor: character-precise rectangles straight
            /// from the recognizer, identical in every kind of window.
            case ocr
        }

        let run: SelectRuns.Run
        /// AX handle per leaf id referenced by the run's fragments.
        let leaves: [Int: AXUIElement]
        /// Recognized line per leaf id, when this unit was sensed from
        /// pixels.
        let ocrLines: [Int: OCRSense.Line]
        /// Settable single element, when this unit is one editable field.
        let editable: AXUIElement?
        let geometry: Geometry
        /// Everything this unit covers on screen, which is how the units
        /// are put in reading order — and reading order is what a span
        /// across them means by "everything in between".
        let frame: CGRect
    }

    /// Top to bottom, then left to right: the order the eye reads in, and
    /// the order a span crossing units walks.
    private static func readingOrder(_ a: Unit, _ b: Unit) -> Bool {
        let dy = a.frame.minY - b.frame.minY
        if abs(dy) > SelectRuns.lineTolerance { return dy < 0 }
        return a.frame.minX < b.frame.minX
    }

    private let model: WindowModel
    private let overlay = SelectOverlay()

    /// Chip alphabet, shared with hints — one set of label letters to own.
    var letters = "asdfghjkl"
    var flash: (String) -> Void = { _ in }
    var observations: ObservationStore?

    private var core: SelectCore?
    private var units: [Unit] = []
    private var generation = 0
    private var boundsGeneration = 0
    private var lastPassLeaves = -1
    /// Pixels answered: accessibility passes stop adopting and serve only
    /// as grounding for commits.
    private var ocrAdopted = false
    /// Which sense the standing core was built from — `ax`, `ocr-fast`,
    /// `ocr` — so an auto-fire's log line says what world it trusted.
    private var world = "none"
    /// The one polite ask per session, when the permission is absent.
    private var screenAccessPrompted = false
    private var focusedPid: pid_t = 0
    /// The accessibility walk's reading, prepared: the ground truth
    /// pixel-sensed copies are repaired against. Built by the harvest, on
    /// the harvest's thread, so committing costs a search and not a
    /// normalization of everything on screen.
    private var grounding = OCRSense.Grounding([])
    /// The mode's own observation: when it began, what it cost, how it
    /// ended. Counts and timings — the text is never anyone's.
    private var modeEnteredAt = Date.distantPast
    private var typedInMode = 0
    private var committedOutcome: String?
    /// Whether the pointer rested on the display that was read. Pixels
    /// are captured for the whole display the focused window is on; the
    /// active display for every other verb is the one under the pointer.
    /// The split between abandons with the pointer on and off it is the
    /// measurement that decides whether select should read the display
    /// under the pointer instead.
    private var pointerOnWindow: Bool?
    /// The captured frame, kept for the mode's life so a span can be
    /// read a second time before it leaves the clipboard.
    private var frozen: CGImage?
    /// The focused window's frame at entry: the drag-and-copy presses
    /// only inside it, because a press in a neighbor would move focus
    /// there, and a copy must never change where the hand is.
    private var focusedFrame = CGRect.zero
    /// What the grounding said about the last gathered span, for the log.
    private var groundingNote = ""
    /// One per verified copy, so a verdict arriving after the next mode
    /// entry lands nowhere.
    private var copyGeneration = 0
    /// Stamped on every event of Lodestar's own drag-and-copy, so the tap
    /// passes them to the app untouched: the ghost's ⌘C would otherwise
    /// take the synthetic ⌘C as the hand's.
    static let ownMark: Int64 = 0x4C4F_4445
    /// select.copy-on-complete: a completed span serves the pasteboard at
    /// the grammar's full stop, every ending alike. The config line is the
    /// arbiter — the mode never reads the situation, which is what buried
    /// the first auto-copy.
    var copyOnComplete = false
    /// select.commit-on-unique: a search narrowed to one match picks it
    /// without the capital. Anchor door only — at the click door a pick is
    /// a click, and an action must never fire itself on uniqueness.
    var commitOnUnique = false
    /// The end word's unclaimed tail behind a span that completed itself.
    /// The mode is over, but the hand may still be finishing the word it
    /// planned — those letters are confirmation, absorbed here so they
    /// cannot land in the app beneath the highlight. The first letter
    /// that is not the word's next one flows through untouched.
    private var ghostContinuation: SelectCore.Continuation?

    /// Which door the mode was entered through: `lode /` anchors on a
    /// pick, `lode ;` clicks on one. Same sensor, same grammar — the
    /// entry key declares the verb, the way ⇧ declares beside.
    enum Door { case anchor, click }
    private(set) var door: Door = .anchor
    private var sticky = false
    /// The `;` door's entry chips: pressables the accessibility tree
    /// could name, pickable by capitals before any typing — a dialog's
    /// three buttons answer the instant the tree does, even while OCR is
    /// still reading. They yield the glass the moment aiming starts and
    /// return if the query empties; the elements stay behind for the
    /// commit layer, which prefers an app's own press to a synthetic
    /// click.
    private var entryTargets: [HintTargets.Target] = []
    private var entryLabels: [String] = []
    private var entryTyped = ""
    /// How many chips greeted the entry, and how long the hands waited
    /// before the first key — the two numbers the entry-chips verdict
    /// rests on, recorded per session.
    private var entryChipsAtEntry = 0
    private var firstKeyAt: Date?
    /// Aiming typed inside the sensor's first beats, held for the first
    /// world instead of dropped — the hands may start the moment the mode
    /// key lands. Lowercase only: a capital typed before any chips exist
    /// had nothing to pick and stays the no-op it always was.
    private var pendingKeys: [(key: String, shift: Bool)] = []
    private var lastMatchCount = 0
    private var windowFrame: CGRect = .zero
    private var appName = ""

    /// The held highlight that outlives the mode on read-only text.
    private var ghost: (text: String, rects: [CGRect])?
    private var ghostClickMonitor: Any?

    private static let textRoles: Set<String> = [
        "AXTextArea", "AXTextField", "AXStaticText", "AXWebArea",
        "AXComboBox", "AXSearchField",
    ]
    /// Containers that never hold visible text and are expensive to walk.
    private static let skipRoles: Set<String> = [
        "AXMenuBar", "AXToolbar", "AXScrollBar",
    ]

    init(model: WindowModel) {
        self.model = model
    }

    // MARK: - Lifecycle

    func enter(door: Door = .anchor, sticky: Bool = false) -> Bool {
        guard let window = model.focusedWindow, window.isAlive else { return false }
        self.door = door
        self.sticky = sticky
        entryTargets = []
        entryLabels = []
        entryTyped = ""
        entryChipsAtEntry = 0
        firstKeyAt = nil
        pendingKeys = []
        dissolveGhost()
        core = nil
        units = []
        windowFrame = window.frame
        focusedFrame = window.frame
        appName = window.appName
        let mouse = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let read = Displays.display(containing: window.frame)?.bounds ?? window.frame
        pointerOnWindow = read.contains(CGPoint(x: mouse.x, y: primaryHeight - mouse.y))
        generation += 1
        copyGeneration += 1
        frozen = nil
        lastPassLeaves = -1
        ocrAdopted = false
        world = "none"
        focusedPid = window.pid
        modeEnteredAt = Date()
        capturedAt = nil
        typedInMode = 0
        committedOutcome = nil
        observations?.verbUsed(door == .click ? "hints" : "select")
        if door == .click {
            let expected = generation
            HintTargets.harvest(
                window: window,
                capacity: HintLabels.capacity(alphabet: letters)
            ) { [weak self] found in
                guard let self, self.generation == expected, self.door == .click else { return }
                self.entryTargets = found
                self.entryLabels = HintLabels.labels(count: found.count, alphabet: self.letters)
                // Counted only while the hands have not yet moved: chips
                // arriving after the first key never greeted anyone.
                if self.firstKeyAt == nil { self.entryChipsAtEntry = found.count }
                self.renderEntry()
            }
        }

        // Everything above is bookkeeping in memory and stays here, because
        // the keys that follow read it: `key` refuses to act while `core` is
        // nil, and that has to be true the instant the mode is entered.
        //
        // Everything below talks to the focused app and to the window
        // server, and this runs inside the event tap. Warming is an
        // accessibility write into an app that may be wedged; the capture is
        // a full-display composite bounded only by the compositor. Until
        // they return, every key on the machine is waiting — and the mode's
        // answer does not depend on either of them, because there is a
        // focused window and that is the whole question.
        let expected = generation
        OffTap.run { [weak self] in
            guard let self, self.generation == expected else { return }
            AXWarmer.warm(window.pid)
            // The scope is the whole active display: pixels do not care which
            // window has focus, and neither do the eyes — a reference window
            // beside the one being typed in is equally selectable. The
            // display's composited image also contains only what is visible,
            // so a chip can never label text hidden behind another window.
            let display = Displays.display(containing: window.frame)?.bounds ?? window.frame
            // Pixels are the primary sensor — identical in every kind of
            // window — with the accessibility walk running alongside for
            // grounding and as the no-permission fallback. The capture happens
            // before any overlay exists: our own scanning band, captured,
            // would become matchable text.
            var captured: CGImage?
            var stack: [CGRect] = []
            if CGPreflightScreenCaptureAccess() {
                captured = CGWindowListCreateImage(display, .optionOnScreenOnly,
                                                   kCGNullWindowID, [.bestResolution])
                // The same instant as the frame: which window owns each
                // pixel of it, so a line is stitched only with lines of
                // its own window.
                stack = Self.windowStack()
            } else if !self.screenAccessPrompted {
                self.screenAccessPrompted = true
                DispatchQueue.global(qos: .utility).async { CGRequestScreenCaptureAccess() }
                self.flash("⌖ grant Screen Recording to select in every window · using accessibility for now")
            }
            if captured != nil { self.windowFrame = display }
            self.frozen = captured
            self.overlay.showScanning(over: self.windowFrame, appName: window.appName,
                                      mode: self.door == .click ? "click" : "select")
            if let captured {
                self.senseOCR(image: captured, frame: display, windows: stack,
                              generation: expected)
            }
            self.harvest(window: window, generation: expected, attempt: 1)
        }
        return true
    }

    func exit() {
        generation += 1
        boundsGeneration += 1
        core = nil
        // The ghost outlives the mode by design — exit runs a beat AFTER a
        // committing pick (the engine's exitSelect follows the .done), so
        // hiding unconditionally here wiped the highlight the commit had
        // just painted. The overlay is the ghost's canvas: it stays up
        // exactly as long as the ghost stands.
        if ghost == nil { overlay.hide() }
        // A harvest is up to 600 units, each carrying its OCR-recognized
        // lines; none of it means anything once the mode is over, and
        // holding it is pure resident-set for an app that lives for weeks.
        // The grounding goes with them: kept, it would stand in for the
        // NEXT session's truth until that window's own harvest lands, and
        // a commit in those first beats would be "repaired" against
        // whatever window the mode last visited.
        units = []
        frozen = nil
        grounding = OCRSense.Grounding([])
        entryTargets = []
        entryLabels = []
        entryTyped = ""
        if modeEnteredAt != .distantPast {
            observations?.selected(
                app: appName, action: committedOutcome == nil ? "abandoned" : "completed",
                source: ocrAdopted ? "ocr" : "ax", outcome: committedOutcome,
                typed: typedInMode, seconds: Date().timeIntervalSince(modeEnteredAt),
                matches: lastMatchCount,
                firstKey: firstKeyAt.map { $0.timeIntervalSince(modeEnteredAt) },
                entryChips: door == .click ? entryChipsAtEntry : nil,
                pointerOn: pointerOnWindow)
            modeEnteredAt = .distantPast
        }
    }

    /// The keys the hands typed before the first world existed, fed
    /// straight into the query the moment it does. Straight in, not
    /// through `key()`: buffered keys are aiming by construction —
    /// capitals were never buffered — and routing them through the
    /// entry-chip gate would let them finish a label pick begun *after*
    /// they were typed, firing a click the engine never hears about.
    /// Later worlds carry their query via seed and find this empty.
    private func replayPendingKeys() {
        guard !pendingKeys.isEmpty else { return }
        let queued = pendingKeys
        pendingKeys = []
        guard core != nil else { return }
        for entry in queued {
            // Auto-anchor stays off through the replay: these keys were
            // typed against a screen the sensor had not finished reading,
            // and a match unique in a partial world is not a pick.
            if case .updated = core!.key(entry.key, shift: false, allowAutoAnchor: false) {
                typedInMode += 1
            }
        }
        lastMatchCount = core!.totalMatches
    }

    func backspace() {
        if door == .click, !entryTyped.isEmpty {
            entryTyped.removeLast()
            renderEntry()
            return
        }
        guard core != nil else {
            _ = pendingKeys.popLast() // walk the buffered aim back too
            return
        }
        _ = core?.backspace()
        render()
    }

    func key(_ key: String, shift: Bool) -> SelectStep {
        if firstKeyAt == nil { firstKeyAt = Date() }
        // The `;` door's entry chips answer before the sensor does: a
        // capital while nothing is typed picks among the pressables the
        // tree named, even if OCR is still reading.
        if door == .click, core?.query.isEmpty != false, !entryTargets.isEmpty,
           key.count == 1, key.first?.isLetter == true,
           shift || !entryTyped.isEmpty {
            return entryPick(letter: key)
        }
        guard core != nil else {
            // Still scanning: aiming is buffered for the first world, not
            // dropped. Only keys that can become query characters get a
            // slot — a held arrow would otherwise hoard the cap with
            // entries the replay must reject — and the cap keeps a
            // runaway letter repeat from hoarding memory.
            if !shift, pendingKeys.count < 32, SelectCore.isSearchKey(key) {
                pendingKeys.append((key: key, shift: shift))
            }
            return .pending
        }
        let labelUnderway = !core!.typedLabel.isEmpty
        let queryBefore = (core!.query as NSString).length
        let effect = core!.key(key, shift: shift)
        // Every aiming key counts, including the one uniqueness turned into
        // a pick: it used to count `.updated` alone, so a session that went
        // wrong on two keys read as a session with no typing at all. A
        // plain letter finishing a capital's label is a pick, not aiming.
        if !shift, !labelUnderway {
            switch effect {
            case .updated:
                typedInMode += 1
            case .anchored:
                typedInMode += 1
                Log.info("select", ["auto": "anchor", "query": queryBefore + 1, "world": world])
            case .selected:
                typedInMode += 1
                Log.info("select", ["auto": "span", "query": queryBefore + 1, "world": world])
            case .none:
                break
            }
        }
        lastMatchCount = core!.totalMatches
        switch effect {
        case .selected(let pieces):
            // A span that completed itself may have been committed
            // mid-word; the end word's tail is absorbed while the
            // highlight stands, so it cannot type into the app beneath.
            ghostContinuation = core?.lastAutoContinuation
            commit(pieces: pieces)
            return .done
        case .anchored:
            // The click door fires on the first pick: the anchor is
            // already snapped to its whole word, so the capital names a
            // word and the click lands on it. No second stage exists
            // behind this door.
            if door == .click, let anchor = core!.anchor {
                performClick(on: anchor)
                return .done
            }
            render()
            return .pending
        case .updated:
            render()
            return .pending
        case .none:
            return .pending
        }
    }

    // MARK: - The click door

    /// The engine's hints grammar feeds here at the `;` door — same keys,
    /// same core, the step vocabulary translated at the seam. Control is
    /// the system's own word for a secondary click, and it is read only
    /// from the keystroke that completes a pick — on a two-letter label,
    /// the last key decides, so the button can be chosen as late as the
    /// final letter.
    func clickKey(_ letter: String, shift: Bool, control: Bool) -> HintStep {
        controlAtPick = control
        firedTextInput = false
        defer { controlAtPick = false }
        switch key(letter, shift: shift) {
        case .done: return firedTextInput ? .firedFocus : .fired
        case .pending: return .pending
        }
    }

    /// True only for the synchronous span of the keystroke being handled.
    private var controlAtPick = false
    /// The fire just focused a text input — the engine ends the mode even
    /// in sticky, because the next keystrokes belong in the field. Known
    /// synchronously for entry picks and for OCR-geometry picks (whose
    /// rects are pure arithmetic); an AX-geometry pick resolves its owner
    /// off the tap and simply keeps today's sticky behavior.
    private var firedTextInput = false

    private func entryPick(letter: String) -> SelectStep {
        let candidate = entryTyped + letter.lowercased()
        switch HintLabels.match(typed: candidate, labels: entryLabels) {
        case .exact(let index):
            let target = entryTargets[index]
            let rightClick = controlAtPick
            firedTextInput = target.isTextInput && !rightClick
            entryTyped = ""
            committedOutcome = "entry"
            Log.info("select", ["outcome": "entry-fired", "right": rightClick])
            OffTap.run { HintTargets.fire(target, rightClick: rightClick) }
            return .done
        case .partial:
            entryTyped = candidate
            renderEntry()
            return .pending
        case .none:
            entryTyped = ""
            return .pending
        }
    }

    /// The entry chips, filtered by any capital prefix underway. Shown
    /// only while the query is empty: the moment aiming starts, the
    /// search universe owns the glass, and it owns it again the moment
    /// the query walks back to nothing.
    private func renderEntry() {
        guard door == .click, core?.query.isEmpty != false else { return }
        let chips: [SelectOverlay.Chip] = zip(entryLabels, entryTargets).compactMap {
            label, target in
            guard entryTyped.isEmpty || label.hasPrefix(entryTyped) else { return nil }
            return SelectOverlay.Chip(label: label, frames: [target.frame],
                                      style: .target)
        }
        let state = SelectOverlay.State(
            appName: appName, query: "", typedLabel: entryTyped,
            shown: chips.count, total: entryTargets.count, capped: false,
            stage: .start, scanning: false, verb: "clicks · ⌃⇧ right-clicks")
        overlay.show(chips: chips, anchor: [], over: windowFrame, state: state)
    }

    /// The three-layer commit: the picked word supplies the point, an AX
    /// pressable that owns the point supplies the press, and a synthetic
    /// click is the honest floor. The press always runs off the tap; so
    /// does geometry for anything AX-backed. Only the OCR branch may
    /// resolve on the tap — it is arithmetic over recognizer data, no AX
    /// anywhere — and that carve-out is load-bearing: it is what lets a
    /// text-input fire end a sticky mode before the typing arrives.
    private func performClick(on match: SelectCore.Match) {
        guard units.indices.contains(match.element) else { return }
        let unit = units[match.element]
        let range = match.range
        let owners = entryTargets
        let rightClick = controlAtPick
        committedOutcome = "clicked"
        // OCR rects are pure arithmetic, so an OCR-geometry pick can know
        // its owner before returning — which is what lets a text-input
        // fire end even a sticky mode in time to receive the typing.
        var resolvedPoint: CGPoint?
        if case .ocr = unit.geometry,
           let rect = boundsRects(unit: unit, range: range).first {
            let point = CGPoint(x: rect.midX, y: rect.midY)
            resolvedPoint = point
            let owner = owners.first { $0.frame.contains(point) }
            firedTextInput = (owner?.isTextInput ?? false) && !rightClick
        }
        Log.info("select", ["outcome": "clicked", "chars": range.length,
                            "right": rightClick])
        OffTap.run { [weak self] in
            guard let self else { return }
            let point: CGPoint
            if let resolvedPoint {
                point = resolvedPoint
            } else if let rect = self.boundsRects(unit: unit, range: range).first {
                point = CGPoint(x: rect.midX, y: rect.midY)
            } else {
                return
            }
            if let owner = owners.first(where: { $0.frame.contains(point) }) {
                HintTargets.fire(owner, rightClick: rightClick)
            } else {
                Self.click(at: point, right: rightClick)
            }
        }
    }

    private static func click(at point: CGPoint, right: Bool) {
        Pointer.post(SyntheticPointer.click(at: point, right: right))
    }

    /// Sticky `lode ⇧;` after a fire: the app may have changed — a beat,
    /// then the whole capture again, entry chips and all.
    func rescanClick() {
        let expected = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.generation == expected else { return }
            _ = self.enter(door: .click, sticky: true)
        }
    }

    // MARK: - The ghost highlight

    /// Every system keyDown passes through here first while a held
    /// highlight exists. Plain ⌘C copies the span and dissolves — served
    /// by Lodestar, because read-only text has no selection for the app
    /// to serve. Escape dissolves. Anything else dissolves and proceeds.
    /// Returns whether the key was consumed. First line is the fast path:
    /// this runs for every keystroke on the machine.
    func ghostHandleKey(key: String, held: Bool, flags: CGEventFlags) -> Bool {
        // The end word's tail first, ghost or no ghost — a native
        // selection holds no ghost, and there the stray letters would
        // replace the selected text itself. A chord, a held key, or a
        // capital is intent and ends the absorption on the spot.
        if ghostContinuation != nil {
            let chord = flags.contains(.maskCommand) || flags.contains(.maskControl)
                || flags.contains(.maskAlternate)
            let shifted = flags.contains(.maskShift)
            if !held, !chord, let character = SelectCore.searchCharacter(for: key) {
                if !shifted, ghostContinuation!.consume(character) {
                    if ghostContinuation!.exhausted { ghostContinuation = nil }
                    return true
                }
                // A capital while the tail is still pending is the pick
                // the hand had planned before uniqueness made it. Passed
                // through, it replaced the native selection the span had
                // just made, or typed into the page beneath the highlight.
                // Swallowed once; the absorption ends with it.
                if shifted, key.count == 1, key.first?.isLetter == true,
                   ghostContinuation!.consumePlannedPick() {
                    ghostContinuation = nil
                    Log.info("select", ["auto": "planned-pick", "swallowed": true])
                    return true
                }
            }
            ghostContinuation = nil
        }
        guard let ghost else { return false }
        if held {
            dissolveGhost()
            return false
        }
        let plainCommand = flags.contains(.maskCommand)
            && !flags.contains(.maskAlternate) && !flags.contains(.maskControl)
            && !flags.contains(.maskShift)
        if key == "c", plainCommand {
            Log.info("select", ["outcome": "ghost-copied", "chars": (ghost.text as NSString).length])
            let span = (text: ghost.text, rects: ghost.rects)
            dissolveGhost()
            serveVerified(span)
            return true
        }
        if key == "escape" {
            dissolveGhost()
            return true
        }
        dissolveGhost()
        return false
    }

    private func holdGhost(text: String, rects: [CGRect], note: String? = nil) {
        ghost = (text, rects)
        overlay.hold(spans: rects, over: windowFrame, note: note)
        guard ghostClickMonitor == nil else { return }
        ghostClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            // Lodestar's own drag-and-copy presses too; the highlight it
            // is verifying must not dissolve under it.
            guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Self.ownMark else { return }
            DispatchQueue.main.async { self?.dissolveGhost() }
        }
    }

    private func dissolveGhost() {
        // The tail dies with the highlight it was protecting. It is NOT
        // cleared in exit(): like the ghost, it outlives the mode by
        // design — exit runs a beat after the committing pick.
        ghostContinuation = nil
        if let monitor = ghostClickMonitor { NSEvent.removeMonitor(monitor) }
        ghostClickMonitor = nil
        guard ghost != nil else { return }
        ghost = nil
        overlay.hide()
    }

    // MARK: - Committing

    /// What a span reads as and where it lies: one piece per unit it
    /// covers, gathered in the order the core placed them. Pieces join
    /// with newlines — the same joiner stitching already puts between the
    /// lines of one run — so a copy taken across four runs pastes as the
    /// four lines it looked like.
    private func gather(_ pieces: [SelectCore.Match]) -> (text: String, rects: [CGRect]) {
        var parts: [String] = []
        var rects: [CGRect] = []
        var confirmed = 0, repaired = 0, declined = 0, axRead = 0
        for piece in pieces {
            guard units.indices.contains(piece.element) else { continue }
            let unit = units[piece.element]
            var text = (unit.run.text as NSString).substring(with: piece.range)
            // Pixel-sensed text is repaired against the accessibility walk
            // piece by piece: recognition's rare single-glyph confusions
            // must never reach a pasteboard when the truth was readable.
            if case .ocr = unit.geometry {
                if let truth = grounding.repair(text) {
                    if truth == text { confirmed += 1 } else { repaired += 1 }
                    text = truth
                } else {
                    declined += 1
                }
            } else {
                axRead += 1
            }
            parts.append(text)
            rects.append(contentsOf: boundsRects(unit: unit, range: piece.range))
        }
        groundingNote = "confirmed=\(confirmed) repaired=\(repaired) declined=\(declined) ax=\(axRead)"
        return (parts.joined(separator: "\n"), rects)
    }

    private func commit(pieces: [SelectCore.Match]) {
        guard pieces.count == 1, let only = pieces.first,
              units.indices.contains(only.element) else {
            return commitAcross(pieces)
        }
        let unit = units[only.element]
        if let editable = unit.editable {
            // A real selection: the app's own highlight, and every verb
            // the app knows — copy, replace, delete — from muscle memory.
            AX.set(editable, kAXFocusedAttribute, to: true)
            var cfRange = CFRange(location: only.range.location, length: only.range.length)
            if let value = AXValueCreate(.cfRange, &cfRange) {
                let error = AXUIElementSetAttributeValue(
                    editable, kAXSelectedTextRangeAttribute as CFString, value)
                if error != .success {
                    flash("✕ the app refused the selection")
                }
            }
            Log.info("select", ["outcome": "selected", "chars": only.range.length])
            committedOutcome = "native"
            // One rule across every ending: the native selection still
            // stands for cut and retype; the copy just arrived early.
            if copyOnComplete { serve(gather(pieces).text) }
            return
        }
        // Read-only, or sensed from pixels. First, grounding: if the
        // focused element is editable and holds this exact text, the span
        // becomes a real native selection — the pixel sensor found it, the
        // accessibility truth commits it, and every editor verb works.
        let span = gather(pieces)
        if case .ocr = unit.geometry, commitToFocusedEditable(span.text) {
            Log.info("select", ["outcome": "grounded-selected", "chars": only.range.length])
            committedOutcome = "grounded"
            if copyOnComplete { serve(span.text) }
            return
        }
        hold(span, pieces: 1)
    }

    /// A span that crosses units. No app can be asked to select across its
    /// own element boundaries, so this ending is always the held
    /// highlight — one rectangle per piece, one copy behind them all.
    private func commitAcross(_ pieces: [SelectCore.Match]) {
        guard !pieces.isEmpty else { return }
        hold(gather(pieces), pieces: pieces.count)
    }

    private func hold(_ span: (text: String, rects: [CGRect]), pieces: Int) {
        guard !span.rects.isEmpty else {
            flash("✕ that text lost its place on screen")
            return
        }
        Log.info("select", ["outcome": "held",
                            "chars": (span.text as NSString).length, "pieces": pieces,
                            "grounding": groundingNote])
        committedOutcome = "held"
        // The receipt rides the band, quiet and in place: a copy is an
        // invisible state change, and the highlight alone does not say it
        // happened.
        holdGhost(text: span.text, rects: span.rects,
                  note: copyOnComplete ? "⌖ copied" : nil)
        if copyOnComplete { serveVerified(span) }
    }

    // MARK: - The verified copy

    /// The pasteboard write for a pixel-sensed span, made deliberate.
    ///
    /// The pixels are served at once, so a ⌘V is never early. Then two
    /// second readings correct them. The app is asked to select the
    /// same span by a synthetic drag and to copy it; when its text agrees
    /// with the pixels up to the confusable glyphs, the app's copy is the
    /// truth, and the mode ends natively — the app's own highlight the
    /// ending, Lodestar's dissolved. And the span is read again from the
    /// frozen frame, cropped and upscaled with the recognizer's
    /// alternatives consulted, which serves when the app could not. The
    /// drag never lands on a control: a press on a button is a press,
    /// so both ends are checked by role first. Aiming stays fast and
    /// stays pixels; only what leaves the clipboard is read twice.
    private func serveVerified(_ span: (text: String, rects: [CGRect])) {
        let pixel = span.text
        serve(pixel)
        copyGeneration += 1
        let token = copyGeneration
        let began = Date()
        let attempt = VerifiedCopy(pixel: pixel)

        // The second reading, off the main thread, structure-preserving:
        // it may fix glyphs and never line breaks, so the promise the
        // highlight made is the text that lands.
        if let frame = frozen {
            let rects = span.rects, frameRect = windowFrame
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let lines = rects.compactMap { OCRSense.reread(image: frame, rect: $0, windowFrame: frameRect) }
                let text = lines.joined(separator: "\n")
                // Glyphs may change; the shape may not. The reading is
                // laid over the pixels' own spacing, and refused when it
                // does not fit glyph for glyph or does not agree.
                let laid = lines.isEmpty ? nil : OCRSense.overlay(reading: text, onto: pixel)
                let usable = laid.map { OCRSense.agrees(pixel, $0) } ?? false
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.copyGeneration == token else { return }
                    attempt.reread = usable ? laid : nil
                    attempt.rereadDone = true
                    self.settleCopy(attempt, token: token, began: began)
                }
            }
        } else {
            attempt.rereadDone = true
        }

        guard dragSelect(span.rects) else {
            attempt.appDone = true
            attempt.appText = nil
            settleCopy(attempt, token: token, began: began)
            return
        }
        let before = NSPasteboard.general.changeCount
        // ⌘C once the app has taken the mouse-up, then a short watch for
        // the pasteboard to move.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self] in
            guard let self, self.copyGeneration == token else { return }
            Self.postCopy()
            self.awaitAppCopy(attempt, token: token, before: before, polls: 0, began: began)
        }
    }

    private final class VerifiedCopy {
        let pixel: String
        var reread: String?
        var rereadDone = false
        var appText: String?
        var appDone = false
        var settled = false
        init(pixel: String) { self.pixel = pixel }
    }

    private func awaitAppCopy(_ attempt: VerifiedCopy, token: Int, before: Int, polls: Int, began: Date) {
        guard copyGeneration == token else { return }
        let board = NSPasteboard.general
        if board.changeCount != before {
            attempt.appText = board.string(forType: .string)
            attempt.appDone = true
            settleCopy(attempt, token: token, began: began)
            return
        }
        guard polls < 8 else {
            attempt.appDone = true
            settleCopy(attempt, token: token, began: began)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.awaitAppCopy(attempt, token: token, before: before, polls: polls + 1, began: began)
        }
    }

    /// Both readings in: decide what stands on the pasteboard, and how
    /// the mode ends.
    private func settleCopy(_ attempt: VerifiedCopy, token: Int, began: Date) {
        guard copyGeneration == token, !attempt.settled else { return }
        let elapsed = Int(Date().timeIntervalSince(began) * 1000)
        if attempt.appDone, let app = attempt.appText {
            // The app's glyphs, cut to the pixels' extent: a drag's ends
            // land a character off, and the period it grabbed is not
            // part of the promise.
            if let truth = OCRSense.reconcile(pixel: attempt.pixel, app: app) {
                attempt.settled = true
                committedOutcome = "dragged"
                if truth != app { serve(truth) }
                // Counts only, never the text: glyphs say whether the
                // app restored a space the pixels dropped or a glyph.
                Log.info("select", ["copy": "app", "chars": (truth as NSString).length,
                                    "pixelChars": (attempt.pixel as NSString).length,
                                    "changed": truth != attempt.pixel, "trimmed": truth != app,
                                    "ms": elapsed])
                // The app's own selection is the ending now.
                dissolveGhost()
                return
            }
            // The app selected something else: what it put on the
            // pasteboard is not what the highlight promised.
            Log.info("select", ["copy": "app disagreed", "appChars": (app as NSString).length,
                                "pixelChars": (attempt.pixel as NSString).length])
            attempt.appText = nil
            guard attempt.rereadDone else {
                serve(attempt.pixel)
                return
            }
        }
        guard attempt.appDone, attempt.rereadDone else { return }
        attempt.settled = true
        let final = attempt.reread ?? attempt.pixel
        if final != attempt.pixel || NSPasteboard.general.string(forType: .string) != final {
            serve(final)
        }
        Log.info("select", ["copy": attempt.reread == nil ? "pixel" : "reread",
                            "changed": final != attempt.pixel, "ms": elapsed])
    }

    /// Roles a press can land on without pressing anything: text and the
    /// containers text lives in. A button, a link, a control of any kind
    /// refuses the drag, and the pixels stand.
    private static let dragSafeRoles: Set<String> = [
        "AXStaticText", "AXTextArea", "AXTextField", "AXWebArea", "AXGroup", "AXScrollArea",
        "AXCell", "AXRow", "AXTable", "AXOutline", "AXList", "AXLayoutArea", "AXLayoutItem",
        "AXSplitGroup", "AXWindow", "AXHeading", "AXGenericElement", "AXParagraph",
    ]

    private static func textLike(at point: CGPoint) -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success,
              let element else { return false }
        AXUIElementSetMessagingTimeout(element, 0.25)
        guard let role = AX.string(element, kAXRoleAttribute) else { return false }
        return dragSafeRoles.contains(role)
    }

    /// Ask the app to select the span: the pointer walked to the first
    /// glyph, a press there, a drag to inside the last, a release. The
    /// pointer goes back where it was a beat later — walked back, not
    /// warped, so the app is told. False when either end is a control, or
    /// the span is too narrow to press inside.
    ///
    /// The walk before the press is load-bearing. Ghostty hands libghostty
    /// a press with no position at all; the position is whatever the last
    /// moved or dragged event carried. A bare press therefore started the
    /// selection wherever the pointer had last moved inside the window —
    /// the app's copy came back 985 characters for an 800-character span
    /// — and after a warp back, which sends nothing, its remembered
    /// position stayed at the previous span's end, so the next select of
    /// the same span selected nothing and no app copy arrived. That was
    /// the select that had to be done twice, the first time to put the
    /// pointer in place. Apps that read the position off the press itself
    /// see one extra move and nothing else.
    private func dragSelect(_ rects: [CGRect]) -> Bool {
        guard let first = rects.first, let last = rects.last,
              first.width > 4, last.width > 4 else { return false }
        let start = CGPoint(x: first.minX + 2, y: first.midY)
        let end = CGPoint(x: last.maxX - 2, y: last.midY)
        guard focusedFrame.contains(start), focusedFrame.contains(end) else {
            Log.info("select", ["copy": "drag refused", "reason": "outside the focused window"])
            return false
        }
        guard Self.textLike(at: start), Self.textLike(at: end) else {
            Log.info("select", ["copy": "drag refused", "reason": "control under an end"])
            return false
        }
        let origin = Pointer.location()
        Pointer.post(SyntheticPointer.drag(from: start, to: end))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            Pointer.post(SyntheticPointer.home(origin))
        }
        return true
    }

    private static func postCopy() {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let code = Keys.codes["c"] else { return }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code),
                                      keyDown: down) else { continue }
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: ownMark)
            event.post(tap: .cghidEventTap)
        }
    }

    /// The one pasteboard write, shared by every copying verb.
    private func serve(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// ⌘C with a start anchored and no far end yet: take that word and end
    /// the mode the way any span ends — copied, still highlighted, the
    /// next verb yours. The second anchor is what a span needs, not what a
    /// word needs, and most of what anyone reaches for is one word.
    func copySelection() -> SelectStep {
        guard let anchor = core?.anchor, units.indices.contains(anchor.element) else {
            flash("⌖ ⇧letter first, then ⌘C takes that word")
            return .pending
        }
        let span = gather([anchor])
        guard !span.text.isEmpty else {
            flash("✕ that text lost its place on screen")
            return .pending
        }
        serve(span.text)
        // The same ending as a finished span, so the highlight standing
        // there is the same statement it always was — and the ending it
        // records is the one it actually reached, native or held.
        commit(pieces: [anchor])
        Log.info("select", ["outcome": "anchor-copied",
                            "chars": (span.text as NSString).length])
        return .done
    }

    /// A pixel-sensed span that lives, verbatim and uniquely, inside the
    /// focused editable element becomes a true selection there. Verbatim
    /// and unique on purpose: a grounding that guessed would be worse
    /// than a highlight that is honest about being pixels.
    private func commitToFocusedEditable(_ text: String) -> Bool {
        guard !text.contains("\n"), focusedPid != 0 else { return false }
        let app = AXUIElementCreateApplication(focusedPid)
        guard let focused = AX.element(app, kAXFocusedUIElementAttribute) else { return false }
        var flag: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(
            focused, kAXSelectedTextRangeAttribute as CFString, &flag) == .success,
            flag.boolValue,
            let value = AX.string(focused, kAXValueAttribute) else { return false }
        let haystack = value as NSString
        let first = haystack.range(of: text)
        guard first.location != NSNotFound else { return false }
        let next = haystack.range(
            of: text,
            range: NSRange(location: first.location + 1,
                           length: haystack.length - first.location - 1))
        guard next.location == NSNotFound else { return false }
        var cfRange = CFRange(location: first.location, length: first.length)
        guard let boxed = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(
            focused, kAXSelectedTextRangeAttribute as CFString, boxed) == .success
    }

    // MARK: - The pixel sensor

    /// Recognize the frozen frame twice: fast to be present within about
    /// a hundred milliseconds, accurate to be right a few hundred later,
    /// the second replacing the first through the same adoption that
    /// already lets richer passes replace poorer ones — unless an anchor
    /// has already landed, which pins the world the anchor indexes into.
    /// A copy made that early is served from the fast pass, with the AX
    /// grounding as its only repair — the price of never yanking a
    /// half-placed span out from under the hand.
    private func senseOCR(image: CGImage, frame: CGRect, windows: [CGRect],
                          generation expected: Int) {
        let began = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for level in [OCRSense.Level.fast, .accurate] {
                let lines = OCRSense.recognize(image: image, windowFrame: frame,
                                               level: level)
                let elapsed = Int(Date().timeIntervalSince(began) * 1000)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == expected else { return }
                    guard !lines.isEmpty else {
                        Log.info("select", ["sense": "ocr-empty", "ms": elapsed])
                        return
                    }
                    guard self.core?.anchor == nil else { return }
                    self.adoptOCR(lines, windows: windows, level: level)
                    if level == .accurate {
                        self.observations?.latency(surface: "select-ocr",
                                                   seconds: Double(elapsed) / 1000)
                    }
                    // `windows` is new in this line on purpose: its presence
                    // in a log is what says the build that stitches by
                    // window is the one running.
                    Log.info("select", ["sense": level == .fast ? "ocr-fast" : "ocr",
                                        "lines": lines.count,
                                        "units": self.units.count, "ms": elapsed,
                                        "windows": windows.count,
                                        "app": self.appName])
                }
            }
        }
    }

    /// The on-screen windows, front to back, as the window server draws
    /// them: which window a recognized line belongs to. Our own are left
    /// out — the band about to appear must not claim the text beneath it
    /// — and so is anything filed below the desktop or at screen-saver
    /// level and above, where system overlays live. Those are invisible
    /// by design and lie about ownership: a notch companion app was found
    /// holding a 624×320 window at the top of the screen, alpha 1, which
    /// claimed fourteen lines of the page beneath it.
    private static func windowStack() -> [CGRect] {
        let own = ProcessInfo.processInfo.processIdentifier
        let overlayLevel = Int(CGWindowLevelForKey(.screenSaverWindow))
        return CGWindows.list(onScreenOnly: true)
            .filter { $0.pid != own && $0.layer >= 0 && $0.layer < overlayLevel
                && $0.bounds.width >= 4 && $0.bounds.height >= 4 }
            .map(\.bounds)
    }

    /// The first moment the mode had anything to offer: entry to the
    /// first adopted sense, pixels or tree, whichever landed first. The
    /// audit's 0.89s median to first key was mostly this wait, and the
    /// instrument had no line for it.
    private var capturedAt: Date?

    private func noteCaptured() {
        guard capturedAt == nil else { return }
        let now = Date()
        capturedAt = now
        observations?.latency(surface: "select-capture",
                              seconds: now.timeIntervalSince(modeEnteredAt))
    }

    private func adoptOCR(_ lines: [OCRSense.Line], windows: [CGRect],
                          level: OCRSense.Level) {
        noteCaptured()
        ocrAdopted = true
        var leaves = lines.enumerated().map { index, line in
            SelectRuns.Leaf(id: index, text: line.text, frame: line.frame)
        }
        leaves.sort { a, b in
            let dy = a.frame.minY - b.frame.minY
            if abs(dy) > SelectRuns.lineTolerance { return dy < 0 }
            return a.frame.minX < b.frame.minX
        }
        let byID = Dictionary(uniqueKeysWithValues: lines.enumerated().map { ($0.offset, $0.element) })
        var units: [Unit] = []
        for run in SelectRuns.merge(leaves, windows: windows) {
            let used = Set(run.fragments.map(\.leaf))
            // Pick the handful of used lines out of the map — filtering
            // the whole dictionary per run made this O(runs × lines).
            let lines = Dictionary(uniqueKeysWithValues: used.compactMap { id in
                byID[id].map { (id, $0) }
            })
            units.append(Unit(run: run, leaves: [:], ocrLines: lines,
                              editable: nil, geometry: .ocr,
                              frame: lines.values.reduce(.null) { $0.union($1.frame) }))
        }
        // Index order is document order — a span across units takes
        // everything between them, so the array had better read the way
        // the page does.
        units.sort(by: Self.readingOrder)
        let query = core?.query ?? ""
        self.units = units
        // Uniqueness may commit only on a settled world. The fast pass is
        // a sketch — a few lines short, rough around rare glyphs — and a
        // match unique in a sketch is not unique on the screen; it shows
        // chips and commits nothing. The accurate pass is the last shape
        // the screen takes, so a query already typed that is unique there
        // lands the anchor its next keystroke would have.
        let settled = level == .accurate
        world = settled ? "ocr" : "ocr-fast"
        var rebuilt = SelectCore(
            elements: units.enumerated().map {
                SelectCore.Element(id: $0.offset, text: $0.element.run.text,
                                   frame: $0.element.frame)
            },
            alphabet: letters, autoAnchor: commitOnUnique && door == .anchor && settled)
        var seeded = SelectCore.Effect.none
        if !query.isEmpty { seeded = rebuilt.seed(query: query, settled: settled) }
        core = rebuilt
        if case .anchored = seeded {
            Log.info("select", ["auto": "anchor", "query": (query as NSString).length,
                                "world": world, "seeded": true])
        }
        replayPendingKeys()
        render()
    }

    // MARK: - Harvest

    /// Bounded walk for text-bearing elements, off the main thread, with
    /// three lessons the browser taught the hard way. **Batched reads**:
    /// role, position, size, and children come back in one AX round trip
    /// instead of four. **Viewport pruning**: a container whose frame is
    /// real and off-window is skipped with its whole subtree, which is
    /// what makes depth affordable. **Convergence**: Chromium materializes
    /// its tree lazily after `AXManualAccessibility` is set, so a single
    /// walk reads a half-built page — the harvest re-walks every beat
    /// until two passes agree, presenting each pass as it lands so the
    /// mode is usable immediately and complete moments later. (Warming
    /// happens at focus time — `AXWarmer` — so by the time anyone enters
    /// the mode, the tree has usually been building for minutes.)
    private func harvest(window: WindowModel.Window, generation expected: Int,
                         attempt: Int) {
        let windowElement = window.element
        let windowFrame = window.frame
        let pid = window.pid
        let began = Date()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString,
                                         kCFBooleanTrue)

            struct Harvested {
                let element: AXUIElement
                let frame: CGRect
                let text: String
                let settable: Bool
                let boundsWork: Bool
                let lineTier: Bool
            }
            var found: [Harvested] = []
            var visited = 0
            var totalChars = 0
            let deadline = Date().addingTimeInterval(2.5)
            let batch = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute,
                         kAXChildrenAttribute] as CFArray

            func boundsWork(_ element: AXUIElement, _ length: Int) -> Bool {
                var range = CFRange(location: 0, length: min(2, max(1, length)))
                guard let parameter = AXValueCreate(.cfRange, &range) else { return false }
                var out: CFTypeRef?
                guard AXUIElementCopyParameterizedAttributeValue(
                    element, kAXBoundsForRangeParameterizedAttribute as CFString,
                    parameter, &out) == .success,
                    let raw = out, CFGetTypeID(raw) == AXValueGetTypeID() else { return false }
                var rect = CGRect.zero
                guard AXValueGetValue(raw as! AXValue, .cgRect, &rect) else { return false }
                return rect.width > 0 && rect.height > 0
            }

            func settable(_ element: AXUIElement) -> Bool {
                var flag: DarwinBoolean = false
                guard AXUIElementIsAttributeSettable(
                    element, kAXSelectedTextRangeAttribute as CFString, &flag) == .success
                else { return false }
                return flag.boolValue
            }

            func walk(_ element: AXUIElement, depth: Int) {
                guard depth < 50, visited < 40_000, found.count < 600,
                      totalChars < 200_000, Date() < deadline else { return }
                visited += 1

                var values: CFArray?
                guard AXUIElementCopyMultipleAttributeValues(
                    element, batch, AXCopyMultipleAttributeOptions(rawValue: 0),
                    &values) == .success,
                    let array = values as? [CFTypeRef], array.count == 4 else { return }

                let role = array[0] as? String
                if let role, Self.skipRoles.contains(role) { return }
                var frame: CGRect?
                if CFGetTypeID(array[1]) == AXValueGetTypeID(),
                   CFGetTypeID(array[2]) == AXValueGetTypeID() {
                    var point = CGPoint.zero
                    var size = CGSize.zero
                    if AXValueGetValue(array[1] as! AXValue, .cgPoint, &point),
                       AXValueGetValue(array[2] as! AXValue, .cgSize, &size) {
                        frame = CGRect(origin: point, size: size)
                    }
                }
                // The pruning that makes depth affordable.
                if let frame, frame.width > 1, frame.height > 1,
                   !frame.intersects(windowFrame.insetBy(dx: -8, dy: -8)) {
                    return
                }

                if let role, Self.textRoles.contains(role), role != "AXWebArea",
                   let frame, frame.width >= 4, frame.height >= 4,
                   frame.intersects(windowFrame),
                   let text = AX.string(element, kAXValueAttribute),
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let editable = settable(element)
                    let bounded = boundsWork(element, (text as NSString).length)
                    // A terminal grid: readable multi-line text with no
                    // per-range geometry. Line arithmetic places rows
                    // honestly when the implied cell height is plausible;
                    // a scrollback-sized value fails the sanity check and
                    // stays excluded rather than guessed at.
                    var lineTier = false
                    if !bounded, !editable, role == "AXTextArea" {
                        // Counted the way the renderer counts rows —
                        // .byLines, one terminator of any spelling per
                        // line, no phantom row for a trailing newline —
                        // so the cell this check approves is the cell
                        // that gets drawn.
                        var lines = 0
                        (text as NSString).enumerateSubstrings(
                            in: NSRange(location: 0, length: (text as NSString).length),
                            options: [.byLines, .substringNotRequired]
                        ) { _, _, _, _ in lines += 1 }
                        let cell = frame.height / CGFloat(max(1, lines))
                        lineTier = lines >= 3 && cell >= 8 && cell <= 40
                    }
                    // Read-only text with no geometry at all cannot wear
                    // chips — excluded. An *editable* field without
                    // geometry keeps its place: its frame interpolates
                    // well enough, and a URL bar that vanished from the
                    // mode was a hole users hit immediately.
                    if bounded || editable || lineTier {
                        totalChars += (text as NSString).length
                        found.append(Harvested(element: element, frame: frame,
                                               text: text, settable: editable,
                                               boundsWork: bounded, lineTier: lineTier))
                    }
                }
                guard CFGetTypeID(array[3]) == CFArrayGetTypeID(),
                      let children = array[3] as? [AXUIElement] else { return }
                for child in children {
                    walk(child, depth: depth + 1)
                }
            }

            walk(windowElement, depth: 0)
            // Reading order before stitching: top to bottom, then left to
            // right — what the merge relies on.
            found.sort { (a: Harvested, b: Harvested) -> Bool in
                let dy: CGFloat = a.frame.minY - b.frame.minY
                if abs(dy) > SelectRuns.lineTolerance { return dy < 0 }
                return a.frame.minX < b.frame.minX
            }
            let elapsed = Int(Date().timeIntervalSince(began) * 1000)
            let grounding = OCRSense.Grounding(found.map(\.text))

            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == expected else { return }
                self.grounding = grounding

                // Present what this pass found — unless the pixel sensor
                // already answered (accessibility then serves only as
                // grounding), or a span is already half-placed, in which
                // case coverage is frozen: swapping the world out from
                // under an anchor breaks its promise.
                let grew = found.count > self.lastPassLeaves
                if !self.ocrAdopted, self.core?.anchor == nil, grew || self.core == nil {
                    if !found.isEmpty { self.noteCaptured() }
                    self.adopt(found.map { item in
                        (element: item.element, frame: item.frame, text: item.text,
                         settable: item.settable, bounded: item.boundsWork,
                         lineTier: item.lineTier)
                    })
                }
                Log.info("select", ["leaves": found.count, "units": self.units.count,
                                    "visited": visited, "ms": elapsed,
                                    "attempt": attempt, "app": self.appName])

                // Convergence: another beat, another pass, until two agree
                // or patience runs out.
                let unsettled = attempt < 5 && found.count != self.lastPassLeaves
                self.lastPassLeaves = found.count
                if unsettled {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                        guard let self, self.generation == expected else { return }
                        guard let window = self.model.focusedWindow, window.isAlive else { return }
                        self.harvest(window: window, generation: expected,
                                     attempt: attempt + 1)
                    }
                }
            }
        }
    }

    /// Rebuild units and the core from a harvest pass, carrying the
    /// user's typed query across so a richer pass upgrades the world
    /// mid-thought instead of resetting it.
    private func adopt(_ found: [(element: AXUIElement, frame: CGRect, text: String,
                                  settable: Bool, bounded: Bool, lineTier: Bool)]) {
        func standalone(_ item: (element: AXUIElement, frame: CGRect, text: String,
                                 settable: Bool, bounded: Bool, lineTier: Bool),
                        editable: Bool, geometry: Unit.Geometry) -> Unit {
            let length = (item.text as NSString).length
            return Unit(
                run: SelectRuns.Run(
                    text: item.text,
                    fragments: [SelectRuns.Fragment(
                        leaf: 0,
                        range: NSRange(location: 0, length: length),
                        localRange: NSRange(location: 0, length: length))]),
                leaves: [0: item.element],
                ocrLines: [:],
                editable: editable ? item.element : nil,
                geometry: geometry,
                frame: item.frame)
        }
        var units: [Unit] = []
        for item in found where item.settable {
            units.append(standalone(item, editable: true,
                                    geometry: item.bounded ? .ax : .interpolated(item.frame)))
        }
        for item in found where !item.settable && item.lineTier {
            units.append(standalone(item, editable: false, geometry: .lines(item.frame)))
        }
        let readOnly = found.enumerated().filter { !$0.element.settable && !$0.element.lineTier }
        let leaves = readOnly.map {
            SelectRuns.Leaf(id: $0.offset, text: $0.element.text, frame: $0.element.frame)
        }
        let handles = Dictionary(uniqueKeysWithValues: readOnly.map {
            ($0.offset, $0.element.element)
        })
        let frames = Dictionary(uniqueKeysWithValues: readOnly.map {
            ($0.offset, $0.element.frame)
        })
        for run in SelectRuns.merge(leaves) {
            let used = Set(run.fragments.map(\.leaf))
            units.append(Unit(run: run,
                              leaves: handles.filter { used.contains($0.key) },
                              ocrLines: [:], editable: nil, geometry: .ax,
                              frame: used.compactMap { frames[$0] }
                                  .reduce(.null) { $0.union($1) }))
        }
        // Editables were hoisted to the front to build; reading order is
        // what a span crossing units walks, so the array is put back into
        // it before anything indexes into it.
        units.sort(by: Self.readingOrder)

        let query = core?.query ?? ""
        self.units = units
        // The tree's uniqueness counts only where the tree is the only
        // sensor. With a capture in hand the accurate pass is the settled
        // world, and a tree pass — adopted a beat before the pixels land,
        // seven units where the page has fifty — commits nothing.
        world = "ax"
        var rebuilt = SelectCore(
            elements: units.enumerated().map {
                SelectCore.Element(id: $0.offset, text: $0.element.run.text,
                                   frame: $0.element.frame)
            },
            alphabet: letters, autoAnchor: commitOnUnique && door == .anchor && frozen == nil)
        if !query.isEmpty { rebuilt.seed(query: query) }
        core = rebuilt
        replayPendingKeys()
        render()
    }

    // MARK: - Geometry

    /// The rectangles a range of a unit occupies on screen: one per
    /// fragment slice, each asked of its own leaf — or, for an editable
    /// field whose geometry does not answer, interpolated inside its
    /// frame on the single-line assumption. Synchronous AX — call off the
    /// main thread for anything plural. The one tap-safe branch is
    /// `.ocr`: pure arithmetic over recognizer data, no AX, which
    /// `performClick` relies on for its synchronous owner check.
    private func boundsRects(unit: Unit, range: NSRange) -> [CGRect] {
        if case .ocr = unit.geometry {
            return unit.run.slices(of: range).flatMap { slice -> [CGRect] in
                unit.ocrLines[slice.leaf]?.rects(for: slice.localRange) ?? []
            }
        }
        if case .interpolated(let frame) = unit.geometry {
            let length = max(1, (unit.run.text as NSString).length)
            let charWidth = frame.width / CGFloat(length)
            return [CGRect(x: frame.minX + charWidth * CGFloat(range.location),
                           y: frame.minY,
                           width: max(6, charWidth * CGFloat(range.length)),
                           height: frame.height)]
        }
        if case .lines(let frame) = unit.geometry {
            // Whole rows: vertical placement is arithmetic on line count,
            // which holds; column placement would be a guess about padding
            // and font metrics, so it is not made.
            let text = unit.run.text as NSString
            var starts: [Int] = [0]
            text.enumerateSubstrings(in: NSRange(location: 0, length: text.length),
                                     options: [.byLines, .substringNotRequired]) {
                _, _, enclosingRange, _ in
                // The enclosing range carries the terminator, whatever it
                // is — one unit for \n, two for \r\n — so the next line
                // starts exactly where it ends. Adding 1 to the line range
                // instead drifted one unit per CRLF, shifting every row
                // below it.
                let next = enclosingRange.location + enclosingRange.length
                if next < text.length { starts.append(next) }
            }
            let lineCount = max(1, starts.count)
            let cell = frame.height / CGFloat(lineCount)
            func line(of offset: Int) -> Int {
                var index = 0
                for (i, start) in starts.enumerated() where start <= offset { index = i }
                return index
            }
            let first = line(of: range.location)
            let last = line(of: max(range.location, range.location + range.length - 1))
            return (first...last).map { row in
                CGRect(x: frame.minX, y: frame.minY + CGFloat(row) * cell,
                       width: frame.width, height: cell)
            }
        }
        return unit.run.slices(of: range).compactMap { fragment in
            guard let element = unit.leaves[fragment.leaf] else { return nil }
            var cfRange = CFRange(location: fragment.localRange.location,
                                  length: fragment.localRange.length)
            guard let parameter = AXValueCreate(.cfRange, &cfRange) else { return nil }
            var out: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString,
                parameter, &out) == .success,
                let raw = out, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
            var rect = CGRect.zero
            guard AXValueGetValue(raw as! AXValue, .cgRect, &rect),
                  rect.width > 0 else { return nil }
            return rect
        }
    }

    // MARK: - Drawing

    /// Geometry per keystroke, off the main thread: dozens of
    /// `AXBoundsForRange` calls against an app that might be slow — a
    /// keystroke must never wait on them, so stale renders are dropped by
    /// generation instead.
    private func render() {
        guard let core else { return }
        // The click door's empty-query state belongs to the entry chips —
        // a sensor pass landing must not wipe them with zero matches.
        if door == .click, core.query.isEmpty {
            renderEntry()
            return
        }
        boundsGeneration += 1
        let expected = boundsGeneration
        let matches = core.matches
        let labels = core.labels
        let anchor = core.anchor
        let snapshot = units
        let state = SelectOverlay.State(
            appName: appName, query: core.query, typedLabel: core.typedLabel,
            shown: matches.count, total: core.totalMatches, capped: core.countCapped,
            stage: anchor == nil ? .start : .end,
            scanning: false,
            verb: door == .click ? "clicks · ⌃⇧ right-clicks"
                : (anchor == nil ? "anchors" : "selects"))

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            func rects(_ match: SelectCore.Match) -> [CGRect] {
                guard snapshot.indices.contains(match.element) else { return [] }
                return self?.boundsRects(unit: snapshot[match.element],
                                         range: match.range) ?? []
            }

            let chips: [SelectOverlay.Chip] = zip(labels, matches).compactMap {
                label, match in
                let frames = rects(match)
                guard !frames.isEmpty else { return nil }
                return SelectOverlay.Chip(label: label, frames: frames)
            }
            let anchorFrames = anchor.map(rects) ?? []

            DispatchQueue.main.async { [weak self] in
                guard let self, self.boundsGeneration == expected else { return }
                self.overlay.show(chips: chips, anchor: anchorFrames,
                                  over: self.windowFrame, state: state)
            }
        }
    }
}
