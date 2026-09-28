import CoreGraphics
import XCTest
@testable import LodestarCore

/// A frame another app reported is used only if it can become whole
/// numbers: an infinite size passed the hints walk's size and overlap
/// checks and trapped at `Int(frame.width)`.
final class FrameScaleTests: XCTestCase {
    func testAFrameOffAnyScreensScaleIsRefused() {
        XCTAssertTrue(CGRect(x: 10, y: 20, width: 300, height: 40).isOnAScreensScale)
        XCTAssertTrue(CGRect(x: -3000, y: 0, width: 2560, height: 1440).isOnAScreensScale, "a screen to the left")
        XCTAssertFalse(CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 40).isOnAScreensScale)
        XCTAssertFalse(CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10).isOnAScreensScale)
        XCTAssertFalse(CGRect(x: 0, y: 0, width: 10, height: 1e19).isOnAScreensScale)
    }
}
