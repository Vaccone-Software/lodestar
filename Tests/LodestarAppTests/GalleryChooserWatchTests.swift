import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The gallery's window chooser stands its stand-in windows on Finder's pid,
/// for the icon, and is kept for the life of the test process. A model that
/// watched Finder there was handed every real Finder window anyone opened
/// afterwards, which its stand-in reader numbered below zero: the test
/// process died in whatever test was running (CI and desk, 2026-11-27).
final class GalleryChooserWatchTests: XCTestCase {
    func testTheChoosersModelWatchesNoRealApp() throws {
        let (_, keep) = try GalleryBars.chooser(look: .day)
        let model = try XCTUnwrap(keep.compactMap { $0 as? WindowModel }.first)
        XCTAssertEqual(model.windows.count, 4, "its stand-in windows are tracked")
        XCTAssertEqual(model.watchedPids, [], "and no real app is watched for more")
    }

}
