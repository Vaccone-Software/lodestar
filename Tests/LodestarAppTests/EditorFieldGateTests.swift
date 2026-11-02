import XCTest
@testable import lodestar
@testable import LodestarCore

/// Which fields the editor reads: prose, and the single lines that are still
/// writing; never a secret, and never a query (a launcher, a search box, an
/// address bar). The decision is a pure function of the attributes read, so
/// these run without an app.
final class EditorFieldGateTests: XCTestCase {
    private func facts(_ role: String, subrole: String = "", roleDescription: String = "", description: String = "",
                       title: String = "", placeholder: String = "", bundle: String? = "com.apple.TextEdit",
                       insideWebArea: Bool = false) -> EditorFieldFacts {
        EditorFieldFacts(role: role, subrole: subrole, roleDescription: roleDescription, description: description,
                         title: title, placeholder: placeholder, bundleID: bundle, valueSettable: true,
                         rangeSettable: true, insideWebArea: insideWebArea)
    }

    private func refused(_ facts: EditorFieldFacts, _ reason: EditorFieldGate.Reason,
                         _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(EditorFieldGate.verdict(facts), .refused(reason), what, file: file, line: line)
    }

    private func read(_ facts: EditorFieldFacts, _ what: String,
                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(EditorFieldGate.verdict(facts), .read, what, file: file, line: line)
    }

    func testALauncherIsNeverRead() {
        for bundle in ["com.raycast.macos", "com.runningwithcrayons.Alfred", "com.apple.Spotlight", "at.obdev.LaunchBar"] {
            refused(facts("AXTextField", bundle: bundle), .launcher, bundle)
            refused(facts("AXTextArea", bundle: bundle), .launcher, "\(bundle), even a text area")
            XCTAssertTrue(EditorFieldGate.refusesApp(bundle), bundle)
        }
        XCTAssertFalse(EditorFieldGate.refusesApp("com.apple.TextEdit"))
        XCTAssertFalse(EditorFieldGate.refusesApp(nil))
    }

    func testASearchFieldIsNeverRead() {
        refused(facts("AXTextField", subrole: "AXSearchField"), .search, "the subrole")
        refused(facts("AXTextField", roleDescription: "search text field"), .search, "the role description")
        refused(facts("AXTextField", description: "Search"), .search, "the description")
        refused(facts("AXTextField", title: "Search messages"), .search, "the title")
        refused(facts("AXTextField", placeholder: "Search the web"), .search, "the placeholder")
        refused(facts("AXTextField", placeholder: "SEARCH"), .search, "any case")
    }

    func testOnlyAWordBeginningSearchNamesASearch() {
        read(facts("AXTextField", description: "Research topic"), "research is not a search")
        read(facts("AXTextField", description: "Subject"), "a subject line")
    }

    func testAComboBoxIsNeverRead() {
        refused(facts("AXComboBox"), .comboBox, "a combo box")
    }

    func testAPasswordIsNeverRead() {
        refused(facts("AXTextField", subrole: "AXSecureTextField"), .secure, "the subrole")
        refused(facts("AXTextField", roleDescription: "secure text field"), .secure, "the role description")
        refused(facts("AXTextField", roleDescription: "Password"), .secure, "a role description naming one")
        refused(facts("AXTextField", subrole: "AXSecureTextField", placeholder: "search"), .secure,
                "a secret is a secret before it is a search")
    }

    func testABrowsersOwnAddressBarIsNeverRead() {
        for bundle in ["com.brave.Browser", "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox",
                       "company.thebrowser.Browser"] {
            let bar = facts("AXTextField", bundle: bundle, insideWebArea: false)
            XCTAssertTrue(bar.asksWhereItStands, bundle)
            refused(bar, .addressBar, "\(bundle): a single line outside every page")
        }
    }

    func testAPageSingleLineInputIsStillRead() {
        read(facts("AXTextField", bundle: "com.brave.Browser", insideWebArea: true), "a form field in a page")
        read(facts("AXTextField", description: "Subject", bundle: "com.google.Chrome", insideWebArea: true),
             "a web mail subject")
        refused(facts("AXTextField", subrole: "AXSearchField", bundle: "com.brave.Browser", insideWebArea: true),
                .search, "a site's own search box")
        refused(facts("AXTextField", placeholder: "Search Reddit", bundle: "com.brave.Browser", insideWebArea: true),
                .search, "a site's search box by its placeholder")
    }

    func testOnlyABrowsersSingleLineFieldAsksWhereItStands() {
        XCTAssertFalse(facts("AXTextArea", bundle: "com.brave.Browser").asksWhereItStands)
        XCTAssertFalse(facts("AXTextField", bundle: "com.apple.mail").asksWhereItStands)
        XCTAssertFalse(facts("AXTextField", bundle: nil).asksWhereItStands)
        read(facts("AXTextArea", bundle: "com.brave.Browser", insideWebArea: false),
             "a text area is prose wherever it stands")
    }

    func testProseAndOrdinaryFieldsAreRead() {
        read(facts("AXTextArea", description: "Message to #search-team", bundle: "com.tinyspeck.slackmacgap"),
             "the Slack composer, a text area whose channel names a search")
        read(facts("AXTextArea", bundle: "com.tinyspeck.slackmacgap"), "the Slack composer")
        read(facts("AXTextField", description: "Subject:", bundle: "com.apple.mail"), "the Mail subject line")
        read(facts("AXTextArea", bundle: "com.apple.mail"), "the Mail body")
        read(facts("AXTextArea", description: "iMessage", bundle: "com.apple.MobileSMS"), "the Messages composer")
        read(facts("AXTextField", description: "iMessage", bundle: "com.apple.MobileSMS"),
             "the Messages composer when it answers as a text field")
        read(facts("AXTextArea", bundle: "com.apple.TextEdit"), "a document")
        read(facts("AXTextField", bundle: "com.apple.Notes"), "an ordinary native single line")
    }

    func testAFieldNobodyTypesIntoIsNeverRead() {
        var terminal = facts("AXTextArea")
        terminal.valueSettable = false
        terminal.rangeSettable = false
        refused(terminal, .notEditable, "a terminal's screen")
        refused(facts("AXButton"), .notText, "not text at all")
        var selection = facts("AXTextField")
        selection.valueSettable = false
        read(selection, "a selection that can be set is enough")
    }

    func testTheOldQuestionAboutRoleAndSubroleStillAnswers() {
        XCTAssertTrue(EditorAX.isReadable(role: "AXTextArea", subrole: "", valueSettable: true, rangeSettable: true))
        XCTAssertFalse(EditorAX.isReadable(role: "AXTextField", subrole: "AXSearchField",
                                           valueSettable: true, rangeSettable: true))
        XCTAssertFalse(EditorAX.isReadable(role: "AXComboBox", subrole: "", valueSettable: true, rangeSettable: true))
    }
}

/// Which apps are fixed by typing into a selection instead of by writing
/// the selected text: the ones that ignore the write, so the editor does
/// not wait on it with the word left selected.
final class EditorTypedFixTests: XCTestCase {
    func testChromiumElectronAndOutlookTakeTyping() {
        XCTAssertTrue(EditorAX.fixesByTyping(bundleID: "com.brave.Browser", chromium: true, electron: false))
        XCTAssertTrue(EditorAX.fixesByTyping(bundleID: "com.tinyspeck.slackmacgap", chromium: false, electron: true))
        XCTAssertTrue(EditorAX.fixesByTyping(bundleID: "com.microsoft.Outlook", chromium: false, electron: false))
    }

    func testNativeTextTakesTheDirectWrite() {
        XCTAssertFalse(EditorAX.fixesByTyping(bundleID: "com.apple.TextEdit", chromium: false, electron: false))
        XCTAssertFalse(EditorAX.fixesByTyping(bundleID: "com.apple.mail", chromium: false, electron: false))
        XCTAssertFalse(EditorAX.fixesByTyping(bundleID: nil, chromium: false, electron: false))
    }

    /// A running process answers from its bundle (here the test runner,
    /// which ships neither a Chromium helper nor the Electron framework).
    func testARunningNativeProcessIsRead() {
        XCTAssertFalse(EditorAX.fixesByTyping(bundleID: "com.apple.dt.xctest", pid: getpid()))
    }
}

/// A field's place never changes, so the walk up to its web area is made
/// once, not on every read.
final class EditorPlaceMemoryTests: XCTestCase {
    func testASecondReadOfTheSameFieldDoesNotWalkAgain() {
        var memory = PlaceMemory()
        var walks = 0
        let field = AXUIElementCreateApplication(4242)
        XCTAssertTrue(memory.answer(for: field) { walks += 1; return true })
        XCTAssertTrue(memory.answer(for: AXUIElementCreateApplication(4242)) { walks += 1; return true },
                      "a new reference to the same node is the same field")
        XCTAssertEqual(walks, 1)
    }

    func testEachFieldIsWalkedOnce() {
        var memory = PlaceMemory()
        var walks = 0
        XCTAssertTrue(memory.answer(for: AXUIElementCreateApplication(1001)) { walks += 1; return true })
        XCTAssertFalse(memory.answer(for: AXUIElementCreateApplication(1002)) { walks += 1; return false },
                       "an address bar's place is remembered too")
        XCTAssertFalse(memory.answer(for: AXUIElementCreateApplication(1002)) { walks += 1; return true })
        XCTAssertEqual(walks, 2)
    }

    func testAWalkThatDidNotFinishIsAskedAgain() {
        var memory = PlaceMemory()
        var walks = 0
        XCTAssertFalse(memory.answer(for: AXUIElementCreateApplication(1001)) { walks += 1; return nil })
        XCTAssertTrue(memory.answer(for: AXUIElementCreateApplication(1001)) { walks += 1; return true })
        XCTAssertEqual(walks, 2, "a timeout is not an answer")
    }

    func testOnlyTheLastFewAreKept() {
        var memory = PlaceMemory()
        var walks = 0
        for pid in 0...PlaceMemory.capacity {
            _ = memory.answer(for: AXUIElementCreateApplication(pid_t(2000 + pid))) { walks += 1; return true }
        }
        _ = memory.answer(for: AXUIElementCreateApplication(2000)) { walks += 1; return true }
        XCTAssertEqual(walks, PlaceMemory.capacity + 2, "the oldest was forgotten")
    }
}
