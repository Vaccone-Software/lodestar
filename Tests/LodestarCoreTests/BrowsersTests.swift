import XCTest
@testable import LodestarCore

/// The browsers Lodestar addresses by profile: the Chromium family's title
/// convention and Local State shape, and how every family's read is sorted
/// into profiles, a refusal, or nothing there.
final class BrowsersTests: XCTestCase {
    // MARK: - Title matching

    func testTitleSuffixMatchesPerBrowser() {
        XCTAssertTrue(Browser.brave.windowMatches(
            title: "Inbox - Brave - Personal", profile: "Personal"))
        XCTAssertTrue(Browser.chrome.windowMatches(
            title: "Docs - Google Chrome - Work", profile: "Work"))
        XCTAssertTrue(Browser.edge.windowMatches(
            title: "Portal - Microsoft Edge - School", profile: "School"))
    }

    func testBareWindowTitleMatches() {
        XCTAssertTrue(Browser.brave.windowMatches(title: "Brave - Personal", profile: "Personal"))
        XCTAssertTrue(Browser.chrome.windowMatches(title: "Google Chrome - Work", profile: "Work"))
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertTrue(Browser.brave.windowMatches(
            title: "inbox - brave - PERSONAL", profile: "personal"))
    }

    func testBrowsersDoNotMatchEachOthersTitles() {
        XCTAssertFalse(Browser.brave.windowMatches(
            title: "Docs - Google Chrome - Work", profile: "Work"))
        XCTAssertFalse(Browser.chrome.windowMatches(
            title: "Inbox - Brave - Work", profile: "Work"))
    }

    func testWrongProfileDoesNotMatch() {
        XCTAssertFalse(Browser.brave.windowMatches(
            title: "Inbox - Brave - Personal", profile: "Work"))
        XCTAssertFalse(Browser.brave.windowMatches(
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
        let dirs = Browser.profileDirectories(fromLocalState: localState)
        XCTAssertEqual(dirs, ["personal": "Default", "work": "Profile 7"],
                       "names lowered, nameless entries skipped")
    }

    func testMalformedLocalStateIsEmptyNotFatal() {
        XCTAssertEqual(Browser.profileDirectories(fromLocalState: Data("junk".utf8)), [:])
        XCTAssertEqual(Browser.profileDirectories(fromLocalState: Data("{}".utf8)), [:])
        XCTAssertEqual(Browser.profileDirectories(
            fromLocalState: Data(#"{"profile": {}}"#.utf8)), [:])
    }

    // MARK: - Identity

    func testConfigKeysAndLabelsAreDistinct() {
        XCTAssertEqual(Set(Browser.allCases.map(\.rawValue)).count,
                       Browser.allCases.count)
        XCTAssertEqual(Set(Browser.allCases.map(\.bundleID)).count,
                       Browser.allCases.count)
        let chromium = Browser.allCases.filter { $0.family == .chromium }
        XCTAssertEqual(Set(chromium.compactMap(\.titleName)).count, chromium.count,
                       "every Chromium browser stamps its own name")
    }

    // MARK: - Families

    func testFamiliesAndBundleIDs() {
        XCTAssertEqual(Browser.safari.family, .safari)
        XCTAssertEqual(Browser.firefox.family, .firefox)
        XCTAssertEqual(Browser(bundleID: "com.apple.Safari"), .safari)
        XCTAssertEqual(Browser(bundleID: "org.mozilla.firefox"), .firefox)
        XCTAssertNil(Browser(bundleID: "company.thebrowser.Browser"), "Arc stays out")
        XCTAssertNil(Browser(bundleID: nil))
    }

    func testOnlyChromiumMatchesByTitleSuffix() {
        XCTAssertFalse(Browser.safari.windowMatches(title: "Work — Inbox", profile: "Work"))
        XCTAssertFalse(Browser.firefox.windowMatches(title: "Inbox — Work", profile: "Work"))
        XCTAssertNil(Browser.safari.localStateSubpath)
    }

    func testReferencesParseForEveryBrowser() {
        XCTAssertEqual(BrowserProfile.parse(reference: "safari:Stevens"),
                       BrowserProfile(browser: .safari, display: "Stevens"))
        XCTAssertEqual(BrowserProfile.parse(reference: "firefox:Test Profile"),
                       BrowserProfile(browser: .firefox, display: "Test Profile"))
        XCTAssertNil(BrowserProfile.parse(reference: "safari:"))
    }

    // MARK: - Reading a profile list

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("browsers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testLocalStateReadIsProfiles() throws {
        let file = try scratch().appendingPathComponent("Local State")
        try localState.write(to: file)
        let listing = ProfileListing.chromium(localState: file)
        XCTAssertEqual(Set(listing.profiles.map(\.name)), ["Personal", "Work"])
        XCTAssertEqual(listing.profiles.first { $0.name == "Work" }?.locator, "Profile 7")
    }

    func testMissingLocalStateIsNotInstalled() throws {
        let file = try scratch().appendingPathComponent("Local State")
        XCTAssertEqual(ProfileListing.chromium(localState: file), .notInstalled)
    }

    /// A refusal is never "no profiles": it is the one answer a person can
    /// fix, and Settings and the doctor say how. A file the user cannot
    /// read stands in for macOS's refusal; both arrive as a permission
    /// error.
    func testUnreadableLocalStateIsRefused() throws {
        let file = try scratch().appendingPathComponent("Local State")
        try localState.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        XCTAssertEqual(ProfileListing.chromium(localState: file), .refused)
    }

    func testErrnoSorting() {
        XCTAssertEqual(ProfileListing.failure(errno: EPERM), .refused)
        XCTAssertEqual(ProfileListing.failure(errno: EACCES), .refused)
        XCTAssertEqual(ProfileListing.failure(errno: ENOENT), .notInstalled)
        if case .unreadable = ProfileListing.failure(errno: EIO) {} else { XCTFail("EIO is unreadable") }
    }
}
