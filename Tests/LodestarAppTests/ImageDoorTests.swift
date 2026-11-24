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

/// The pinch, as arithmetic: scaled by the gesture's own factor and held
/// between the floor and the ceiling.
final class ImageDoorZoomTests: XCTestCase {
    func testAPinchScalesByItsFactor() {
        XCTAssertEqual(ImageDoor.zoomed(1, by: 0.5, floor: 0.1, ceiling: 8), 1.5)
        XCTAssertEqual(ImageDoor.zoomed(2, by: -0.25, floor: 0.1, ceiling: 8), 1.5)
    }

    func testTheFloorAndCeilingHold() {
        XCTAssertEqual(ImageDoor.zoomed(7, by: 1, floor: 0.1, ceiling: 8), 8)
        XCTAssertEqual(ImageDoor.zoomed(0.2, by: -0.9, floor: 0.1, ceiling: 8), 0.1)
    }
}
