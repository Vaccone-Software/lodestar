import AppKit
import XCTest
@testable import lodestar

/// The door's one rule: as large as the room allows, never past the
/// image's own pixels.
final class ImageDoorTests: XCTestCase {
    func testASmallImageStandsAtOnePointPerPixel() {
        XCTAssertEqual(ImageDoor.fit(pixels: CGSize(width: 400, height: 300),
                                     within: CGSize(width: 1400, height: 900)),
                       CGSize(width: 400, height: 300))
    }

    func testALargeImageIsFittedOnItsLongerSide() {
        XCTAssertEqual(ImageDoor.fit(pixels: CGSize(width: 2800, height: 1800),
                                     within: CGSize(width: 1400, height: 1200)),
                       CGSize(width: 1400, height: 900))
        XCTAssertEqual(ImageDoor.fit(pixels: CGSize(width: 1000, height: 3000),
                                     within: CGSize(width: 1400, height: 900)),
                       CGSize(width: 300, height: 900))
    }

    func testNothingIsNothing() {
        XCTAssertEqual(ImageDoor.fit(pixels: .zero, within: CGSize(width: 10, height: 10)), .zero)
        XCTAssertEqual(ImageDoor.fit(pixels: CGSize(width: 10, height: 10), within: .zero), .zero)
    }
}
