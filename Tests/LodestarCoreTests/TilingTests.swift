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
        ], orientation: .horizontal)
        XCTAssertEqual(order, [1, 2, 3])
    }

    /// A narrow window centered in the top slice of a vertical stack has
    /// a left edge to the right of the wide window under it; the digits
    /// follow the stack, not the edge.
    func testIndexOrderInAStackFollowsTheCenterNotTheEdge() {
        let order = Tiling.indexOrder([
            (id: 2, frame: CGRect(x: 0, y: 450, width: 1600, height: 450)),
            (id: 1, frame: CGRect(x: 500, y: 0, width: 600, height: 450)),
        ], orientation: .vertical)
        XCTAssertEqual(order, [1, 2])
    }

    /// And a narrow window centered in the second column still comes
    /// second: its center is in that column, wherever its edge fell.
    func testIndexOrderInARowFollowsTheCenter() {
        let order = Tiling.indexOrder([
            (id: 2, frame: CGRect(x: 1000, y: 300, width: 400, height: 300)),
            (id: 1, frame: CGRect(x: 0, y: 0, width: 800, height: 900)),
        ], orientation: .horizontal)
        XCTAssertEqual(order, [1, 2])
    }

    // MARK: - Settling

    private let slice = CGRect(x: 800, y: 0, width: 800, height: 900)

    func testAWindowThatFilledItsSliceIsNotMoved() {
        XCTAssertNil(Tiling.settledOrigin(of: slice, in: slice))
        // Within the tolerance is filled: a two-point shortfall is jitter.
        XCTAssertNil(Tiling.settledOrigin(of: CGRect(x: 800, y: 0, width: 798, height: 898), in: slice))
    }

    func testAShortWindowIsCenteredOnEachShortAxis() {
        XCTAssertEqual(Tiling.settledOrigin(of: CGRect(x: 800, y: 0, width: 400, height: 300), in: slice),
                       CGPoint(x: 1000, y: 300))
    }

    func testOneShortAxisCentersThatAxisAlone() {
        // System Settings: a fixed width, the height it was given.
        XCTAssertEqual(Tiling.settledOrigin(of: CGRect(x: 800, y: 0, width: 700, height: 900), in: slice),
                       CGPoint(x: 850, y: 0))
    }

    func testAnOverflowingAxisIsLeftWhereItIs() {
        // Wider than the slice: centering would push it off screen, and
        // the corrective pass owns the axis. The short height still centers.
        XCTAssertEqual(Tiling.settledOrigin(of: CGRect(x: 800, y: 0, width: 1000, height: 300), in: slice),
                       CGPoint(x: 800, y: 300))
    }

    func testAlreadyCenteredNeverWrites() {
        XCTAssertNil(Tiling.settledOrigin(of: CGRect(x: 1000, y: 300, width: 400, height: 300), in: slice))
        // A point of AX rounding either side is still centered.
        XCTAssertNil(Tiling.settledOrigin(of: CGRect(x: 1000.5, y: 299.5, width: 400, height: 300), in: slice))
    }

    func testAFilledAxisThatDriftedReturnsToTheEdge() {
        // Grew to its full size late, from the origin an earlier settle
        // centered it at: back to the slice's edge.
        XCTAssertEqual(Tiling.settledOrigin(of: CGRect(x: 1000, y: 300, width: 800, height: 900), in: slice),
                       CGPoint(x: 800, y: 0))
    }

    func testCenteringLandsOnWholePoints() {
        let origin = Tiling.settledOrigin(of: CGRect(x: 800, y: 0, width: 715, height: 900), in: slice)
        XCTAssertEqual(origin?.x, 843)
        XCTAssertEqual(origin?.x.rounded(), origin?.x)
    }

    func testOrientationFlip() {
        XCTAssertEqual(Orientation.horizontal.flipped, .vertical)
        XCTAssertEqual(Orientation.vertical.flipped, .horizontal)
    }
}
