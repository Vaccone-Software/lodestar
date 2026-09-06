import XCTest
@testable import LodestarCore

/// Where a saved image lands and what it is called: the pure rules the
/// save band speaks.
final class ClipboardSaveTests: XCTestCase {
    private let home = "/Users/vac"
    private let offered = "Image 2026-09-06 at 12.04.31.png"

    private func clip(host: String? = nil, app: String? = nil) -> Clipboard.Clip {
        Clipboard.Clip(id: "img", kind: .image,
                       created: Date(timeIntervalSince1970: 1_788_710_671),
                       sourceBundleID: app.map { "com.example.\($0)" }, sourceAppName: app,
                       preview: "image 1200×800", bytes: 4096, sourceHost: host)
    }

    private func destination(_ typed: String, folder: String = "~/Downloads") -> String {
        Clipboard.saveDestination(typed: typed, offered: offered, folder: folder, home: home)
    }

    func testTheOfferedNameSaysWhereAndWhenLikeAScreenshot() {
        let zone = TimeZone(identifier: "America/New_York")!
        XCTAssertEqual(Clipboard.imageFileName(for: clip(host: "github.com", app: "Brave"), timeZone: zone),
                       "github.com 2026-09-06 at 12.04.31.png", "the host comes first")
        XCTAssertEqual(Clipboard.imageFileName(for: clip(app: "Brave"), timeZone: zone),
                       "Brave 2026-09-06 at 12.04.31.png", "then the app")
        XCTAssertEqual(Clipboard.imageFileName(for: clip(), timeZone: zone),
                       "Image 2026-09-06 at 12.04.31.png", "then nothing at all")
        XCTAssertEqual(Clipboard.imageFileName(for: clip(app: "Foo/Bar:Baz"), timeZone: zone),
                       "Foo-Bar-Baz 2026-09-06 at 12.04.31.png", "a name is never a path")
    }

    func testNothingTypedTakesTheOfferedNameInTheFolder() {
        XCTAssertEqual(destination(""), "/Users/vac/Downloads/" + offered)
        XCTAssertEqual(destination("   "), "/Users/vac/Downloads/" + offered)
    }

    func testANameLandsInTheFolderAndGetsAnExtension() {
        XCTAssertEqual(destination("chart"), "/Users/vac/Downloads/chart.png")
        XCTAssertEqual(destination("chart.png"), "/Users/vac/Downloads/chart.png")
        XCTAssertEqual(destination("v1.2"), "/Users/vac/Downloads/v1.2.png", "a dot is not an extension")
        XCTAssertEqual(destination("chart.jpg"), "/Users/vac/Downloads/chart.jpg")
        XCTAssertEqual(destination("chart.JPEG"), "/Users/vac/Downloads/chart.JPEG")
        XCTAssertEqual(destination("chart.tiff"), "/Users/vac/Downloads/chart.tiff")
    }

    func testASlashInsideIsASubfolder() {
        XCTAssertEqual(destination("reports/chart"), "/Users/vac/Downloads/reports/chart.png")
    }

    func testATrailingSlashIsAFolderThatTakesTheOfferedName() {
        XCTAssertEqual(destination("reports/"), "/Users/vac/Downloads/reports/" + offered)
        XCTAssertEqual(destination("~/Desktop/"), "/Users/vac/Desktop/" + offered)
    }

    func testALeadingSlashOrTildeIsAbsolute() {
        XCTAssertEqual(destination("/tmp/chart"), "/tmp/chart.png")
        XCTAssertEqual(destination("~/Desktop/chart"), "/Users/vac/Desktop/chart.png")
        XCTAssertEqual(destination("~"), "/Users/vac.png", "a bare ~ is a name for nothing sensible, and still a file")
    }

    func testTheFolderExpandsItsOwnTilde() {
        XCTAssertEqual(destination("chart", folder: "~/Pictures/Clips"), "/Users/vac/Pictures/Clips/chart.png")
        XCTAssertEqual(destination("chart", folder: "/Volumes/Work"), "/Volumes/Work/chart.png")
        XCTAssertEqual(destination("chart", folder: "~/Downloads/"), "/Users/vac/Downloads/chart.png",
                       "a trailing slash on the folder is not a second slash in the path")
    }

    func testTheFormatFollowsTheExtension() {
        XCTAssertEqual(Clipboard.saveFormat(of: "/a/b.png"), .png)
        XCTAssertEqual(Clipboard.saveFormat(of: "/a/b.jpg"), .jpeg)
        XCTAssertEqual(Clipboard.saveFormat(of: "/a/b.tif"), .tiff)
        XCTAssertEqual(Clipboard.saveFormat(of: "/a/b"), .png)
    }

    func testTheFolderIsNamedTheShortWay() {
        XCTAssertEqual(Clipboard.folderName(of: "/Users/vac/Downloads/chart.png", home: home), "Downloads")
        XCTAssertEqual(Clipboard.folderName(of: "/Users/vac/Downloads/reports/chart.png", home: home), "reports")
        XCTAssertEqual(Clipboard.folderName(of: "/Users/vac/chart.png", home: home), "home")
    }
}
