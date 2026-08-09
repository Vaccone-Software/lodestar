import XCTest
@testable import LodestarCore

final class TilingTests: XCTestCase {
    let bounds = CGRect(x: 0, y: 30, width: 3008, height: 1662)

    func testSingleWindowFillsBounds() {
        XCTAssertEqual(Tiling.frames(count: 1, in: bounds, orientation: .horizontal), [bounds])
    }

    func testHorizontalSplitCoversAxisExactly() {
        for count in 2...10 {
            let frames = Tiling.frames(count: count, in: bounds, orientation: .horizontal)
            XCTAssertEqual(frames.count, count)
            XCTAssertEqual(frames.first?.minX, bounds.minX)
            XCTAssertEqual(frames.last!.maxX, bounds.maxX, accuracy: 1.0, "count \(count)")
            for frame in frames {
                XCTAssertEqual(frame.minY, bounds.minY)
                XCTAssertEqual(frame.height, bounds.height)
            }
            let widths = frames.map(\.width)
            XCTAssertLessThanOrEqual(widths.max()! - widths.min()!, 1, "equal-sized within a pixel")
        }
    }

    func testVerticalSplitCoversAxisExactly() {
        let frames = Tiling.frames(count: 3, in: bounds, orientation: .vertical)
        XCTAssertEqual(frames.last!.maxY, bounds.maxY, accuracy: 1.0)
        for frame in frames { XCTAssertEqual(frame.width, bounds.width) }
    }

    func testAdjacentFramesDoNotOverlap() {
        let frames = Tiling.frames(count: 4, in: bounds, orientation: .horizontal)
        for i in 1..<frames.count {
            XCTAssertEqual(frames[i].minX, frames[i - 1].maxX, accuracy: 0.5)
        }
    }

    func testIndexOrderLeftToRightThenTopToBottom() {
        let order = Tiling.indexOrder([
            (id: 3, frame: CGRect(x: 2000, y: 0, width: 100, height: 100)),
            (id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
            (id: 2, frame: CGRect(x: 0, y: 500, width: 100, height: 100)),
        ])
        XCTAssertEqual(order, [1, 2, 3])
    }

    func testOrientationFlip() {
        XCTAssertEqual(Orientation.horizontal.flipped, .vertical)
        XCTAssertEqual(Orientation.vertical.flipped, .horizontal)
    }
}
