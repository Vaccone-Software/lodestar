import XCTest
@testable import LodestarCore

/// The mark is one definition every picture of it is drawn from; these pin
/// the definition so a change to it is a decision, not an accident.
final class MarkTests: XCTestCase {
    func testTheStarIsTheChosenOne() {
        XCTAssertEqual(Mark.faces.count, 34, "the visible faces of the chosen construction")
        for face in Mark.faces {
            XCTAssertEqual(face.points.count, 3)
            for p in face.points {
                XCTAssertLessThanOrEqual(abs(p.x), 1.0001)
                XCTAssertLessThanOrEqual(abs(p.y), 1.0001)
            }
            XCTAssertGreaterThanOrEqual(face.tone, -1)
            XCTAssertLessThanOrEqual(face.tone, 1)
        }
    }

    /// Two faces that share an edge are always told apart.
    func testNeighboursAreSeparated() {
        let key = { (p: Mark.Point) in String(format: "%.4f,%.4f", p.x, p.y) }
        var edges: [String: [Double]] = [:]
        for face in Mark.faces {
            for k in 0..<3 {
                let a = key(face.points[k]), b = key(face.points[(k + 1) % 3])
                edges[a < b ? a + "|" + b : b + "|" + a, default: []].append(face.tone)
            }
        }
        let shared = edges.values.filter { $0.count == 2 }
        XCTAssertFalse(shared.isEmpty)
        for tones in shared {
            XCTAssertGreaterThanOrEqual(abs(tones[0] - tones[1]), Mark.separation - 1e-9)
        }
    }

    func testTheColorIsAParameter() {
        let orange = Mark.internationalOrange
        XCTAssertEqual(orange.hex, "#FF4F00")
        XCTAssertEqual(Mark.fill(tone: 0, accent: orange), orange, "the middle value is the accent itself")
        XCTAssertEqual(Mark.fill(tone: 1, accent: orange), orange.mixed(with: .white, 0.4))
        XCTAssertEqual(Mark.fill(tone: -1, accent: orange), orange.mixed(with: .black, 0.44))
        XCTAssertEqual(Mark.fill(tone: 5, accent: orange), Mark.fill(tone: 1, accent: orange), "values are clamped")
        let blue = Mark.RGB(hex: "#0A84FF")!
        XCTAssertNotEqual(Mark.ground(accent: blue).top, Mark.ground(accent: orange).top, "the ground carries the accent")
        XCTAssertNil(Mark.RGB(hex: "#12345"))
        XCTAssertEqual(Mark.RGB(hex: "0a84ff")?.hex, "#0A84FF")
        XCTAssertEqual(Set(Mark.presets.map(\.name)).count, Mark.presets.count)
        XCTAssertEqual(Mark.presets.first?.color, orange, "the shipped color comes first")
    }

    func testTheSVGDrawsEveryFace() {
        let svg = Mark.svg(accent: .init(hex: 0x30D158), size: 64, ground: true)
        XCTAssertEqual(svg.components(separatedBy: "<polygon").count - 1, Mark.faces.count)
        XCTAssertTrue(svg.contains("linearGradient"), "the ground")
        XCTAssertFalse(Mark.svg().contains("linearGradient"), "the bare mark has no ground")
    }
}
