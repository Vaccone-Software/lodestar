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
    /// through untouched.
    static func type(_ text: String, to pid: pid_t) {
        let units = Array(text.utf16)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            event.setIntegerValueField(.eventSourceUserData, value: SelectController.ownMark)
            event.postToPid(pid)
            usleep(15_000)
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
    private static let systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }()

    private static let editableRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]

    // MARK: - Reading

    /// The focused field, if it is one the editor may read: editable, not a
    /// password, not a search box, not Lodestar's own glass.
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
        AXUIElementSetMessagingTimeout(element, timeout)
        // Rich web editors focus a node inside the field; Chromium names
        // the field itself.
        if let ancestor = AX.element(element, "AXEditableAncestor") {
            element = ancestor
            AXUIElementSetMessagingTimeout(element, timeout)
        }
        guard isReadable(role: AX.string(element, kAXRoleAttribute as String) ?? "",
                         subrole: AX.string(element, kAXSubroleAttribute as String) ?? "",
                         valueSettable: settable(element, kAXValueAttribute as String),
                         rangeSettable: settable(element, kAXSelectedTextRangeAttribute as String))
        else { return nil }
        guard let text = AX.string(element, kAXValueAttribute as String) else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        var field = EditorField(element: element, pid: pid, appName: app?.localizedName ?? "",
                                bundleID: app?.bundleIdentifier, text: text)
        if let selection = selectedRange(element), selection.length == 0 { field.caret = selection.location }
        field.frame = frame(of: element)
        if let window = AX.element(element, kAXWindowAttribute as String) { field.windowFrame = frame(of: window) }
        return field
    }

    /// Which fields the editor may read: editable text, never a password,
    /// never a search box, never a terminal's screen — a text area nobody
    /// types into through accessibility, its text and selection both fixed.
    static func isReadable(role: String, subrole: String, valueSettable: Bool, rangeSettable: Bool) -> Bool {
        guard editableRoles.contains(role) else { return false }
        guard subrole != "AXSecureTextField", subrole != "AXSearchField" else { return false }
        return valueSettable || rangeSettable
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
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    @discardableResult
    static func select(_ element: AXUIElement, _ range: NSRange) -> Bool {
        var cf = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cf) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    // MARK: - Waking Chromium

    private static let wakeLock = NSLock()
    nonisolated(unsafe) private static var wokenAt: [pid_t: Date] = [:]
    nonisolated(unsafe) private static var browserBundles: [String: Bool] = [:]

    /// Ask an app to build the tree of its pages' fields. Electron apps
    /// answer `AXManualAccessibility` (the warmer's flag). Chromium
    /// browsers do not: measured on Brave (2026-09-24), that flag is
    /// refused (-25205) and the window keeps 51 nodes and no web area,
    /// while `AXEnhancedUserInterface` — the flag VoiceOver sets — builds
    /// the page at once. So a browser gets that one. Its only side effect
    /// the window mover already handles (it drops the flag around a move).
    /// Throttled per app to one ask a half minute, like the warmer.
    static func wake(_ pid: pid_t) {
        AXWarmer.warm(pid)
        let now = Date()
        let due: Bool = wakeLock.withLock {
            wokenAt = wokenAt.filter { now.timeIntervalSince($0.value) < 30 }
            guard wokenAt[pid] == nil else { return false }
            wokenAt[pid] = now
            return true
        }
        guard due, let bundle = NSRunningApplication(processIdentifier: pid)?.bundleURL,
              isChromiumBrowser(bundle) else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    /// A Chromium browser: renderer helpers inside its frameworks, and no
    /// Electron framework (Electron apps answer the warmer's flag).
    static func isChromiumBrowser(_ bundle: URL) -> Bool {
        if let known = wakeLock.withLock({ browserBundles[bundle.path] }) { return known }
        let frameworks = bundle.appendingPathComponent("Contents/Frameworks")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: frameworks.path)) ?? []
        var chromium = false
        if !names.contains("Electron Framework.framework") {
            for name in names where name.hasSuffix(" Framework.framework") {
                let versions = frameworks.appendingPathComponent(name).appendingPathComponent("Versions")
                for version in (try? FileManager.default.contentsOfDirectory(atPath: versions.path)) ?? [] {
                    let helpers = versions.appendingPathComponent(version).appendingPathComponent("Helpers")
                    let apps = (try? FileManager.default.contentsOfDirectory(atPath: helpers.path)) ?? []
                    if apps.contains(where: { $0.hasSuffix("Helper (Renderer).app") }) { chromium = true }
                }
            }
        }
        wakeLock.withLock { browserBundles[bundle.path] = chromium }
        return chromium
    }

    // MARK: - Geometry

    private static func bounds(_ element: AXUIElement, _ range: NSRange) -> CGRect? {
        var cf = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cf) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &out) == .success,
              let raw = out, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(raw as! AXValue, .cgRect, &rect), rect.width > 0, rect.height > 0 else { return nil }
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
            if let frame = field.frame, !frame.insetBy(dx: -2, dy: -2).contains(rect) { return nil }
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
    /// one road their own editors and undo understand.
    static func replace(_ range: NSRange, expected: String, with text: String, in field: EditorField,
                        post: (String) -> Void) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let current = AX.string(field.element, kAXValueAttribute as String),
              stillReads(current, range: range, expected: expected) else { return false }
        let ns = current as NSString
        let before = selectedRange(field.element)
        let target = ns.replacingCharacters(in: range, with: text)
        guard select(field.element, range) else { return false }
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
        // The caret goes back where it was, moved by the change in length
        // when it stood after the fix.
        if let before {
            settleCaret(field.element, at: restoredCaret(before: before, fixed: range,
                                                         replacementLength: (text as NSString).length))
        }
        return true
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
