import XCTest
@testable import LodestarCore

/// The glyphs are one definition every symbol Lodestar draws comes from;
/// these pin what each one is made of, so a change is a decision.
final class GlyphTests: XCTestCase {
    /// Every glyph is cut inside its square and the margin round it, of
    /// planes the light can value.
    func testEveryGlyphIsPlanesInsideItsSquare() {
        for glyph in Glyph.allCases {
            let solid = glyph.planes.filter { !$0.cut }
            XCTAssertGreaterThan(solid.count, 0, "\(glyph) has something to draw")
            for plane in glyph.planes {
                XCTAssertGreaterThanOrEqual(plane.points.count, 3, "\(glyph): a plane is a shape")
                XCTAssertTrue((0...1).contains(plane.value), "\(glyph): a value from the light")
                for p in plane.points {
                    let reach = -Glyph.margin...(100 + Glyph.margin)
                    XCTAssertTrue(reach.contains(p.x) && reach.contains(p.y), "\(glyph) stays in its square: \(p)")
                }
            }
        }
    }

    /// The accent lands only where the hand goes next (design/01-colour.md):
    /// the click, the caret, a correction, the way a thing moves or routes,
    /// what is added, chosen or pinned, what needs you, and the way back.
    func testTheAccentIsWhereTheHandGoesNext() {
        let lit: Set<Glyph> = [.click, .select, .rename, .editor, .needsYou, .moveHere, .addLink, .route,
                               .profilePinned, .chosen, .undo]
        XCTAssertEqual(Set(Glyph.allCases.filter(\.hasAccent)), lit)
    }

    /// Lit from above: a stroke lying flat shows its upper face lit and its
    /// lower face turned away, so the two strengths are always there.
    func testTheLightIsAbove() {
        let values = Glyph.refused.planes.map(\.value) + Glyph.menuBarShown.planes.map(\.value)
        XCTAssertTrue(values.contains { $0 >= 0.5 } && values.contains { $0 < 0.5 })
        XCTAssertGreaterThan(Glyph.light.y, 0.9, "the one light is above")
    }

    /// The same glyph every time: nothing in a drawing is random.
    func testAGlyphIsTheSameEveryTime() {
        for glyph in Glyph.allCases {
            XCTAssertEqual(glyph.planes.map(\.points), glyph.planes.map(\.points))
        }
    }
}
