import AppKit
import LodestarCore

/// Select (`lode /`): text addressed by its own content. Type a few
/// characters of what you can see; matches highlight and wear capital
/// chips; a capital anchors the start — lit as a whole word, which ⌘C
/// alone will take — and a second search and capital anchor the end.
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
/// reading order, which is what lets it run down a page whose every line
/// is its own run: the pieces it covers are gathered into one copy and one
/// highlight, so what lights up is exactly what ⌘C serves.
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

    func enter() -> Bool {
        guard let window = model.focusedWindow, window.isAlive else { return false }
        dissolveGhost()
        core = nil
        units = []
        windowFrame = window.frame
        appName = window.appName
        generation += 1
        lastPassLeaves = -1
        ocrAdopted = false
        focusedPid = window.pid
        modeEnteredAt = Date()
        typedInMode = 0
        committedOutcome = nil
        observations?.verbUsed("select")
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
        if CGPreflightScreenCaptureAccess() {
            captured = CGWindowListCreateImage(display, .optionOnScreenOnly,
                                               kCGNullWindowID, [.bestResolution])
        } else if !screenAccessPrompted {
            screenAccessPrompted = true
            DispatchQueue.global(qos: .utility).async { CGRequestScreenCaptureAccess() }
            flash("⌖ grant Screen Recording to select in every window · using accessibility for now")
        }
        if captured != nil { windowFrame = display }
        overlay.showScanning(over: windowFrame, appName: window.appName)
        if let captured {
            senseOCR(image: captured, frame: display, generation: generation)
        }
        harvest(window: window, generation: generation, attempt: 1)
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
        if modeEnteredAt != .distantPast {
            observations?.selected(
                app: appName, action: committedOutcome == nil ? "abandoned" : "completed",
                source: ocrAdopted ? "ocr" : "ax", outcome: committedOutcome,
                typed: typedInMode, seconds: Date().timeIntervalSince(modeEnteredAt),
                matches: lastMatchCount)
            modeEnteredAt = .distantPast
        }
    }

    func backspace() {
        guard core != nil else { return }
        _ = core?.backspace()
        render()
    }

    func key(_ key: String, shift: Bool) -> SelectStep {
        guard core != nil else { return .pending } // still scanning — keys wait
        let effect = core!.key(key, shift: shift)
        if !shift, case .updated = effect { typedInMode += 1 }
        lastMatchCount = core!.totalMatches
        switch effect {
        case .selected(let pieces):
            commit(pieces: pieces)
            return .done
        case .anchored, .updated:
            render()
            return .pending
        case .none:
            return .pending
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
        guard let ghost else { return false }
        if held {
            dissolveGhost()
            return false
        }
        let plainCommand = flags.contains(.maskCommand)
            && !flags.contains(.maskAlternate) && !flags.contains(.maskControl)
            && !flags.contains(.maskShift)
        if key == "c", plainCommand {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ghost.text, forType: .string)
            Log.info("select", ["outcome": "ghost-copied", "chars": (ghost.text as NSString).length])
            dissolveGhost()
            return true
        }
        if key == "escape" {
            dissolveGhost()
            return true
        }
        dissolveGhost()
        return false
    }

    private func holdGhost(text: String, rects: [CGRect]) {
        ghost = (text, rects)
        overlay.hold(spans: rects, over: windowFrame)
        guard ghostClickMonitor == nil else { return }
        ghostClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.dissolveGhost() }
        }
    }

    private func dissolveGhost() {
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
        for piece in pieces {
            guard units.indices.contains(piece.element) else { continue }
            let unit = units[piece.element]
            var text = (unit.run.text as NSString).substring(with: piece.range)
            // Pixel-sensed text is repaired against the accessibility walk
            // piece by piece: recognition's rare single-glyph confusions
            // must never reach a pasteboard when the truth was readable.
            if case .ocr = unit.geometry, let repaired = grounding.repair(text) {
                text = repaired
            }
            parts.append(text)
            rects.append(contentsOf: boundsRects(unit: unit, range: piece.range))
        }
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
                            "chars": (span.text as NSString).length, "pieces": pieces])
        committedOutcome = "held"
        holdGhost(text: span.text, rects: span.rects)
    }

    /// ⌘C with a start anchored and no far end yet: take that word and end
    /// the mode the way any span ends — copied, still highlighted, the
    /// next verb yours. The second anchor is what a span needs, not what a
    /// word needs, and most of what anyone reaches for is one word.
    func copySelection() -> SelectStep {
        guard let anchor = core?.anchor, units.indices.contains(anchor.element) else {
            flash("⌖ ⇧letter first — then ⌘C takes that word")
            return .pending
        }
        let span = gather([anchor])
        guard !span.text.isEmpty else {
            flash("✕ that text lost its place on screen")
            return .pending
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(span.text, forType: .string)
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
    /// already lets richer passes replace poorer ones. Copies are always
    /// served from the accurate world (or grounded against AX regardless).
    private func senseOCR(image: CGImage, frame: CGRect, generation expected: Int) {
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
                    self.adoptOCR(lines)
                    Log.info("select", ["sense": level == .fast ? "ocr-fast" : "ocr",
                                        "lines": lines.count,
                                        "units": self.units.count, "ms": elapsed,
                                        "app": self.appName])
                }
            }
        }
    }

    private func adoptOCR(_ lines: [OCRSense.Line]) {
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
        for run in SelectRuns.merge(leaves) {
            let used = Set(run.fragments.map(\.leaf))
            let lines = byID.filter { used.contains($0.key) }
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
        var rebuilt = SelectCore(
            elements: units.enumerated().map {
                SelectCore.Element(id: $0.offset, text: $0.element.run.text)
            },
            alphabet: letters)
        if !query.isEmpty { rebuilt.seed(query: query) }
        core = rebuilt
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
                        let lines = text.components(separatedBy: "\n").count
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
        var rebuilt = SelectCore(
            elements: units.enumerated().map {
                SelectCore.Element(id: $0.offset, text: $0.element.run.text)
            },
            alphabet: letters)
        if !query.isEmpty { rebuilt.seed(query: query) }
        core = rebuilt
        render()
    }

    // MARK: - Geometry

    /// The rectangles a range of a unit occupies on screen: one per
    /// fragment slice, each asked of its own leaf — or, for an editable
    /// field whose geometry does not answer, interpolated inside its
    /// frame on the single-line assumption. Synchronous AX — call off the
    /// main thread for anything plural.
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
                _, lineRange, _, _ in
                let next = lineRange.location + lineRange.length
                if next < text.length { starts.append(next + 1) }
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
        boundsGeneration += 1
        let expected = boundsGeneration
        let matches = core.matches
        let labels = core.labels
        let anchor = core.anchor
        let snapshot = units
        let state = SelectOverlay.State(
            appName: appName, query: core.query, typedLabel: core.typedLabel,
            shown: matches.count, total: core.totalMatches,
            stage: anchor == nil ? .start : .end,
            scanning: false)

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
