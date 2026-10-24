import AppKit
import XCTest
@testable import lodestar

/// The sweeps share one build of each picture (GalleryBuilds), which is
/// right only if that build is what a fresh one would be.
final class GalleryBuildsTests: XCTestCase {
    override func tearDown() {
        GalleryBuilds.discard()
        GalleryLook.reset()
        super.tearDown()
    }

    private func pixels(_ view: NSView) -> Data? {
        GalleryRender.bitmap(of: view).tiffRepresentation
    }

    /// A shot kept through the other look's turn, and served again, draws as a
    /// shot built just now does, in both looks, for panels and for sheets.
    func testAKeptBuildDrawsAsAFreshOneDoes() throws {
        let surfaces = ["launcher", "keep", "settings", "foundation", "pill", "meeting"]
        var seen = 0
        for surface in surfaces {
            guard let shot = GalleryShots.all.first(where: { $0.surface == surface && $0.level == 1 && !$0.receded && $0.looks == GalleryLook.all })
            else { continue }
            for look in GalleryLook.all {
                look.apply()
                guard let first = try? shot.built(in: look) else { continue }
                let before = pixels(first.view)
                // The other look's turn, with this one kept through it.
                for other in GalleryLook.all where other != look { other.apply() }
                look.apply()
                let again = try shot.built(in: look)
                XCTAssertTrue(again.view === first.view, "\(shot.name(in: look)) is served, not built again")
                let fresh = try shot.build(look)
                let another = try shot.build(look)
                // A picture with something alive in it (a caret, an icon read
                // on a later turn) is not the same twice even when built twice
                // fresh; only a shot that is, is held to the kept one.
                guard pixels(fresh.view) == pixels(another.view) else { continue }
                XCTAssertNotNil(before)
                XCTAssertEqual(pixels(again.view), pixels(fresh.view), "\(shot.name(in: look)) draws as a fresh build does")
                seen += 1
            }
        }
        XCTAssertGreaterThanOrEqual(seen, 8, "enough of the shots were compared")
    }

    /// A shot is kept for the look in force and the Eye comfort it was built at, and no other.
    func testABuildIsKeptOnlyForTheLookAndTheComfortItWasBuiltAt() throws {
        let shot = try XCTUnwrap(GalleryShots.all.first { $0.surface == "foundation" && $0.looks == GalleryLook.all })
        GalleryLook.day.apply()
        let full = try shot.built(in: .day)
        XCTAssertTrue(try shot.built(in: .day).view === full.view)
        EyeComfortState.shared.set(enabled: true, level: GalleryShots.bedtime)
        defer { EyeComfortState.shared.set(enabled: false, level: 1) }
        XCTAssertFalse(try shot.built(in: .day).view === full.view, "built at another level")
        EyeComfortState.shared.set(enabled: false, level: 1)
        // Asked for the night's while the day is in force: made fresh, and not kept.
        let wrong = try shot.built(in: .night)
        GalleryLook.night.apply()
        XCTAssertFalse(try shot.built(in: .night).view === wrong.view)
    }
}
