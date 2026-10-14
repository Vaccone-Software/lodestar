import CoreGraphics
import XCTest
@testable import LodestarCore

final class WindowCaptureTests: XCTestCase {
    /// The floor moved past the SDK's cut-off for `CGWindowListCreateImage`;
    /// Select's pixels depend on the run-time lookup still finding it.
    func testTheCaptureFunctionIsFoundAtRunTime() {
        XCTAssertTrue(WindowCapture.isAvailable)
    }

    /// The call goes through with the original's arguments; with Screen
    /// Recording allowed it must produce pixels (without, the system may
    /// answer either way).
    func testACaptureCallsThroughWithTheOriginalArguments() {
        let image = WindowCapture.image(CGRect(x: 0, y: 0, width: 16, height: 16),
                                        .optionOnScreenOnly, kCGNullWindowID, [])
        if CGPreflightScreenCaptureAccess() { XCTAssertNotNil(image) }
    }
}
