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

    private func difference(_ a: NSView, _ b: NSView) -> String {
        let x = GalleryRender.bitmap(of: a), y = GalleryRender.bitmap(of: b)
        guard let p = x.bitmapData, let q = y.bitmapData, x.pixelsWide == y.pixelsWide, x.pixelsHigh == y.pixelsHigh else {
            return "sizes \(x.pixelsWide)x\(x.pixelsHigh) and \(y.pixelsWide)x\(y.pixelsHigh)"
        }
        var count = 0, minX = Int.max, maxX = 0, minY = Int.max, maxY = 0
        for row in 0..<x.pixelsHigh {
            for column in 0..<x.pixelsWide {
                let at = row * x.bytesPerRow + column * 4
                if (0..<4).contains(where: { p[at + $0] != q[at + $0] }) {
                    count += 1
                    minX = min(minX, column); maxX = max(maxX, column); minY = min(minY, row); maxY = max(maxY, row)
                }
            }
        }
        return count == 0 ? "no pixel differs (the files do)" : "\(count) pixels differ, in x \(minX)...\(maxX), y \(minY)...\(maxY) of \(x.pixelsWide)x\(x.pixelsHigh)"
    }

    /// A shot kept through the other look's turn, and served again, draws as a
    /// shot built just now does, in both looks, for panels and for sheets; one
    /// with a caret in it is served to a sweep that only reads it and built
    /// again for one that draws it.
    func testAKeptBuildDrawsAsAFreshOneDoes() throws {
        let surfaces = ["launcher", "keep", "settings", "foundation", "pill", "meeting"]
        var seen = 0, seenCaret = 0
        for surface in surfaces {
            guard let shot = GalleryShots.all.first(where: { $0.surface == surface && $0.level == 1 && !$0.receded && $0.looks == GalleryLook.all })
            else { continue }
            for look in GalleryLook.all {
                look.apply()
                guard let first = try? shot.built(in: look) else { continue }
                // One with a caret in it is not drawn: drawing it ends the editing it was built in.
                let before = GalleryBuilds.isQuiet(first) ? pixels(first.view) : nil
                // The other look's turn, with this one kept through it.
                for other in GalleryLook.all where other != look { other.apply() }
                look.apply()
                let again = try shot.built(in: look)
                XCTAssertTrue(again.view === first.view, "\(shot.name(in: look)) is served, not built again")
                if !GalleryBuilds.isQuiet(first) {
                    let drawn = try shot.built(in: look, drawing: true)
                    XCTAssertFalse(drawn.view === first.view, "\(shot.name(in: look)) has a caret in it: built again for a sweep that draws it")
                    XCTAssertTrue(try shot.built(in: look).view === first.view, "and the fresh build is not what readers are served")
                    // What a reader is served is what a fresh build is: the same kinds of view, in the
                    // same places, holding the same words (drawing it would end the editing, so it is not drawn).
                    XCTAssertEqual(GalleryHost.appearance(of: [again.view.window].compactMap { $0 }),
                                   GalleryHost.appearance(of: [drawn.view.window].compactMap { $0 }),
                                   "\(shot.name(in: look)) is served as a fresh build stands")
                    seenCaret += 1
                    continue
                }
                let fresh = try shot.build(look)
                let another = try shot.build(look)
                // A picture with something alive in it (an icon read on a later
                // turn) is not the same twice even when built twice fresh; only
                // a shot that is, is held to the kept one.
                guard pixels(fresh.view) == pixels(another.view) else { continue }
                XCTAssertNotNil(before)
                XCTAssertEqual(pixels(again.view), pixels(fresh.view),
                               "\(shot.name(in: look)) draws as a fresh build does: \(difference(again.view, fresh.view))")
                seen += 1
            }
        }
        XCTAssertGreaterThanOrEqual(seen, 6, "enough of the shots were compared")
        XCTAssertGreaterThanOrEqual(seenCaret, 2, "and enough with a caret in them")
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
