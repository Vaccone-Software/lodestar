import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The editor's own accessibility code against real apps: read the field,
/// place a word, fix it, move the caret right, refuse a stale fix, and put
/// everything back. On demand only — it opens windows and takes focus:
///
///     scripts/editor-conformance.sh            TextEdit and two Brave pages
///     LODESTAR_EDITOR_SLACK=1 scripts/…        also Slack: open your own DM
///                                              first; its draft is restored
///                                              and nothing is ever sent
///
/// Nothing here presses return. The Brave pages are local files; what the
/// test opened is closed whatever the outcome, and only that: tabs showing
/// its local page, the document it wrote.
final class EditorConformanceTests: XCTestCase {
    static let sentence = "Lodestar probe: We need to recieve the files tomorrow."
    static let title = "Lodestar editor conformance"
    private var directory: URL!

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["LODESTAR_EDITOR_CONFORMANCE"] != nil else {
            throw XCTSkip("on demand: scripts/editor-conformance.sh")
        }
        guard AXIsProcessTrusted() else { throw XCTSkip("the launching terminal needs Accessibility") }
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-conformance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - The apps

    func testTextEdit() throws {
        let file = directory.appendingPathComponent("conformance.txt")
        try Self.sentence.write(to: file, atomically: true, encoding: .utf8)
        // Closed whatever happens, never saved: the file is the test's.
        addTeardownBlock { Self.script(#"tell application "TextEdit" to close (every document whose name is "conformance.txt") saving no"#) }
        try open(file, with: "com.apple.TextEdit")
        let field = try XCTUnwrap(waitForField(), "TextEdit's text view never took focus")
        try exercise(field)
    }

    func testBraveTextarea() throws {
        try page("<textarea autofocus rows=4 cols=70>\(Self.sentence)</textarea>")
    }

    func testBraveRichEditor() throws {
        try page("<div contenteditable autofocus style='border:1px solid;padding:8px;width:520px'>\(Self.sentence)</div>")
    }

    /// Slack's composer: the hand opens its own DM and focuses the box
    /// first. Whatever draft was there is put back.
    func testSlackSelfDM() throws {
        guard ProcessInfo.processInfo.environment["LODESTAR_EDITOR_SLACK"] != nil else {
            throw XCTSkip("LODESTAR_EDITOR_SLACK=1 with your own DM open")
        }
        let slack = try XCTUnwrap(NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.tinyspeck.slackmacgap").first, "Slack is not running")
        slack.activate()
        let composer = try XCTUnwrap(waitForField(containing: nil), "no composer focused in Slack")
        XCTAssertEqual(composer.pid, slack.processIdentifier)
        let draft = composer.text
        let whole = NSRange(location: 0, length: (draft as NSString).length)
        XCTAssertTrue(onAX { AXFieldSource().replace(whole, expected: draft, with: Self.sentence, in: composer) },
                      "the probe sentence could not be put in the composer")
        defer {
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if let now = onAX({ EditorAX.focusedField(frontmost: front) }), now.pid == composer.pid {
                _ = onAX { AXFieldSource().replace(NSRange(location: 0, length: (now.text as NSString).length),
                                                   expected: now.text, with: draft, in: now) }
            }
        }
        try exercise(try XCTUnwrap(waitForField()))
    }

    // MARK: - The checks

    /// Every question the editor asks of a field, then the field put back.
    private func exercise(_ field: EditorField, file: StaticString = #filePath, line: UInt = #line) throws {
        let original = field.text
        let ns = original as NSString
        let typo = ns.range(of: "recieve")
        XCTAssertNotEqual(typo.location, NSNotFound, "the field reads its text", file: file, line: line)

        // Placed: the word's rectangle is a word's, inside the field.
        let rect = try XCTUnwrap(onAX { EditorAX.rects(for: [typo], in: field) }.first ?? nil,
                                 "no rectangle for the word", file: file, line: line)
        XCTAssertTrue((20...200).contains(rect.width), "a word's width, not a line's: \(rect)", file: file, line: line)
        if let frame = field.frame { XCTAssertTrue(frame.insetBy(dx: -2, dy: -2).contains(rect), file: file, line: line) }

        // Stale: words that no longer read as expected are never replaced.
        XCTAssertFalse(onAX { AXFieldSource().replace(typo, expected: "zzzzzzz", with: "receive", in: field) },
                       "a stale fix went through", file: file, line: line)

        // Fixed, with the caret where the hand left it.
        let end = ns.length
        onAX { _ = EditorAX.select(field.element, NSRange(location: end, length: 0)) }
        // Chromium reports a selection one change late: wait for the caret
        // to read where it was put, as a hand's caret has long settled by
        // the time a fix is chosen.
        let settle = Date().addingTimeInterval(1)
        while onAX({ EditorAX.selectedRange(field.element) }) != NSRange(location: end, length: 0), Date() < settle {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        XCTAssertTrue(onAX { AXFieldSource().replace(typo, expected: "recieve", with: "receive", in: field) },
                      "the fix did not land", file: file, line: line)
        var now = try XCTUnwrap(waitForField(containing: "receive the files"), "the fix is not in the field",
                                file: file, line: line)
        XCTAssertEqual(now.caret, end, "a same-length fix leaves the caret", file: file, line: line)

        // A longer fix before the caret moves it by the difference.
        let need = (now.text as NSString).range(of: "We need")
        XCTAssertTrue(onAX { AXFieldSource().replace(need, expected: "We need", with: "We really need", in: now) },
                      file: file, line: line)
        now = try XCTUnwrap(waitForField(containing: "We really need"), file: file, line: line)
        XCTAssertEqual(now.caret, end + 7, "the caret moved with the text before it", file: file, line: line)

        // Put back, both changes, by the same road ⌫ takes.
        let really = (now.text as NSString).range(of: "We really need")
        XCTAssertTrue(onAX { AXFieldSource().replace(really, expected: "We really need", with: "We need", in: now) },
                      file: file, line: line)
        now = try XCTUnwrap(waitForField(containing: "We need to receive"), file: file, line: line)
        let fixed = (now.text as NSString).range(of: "receive")
        XCTAssertTrue(onAX { AXFieldSource().replace(fixed, expected: "receive", with: "recieve", in: now) },
                      file: file, line: line)
        now = try XCTUnwrap(waitForField(containing: "recieve"), file: file, line: line)
        XCTAssertEqual(now.text, original, "the field is as it was", file: file, line: line)
    }

    // MARK: - Driving

    private func onAX<T>(_ work: () -> T) -> T { EditorAX.queue.sync(execute: work) }

    /// The focused field once it reads `text` (the probe sentence by
    /// default), or nil after five seconds.
    private func waitForField(containing text: String? = "Lodestar probe", within seconds: TimeInterval = 5) -> EditorField? {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if let field = onAX({ EditorAX.focusedField(frontmost: front) }), text.map(field.text.contains) ?? true {
                return field
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        } while Date() < deadline
        return nil
    }

    private func open(_ url: URL, with bundleID: String) throws {
        let app = try XCTUnwrap(NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID), "\(bundleID) missing")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        var opened = false
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { _, _ in opened = true }
        let deadline = Date().addingTimeInterval(10)
        while !opened, Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        // Under cooperative activation a background process's activate is
        // only a request, and a test is a background process; the probe
        // found an Apple Event's is honoured.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "tell application id \"\(bundleID)\" to activate"]
        try? task.run()
        task.waitUntilExit()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.8))
    }

    private func page(_ body: String) throws {
        let file = directory.appendingPathComponent("page.html")
        try "<!doctype html><title>\(Self.title)</title><body>\(body)</body>".write(to: file, atomically: true, encoding: .utf8)
        // Closed whatever happens: only tabs showing this local page.
        addTeardownBlock {
            Self.script("""
            tell application "Brave Browser"
                repeat with w in windows
                    repeat with i from (count of tabs of w) to 1 by -1
                        set t to tab i of w
                        if title of t is "\(Self.title)" and URL of t starts with "file://" then close t
                    end repeat
                end repeat
            end tell
            """)
        }
        try open(file, with: "com.brave.Browser")
        // As the editor's watch does when an app comes forward: Chromium
        // builds its pages' tree for a client that asks.
        if let brave = NSRunningApplication.runningApplications(withBundleIdentifier: "com.brave.Browser").first {
            EditorAX.wake(brave.processIdentifier)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
        }
        // A page opened from outside may leave the focus in the address
        // bar: the field is focused through accessibility, the way a click
        // would.
        if waitForField(within: 1.5) == nil { focusProbeField(in: "com.brave.Browser") }
        let field = try XCTUnwrap(waitForField(), "the page's field never took focus")
        try exercise(field)
    }

    /// Put the focus in the element holding the probe sentence.
    private func focusProbeField(in bundleID: String) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = AX.element(root, kAXFocusedWindowAttribute as String) else { return }
        var budget = 4000
        func find(_ element: AXUIElement) -> AXUIElement? {
            guard budget > 0 else { return nil }
            budget -= 1
            let role = AX.string(element, kAXRoleAttribute as String) ?? ""
            if ["AXTextArea", "AXTextField"].contains(role),
               AX.string(element, kAXValueAttribute as String)?.contains("Lodestar probe") == true { return element }
            for child in AX.elements(element, kAXChildrenAttribute as String) ?? [] {
                if let found = find(child) { return found }
            }
            return nil
        }
        if let field = find(window) {
            AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
    }

    @discardableResult
    static func script(_ source: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", source]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }
}
