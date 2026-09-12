import XCTest
@testable import LodestarCore

/// The histogram is the shape the moments could not give. Its edges are
/// constants rather than data, because two histograms can only be merged
/// if they agree on their bins and these must merge for the life of the
/// archive — so the arithmetic of the edges is worth pinning exactly.
final class HistogramTests: XCTestCase {
    func testFourBinsPerDoubling() {
        XCTAssertEqual(Histogram.index(for: Histogram.base), 0, "the base edge is the first bin")
        XCTAssertEqual(Histogram.index(for: 0.016), 4, "one doubling on is four bins on")
        XCTAssertEqual(Histogram.index(for: 0.032), 8)
        XCTAssertEqual(Histogram.index(for: 0.0001), 0, "under the base is the first bin, not a crash")
        XCTAssertEqual(Histogram.index(for: 100_000), Histogram.count - 1,
                       "past the top edge lands in the last bin: a histogram may not drop its own tail")
    }

    func testEdgesAndMidpointsAgreeWithTheIndex() {
        for index in [0, 1, 7, 20, 63] {
            let edge = Histogram.edge(index)
            XCTAssertEqual(Histogram.index(for: edge * 1.0001), index,
                           "just inside an edge is that edge's bin")
            let midpoint = Histogram.midpoint(index)
            XCTAssertGreaterThan(midpoint, edge)
            XCTAssertLessThan(midpoint, Histogram.edge(index + 1))
        }
    }

    func testQuantilesReadToTheBin() throws {
        var hist = Histogram()
        for _ in 0..<90 { hist.add(0.09) }
        for _ in 0..<10 { hist.add(4.0) }
        XCTAssertEqual(hist.total, 100)
        let median = try XCTUnwrap(hist.median)
        XCTAssertEqual(median, 0.09, accuracy: 0.02, "the mass, not the tail")
        let p95 = try XCTUnwrap(hist.quantile(0.95))
        XCTAssertGreaterThan(p95, 1.0, "the top twentieth is out in the tail")
    }

    func testTailMass() throws {
        var hist = Histogram()
        for _ in 0..<75 { hist.add(0.1) }
        for _ in 0..<25 { hist.add(3.0) }
        let mass = try XCTUnwrap(hist.mass(atOrAbove: 2.0))
        XCTAssertEqual(mass, 0.25, accuracy: 0.001)
        XCTAssertEqual(hist.mass(atOrAbove: 0.001), 1.0)
    }

    func testMergeIsAddition() {
        var a = Histogram()
        var b = Histogram()
        a.add(0.1)
        a.add(0.1)
        b.add(0.1)
        b.add(0.5)
        a.merge(b)
        XCTAssertEqual(a.total, 4)
        XCTAssertEqual(a.bins[Histogram.index(for: 0.1)], 3)
        XCTAssertEqual(a.bins[Histogram.index(for: 0.5)], 1)
    }

    /// Trailing zeros are trimmed on the way out and restored on the way
    /// in. A pulse of key presses occupies a dozen bins near the bottom,
    /// and fifty zeros after them on every pulse forever is the kind of
    /// cost that is invisible until the year it is not.
    func testCodableTrimsTrailingZeros() throws {
        var hist = Histogram()
        hist.add(0.01)
        let data = try JSONEncoder().encode(hist)
        let raw = try XCTUnwrap(String(data: data, encoding: .utf8))
        let written = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [Int])
        XCTAssertEqual(written.count, Histogram.index(for: 0.01) + 1,
                       "written up to the last non-empty bin and no further: \(raw)")
        let back = try JSONDecoder().decode(Histogram.self, from: data)
        XCTAssertEqual(back, hist, "a short array decodes back to a full-width histogram")
        XCTAssertEqual(back.bins.count, Histogram.count)
    }

    func testEmptyHistogramEncodesEmptyAndAnswersNothing() throws {
        let hist = Histogram()
        XCTAssertTrue(hist.isEmpty)
        XCTAssertNil(hist.median)
        XCTAssertNil(hist.mass(atOrAbove: 1))
        XCTAssertNil(hist.mean)
        let data = try JSONEncoder().encode(hist)
        XCTAssertEqual(String(data: data, encoding: .utf8), "[]")
        XCTAssertEqual(try JSONDecoder().decode(Histogram.self, from: data), hist)
    }
}
