import AppKit
import LodestarCore

/// Bring's last step: the chosen text put at the caret of the app that
/// was in front, the pasteboard never touched.
///
/// A field that says what it holds takes the text as one insertion
/// through accessibility, which no autocorrect, smart quote or closing
/// bracket rewrites; it counts only when the field's text is seen to
/// change. Everything else — a terminal, a field that will not say — is
/// typed the way a hand would type it. An app takes a typed string of a
/// few dozen characters and quietly drops the rest, so the text goes in
/// short pieces, never cutting a character in two, marked so the tap lets
/// it through. All of it off the main thread.
enum BringTyping {
    private static let queue = DispatchQueue(label: "com.vaccone.lodestar.bring.land", qos: .userInteractive)
    private static let editable: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    static func land(_ text: String, into pid: pid_t) {
        // Chromium and Electron report a field's text a beat after it
        // changes, so an insertion there cannot be seen in time to be
        // trusted, and trusting it blind could type the text twice. Those
        // apps are typed into.
        let lateTree = NSRunningApplication(processIdentifier: pid)?.bundleURL.map(reportsLate) ?? true
        queue.async {
            if !lateTree, insert(text, into: pid) { return }
            typeNow(text, to: pid)
        }
    }

    /// A Chromium browser or an Electron app.
    static func reportsLate(_ bundle: URL) -> Bool {
        if AXWarmer.isChromiumBrowser(bundle) { return true }
        let frameworks = bundle.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return FileManager.default.fileExists(atPath: frameworks.path)
    }

    /// One insertion at the caret, true only when the field's text changed.
    private static func insert(_ text: String, into pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let field = AX.element(app, kAXFocusedUIElementAttribute as String),
              editable.contains(AX.string(field, kAXRoleAttribute as String) ?? ""),
              AX.string(field, kAXSubroleAttribute as String) != "AXSecureTextField" else { return false }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(field, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue,
              let before = AX.string(field, kAXValueAttribute as String) else { return false }
        guard AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, text as CFString) == .success
        else { return false }
        // Seen within 150 ms, or typed instead.
        for _ in 0..<10 {
            usleep(15_000)
            if AX.string(field, kAXValueAttribute as String) != before { return true }
        }
        return false
    }

    static let piece = 16

    static func pieces(of text: String) -> [[UInt16]] {
        var out: [[UInt16]] = []
        var current: [UInt16] = []
        for character in text {
            let units = Array(String(character).utf16)
            if current.count + units.count > piece, !current.isEmpty {
                out.append(current)
                current = []
            }
            current += units
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    static func type(_ text: String, to pid: pid_t) {
        queue.async { typeNow(text, to: pid) }
    }

    private static func typeNow(_ text: String, to pid: pid_t) {
        let chunks = pieces(of: text)
        do {
            for units in chunks {
                for down in [true, false] {
                    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
                    event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    event.flags = []
                    event.setIntegerValueField(.eventSourceUserData, value: SelectController.ownMark)
                    SystemEvents.post(event, toPid: pid)
                    usleep(4_000)
                }
            }
        }
    }
}
