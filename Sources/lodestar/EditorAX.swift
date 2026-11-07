import AppKit
import LodestarCore

/// The field the hand is typing in, read through accessibility.
struct EditorField {
    let element: AXUIElement
    let pid: pid_t
    let appName: String
    let bundleID: String?
    var text: String
    /// Where the caret stands, when nothing is selected.
    var caret: Int?
    /// The field's own frame and its window's, top-left origin: a mark is
    /// drawn only where both can show it.
    var frame: CGRect?
    var windowFrame: CGRect?

    /// The same field, whatever its text: a new element reference for the
    /// same node compares equal.
    func isSame(as other: EditorField) -> Bool {
        pid == other.pid && CFEqual(element, other.element)
    }
}

/// Where the editor's field comes from — accessibility in the app, a
/// scripted field in the tests.
protocol EditorFieldSource {
    /// The focused field, if readable. `frontmost` is the frontmost app,
    /// taken on the main thread, for when the system-wide question fails.
    func focusedField(frontmost: pid_t?) -> EditorField?
    func rects(for ranges: [NSRange], in field: EditorField) -> [CGRect?]
    func replace(_ range: NSRange, expected: String, with text: String, in field: EditorField) -> Bool
}

/// The real source: accessibility, and typing marked as Lodestar's own.
struct AXFieldSource: EditorFieldSource {
    func focusedField(frontmost: pid_t?) -> EditorField? { EditorAX.focusedField(frontmost: frontmost) }
    func rects(for ranges: [NSRange], in field: EditorField) -> [CGRect?] { EditorAX.rects(for: ranges, in: field) }
    func replace(_ range: NSRange, expected: String, with text: String, in field: EditorField) -> Bool {
        EditorAX.replace(range, expected: expected, with: text, in: field, post: { Self.type($0, to: field.pid) })
    }

    /// Type a replacement the way a hand would, marked so the tap lets it
    /// through untouched. `pace` is the gap between the key's two events.
    static func type(_ text: String, to pid: pid_t, pace: useconds_t = 15_000) {
        let units = Array(text.utf16)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            event.flags = event.flags.withoutModifiers
            event.setIntegerValueField(.eventSourceUserData, value: SelectController.ownMark)
            SystemEvents.post(event, toPid: pid)
            if pace > 0 { usleep(pace) }
        }
    }

    /// A key that types no character (⌫ is 51, ⏎ is 36), struck with the
    /// modifiers given (none, for the hand's typing held back) and marked
    /// as Lodestar's own like the typing is.
    static func strike(_ code: CGKeyCode, to pid: pid_t, pace: useconds_t = 15_000,
                       flags: CGEventFlags = []) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: SelectController.ownMark)
            SystemEvents.post(event, toPid: pid)
            if pace > 0 { usleep(pace) }
        }
    }
}

/// Every accessibility call the editor makes. They run on one serial queue,
/// never the main thread, each bounded by a short timeout: an app that
/// stops answering costs the editor a beat and the tap nothing — the
/// freezes this project has had all began with an accessibility call on
/// the main thread.
enum EditorAX {
    static let queue = DispatchQueue(label: "com.vaccone.lodestar.editor.ax", qos: .userInitiated)
    static let timeout: Float = 0.25
    private static let systemWide = AX.systemWide()

    // MARK: - Reading

    /// The focused field, if it is one the editor may read: editable, not a
    /// password, not a query (a search box, a launcher, an address bar), not
    /// Lodestar's own glass.
    static func focusedField(frontmost: pid_t? = nil) -> EditorField? {
        dispatchPrecondition(condition: .onQueue(queue))
        // The system-wide question can fail outright ("cannot complete",
        // -25204) — an app slow to answer, or a process macOS will not
        // answer it for — so the frontmost app is asked in its place.
        guard var element = AX.element(systemWide, kAXFocusedUIElementAttribute as String)
                ?? frontmost.flatMap({ pid -> AXUIElement? in
                    let app = AXUIElementCreateApplication(pid)
                    AXUIElementSetMessagingTimeout(app, timeout)
                    return AX.element(app, kAXFocusedUIElementAttribute as String)
                })
        else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid != getpid() else { return nil }
        // A launcher's one field is a query, whatever it answers about
        // itself: refused before the app is asked anything more.
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        guard !EditorFieldGate.refusesApp(bundleID) else { return nil }
        AXUIElementSetMessagingTimeout(element, timeout)
        // Rich web editors focus a node inside the field; Chromium names
        // the field itself.
        if let ancestor = AX.element(element, "AXEditableAncestor") {
            element = ancestor
            AXUIElementSetMessagingTimeout(element, timeout)
        }
        var facts = EditorFieldFacts(role: AX.string(element, kAXRoleAttribute as String) ?? "",
                                     subrole: AX.string(element, kAXSubroleAttribute as String) ?? "",
                                     bundleID: bundleID,
                                     valueSettable: settable(element, kAXValueAttribute as String),
                                     rangeSettable: settable(element, kAXSelectedTextRangeAttribute as String))
        // The names are only read for the fields that could be refused by
        // them: every one is a message to the app.
        if facts.isSingleLine {
            facts.roleDescription = AX.string(element, kAXRoleDescriptionAttribute as String) ?? ""
            facts.description = AX.string(element, kAXDescriptionAttribute as String) ?? ""
            facts.title = AX.string(element, kAXTitleAttribute as String) ?? ""
            facts.placeholder = AX.string(element, "AXPlaceholderValue") ?? ""
            if facts.asksWhereItStands { facts.insideWebArea = isInsideWebArea(element) }
        }
        guard EditorFieldGate.verdict(facts) == .read else { return nil }
        guard let text = AX.string(element, kAXValueAttribute as String) else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        var field = EditorField(element: element, pid: pid, appName: app?.localizedName ?? "",
                                bundleID: bundleID, text: text)
        if let selection = selectedRange(element), selection.length == 0 { field.caret = selection.location }
        field.frame = frame(of: element)
        if let window = AX.element(element, kAXWindowAttribute as String) { field.windowFrame = frame(of: window) }
        return field
    }

    /// Which fields the editor may read: see `EditorFieldGate`. Kept for
    /// the callers that know only the role and the subrole.
    static func isReadable(role: String, subrole: String, valueSettable: Bool, rangeSettable: Bool) -> Bool {
        EditorFieldGate.verdict(EditorFieldFacts(role: role, subrole: subrole, valueSettable: valueSettable,
                                                 rangeSettable: rangeSettable)) == .read
    }

    /// Whether an AXWebArea stands above the element: the page's own
    /// fields do, a browser's address bar (its own interface) does not.
    /// A field's place never changes, and the answer costs up to forty
    /// accessibility messages, one per hop, on every read of a field (every
    /// keystroke and caret move in a page's single-line input), so a field
    /// pays for the walk once and the last few are remembered.
    static func isInsideWebArea(_ element: AXUIElement) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return placeMemory.answer(for: element) { walkUpToWebArea(element) }
    }

    nonisolated(unsafe) static var placeMemory = PlaceMemory()

    /// The walk itself, bounded: nil when it did not finish (a timeout, a
    /// tree deeper than any page), which refuses the field for now, the
    /// quiet side, and is not remembered.
    static func walkUpToWebArea(_ element: AXUIElement) -> Bool? {
        var node = element
        for _ in 0..<40 {
            guard let parent = AX.element(node, kAXParentAttribute as String) else { return nil }
            let role = AX.string(parent, kAXRoleAttribute as String)
            if role == "AXWebArea" { return true }
            if role == kAXWindowRole as String { return false }
            node = parent
        }
        return nil
    }

    /// Does the range still read what the mark was made for? A fix whose
    /// words have moved or changed would overwrite something else.
    static func stillReads(_ text: String, range: NSRange, expected: String) -> Bool {
        let ns = text as NSString
        return range.location >= 0 && range.location + range.length <= ns.length
            && ns.substring(with: range) == expected
    }

    /// Where the caret goes after a fix: where it was, moved by the change
    /// in length when it stood after the fixed words.
    static func restoredCaret(before: NSRange, fixed range: NSRange, replacementLength: Int) -> NSRange {
        let delta = replacementLength - range.length
        let location = before.location >= range.location + range.length ? before.location + delta : before.location
        return NSRange(location: max(0, location), length: before.length)
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let p = AX.point(element, kAXPositionAttribute as String),
              let s = AX.size(element, kAXSizeAttribute as String) else { return nil }
        return CGRect(origin: p, size: s)
    }

    static func settable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var flag: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &flag) == .success && flag.boolValue
    }

    static func selectedRange(_ element: AXUIElement) -> NSRange? {
        guard let raw = AX.copy(element, kAXSelectedTextRangeAttribute as String),
              let range = AX.range(raw) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    @discardableResult
    static func select(_ element: AXUIElement, _ range: NSRange) -> Bool {
        var cf = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cf) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    // MARK: - Waking Chromium

    /// Ask an app to build the tree of its pages' fields, the way every
    /// door does (AXWarmer.ask: Electron's flag, and VoiceOver's for a
    /// Chromium browser), throttled per app like the focus warmer.
    static func wake(_ pid: pid_t) {
        AXWarmer.warm(pid)
    }

    static func isChromiumBrowser(_ bundle: URL) -> Bool { AXWarmer.isChromiumBrowser(bundle) }

    // MARK: - Geometry

    private static func bounds(_ element: AXUIElement, _ range: NSRange) -> CGRect? {
        var cf = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cf) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &out) == .success,
              let raw = out, let rect = AX.rect(raw), rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    /// Where each range is drawn, or nil where it cannot be shown: out of
    /// the field's view, off its window, or unplaceable. Two routes, the
    /// probe's: the field answers ranges directly (native text, plain web
    /// fields), or — where it answers every range with its whole line, as
    /// Slack, Claude and Proton Mail do — each text node inside it does.
    static func rects(for ranges: [NSRange], in field: EditorField) -> [CGRect?] {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !ranges.isEmpty else { return [] }
        var direct = ranges.map { bounds(field.element, $0) }
        // The whole-line tell: a word answers with the same rectangle as
        // its own first letter.
        let wholeLine = zip(ranges, direct).contains { range, rect in
            guard let rect, range.length > 1, let first = bounds(field.element, NSRange(location: range.location, length: 1))
            else { return false }
            return first == rect
        }
        if wholeLine || direct.allSatisfy({ $0 == nil }) {
            if let byNode = nodeRects(for: ranges, in: field) { direct = byNode }
        }
        return direct.map { rect in
            guard let rect else { return nil }
            if let frame = field.frame, !frame.insetBy(dx: -Grid.hair, dy: -Grid.hair).contains(rect) { return nil }
            if let window = field.windowFrame, !window.intersects(rect) { return nil }
            return rect
        }
    }

    /// Ranges answered by the static-text nodes inside the field, each
    /// placed in the field's text by its contents.
    private static func nodeRects(for ranges: [NSRange], in field: EditorField) -> [CGRect?]? {
        var nodes: [(AXUIElement, NSString)] = []
        var budget = 600
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 24, budget > 0 else { return }
            budget -= 1
            if AX.string(element, kAXRoleAttribute as String) == "AXStaticText",
               let value = AX.string(element, kAXValueAttribute as String), !value.isEmpty {
                nodes.append((element, value as NSString))
            }
            for child in AX.elements(element, kAXChildrenAttribute as String) ?? [] { walk(child, depth: depth + 1) }
        }
        walk(field.element, depth: 0)
        guard !nodes.isEmpty else { return nil }
        let text = field.text as NSString
        var placed: [(AXUIElement, NSRange)] = []
        var from = 0
        for (node, value) in nodes {
            let found = text.range(of: value as String, range: NSRange(location: from, length: text.length - from))
            guard found.location != NSNotFound else { continue }
            placed.append((node, found))
            from = found.location + found.length
        }
        return ranges.map { range in
            guard let (node, span) = placed.first(where: { NSLocationInRange(range.location, $0.1) }),
                  range.location + range.length <= span.location + span.length else { return nil }
            return bounds(node, NSRange(location: range.location - span.location, length: range.length))
        }
    }

    // MARK: - Writing

    /// Replace `range` — which must still read `expected` — with `text`,
    /// and put the caret back where the hand left it. Native text takes
    /// the replacement directly; Chromium, Electron and Outlook ignore
    /// that and take typing into a selection instead, which is also the
    /// one road their editors and undo understand.
    ///
    /// For those the write is not tried. It was, first, and waited a
    /// third of a second to see whether it landed (some native apps apply
    /// one that late), then typed for up to 0.6 s more: the word stood
    /// selected for 0.3 to 0.9 s, and the hand's next character, struck
    /// inside that time, replaced it. Going straight to the selection and
    /// the typing leaves the word selected only for the typing itself: two
    /// key events fifteen milliseconds apart, and the beat Chromium takes
    /// to apply them.
    static func replace(_ range: NSRange, expected: String, with text: String, in field: EditorField,
                        post: (String) -> Void) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let current = AX.string(field.element, kAXValueAttribute as String),
              stillReads(current, range: range, expected: expected) else { return false }
        let ns = current as NSString
        let before = selectedRange(field.element)
        let target = ns.replacingCharacters(in: range, with: text)
        guard select(field.element, range) else { return false }
        if fixesByTyping(bundleID: field.bundleID, pid: field.pid) {
            post(text)
            guard settles(field.element, to: target, within: 0.6) else { return false }
        } else {
            _ = AXUIElementSetAttributeValue(field.element, kAXSelectedTextAttribute as CFString, text as CFString)
            if !settles(field.element, to: target, within: 0.3) {
                // The direct write was ignored: the selection stands, so type.
                if AX.string(field.element, kAXValueAttribute as String) == current {
                    select(field.element, range)
                    post(text)
                    guard settles(field.element, to: target, within: 0.6) else { return false }
                } else if AX.string(field.element, kAXValueAttribute as String) != target {
                    return false
                }
            }
        }
        // The caret goes back where it was, moved by the change in length
        // when it stood after the fix.
        if let before {
            settleCaret(field.element, at: restoredCaret(before: before, fixed: range,
                                                         replacementLength: (text as NSString).length))
        }
        return true
    }

    // MARK: - Which apps take typing

    /// Whether an app ignores a direct write to the selected text and
    /// takes typing into a selection instead: Chromium, Electron and
    /// Outlook, as probed. Pure, so the table is testable.
    static func fixesByTyping(bundleID: String?, chromium: Bool, electron: Bool) -> Bool {
        chromium || electron || bundleID?.lowercased() == "com.microsoft.outlook"
    }

    nonisolated(unsafe) private static var typed: [String: Bool] = [:]
    private static let typedLock = NSLock()

    /// The same question of a running app, read once per bundle: Chromium
    /// browsers carry renderer helpers and Electron apps carry their
    /// framework, both a directory listing away.
    static func fixesByTyping(bundleID: String?, pid: pid_t) -> Bool {
        guard let bundle = NSRunningApplication(processIdentifier: pid)?.bundleURL else {
            return fixesByTyping(bundleID: bundleID, chromium: false, electron: false)
        }
        if let known = typedLock.withLock({ typed[bundle.path] }) { return known }
        let electron = FileManager.default.fileExists(
            atPath: bundle.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
        let answer = fixesByTyping(bundleID: bundleID, chromium: AXWarmer.isChromiumBrowser(bundle), electron: electron)
        typedLock.withLock { typed[bundle.path] = answer }
        return answer
    }

    /// Put the caret back, and keep it there: Chromium applies typed text
    /// a beat after its value reads as changed, and its caret lands after
    /// the typing — over a restore made too soon (measured on Brave, a
    /// textarea and a contenteditable alike). Checked, and set again when
    /// it moved, for a quarter second.
    private static func settleCaret(_ element: AXUIElement, at wanted: NSRange) {
        select(element, wanted)
        let deadline = Date().addingTimeInterval(0.25)
        var steady = 0
        while Date() < deadline, steady < 3 {
            usleep(30_000)
            if selectedRange(element) == wanted {
                steady += 1
            } else {
                steady = 0
                select(element, wanted)
            }
        }
    }

    /// Wait, briefly, for the field to read `target` — some apps apply an
    /// accessibility write a quarter second late.
    private static func settles(_ element: AXUIElement, to target: String, within seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if AX.string(element, kAXValueAttribute as String) == target { return true }
            usleep(30_000)
        } while Date() < deadline
        return AX.string(element, kAXValueAttribute as String) == target
    }
}

/// What the editor knows about a focused field before it reads a word of
/// it: the attributes the gate decides on, gathered by `EditorAX` and
/// handed over as plain values so the decision is testable without an app.
struct EditorFieldFacts {
    var role = ""
    var subrole = ""
    var roleDescription = ""
    var description = ""
    var title = ""
    var placeholder = ""
    var bundleID: String?
    var valueSettable = false
    var rangeSettable = false
    /// An AXWebArea stands above the field. Only asked of a browser's
    /// single-line fields (`asksWhereItStands`), false elsewhere.
    var insideWebArea = false

    /// One line: a text field or a combo box. A text area (and a web
    /// contenteditable, which Chromium exposes as one) is where prose is
    /// written; a one-line field is a query, a name, a subject.
    var isSingleLine: Bool { role == "AXTextField" || role == "AXComboBox" }

    var isBrowser: Bool { AppCategory.of(bundleID: bundleID, declared: nil).kind == "browser" }

    /// Whether the gate needs to know if the field is inside a page: a
    /// browser's single-line field is the page's own, or the browser's
    /// address bar, and only its place tells which.
    var asksWhereItStands: Bool { role == "AXTextField" && isBrowser }
}

/// Which fields the editor may read.
///
/// Editable text, with three kinds left alone. A **secret** is never read.
/// A **query** is not writing: the editor marked 368 things in Raycast in
/// ten days and the hand fixed none, because a launcher's field, a search
/// box and a browser's address bar hold a few words typed to be matched, not
/// a sentence, and an underline there is noise the eye must dismiss. Browsers
/// and Harper (Automattic's checker) draw the same line: they check a
/// multi-line field and a contenteditable by default and skip a single-line
/// input unless asked. The editor is kinder than that to the single-line
/// field that is still writing (an email's subject, a form's name), since a
/// subject line is worth a mark. A **terminal's screen** is a text area
/// nobody types into through accessibility, its text and selection both
/// fixed.
///
/// What a query looks like, from what the apps say about themselves:
/// Chromium maps `<input type=search>` and role=searchbox to AXTextField
/// with subrole AXSearchField and exposes AXPlaceholderValue; its address
/// bar is a single-line AXTextField in the browser's own interface, outside
/// every AXWebArea, described as the address and search bar. Which of these
/// a live Raycast or omnibox answers is unverified here; the gate refuses
/// on any of them.
enum EditorFieldGate {
    enum Reason: Equatable {
        case notText, secure, launcher, search, comboBox, addressBar, notEditable
    }

    enum Verdict: Equatable {
        case read
        case refused(Reason)
    }

    /// Apps whose only field is a query, by bundle id (lowercased, as
    /// `EditorController.neverReadBundles` is).
    static let launchers: Set<String> = [
        "com.raycast.macos", "com.runningwithcrayons.alfred", "com.apple.spotlight", "at.obdev.launchbar",
    ]

    static func refusesApp(_ bundleID: String?) -> Bool {
        bundleID.map { launchers.contains($0.lowercased()) } ?? false
    }

    private static let editableRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]

    /// A name that says the field is a search: "search" opening a word, so
    /// "Search or enter address" and "Address and search bar" are searches
    /// and "research" is not.
    static func namesSearch(_ names: [String]) -> Bool {
        names.contains { $0.range(of: "\\bsearch", options: [.regularExpression, .caseInsensitive]) != nil }
    }

    static func verdict(_ facts: EditorFieldFacts) -> Verdict {
        guard editableRoles.contains(facts.role) else { return .refused(.notText) }
        let kind = facts.roleDescription.lowercased()
        if facts.subrole == "AXSecureTextField" || kind.contains("secure") || kind.contains("password") {
            return .refused(.secure)
        }
        if refusesApp(facts.bundleID) { return .refused(.launcher) }
        if facts.role == "AXComboBox" { return .refused(.comboBox) }
        if facts.subrole == "AXSearchField" { return .refused(.search) }
        // A name is read on single-line fields only: a text area called
        // "Message to #search-team" is a message.
        if facts.isSingleLine,
           namesSearch([facts.roleDescription, facts.description, facts.title, facts.placeholder]) {
            return .refused(.search)
        }
        if facts.asksWhereItStands, !facts.insideWebArea { return .refused(.addressBar) }
        guard facts.valueSettable || facts.rangeSettable else { return .refused(.notEditable) }
        return .read
    }
}

/// The last few fields whose place was worked out, compared the way
/// `EditorField.isSame` compares: a new reference to the same node is
/// equal. Only an answer the walk was sure of is kept.
struct PlaceMemory {
    private var seen: [(element: AXUIElement, inside: Bool)] = []
    static let capacity = 8

    mutating func answer(for element: AXUIElement, walk: () -> Bool?) -> Bool {
        if let known = seen.first(where: { CFEqual($0.element, element) }) { return known.inside }
        guard let inside = walk() else { return false }
        seen.append((element, inside))
        if seen.count > Self.capacity { seen.removeFirst() }
        return inside
    }
}

/// When to read the field: the moment the app says something changed —
/// the text, the caret, the focus, a window's place — rather than on a
/// clock. One observer, on the frontmost app, moved when another app comes
/// forward. The editor keeps a slow beat besides for apps that say
/// nothing; this is what lets that beat be slow.
///
/// The observer is made on the main thread and delivers there (it only
/// asks for a read); every registration messages the app, so those run
/// on the editor's queue under its timeout.
final class EditorWatch {
    /// What the app announced — a notification's name, or "activated"
    /// when another app came forward.
    var changed: (String) -> Void = { _ in }
    private var observer: AppObserver?
    private var activation: NSObjectProtocol?
    private let queue: DispatchQueue

    /// What the app is asked to announce. Registered on the application
    /// element, they arrive for every element in it.
    static let notifications = [
        kAXFocusedUIElementChangedNotification, kAXValueChangedNotification,
        kAXSelectedTextChangedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
    ]

    init(queue: DispatchQueue = EditorAX.queue) { self.queue = queue }

    func start() {
        guard activation == nil else { return }
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.watch(app?.processIdentifier)
            self?.changed("activated")
        }
        watch(NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    func stop() {
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
        observer?.invalidate()
        observer = nil
    }

    private func watch(_ pid: pid_t?) {
        guard let pid, pid != getpid(), pid != observer?.pid else { return }
        observer?.invalidate()
        guard let observer = AppObserver(pid: pid, handler: { [weak self] name, _ in self?.changed(name) }) else {
            self.observer = nil
            return
        }
        self.observer = observer
        queue.async {
            EditorAX.wake(pid)
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, EditorAX.timeout)
            for name in Self.notifications { observer.watch(name, on: app) }
        }
    }
}
