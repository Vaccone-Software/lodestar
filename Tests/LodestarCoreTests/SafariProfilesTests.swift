import XCTest
@testable import LodestarCore

/// Safari's profiles as its accessibility tree spells them, from the
/// strings measured on Safari 27.2.
final class SafariProfilesTests: XCTestCase {
    func testMenuIdentifiersNameTheProfiles() {
        let profiles = SafariProfiles.menuProfiles(fromIdentifiers: [
            "NewPersonalWindow?isDefaultProfile=true",
            "NewStevensWindow?isDefaultProfile=false",
            "NewYouTubeWindow?isDefaultProfile=false",
            "NewTab",
            "NewPrivateWindow",
        ])
        XCTAssertEqual(profiles.map(\.name), ["Personal", "Stevens", "YouTube"])
        XCTAssertEqual(profiles.map(\.isDefault), [true, false, false])
        XCTAssertEqual(profiles[1].identifier, "NewStevensWindow?isDefaultProfile=false")
    }

    /// A name with a space may come spelled either way; it is one profile.
    func testMenuNamesDecodeAndRepeatOnce() {
        let profiles = SafariProfiles.menuProfiles(fromIdentifiers: [
            "NewSide%20WorkWindow?isDefaultProfile=false",
            "NewSide WorkWindow?isDefaultProfile=false",
            "Newside workWindow?isDefaultProfile=false",
        ])
        XCTAssertEqual(profiles.map(\.name), ["Side Work"])
    }

    func testOtherMenuItemsAreNotProfiles() {
        XCTAssertNil(SafariProfiles.menuProfile(fromIdentifier: "NewTab"))
        XCTAssertNil(SafariProfiles.menuProfile(fromIdentifier: "NewWindow?isDefaultProfile=true"),
                     "a nameless item is not a profile")
        XCTAssertNil(SafariProfiles.menuProfile(fromIdentifier: "OpenLocation"))
    }

    func testTitleNamesItsProfile() {
        let names = ["Personal", "Stevens", "YouTube"]
        XCTAssertEqual(SafariProfiles.profile(ofTitle: "Stevens — Start Page", among: names), "Stevens")
        XCTAssertEqual(SafariProfiles.profile(ofTitle: "personal — Example Domain", among: names), "Personal")
        XCTAssertNil(SafariProfiles.profile(ofTitle: "Untitled, Private Browsing", among: names),
                     "a private window belongs to no profile")
        XCTAssertNil(SafariProfiles.profile(ofTitle: "Stevens Institute — Home", among: names),
                     "a page that merely begins with a profile's name is not that profile's")
    }

    /// The longest listed name wins, so a profile whose name holds the
    /// separator is never read as the shorter profile it begins with.
    func testLongestProfileNameWins() {
        let names = ["Work", "Work — Old"]
        XCTAssertEqual(SafariProfiles.profile(ofTitle: "Work — Old — Inbox", among: names), "Work — Old")
        XCTAssertEqual(SafariProfiles.profile(ofTitle: "Work — Inbox", among: names), "Work")
    }

    func testActiveTabIdentifier() {
        XCTAssertTrue(SafariProfiles.isActiveTab(identifier:
            "TabBarTab?isNarrow=false&isExpanded=false&tabCount=&isPinned=false&isCluster=false&clusterID=&isActive=true"))
        XCTAssertFalse(SafariProfiles.isActiveTab(identifier:
            "TabBarTab?isNarrow=false&isActive=false"))
        XCTAssertFalse(SafariProfiles.isActiveTab(identifier: nil))
    }

    func testJavascriptIsNeverTyped() {
        XCTAssertFalse(SafariProfiles.mayType("javascript:alert(1)"))
        XCTAssertFalse(SafariProfiles.mayType("  JavaScript:void(0)"))
        XCTAssertTrue(SafariProfiles.mayType("https://example.com/"))
    }
}
