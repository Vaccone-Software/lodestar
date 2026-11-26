import ApplicationServices
import CoreGraphics
import Foundation
import XCTest
@testable import LodestarCore

/// Conversions of accessibility values, with no app and no AppKit. A
/// wrong type is a miss: the same read used to trap, and the process
/// that traps owns the event tap.
final class AXValueTests: XCTestCase {
    func testAPointReadsBackAsAPoint() throws {
        var point = CGPoint(x: 12, y: -4)
        let boxed = try XCTUnwrap(AXValueCreate(.cgPoint, &point))
        XCTAssertEqual(AX.point(boxed), point)
        XCTAssertNil(AX.size(boxed), "a point is not a size")
        XCTAssertNil(AX.rect(boxed))
        XCTAssertNil(AX.range(boxed))
        XCTAssertNil(AX.element(boxed))
    }

    func testASizeReadsBackAsASize() throws {
        var size = CGSize(width: 80, height: 24)
        let boxed = try XCTUnwrap(AXValueCreate(.cgSize, &size))
        XCTAssertEqual(AX.size(boxed), size)
        XCTAssertNil(AX.point(boxed), "a size is not a point")
        XCTAssertNil(AX.rect(boxed))
        XCTAssertNil(AX.range(boxed))
    }

    func testARectReadsBackIncludingZero() throws {
        var rect = CGRect(x: 3, y: 9, width: 40, height: 11)
        let boxed = try XCTUnwrap(AXValueCreate(.cgRect, &rect))
        XCTAssertEqual(AX.rect(boxed), rect)
        XCTAssertNil(AX.point(boxed))
        XCTAssertNil(AX.size(boxed))

        var zero = CGRect.zero
        let empty = try XCTUnwrap(AXValueCreate(.cgRect, &zero))
        XCTAssertEqual(AX.rect(empty), .zero, "an empty rect is still a rect; callers decide whether it is usable")
    }

    func testARangeReadsBackAsARange() throws {
        var range = CFRange(location: 3, length: 8)
        let boxed = try XCTUnwrap(AXValueCreate(.cfRange, &range))
        let read = try XCTUnwrap(AX.range(boxed))
        XCTAssertEqual(read.location, 3)
        XCTAssertEqual(read.length, 8)
        XCTAssertNil(AX.point(boxed))
        XCTAssertNil(AX.rect(boxed))
    }

    func testAnElementReadsBackAsAnElement() {
        let app = AXUIElementCreateApplication(1)
        guard let read = AX.element(app) else {
            XCTFail("an application element is an element")
            return
        }
        XCTAssertTrue(CFEqual(read, app))
        XCTAssertNil(AX.point(app))
        XCTAssertNil(AX.size(app))
        XCTAssertNil(AX.rect(app))
        XCTAssertNil(AX.range(app))
    }

    func testASurprisingTypeIsSkipped() {
        let samples: [CFTypeRef] = [
            "title" as CFString,
            NSNumber(value: 7),
            kCFBooleanTrue,
            kCFNull,
            ["child"] as CFArray,
        ]
        for sample in samples {
            XCTAssertNil(AX.element(sample))
            XCTAssertNil(AX.point(sample))
            XCTAssertNil(AX.size(sample))
            XCTAssertNil(AX.rect(sample))
            XCTAssertNil(AX.range(sample))
        }
    }
}
