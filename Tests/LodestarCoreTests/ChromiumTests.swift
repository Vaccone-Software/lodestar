import XCTest
@testable import LodestarCore

/// The Chromium family's shared behaviors, pinned per browser: the window
/// title convention summoning matches on, and the Local State shape the
/// profile registry is read from.
final class ChromiumTests: XCTestCase {
    // MARK: - Title matching

    func testTitleSuffixMatchesPerBrowser() {
        XCTAssertTrue(ChromiumBrowser.brave.windowMatches(
            title: "Inbox - Brave - Personal", profile: "Personal"))
        XCTAssertTrue(ChromiumBrowser.chrome.windowMatches(
            title: "Docs - Google Chrome - Work", profile: "Work"))
        XCTAssertTrue(ChromiumBrowser.edge.windowMatches(
            title: "Portal - Microsoft Edge - School", profile: "School"))
    }

    func testBareWindowTitleMatches() {
        XCTAssertTrue(ChromiumBrowser.brave.windowMatches(title: "Brave - Personal", profile: "Personal"))
        XCTAssertTrue(ChromiumBrowser.chrome.windowMatches(title: "Google Chrome - Work", profile: "Work"))
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertTrue(ChromiumBrowser.brave.windowMatches(
            title: "inbox - brave - PERSONAL", profile: "personal"))
    }

    func testBrowsersDoNotMatchEachOthersTitles() {
        XCTAssertFalse(ChromiumBrowser.brave.windowMatches(
            title: "Docs - Google Chrome - Work", profile: "Work"))
        XCTAssertFalse(ChromiumBrowser.chrome.windowMatches(
            title: "Inbox - Brave - Work", profile: "Work"))
    }

    func testWrongProfileDoesNotMatch() {
        XCTAssertFalse(ChromiumBrowser.brave.windowMatches(
            title: "Inbox - Brave - Personal", profile: "Work"))
        XCTAssertFalse(ChromiumBrowser.brave.windowMatches(
            title: "A title mentioning Brave - Personal somewhere", profile: "Personal"),
            "the profile suffix must end the title")
    }

    // MARK: - Local State

    private let localState = """
    {"profile": {"info_cache": {
        "Default": {"name": "Personal", "avatar_icon": "x"},
        "Profile 7": {"name": "Work"},
        "Broken": {"no_name": true}
    }}}
    """.data(using: .utf8)!

    func testProfileDirectoriesFromLocalState() {
        let dirs = ChromiumBrowser.profileDirectories(fromLocalState: localState)
        XCTAssertEqual(dirs, ["personal": "Default", "work": "Profile 7"],
                       "names lowered, nameless entries skipped")
    }

    func testMalformedLocalStateIsEmptyNotFatal() {
        XCTAssertEqual(ChromiumBrowser.profileDirectories(fromLocalState: Data("junk".utf8)), [:])
        XCTAssertEqual(ChromiumBrowser.profileDirectories(fromLocalState: Data("{}".utf8)), [:])
        XCTAssertEqual(ChromiumBrowser.profileDirectories(
            fromLocalState: Data(#"{"profile": {}}"#.utf8)), [:])
    }

    // MARK: - Identity

    func testConfigKeysAndLabelsAreDistinct() {
        XCTAssertEqual(Set(ChromiumBrowser.allCases.map(\.rawValue)).count,
                       ChromiumBrowser.allCases.count)
        XCTAssertEqual(Set(ChromiumBrowser.allCases.map(\.bundleID)).count,
                       ChromiumBrowser.allCases.count)
        XCTAssertEqual(Set(ChromiumBrowser.allCases.map(\.titleName)).count,
                       ChromiumBrowser.allCases.count)
    }
}
