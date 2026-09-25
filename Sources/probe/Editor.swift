import AppKit
import Vision
import LodestarCore

// MARK: - The editor's questions

/// Can Lodestar be an editor across the Mac? Before a line of the feature
/// exists, each app's text fields have to answer five questions:
///
/// 1. Is the text readable — the whole value, not just what is on screen?
/// 2. Are word rectangles *true*: does `AXBoundsForRange` land on the
///    word as drawn? Checked by photographing the window and reading each
///    rectangle back with OCR, not by trusting the numbers.
/// 3. Can one word be replaced without touching the rest — and does the
///    formatting around it survive?
/// 4. Does ⌘Z in the app take the replacement back?
/// 5. Does the app announce changes, so the editor can listen rather than
///    poll?
///
/// `survey` is read-only across every running app. `field` works on one
/// field, and writes only with `--write`: it replaces the field's text
/// with a probe sentence, measures, and puts the original back. Nothing
/// here ever sends a key that submits — no return, ever.
func runEditor(_ args: inout [String]) {
    requireTrust()
    guard !args.isEmpty else { fail("usage: probe editor survey | field <app> [flags]") }
    switch args.removeFirst() {
    case "survey": editorSurvey(&args)
    case "field": editorField(&args)
    case "residency": editorResidency(&args)
    case "bench": editorBench(&args)
    case let other: fail("probe editor: unknown subcommand '\(other)'")
    }
}

/// Field contents are shown only for the probe's own test targets; for a
/// real app's field only the length and whether the probe text is in it.
nonisolated(unsafe) var showsContents = false
func shown(_ text: String) -> String {
    showsContents || (text.hasPrefix("Lodestar probe") && (text as NSString).length < 200)
        ? text.prefix(90).debugDescription
        : "\((text as NSString).length) chars\(text.contains("Lodestar probe") ? ", probe text present" : "")"
}

private let editableRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"]
let editorProbeText = "Lodestar probe: Their going to recieve the files from Ghostty tomorrow, its fine."

private func settable(_ element: AXUIElement, _ attribute: String) -> Bool {
    var flag: DarwinBoolean = false
    guard AXUIElementIsAttributeSettable(element, attribute as CFString, &flag) == .success else { return false }
    return flag.boolValue
}

private func parameterized(_ element: AXUIElement, _ attribute: String, _ location: Int, _ length: Int) -> CFTypeRef? {
    var range = CFRange(location: location, length: length)
    guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
    var out: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &out) == .success
    else { return nil }
    return out
}

private func bounds(_ element: AXUIElement, _ range: NSRange) -> CGRect? {
    guard let raw = parameterized(element, kAXBoundsForRangeParameterizedAttribute as String,
                                  range.location, range.length),
          CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    var rect = CGRect.zero
    guard AXValueGetValue(raw as! AXValue, .cgRect, &rect) else { return nil }
    return rect
}

private func selectedRange(_ element: AXUIElement) -> CFRange? {
    guard let raw = AX.copy(element, kAXSelectedTextRangeAttribute as String),
          CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    var range = CFRange()
    guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { return nil }
    return range
}

private func visibleRange(_ element: AXUIElement) -> CFRange? {
    guard let raw = AX.copy(element, kAXVisibleCharacterRangeAttribute as String),
          CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    var range = CFRange()
    guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { return nil }
    return range
}

@discardableResult
private func select(_ element: AXUIElement, _ range: NSRange) -> AXError {
    var cf = CFRange(location: range.location, length: range.length)
    guard let value = AXValueCreate(.cfRange, &cf) else { return .failure }
    return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
}

/// The font name at each character run, from the attributed string the
/// field exposes — nil when it exposes none. The question is whether a
/// code span or a bold name can be told apart, and whether a fix keeps it.
private func fontRuns(_ element: AXUIElement, length: Int) -> [(NSRange, String)]? {
    guard length > 0,
          let raw = parameterized(element, kAXAttributedStringForRangeParameterizedAttribute as String, 0, length),
          CFGetTypeID(raw) == CFAttributedStringGetTypeID() else { return nil }
    let attributed = raw as! NSAttributedString
    var runs: [(NSRange, String)] = []
    attributed.enumerateAttribute(NSAttributedString.Key("AXFont"),
                                  in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
        let name = (value as? [String: Any])?["AXFontName"] as? String ?? "–"
        runs.append((range, name))
    }
    return runs
}

private func fontName(at location: Int, in runs: [(NSRange, String)]?) -> String {
    runs?.first { NSLocationInRange(location, $0.0) }?.1 ?? "–"
}

private func parameterized(_ element: AXUIElement, _ attribute: String, _ parameter: CFTypeRef) -> CFTypeRef? {
    var out: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &out) == .success
    else { return nil }
    return out
}

/// Words by Chromium's text markers — the route rich web editors need,
/// where `AXBoundsForRange` answers nothing. Steps word end to word end,
/// asking each word's string and rectangle.
private func markerWords(_ element: AXUIElement, limit: Int = 200) -> [(String, CGRect?)] {
    guard let whole = parameterized(element, "AXTextMarkerRangeForUIElement", element),
          CFGetTypeID(whole) == AXTextMarkerRangeGetTypeID() else { return [] }
    let range = whole as! AXTextMarkerRange
    let end = AXTextMarkerRangeCopyEndMarker(range)
    var cursor: CFTypeRef = AXTextMarkerRangeCopyStartMarker(range)
    var words: [(String, CGRect?)] = []
    // The field's own text bounds the walk: word stepping does not stop at
    // an element's edge, and past it lies the rest of the page.
    let own = (AX.string(element, kAXValueAttribute as String) ?? "") as NSString
    var searchFrom = 0
    while words.count < limit {
        guard let wordEnd = parameterized(element, "AXNextWordEndTextMarkerForTextMarker", cursor),
              !CFEqual(wordEnd, cursor),
              let wordStart = parameterized(element, "AXPreviousWordStartTextMarkerForTextMarker", wordEnd),
              let span = parameterized(element, "AXTextMarkerRangeForUnorderedTextMarkers", [wordStart, wordEnd] as CFArray)
        else { break }
        let text = parameterized(element, "AXStringForTextMarkerRange", span) as? String ?? ""
        var rect: CGRect?
        if let raw = parameterized(element, "AXBoundsForTextMarkerRange", span), CFGetTypeID(raw) == AXValueGetTypeID() {
            var r = CGRect.zero
            if AXValueGetValue(raw as! AXValue, .cgRect, &r) { rect = r }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let found = own.range(of: trimmed, range: NSRange(location: searchFrom, length: own.length - searchFrom))
            guard found.location != NSNotFound else { break }
            searchFrom = found.location + found.length
            words.append((text, rect))
        }
        cursor = wordEnd
        if CFEqual(wordEnd, end) { break }
    }
    return words
}

/// Words by hit-testing: where an editor answers every range with the
/// whole line's rectangle, sweep points along the line and ask which
/// character each one lands on — the reverse question, which it answers
/// per character. Returns a rectangle per word, in the field's own text.
private func hitTestWords(_ element: AXUIElement, line: CGRect, text: NSString) -> [(String, CGRect?)] {
    guard let whole = parameterized(element, "AXTextMarkerRangeForUIElement", element),
          CFGetTypeID(whole) == AXTextMarkerRangeGetTypeID() else { return [] }
    let start = AXTextMarkerRangeCopyStartMarker(whole as! AXTextMarkerRange)
    // x of the left edge where each character offset begins.
    var edges: [Int: CGFloat] = [:]
    var x = line.minX
    let y = line.midY
    while x <= line.maxX + 2 {
        var point = CGPoint(x: x, y: y)
        if let value = AXValueCreate(.cgPoint, &point),
           let marker = parameterized(element, "AXTextMarkerForPosition", value),
           let span = parameterized(element, "AXTextMarkerRangeForUnorderedTextMarkers", [start, marker] as CFArray),
           let length = parameterized(element, "AXLengthForTextMarkerRange", span) as? Int {
            if edges[length] == nil { edges[length] = x }
        }
        x += 2
    }
    var words: [(String, CGRect?)] = []
    text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byWords) { word, range, _, _ in
        guard let word else { return }
        // The first sample at or past each boundary gives its x.
        let left = edges.filter { $0.key >= range.location }.min { $0.key < $1.key }?.value
        let right = edges.filter { $0.key >= range.location + range.length }.min { $0.key < $1.key }?.value
        if let left, let right, right > left {
            words.append((word, CGRect(x: left, y: line.minY, width: right - left, height: line.height)))
        } else {
            words.append((word, nil))
        }
    }
    return words
}

/// Words by text node: rich editors split a field into static-text
/// descendants, and where the field answers a range with the whole line,
/// each node still answers ranges of its own text exactly. The nodes are
/// found in order and placed in the field's text by their contents.
private func nodeWords(_ element: AXUIElement, text: NSString) -> [(String, CGRect?)]? {
    var nodes: [(AXUIElement, NSString)] = []
    var budget = 400
    walk(element, budget: &budget) { node, role in
        if role == "AXStaticText", let value = AX.string(node, kAXValueAttribute as String), !value.isEmpty {
            nodes.append((node, value as NSString))
        }
        return true
    }
    guard !nodes.isEmpty else { return nil }
    // Global offset of each node's text within the field's value.
    var placed: [(AXUIElement, NSRange)] = []
    var searchFrom = 0
    for (node, value) in nodes {
        let found = text.range(of: value as String, range: NSRange(location: searchFrom, length: text.length - searchFrom))
        guard found.location != NSNotFound else { continue }
        placed.append((node, found))
        searchFrom = found.location + found.length
    }
    var words: [(String, CGRect?)] = []
    text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byWords) { word, range, _, _ in
        guard let word else { return }
        guard let (node, span) = placed.first(where: { NSLocationInRange(range.location, $0.1) }),
              range.location + range.length <= span.location + span.length else { words.append((word, nil)); return }
        words.append((word, bounds(node, NSRange(location: range.location - span.location, length: range.length))))
    }
    return words
}

/// WebKit's and Chromium's one-call edit: replace a character range with
/// text, the way an assistive app is meant to. The parameter is the
/// range and the string, in that order.
private func replaceRange(_ element: AXUIElement, _ range: NSRange, with text: String) -> Bool {
    var cf = CFRange(location: range.location, length: range.length)
    guard let value = AXValueCreate(.cfRange, &cf) else { return false }
    return parameterized(element, "AXReplaceRangeWithText", [value, text as CFString] as CFArray) != nil
        || (AX.string(element, kAXValueAttribute as String) ?? "").contains(text)
}

private func milliseconds(_ body: () -> Void) -> Double {
    let start = Date()
    body()
    return Date().timeIntervalSince(start) * 1000
}

private func app(named name: String) -> (NSRunningApplication, AXUIElement) {
    guard let running = NSWorkspace.shared.runningApplications.first(where: {
        $0.activationPolicy == .regular && ($0.localizedName ?? "").localizedCaseInsensitiveContains(name)
    }) else { fail("no running app matching '\(name)'") }
    let element = AXUIElementCreateApplication(running.processIdentifier)
    AXUIElementSetMessagingTimeout(element, 1.0)
    // Chromium and Electron build their tree only for a client that asks.
    AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    usleep(400_000)
    return (running, element)
}

private func walk(_ element: AXUIElement, depth: Int = 0, budget: inout Int,
                  visit: (AXUIElement, String) -> Bool) {
    guard depth <= 40, budget > 0 else { return }
    budget -= 1
    let role = AX.string(element, kAXRoleAttribute as String) ?? "?"
    if !visit(element, role) { budget = 0; return }
    guard let children = AX.elements(element, kAXChildrenAttribute as String) else { return }
    for child in children.prefix(80) { walk(child, depth: depth + 1, budget: &budget, visit: visit) }
}

// MARK: - survey

private func editorSurvey(_ args: inout [String]) {
    let only = value(of: "--app", in: &args)
    print(String(format: "%-18@ %-12@ %-8@ %6@ %5@ %5@ %5@ %5@ %5@ %5@ %4@",
                 "app" as NSString, "role" as NSString, "subrole" as NSString, "chars" as NSString,
                 "read" as NSString, "setV" as NSString, "setR" as NSString, "setT" as NSString,
                 "rect" as NSString, "attr" as NSString, "vis" as NSString))
    for running in NSWorkspace.shared.runningApplications where running.activationPolicy == .regular {
        let name = running.localizedName ?? "?"
        if let only, !name.localizedCaseInsensitiveContains(only) { continue }
        let application = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 1.0)
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        usleep(300_000)
        guard let windows = AX.elements(application, kAXWindowsAttribute as String) else { continue }
        var seen = 0
        var budget = 6000
        for window in windows.prefix(3) {
            walk(window, budget: &budget) { element, role in
                guard editableRoles.contains(role) else { return true }
                let subrole = AX.string(element, kAXSubroleAttribute as String) ?? "–"
                let chars = AX.int(element, kAXNumberOfCharactersAttribute as String) ?? -1
                let text = AX.string(element, kAXValueAttribute as String)
                let readable = text.map { ($0 as NSString).length == chars || chars < 0 } ?? false
                let rect = chars > 0 ? bounds(element, NSRange(location: 0, length: min(3, chars))) : nil
                let attributed = chars > 0 && parameterized(
                    element, kAXAttributedStringForRangeParameterizedAttribute as String, 0, min(3, chars)) != nil
                print(String(format: "%-18@ %-12@ %-8@ %6d %5@ %5@ %5@ %5@ %5@ %5@ %4@",
                             String(name.prefix(18)) as NSString, role as NSString,
                             String(subrole.replacingOccurrences(of: "AX", with: "").prefix(8)) as NSString, chars,
                             (readable ? "yes" : "NO") as NSString,
                             (settable(element, kAXValueAttribute as String) ? "yes" : "no") as NSString,
                             (settable(element, kAXSelectedTextRangeAttribute as String) ? "yes" : "no") as NSString,
                             (settable(element, kAXSelectedTextAttribute as String) ? "yes" : "no") as NSString,
                             (chars > 0 ? ((rect?.width ?? 0) > 0 ? "yes" : "NO") : "–") as NSString,
                             (chars > 0 ? (attributed ? "yes" : "no") : "–") as NSString,
                             (visibleRange(element) != nil ? "yes" : "no") as NSString))
                seen += 1
                return seen < 12
            }
        }
    }
}

// MARK: - field

private final class NotificationLog {
    var seen: [(String, Date)] = []
}

private func editorField(_ args: inout [String]) {
    let write = has("--write", in: &args)
    let undo = has("--undo", in: &args)
    let notify = has("--notify", in: &args)
    let long = has("--long", in: &args)
    // Fix a word already in the field and put it back, never replacing
    // the text: the only honest test of whether formatting survives.
    let inPlace = has("--in-place", in: &args)
    let typeFix = has("--type", in: &args)
    let printRects = has("--rects", in: &args)
    let hold = has("--hold", in: &args)
    let typeWrite = has("--typewrite", in: &args)
    // Type the probe text key by key with real space keys, the way undo
    // checkpoints in web editors expect it.
    let perKey = has("--perkey", in: &args)
    // After the fix, put the caret back where the hand was — the end of
    // the text, moved by the fix's change in length — and check it held.
    let restoreCaret = has("--restore-caret", in: &args)
    // Some apps apply AX edits late (Outlook: ~240 ms); wait this long before reading back.
    let settleMs = value(of: "--settle", in: &args).flatMap(Int.init) ?? 200   // write the probe text by typing, as a hand would   // leave the probe text in place, for inspection
    let marker = value(of: "--find", in: &args)
    // The first multi-line field in the front window — for an empty
    // composer, which has no text to find it by.
    let first = has("--first", in: &args)
    // With --first: only a field whose placeholder holds this text — the
    // guard that a chat composer is the one intended, before any write.
    let placeholderMust = value(of: "--placeholder", in: &args)
    let identifier = value(of: "--ident", in: &args)   // a field by its AXIdentifier
    let imagePath = value(of: "--image", in: &args)
    let text = value(of: "--text", in: &args) ?? editorProbeText
    let fix = value(of: "--fix", in: &args) ?? "recieve=receive"
    guard let appName = args.first else { fail("usage: probe editor field <app> [--find text] [--write] ...") }
    let (running, application) = app(named: appName)
    let name = running.localizedName ?? appName
    showsContents = ["TextEdit", "Brave Browser"].contains(name)

    // The field: one holding the marker, else the app's focused element.
    var field: AXUIElement?
    if let marker {
        var budget = 8000
        if let windows = AX.elements(application, kAXWindowsAttribute as String) {
            for window in windows.prefix(12) where field == nil {
                walk(window, budget: &budget) { element, role in
                    guard editableRoles.contains(role),
                          (AX.string(element, kAXValueAttribute as String) ?? "").contains(marker) else { return true }
                    field = element
                    return false
                }
            }
        }
    } else if let identifier {
        var budget = 8000
        if let window = AX.element(application, kAXFocusedWindowAttribute as String) {
            walk(window, budget: &budget) { element, _ in
                guard AX.string(element, "AXIdentifier") == identifier else { return true }
                field = element
                return false
            }
        }
    } else if first {
        var budget = 8000
        if let window = AX.element(application, kAXFocusedWindowAttribute as String)
            ?? AX.elements(application, kAXWindowsAttribute as String)?.first {
            walk(window, budget: &budget) { element, role in
                guard role == "AXTextArea", settable(element, kAXValueAttribute as String) else { return true }
                if let placeholderMust {
                    let label = (AX.string(element, "AXPlaceholderValue") ?? "") + " " + (AX.string(element, kAXDescriptionAttribute as String) ?? "")
                    guard label.localizedCaseInsensitiveContains(placeholderMust) else { return true }
                }
                field = element
                return false
            }
        }
    } else if let focused = AX.element(application, kAXFocusedUIElementAttribute as String) {
        field = focused
    }
    guard let field else { fail("\(name): no field found\(marker.map { " holding '\($0)'" } ?? "")") }
    let role = AX.string(field, kAXRoleAttribute as String) ?? "?"
    let subrole = AX.string(field, kAXSubroleAttribute as String) ?? "–"
    let placeholder = AX.string(field, "AXPlaceholderValue") ?? AX.string(field, kAXDescriptionAttribute as String) ?? ""
    print("\(name) · \(role) \(subrole)\(placeholder.isEmpty ? "" : " · \"\(placeholder.prefix(60))\"")")
    if has("--dump", in: &args) {
        var names: CFArray?
        _ = AXUIElementCopyParameterizedAttributeNames(field, &names)
        print("parameterized: \(((names as? [String]) ?? []).joined(separator: " "))")
        var plain: CFArray?
        _ = AXUIElementCopyActionNames(field, &plain)
        print("actions: \(((plain as? [String]) ?? []).joined(separator: " "))")
        let length = AX.int(field, kAXNumberOfCharactersAttribute as String) ?? 0
        if length > 0, let raw = parameterized(field, kAXAttributedStringForRangeParameterizedAttribute as String, 0, length),
           CFGetTypeID(raw) == CFAttributedStringGetTypeID() {
            let attributed = raw as! NSAttributedString
            attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attrs, range, _ in
                let text = (attributed.string as NSString).substring(with: range)
                print("  run \(showsContents || text.contains("Lodestar") ? text.prefix(24).debugDescription : "\((text as NSString).length) chars"): \(attrs.keys.map(\.rawValue).sorted().joined(separator: ","))"
                      + (attrs[NSAttributedString.Key("AXFont")].map { " font=\($0)" }?.replacingOccurrences(of: "\n", with: " ") ?? ""))
            }
        }
        if let children = AX.elements(field, kAXChildrenAttribute as String) {
            print("children: \(children.prefix(8).map { AX.string($0, kAXRoleAttribute as String) ?? "?" }.joined(separator: " "))")
        }
    }
    if subrole == "AXSecureTextField" {
        print("secure field: value \(AX.string(field, kAXValueAttribute as String).map { "readable (\($0.count))" } ?? "unreadable") — the editor never reads these")
        return
    }

    // Typing needs the field to hold the app's focus, so bring it forward
    // now — before the probe text is written — and put things back after.
    let startedFront = NSWorkspace.shared.frontmostApplication
    if typeFix {
        bringForward(running)
        usleep(500_000)
        AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        usleep(250_000)
        print("focus: \(holdsFocus(field, pid: running.processIdentifier, explain: true) ? "the probe field holds it" : "NOT held — typing will be skipped")")
    }
    defer { if typeFix { bringForward(startedFront) } }

    var original = ""
    var readMs = milliseconds { original = AX.string(field, kAXValueAttribute as String) ?? "" }
    print(String(format: "read value: %d chars in %.1f ms", (original as NSString).length, readMs))

    func setText(_ value: String) -> String {
        var how = "AXValue"
        var error = AXError.success
        if !(typeWrite && typeFix) {
            error = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, value as CFString)
        }
        if !(typeWrite && typeFix), error != .success || (AX.string(field, kAXValueAttribute as String) ?? "") != value {
            how = "select-all + AXSelectedText"
            let length = AX.int(field, kAXNumberOfCharactersAttribute as String)
                ?? ((AX.string(field, kAXValueAttribute as String) ?? "") as NSString).length
            select(field, NSRange(location: 0, length: length))
            error = AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, value as CFString)
        }
        var now = AX.string(field, kAXValueAttribute as String) ?? ""
        if now != value, typeFix, holdsFocus(field, pid: running.processIdentifier) {
            // Editors that ignore AX writes still take typing: select all
            // with ⌘A, then type the text, or delete when it is empty.
            how = "⌘A + typed"
            postKey(0, flags: .maskCommand, to: running.processIdentifier)      // ⌘A
            usleep(150_000)
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { postKey(51, flags: [], to: running.processIdentifier) }
            else if perKey { typeKeys(value, to: running.processIdentifier) }
            else { typeText(value, to: running.processIdentifier) }
            usleep(400_000)
            now = AX.string(field, kAXValueAttribute as String) ?? ""
            // Editors keep a trailing newline of their own; compare the text.
            if now.trimmingCharacters(in: .whitespacesAndNewlines) == value { return how }
        }
        return now == value ? how : "FAILED (\(how), AXError \(error.rawValue), now \(shown(now)))"
    }

    var current = original
    if write {
        let body = long ? (1...80).map { "Line \($0) of the long probe, recieve here." }.joined(separator: "\n") : text
        print("write probe text: \(setText(body))")
        // A pause, as between a hand's typing and a fix: apps close an
        // undo group after a moment, and the fix must be its own step.
        usleep(typeWrite ? 1_500_000 : 300_000)
        current = AX.string(field, kAXValueAttribute as String) ?? ""
    }
    let ns = current as NSString
    guard ns.length > 0 else {
        print("field is empty — nothing to measure (use --write)")
        return
    }

    // Geometry: every word's rectangle, then the photograph that checks it.
    var words: [(String, NSRange)] = []
    ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { word, range, _, _ in
        if let word { words.append((word, range)) }
    }
    if long { words = Array(words.suffix(12)) }
    var rects: [CGRect?] = []
    var boundsMs: [Double] = []
    for (_, range) in words {
        var rect: CGRect?
        boundsMs.append(milliseconds { rect = bounds(field, range) })
        rects.append(rect)
    }
    var usable = rects.filter { ($0?.width ?? 0) > 0 && ($0?.height ?? 0) > 0 }.count
    var viaMarkers = false
    if usable == 0 {
        var marked: [(String, CGRect?)] = []
        let walkMs = milliseconds { marked = markerWords(field) }
        if !marked.isEmpty {
            viaMarkers = true
            words = marked.map { ($0.0, NSRange(location: NSNotFound, length: 0)) }
            rects = marked.map(\.1)
            usable = rects.filter { ($0?.width ?? 0) > 0 }.count
            print(String(format: "text markers: %d words walked in %.1f ms (%.2f ms per word)",
                         marked.count, walkMs, walkMs / Double(marked.count)))
            let distinct = Set(rects.compactMap { $0.map { "\($0)" } })
            if distinct.count == 1, marked.count > 1 {
                // One rectangle for every word: the editor answers per block.
                // Ask the text nodes inside it instead.
                var byNode: [(String, CGRect?)]?
                let nodeMs = milliseconds { byNode = nodeWords(field, text: ns) }
                if let byNode {
                    words = byNode.map { ($0.0, NSRange(location: NSNotFound, length: 0)) }
                    rects = byNode.map(\.1)
                    usable = rects.filter { ($0?.width ?? 0) > 0 }.count
                    print(String(format: "every marker rect was the whole line → text nodes: %d/%d words placed in %.1f ms",
                                 usable, byNode.count, nodeMs))
                }
            }
            if false, let line = rects.first ?? nil, marked.count > 1 {
                // One rectangle for every word: the editor answers per block.
                var hit: [(String, CGRect?)] = []
                let hitMs = milliseconds { hit = hitTestWords(field, line: line, text: ns) }
                words = hit.map { ($0.0, NSRange(location: NSNotFound, length: 0)) }
                rects = hit.map(\.1)
                usable = rects.filter { ($0?.width ?? 0) > 0 }.count
                print(String(format: "every marker rect was the whole line → hit-testing: %d/%d words placed in %.1f ms",
                             usable, hit.count, hitMs))
            }
        }
    }
    if printRects {
        for ((word, _), rect) in zip(words, rects) {
            print("  \(word.padding(toLength: 12, withPad: " ", startingAt: 0)) \(rect.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "nil")")
        }
        let distinct = Set(rects.compactMap { $0.map { "\($0)" } }).count
        print("distinct rects: \(distinct) of \(rects.count)")
    }
    let mean = boundsMs.reduce(0, +) / Double(max(1, boundsMs.count))
    print(String(format: "word rects%@: %d/%d usable · %.2f ms mean, %.2f ms max per word (AXBoundsForRange)",
                 viaMarkers ? " via text markers" : "", usable, words.count, mean, boundsMs.max() ?? 0))

    let window = AX.element(field, kAXWindowAttribute as String)
    let windowFrame = window.flatMap { w -> CGRect? in
        guard let p = AX.point(w, kAXPositionAttribute as String),
              let s = AX.size(w, kAXSizeAttribute as String) else { return nil }
        return CGRect(origin: p, size: s)
    }
    if long, let last = rects.last ?? nil, let windowFrame {
        let vis = visibleRange(field)
        print("long text: last word rect \(Int(last.minX)),\(Int(last.minY)) \(windowFrame.intersects(last) ? "INSIDE" : "outside") the window"
              + " · visible range \(vis.map { "\($0.location)..<\($0.location + $0.length)" } ?? "unsupported")")
    }

    // The field's own frame: a word whose rectangle falls outside it is
    // scrolled out of view, and its mark must not be drawn.
    let fieldFrame: CGRect? = {
        guard let p = AX.point(field, kAXPositionAttribute as String),
              let z = AX.size(field, kAXSizeAttribute as String) else { return nil }
        return CGRect(origin: p, size: z)
    }()
    if let fieldFrame {
        let inside = rects.compactMap { $0 }.filter { fieldFrame.insetBy(dx: -2, dy: -2).contains($0) }.count
        let vis = visibleRange(field)
        print("field frame \(Int(fieldFrame.width))×\(Int(fieldFrame.height)): \(inside)/\(rects.compactMap { $0 }.count) word rects inside it"
              + " · visible character range \(vis.map { "\($0.location)..<\($0.location + $0.length)" } ?? "unsupported")")
    }
    if let window, let windowFrame, let id = windowID(of: window) {
        if !CGPreflightScreenCaptureAccess() {
            print("geometry check skipped: no Screen Recording permission for this shell")
        } else if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, id,
                                                      [.boundsIgnoreFraming, .bestResolution]) {
            let scale = CGFloat(image.width) / windowFrame.width
            var matched = 0
            var checked = 0
            var misses: [String] = []
            for ((word, _), rect) in zip(words, rects) {
                guard let rect, rect.width > 0, word.count >= 2 else { continue }
                if let fieldFrame, !fieldFrame.insetBy(dx: -2, dy: -2).contains(rect) { continue }
                checked += 1
                let local = rect.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY)
                let padded = CGRect(x: local.minX * scale - 4, y: local.minY * scale - 3,
                                    width: local.width * scale + 8, height: local.height * scale + 6)
                let canvas = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
                let pixel = padded.intersection(canvas)
                guard !pixel.isEmpty, let crop = image.cropping(to: pixel.integral) else {
                    misses.append("\(word)→offscreen"); continue
                }
                let read = ocrWord(crop)
                let clean = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
                if clean(read) == clean(word) || clean(read).contains(clean(word)) { matched += 1 }
                else { misses.append("\(word)→\(read.isEmpty ? "∅" : read)") }
            }
            print("geometry check: \(matched)/\(checked) word rects read back as their word"
                  + (misses.isEmpty ? "" : showsContents || current.contains("Lodestar probe")
                     ? " · misses: \(misses.prefix(6).joined(separator: ", "))" : " · \(misses.count) misses"))
            // Captures of real apps hold private content: only a test page
            // or the probe's own document is ever written to disk.
            if let imagePath, ["Brave Browser", "TextEdit"].contains(name) {
                annotate(image, rects: rects, windowFrame: windowFrame, scale: scale, path: imagePath)
            }
        }
    }

    // Fonts: can a name or a code span be told apart, and does a fix keep them?
    let runsBefore = fontRuns(field, length: ns.length)
    if let runsBefore {
        let fonts = Set(runsBefore.map(\.1))
        print("attributed text: \(runsBefore.count) runs · fonts \(fonts.sorted().joined(separator: ", "))")
    } else {
        print("attributed text: unsupported")
    }

    // Write-back: one word, through the selection.
    let parts = fix.split(separator: "=").map(String.init)
    if write || inPlace, parts.count == 2, case let target = ns.range(of: parts[0]), target.location != NSNotFound {
        let beforeSelection = selectedRange(field)
        var selectError = AXError.success, replaceError = AXError.success
        let selectMs = milliseconds { selectError = select(field, target) }
        let selectedNow = AX.string(field, kAXSelectedTextAttribute as String) ?? ""
        let replaceMs = milliseconds {
            replaceError = AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, parts[1] as CFString)
        }
        usleep(useconds_t(settleMs * 1000))
        var after = AX.string(field, kAXValueAttribute as String) ?? ""
        let expected = ns.replacingCharacters(in: target, with: parts[1])
        if after != expected, typeFix {
            // Select through AX, then type the replacement as keystrokes —
            // only while the field itself holds the app's focus.
            let previous = NSWorkspace.shared.frontmostApplication
            bringForward(running)
            usleep(400_000)
            AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            usleep(200_000)
            select(field, target)
            usleep(100_000)
            if holdsFocus(field, pid: running.processIdentifier) {
                let ms = milliseconds { typeText(parts[1], to: running.processIdentifier) }
                usleep(300_000)
                after = AX.string(field, kAXValueAttribute as String) ?? ""
                print(String(format: "select + typed keystrokes: %.1f ms · text %@", ms,
                             after == expected ? "EXACT" : "DIFFERS: \(shown(after))"))
                if restoreCaret {
                    let end = (after as NSString).length
                    let caretBefore = selectedRange(field)
                    select(field, NSRange(location: end, length: 0))
                    usleep(150_000)
                    let caretNow = selectedRange(field)
                    // Then type one character to prove the hand continues at the end.
                    typeText("Z", to: running.processIdentifier)
                    usleep(250_000)
                    let continued = (AX.string(field, kAXValueAttribute as String) ?? "").hasSuffix("Z")
                    postKey(51, flags: [], to: running.processIdentifier)
                    usleep(150_000)
                    print("caret after fix \(caretBefore.map { "\($0.location)" } ?? "?") → restored to \(caretNow.map { "\($0.location)" } ?? "?") of \(end) · next keystroke lands at the end: \(continued ? "yes" : "NO")")
                }
                if undo {
                    postKey(6, flags: .maskCommand, to: running.processIdentifier)
                    usleep(500_000)
                    let undone = AX.string(field, kAXValueAttribute as String) ?? ""
                    print("⌘Z after typed fix: " + (undone == current ? "REVERTS exactly" : undone == after ? "no change" : "changed to \(shown(undone))"))
                    after = undone
                }
            } else {
                print("typed fix skipped: the probe field did not hold focus")
            }
            bringForward(previous)
            usleep(300_000)
        }
        if after != expected, !typeFix {
            // The selection route was ignored: try the one-call replace.
            var ok = false
            let ms = milliseconds { ok = replaceRange(field, target, with: parts[1]) }
            usleep(200_000)
            after = AX.string(field, kAXValueAttribute as String) ?? ""
            print(String(format: "AXSelectedText ignored → AXReplaceRangeWithText: %@ (%.1f ms) · text %@",
                         ok ? "accepted" : "refused", ms, after == expected ? "EXACT" : "still differs"))
        }
        let clean = after == expected
        print(String(format: "fix '%@'→'%@': select %@ (%.1f ms, selected '%@') · replace %@ (%.1f ms) · text %@",
                     parts[0], parts[1], selectError == .success ? "ok" : "AXError \(selectError.rawValue)", selectMs,
                     selectedNow, replaceError == .success ? "ok" : "AXError \(replaceError.rawValue)", replaceMs,
                     clean ? "EXACT" : "DIFFERS: \(shown(after))"))
        if let runsBefore, let runsAfter = fontRuns(field, length: (after as NSString).length) {
            let names = (before: fontName(at: ns.range(of: "Ghostty").location, in: runsBefore),
                         after: fontName(at: (after as NSString).range(of: "Ghostty").location, in: runsAfter))
            print("formatting: 'Ghostty' font \(names.before) → \(names.after)"
                  + " · runs \(runsBefore.count) → \(runsAfter.count)")
        }
        if let caret = selectedRange(field) {
            print("caret after fix: \(caret.location)+\(caret.length) (was \(beforeSelection.map { "\($0.location)+\($0.length)" } ?? "?"))")
        }

        if undo, !typeFix {
            let previous = NSWorkspace.shared.frontmostApplication
            bringForward(running)
            usleep(500_000)
            AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            usleep(200_000)
            guard holdsFocus(field, pid: running.processIdentifier) else {
                print("⌘Z test skipped: the probe field did not hold focus")
                bringForward(previous)
                return
            }
            postKey(6, flags: .maskCommand, to: running.processIdentifier)   // ⌘Z
            usleep(500_000)
            let undone = AX.string(field, kAXValueAttribute as String) ?? ""
            print("⌘Z in the app: " + (undone == current ? "REVERTS the fix exactly"
                                       : undone == after ? "no change"
                                       : "changed to \(shown(undone))"))
            bringForward(previous)
            usleep(300_000)
        }
    }

    if notify { listen(field: field, pid: running.processIdentifier) }

    if inPlace, !write, parts.count == 2 {
        // Put the word back the way it came, through the same selection.
        let now = (AX.string(field, kAXValueAttribute as String) ?? "") as NSString
        let fixed = now.range(of: parts[1])
        if now as String != current, fixed.location != NSNotFound {
            select(field, fixed)
            AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, parts[0] as CFString)
        }
        var back = AX.string(field, kAXValueAttribute as String) ?? ""
        if back != current, typeFix, fixed.location != NSNotFound {
            // Chromium ignores the AX write here as it did for the fix.
            let previous = NSWorkspace.shared.frontmostApplication
            bringForward(running)
            usleep(300_000)
            AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            usleep(150_000)
            select(field, fixed)
            usleep(100_000)
            if holdsFocus(field, pid: running.processIdentifier) { typeText(parts[0], to: running.processIdentifier) }
            usleep(300_000)
            back = AX.string(field, kAXValueAttribute as String) ?? ""
            bringForward(previous)
        }
        print("restore in place: \(back == current ? "exact" : "DIFFERS: \(shown(back))")")
    }

    if write, !hold {
        readMs = milliseconds { print("restore original: \(setText(original))") }
    }
}

/// Does the app announce edits? One programmatic edit and one keystroke,
/// with an observer on the field and on the app; the keystroke is an `x`
/// then a delete, posted to the app's process — never a return.
private func listen(field: AXUIElement, pid: pid_t) {
    var observer: AXObserver?
    let callback: AXObserverCallback = { _, _, notification, refcon in
        guard let refcon else { return }
        let log = Unmanaged<NotificationLog>.fromOpaque(refcon).takeUnretainedValue()
        log.seen.append((notification as String, Date()))
    }
    guard AXObserverCreate(pid, callback, &observer) == .success, let observer else {
        print("notifications: could not create an observer")
        return
    }
    let log = NotificationLog()
    let refcon = Unmanaged.passUnretained(log).toOpaque()
    let application = AXUIElementCreateApplication(pid)
    var registered: [String] = []
    for name in [kAXValueChangedNotification, kAXSelectedTextChangedNotification] {
        if AXObserverAddNotification(observer, field, name as CFString, refcon) == .success { registered.append("field:\(name)") }
        if AXObserverAddNotification(observer, application, name as CFString, refcon) == .success { registered.append("app:\(name)") }
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
    func pump(_ seconds: Double) { CFRunLoopRunInMode(.defaultMode, seconds, false) }

    // Programmatic: append a word through the selection at the end.
    let length = AX.int(field, kAXNumberOfCharactersAttribute as String) ?? 0
    select(field, NSRange(location: length, length: 0))
    log.seen.removeAll()
    var start = Date()
    AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, " ok" as CFString)
    pump(0.6)
    let programmatic = log.seen.map { "\($0.0.replacingOccurrences(of: "AX", with: "")) +\(Int($0.1.timeIntervalSince(start) * 1000))ms" }

    // A keystroke, as the hand would type it.
    AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    usleep(150_000)
    guard holdsFocus(field, pid: pid) else {
        print("notifications registered: \(registered.joined(separator: ", "))")
        print("  on a programmatic edit: \(programmatic.isEmpty ? "NONE" : programmatic.joined(separator: ", "))")
        print("  keystroke test skipped: the probe field is not the focused element of the frontmost app")
        return
    }
    log.seen.removeAll()
    start = Date()
    postKey(7, flags: [], to: pid)      // x
    pump(0.6)
    let typed = log.seen.map { "\($0.0.replacingOccurrences(of: "AX", with: "")) +\(Int($0.1.timeIntervalSince(start) * 1000))ms" }
    postKey(51, flags: [], to: pid)     // delete, taking the x back
    pump(0.3)
    let value = AX.string(field, kAXValueAttribute as String) ?? ""
    print("notifications registered: \(registered.isEmpty ? "none" : registered.joined(separator: ", "))")
    print("  on a programmatic edit: \(programmatic.isEmpty ? "NONE" : programmatic.joined(separator: ", "))")
    print("  on a keystroke:         \(typed.isEmpty ? "NONE" : typed.joined(separator: ", "))"
          + (value.hasSuffix("x") ? " (the keystroke landed; delete did not)" : ""))
}

/// Keys go wherever the app's focus is, so none is sent unless the
/// probe's own field holds that focus: a keystroke meant for a test page
/// must never land in a window someone is working in.
private func holdsFocus(_ field: AXUIElement, pid: pid_t, explain: Bool = false) -> Bool {
    let application = AXUIElementCreateApplication(pid)
    let front = NSWorkspace.shared.frontmostApplication
    guard front?.processIdentifier == pid else {
        if explain { print("  focus check: frontmost is \(front?.localizedName ?? "nothing"), not the probe's app") }
        return false
    }
    guard let focused = AX.element(application, kAXFocusedUIElementAttribute as String) else {
        if explain { print("  focus check: the app reports no focused element") }
        return false
    }
    // Rich editors put focus on a node inside the field; the field itself
    // or anything within it is fine, anything outside it is not.
    var node: AXUIElement? = focused
    for _ in 0..<8 {
        guard let current = node else { break }
        if CFEqual(current, field) { return true }
        node = AX.element(current, kAXParentAttribute as String)
    }
    if explain {
        print("  focus check: focused is \(AX.string(focused, kAXRoleAttribute as String) ?? "?") "
              + "\((AX.string(focused, "AXPlaceholderValue") ?? AX.string(focused, kAXDescriptionAttribute as String) ?? "").prefix(40).debugDescription), outside the probe field")
    }
    return false
}

/// Type text word by word, with a real space key between words and a
/// short gap, the rhythm web editors take their undo checkpoints from.
private func typeKeys(_ text: String, to pid: pid_t) {
    guard !text.contains(where: \.isNewline) else { return }
    let words = text.components(separatedBy: " ")
    for (index, word) in words.enumerated() {
        if !word.isEmpty { typeText(word, to: pid) }
        if index < words.count - 1 { postKey(49, flags: [], to: pid) }   // space
        usleep(60_000)
    }
}

/// Type text as the hand would: one key event carrying the string.
private func typeText(_ text: String, to pid: pid_t) {
    // In a chat composer a typed newline is a return, and a return sends.
    guard !text.contains(where: \.isNewline) else {
        print("typing refused: the text holds a line break, which a chat app would send")
        return
    }
    let units = Array(text.utf16)
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        event.postToPid(pid)
        usleep(20_000)
    }
}

/// Bring an app forward through Launch Services. A command-line tool's
/// own `activate()` is only a request under cooperative activation, and
/// from the background it is declined.
private func bringForward(_ app: NSRunningApplication?) {
    guard let id = app?.bundleIdentifier else { return }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", "tell application id \"\(id)\" to activate"]
    try? task.run()
    task.waitUntilExit()
}

private func postKey(_ code: CGKeyCode, flags: CGEventFlags, to pid: pid_t) {
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
        event.flags = flags
        event.postToPid(pid)
        usleep(20_000)
    }
}

private func ocrWord(_ crop: CGImage) -> String {
    // Upscaled threefold: a single word at text size is below what the
    // accurate pass reads reliably.
    let width = crop.width * 3, height = crop.height * 3
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "" }
    context.interpolationQuality = .high
    context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let scaled = context.makeImage() else { return "" }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    try? VNImageRequestHandler(cgImage: scaled, options: [:]).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
}

private func annotate(_ image: CGImage, rects: [CGRect?], windowFrame: CGRect, scale: CGFloat, path: String) {
    guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    context.setStrokeColor(CGColor(red: 1, green: 0.31, blue: 0, alpha: 1))
    context.setLineWidth(2 * scale / 2)
    for rect in rects.compactMap({ $0 }) where rect.width > 0 {
        let local = rect.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY)
        // CGContext is bottom-up; AX is top-down. The underline sits on
        // the rectangle's bottom edge, where the editor would draw it.
        let y = CGFloat(image.height) - local.maxY * scale
        context.stroke(CGRect(x: local.minX * scale, y: y, width: local.width * scale, height: local.height * scale))
    }
    guard let annotated = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                            "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, annotated, nil)
    CGImageDestinationFinalize(destination)
    print("annotated capture: \(path)")
}


// MARK: - residency

/// How long would a model sit in memory? Replays the key store against the
/// focus record: the model loads at a keystroke in a field meant for a
/// person and unloads after a quiet stretch. Counts only, per day — which
/// apps and when, never what was typed (the store holds no key identities).
private func editorResidency(_ args: inout [String]) {
    let idles = (value(of: "--idle", in: &args) ?? "1,2,5,10").split(separator: ",").compactMap { Double($0) }
    let prose: Set<String> = ["slack", "messages", "microsoft outlook", "proton mail", "telegram", "claude",
                              "brave browser", "asana", "notes", "mail", "textedit", "signal", "discord"]
    let writing: Set<Keys.Kind> = [.letter, .digit, .space, .punctuation, .backspace]
    let focus = EventLog().readAll().filter { $0.kind == .focus && $0.app != nil }.sorted { $0.t < $1.t }
    guard !focus.isEmpty else { fail("no focus events") }
    let times = focus.map(\.t.timeIntervalSince1970)
    func app(at t: Double) -> String? {
        var lo = 0, hi = times.count - 1
        guard t >= times[0] else { return nil }
        while lo < hi { let mid = (lo + hi + 1) / 2; if times[mid] <= t { lo = mid } else { hi = mid - 1 } }
        return focus[lo].app
    }
    let directory = Paths.data.appendingPathComponent("keys", isDirectory: true)
    var totals = Array(repeating: (hours: 0.0, loads: 0), count: idles.count)
    var totalSpan = 0.0, totalDays = 0
    print("day          presses  prose   span h   " + idles.map { String(format: "%4.0f min: loaded h (%%) loads", $0) }.joined(separator: "   "))
    for day in KeyStore.days(in: directory) {
        let presses = KeyStore.presses(day: day, in: directory)
        guard let first = presses.first?.down, let last = presses.last?.down, presses.count > 500 else { continue }
        let span = last.timeIntervalSince(first) / 3600
        let proseTimes = presses.filter { writing.contains($0.kind) && !$0.chord }
            .map(\.down.timeIntervalSince1970)
            .filter { app(at: $0).map(prose.contains) ?? false }
        var line = String(format: "%@  %7d %6d  %6.1f   ", day, presses.count, proseTimes.count, span)
        for (index, idle) in idles.enumerated() {
            var loaded = 0.0, loads = 0, start: Double?, previous = 0.0
            for t in proseTimes {
                if let s = start, t - previous <= idle * 60 { _ = s } else {
                    if let s = start { loaded += previous + idle * 60 - s }
                    start = t; loads += 1
                }
                previous = t
            }
            if let s = start { loaded += previous + idle * 60 - s }
            let hours = loaded / 3600
            totals[index].hours += hours; totals[index].loads += loads
            line += String(format: "%10.1f (%3.0f%%) %5d      ", hours, span > 0 ? 100 * hours / span : 0, loads)
        }
        totalSpan += span; totalDays += 1
        print(line)
    }
    guard totalDays > 0 else { return }
    print(String(format: "per day (%d days, active span %.1f h):", totalDays, totalSpan / Double(totalDays)))
    for (index, idle) in idles.enumerated() {
        print(String(format: "  unload after %2.0f min idle: loaded %.1f h a day (%.0f%% of the active day), %.0f loads a day",
                     idle, totals[index].hours / Double(totalDays), 100 * totals[index].hours / totalSpan,
                     Double(totals[index].loads) / Double(totalDays)))
    }
}


// MARK: - bench

/// The engine over a model's recorded answers: every benchmark sentence's
/// reply fed through the real session — the diff, the filter, the guards,
/// the spell checker's merge — and scored the way the harness scored the
/// models, per suggestion.
private func editorBench(_ args: inout [String]) {
    guard let path = args.first, let data = FileManager.default.contents(atPath: path),
          let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        fail("usage: probe editor bench <model-output.json>")
    }
    func norm(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).map { String($0).lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" } }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
    var right = 0, wrong = 0, injected = 0, cleanMarks = 0, cleanRows = 0
    var fixedWhole = 0
    for row in rows {
        guard let text = row["text"] as? String, let want = (row["want"] ?? row["fixed"]) as? String,
              let got = row["got"] as? String else { continue }
        let session = EditorSession()
        session.record(sentence: text, corrected: got)
        var issues = session.issues(text: text, caret: nil)
        if ProcessInfo.processInfo.environment["FORM_ONLY"] != nil {
            let kept = issues.filter { $0.kind == .spelling || $0.note != nil
                || isFormCorrection($0.original, $0.replacement, language: "en_US") }
            if ProcessInfo.processInfo.environment["SHOW_DROPPED"] != nil, text != want {
                for issue in issues where !kept.contains(issue) {
                    let alone = (text as NSString).replacingCharacters(in: issue.range, with: issue.replacement)
                    if norm(alone) == norm(want) { print("  dropped a right fix: \(issue.original) → \(issue.replacement)") }
                }
            }
            issues = kept
        }
        if text == want {
            cleanRows += 1; cleanMarks += issues.count; wrong += issues.count
            if has("--show-notes", in: &args) || ProcessInfo.processInfo.environment["SHOW_NOTES"] != nil {
                for issue in issues where issue.note != nil || ProcessInfo.processInfo.environment["SHOW_ALL"] != nil {
                    let ns = text as NSString
                    let from = max(0, issue.range.location - 30)
                    let context = ns.substring(with: NSRange(location: from, length: min(ns.length - from, issue.range.length + 45)))
                    print("  [\(issue.note ?? "\(issue.original) → \(issue.replacement)")] …\(context)…")
                }
            }
            continue
        }
        injected += 1
        var applied = text as NSString
        for issue in issues.sorted(by: { $0.range.location > $1.range.location }) {
            let alone = (text as NSString).replacingCharacters(in: issue.range, with: issue.replacement)
            if norm(alone) == norm(want) { right += 1 } else { wrong += 1 }
            applied = applied.replacingCharacters(in: issue.range, with: issue.replacement) as NSString
        }
        if norm(applied as String) == norm(want) { fixedWhole += 1 }
    }
    let marks = right + wrong
    print(String(format: "%@: marks right %d/%d (%.0f%%) · errors caught %d/%d (%.0f%%) · false marks per clean sentence %.2f · whole sentence fixed %d",
                 (path as NSString).lastPathComponent, right, marks, 100 * Double(right) / Double(max(1, marks)),
                 right, injected, 100 * Double(right) / Double(max(1, injected)),
                 Double(cleanMarks) / Double(max(1, cleanRows)), fixedWhole))
}


// MARK: - form, not word choice (prototype)

import NaturalLanguage

/// Would this change be a correction of form rather than a choice of word?
/// Non-words may always be fixed; a real word may become another only as
/// its own inflection, a known confusable, a pronoun's case, or an article.
func isFormCorrection(_ original: String, _ replacement: String, language: String) -> Bool {
    let a = original.split(whereSeparator: \.isWhitespace).map { EditorTextNormalize($0) }
    let b = replacement.split(whereSeparator: \.isWhitespace).map { EditorTextNormalize($0) }
    // Inserts and deletes of little words (an article, a doubled word) are form.
    let setA = Set(a), setB = Set(b)
    let added = setB.subtracting(setA), removed = setA.subtracting(setB)
    let little: Set<String> = ["a", "an", "the", "to", "of", "in", "on", "at", "for", "and", "is", "was", "it", "that"]
    if added.isEmpty && removed.isEmpty { return true }
    if removed.isEmpty, added.isSubset(of: little) { return true }
    if added.isEmpty, removed.isSubset(of: little) { return true }
    guard removed.count == 1, added.count == 1, let from = removed.first, let to = added.first else { return true }
    if EditorSpelling.isMisspelled(from, language: language) { return true }
    let confusables: [Set<String>] = [
        ["their", "there", "they're"], ["its", "it's"], ["your", "you're"], ["then", "than"],
        ["affect", "effect"], ["lose", "loose"], ["whose", "who's"], ["to", "too", "two"],
        ["fewer", "less"], ["lie", "lay"], ["were", "we're", "where"], ["accept", "except"],
        ["a", "an"], ["of", "have"], ["could", "couldn't"], ["i", "me"], ["he", "him"], ["she", "her"],
        ["we", "us"], ["they", "them"], ["who", "whom"], ["that", "which"],
        ["is", "are", "was", "were", "be", "been", "am", "being"], ["has", "have", "had"],
        ["does", "do", "did", "done"], ["doesn't", "don't", "didn't"], ["isn't", "aren't", "wasn't", "weren't"],
        ["this", "these"], ["that", "those"],
    ]
    if confusables.contains(where: { $0.contains(from) && $0.contains(to) }) { return true }
    if ProcessInfo.processInfo.environment["FORM_TYPO"] != nil, typoDistance(from, to) <= 2 { return true }
    return lemma(from) == lemma(to)
}

/// Letters inserted, removed, replaced or swapped: how far a slip goes.
private func typoDistance(_ a: String, _ b: String) -> Int {
    let x = Array(a), y = Array(b)
    var d = Array(repeating: Array(repeating: 0, count: y.count + 1), count: x.count + 1)
    for i in 0...x.count { d[i][0] = i }
    for j in 0...y.count { d[0][j] = j }
    if x.isEmpty || y.isEmpty { return max(x.count, y.count) }
    for i in 1...x.count {
        for j in 1...y.count {
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
        }
    }
    return d[x.count][y.count]
}

private func EditorTextNormalize(_ s: Substring) -> String {
    String(s.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").filter { $0.isLetter || $0 == "'" })
}

private func lemma(_ word: String) -> String {
    let tagger = NLTagger(tagSchemes: [.lemma])
    tagger.string = word
    let (tag, _) = tagger.tag(at: word.startIndex, unit: .word, scheme: .lemma)
    return tag?.rawValue.lowercased() ?? word
}
