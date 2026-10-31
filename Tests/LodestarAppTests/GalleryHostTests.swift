import AppKit
import XCTest
@testable import lodestar

/// How the harness waits. It waits for what a surface shows to be there and to
/// stop changing, never for a time to pass; and a sweep says which surface broke.
final class GalleryHostTests: XCTestCase {
    override func tearDown() { GalleryLook.reset() }

    /// A borderless window holding one label, which `body` can change.
    private func labelled(_ text: String) -> (NSWindow, NSTextField) {
        let label = NSTextField(labelWithString: text)
        let window = GalleryHost.window(label, size: NSSize(width: 200, height: 40), look: .day)
        return (window, label)
    }

    /// A surface that stages itself two turns after it is asked for: the
    /// window is waited for, with its words in it.
    func testASurfaceThatIsMadeTwoTurnsLaterIsWaitedFor() throws {
        var holder: [NSWindow] = []
        let (view, keep) = try GalleryHost.surface(made: {
            DispatchQueue.main.async {
                DispatchQueue.main.async {
                    let (window, _) = self.labelled("late")
                    holder.append(window)
                }
            }
            return []
        })
        let label = try XCTUnwrap(view as? NSTextField, "the surface that was made is not the one asked for")
        XCTAssertEqual(label.stringValue, "late")
        _ = (keep, holder)
    }

    /// A surface whose words and size arrive on later turns is read when they
    /// have, not before: settling returns once nothing changes.
    func testSettleWaitsForWhatArrivesOnLaterTurns() {
        let (window, label) = labelled("")
        var turns = 0
        func arrive() {
            turns += 1
            if turns < 5 { DispatchQueue.main.async(execute: arrive) } else {
                label.stringValue = "arrived"
                label.frame.size.width = 120
            }
        }
        DispatchQueue.main.async(execute: arrive)
        XCTAssertTrue(GalleryHost.settle(window))
        XCTAssertEqual(label.stringValue, "arrived")
        XCTAssertEqual(label.frame.width, 120)
    }

    /// A window that never stops changing does not hold the run for ever: the
    /// guard ends the wait, and says it did.
    func testSettleGivesUpOnASurfaceThatNeverStops() {
        let (window, label) = labelled("0")
        var count = 0
        var running = true
        func change() {
            guard running else { return }
            count += 1
            label.stringValue = "\(count)"
            DispatchQueue.main.async(execute: change)
        }
        DispatchQueue.main.async(execute: change)
        defer { running = false }
        XCTAssertFalse(GalleryHost.settle({ [window] in [window] }, limit: 0.3))
        XCTAssertGreaterThan(count, 3, "and it turned the loop in the meantime")
    }

    /// A message from a sweep is "<surface>: <what>", and a surface with
    /// several is one failure.
    func testAFailureIsGroupedUnderTheSurfaceThatBrokeIt() {
        let grouped = GallerySweep.grouped([
            "keep-source-menu-day: a key is narrower than tall",
            "launcher-typed-ma-night: a row is 47, not 48",
            "keep-source-menu-day: two lode keys: side by side",
            "keep-source-menu-day: a key is narrower than tall",
        ])
        XCTAssertEqual(grouped.keys.sorted(), ["keep-source-menu-day", "launcher-typed-ma-night"])
        XCTAssertEqual(grouped["keep-source-menu-day"], ["a key is narrower than tall", "two lode keys: side by side"])
    }

    /// The evening is held as arithmetic, and a sweep draws the full level and
    /// bedtime; a sweep that asks for every hour gets the evening too.
    func testASweepDrawsFullAndBedtimeUnlessItAsksForEveryHour() throws {
        let shots = GalleryShots.all
        let evening = try XCTUnwrap(shots.first { $0.level == GalleryShots.evening })
        let bedtime = try XCTUnwrap(shots.first { $0.level == GalleryShots.bedtime })
        let full = try XCTUnwrap(shots.first { $0.level == 1 && !$0.receded })
        XCTAssertFalse(GallerySweep.Hours.drawn.includes(evening))
        XCTAssertTrue(GallerySweep.Hours.drawn.includes(bedtime))
        XCTAssertTrue(GallerySweep.Hours.drawn.includes(full))
        XCTAssertTrue(GallerySweep.Hours.every.includes(evening))
    }

    /// The memoised pixel is the pixel `colorAt` gives, converted as the sweeps
    /// always converted it: the same sRGB components and alpha, at every point
    /// of pictures that have edges, shadows, text and icons in them.
    func testAMemoisedPixelIsTheOneColorAtGives() throws {
        var compared = 0
        for name in ["launcher-results-second-chosen", "keep-clips-newest-chosen", "settings-general"] {
            let shot = try XCTUnwrap(GalleryShots.all.first { $0.surface + "-" + $0.state == name })
            GalleryLook.day.apply()
            let (view, keep) = try shot.built(in: .day)
            let rep = GalleryRender.bitmap(of: view, keys: false)
            for y in stride(from: 0, to: rep.pixelsHigh, by: 7) {
                for x in stride(from: 0, to: rep.pixelsWide, by: 7) {
                    let direct = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                    let memo = GalleryPixels.srgb(rep, x: x, y: y)
                    XCTAssertEqual(memo?.redComponent, direct?.redComponent, "\(name) (\(x), \(y))")
                    XCTAssertEqual(memo?.greenComponent, direct?.greenComponent)
                    XCTAssertEqual(memo?.blueComponent, direct?.blueComponent)
                    XCTAssertEqual(memo?.alphaComponent, direct?.alphaComponent)
                    compared += 1
                }
            }
            _ = keep
        }
        XCTAssertGreaterThan(compared, 20_000)
        XCTAssertNil(GalleryPixels.srgb(GalleryRender.bitmap(of: NSView(frame: NSRect(x: 0, y: 0, width: 4, height: 4))), x: 99, y: 99))
    }

    /// A region drawn alone has the pixels the whole picture has there, for panels, sheets and
    /// pictures with a caret in them: all of them, bar the odd one a level of 255 off.
    func testARegionHasTheWholePicturesPixels() throws {
        var compared = 0, off = 0, pictures = 0
        var worst: CGFloat = 0
        let all = GalleryShots.all.filter { $0.looks.contains(.day) && $0.level == 1 && !$0.receded }
        let chosen = Set(stride(from: 5, to: all.count, by: 12).map { all[$0].surface + "-" + all[$0].state })
        for picture in GallerySweep.pictures(looks: [.day], where: { chosen.contains($0.surface + "-" + $0.state) }) {
            pictures += 1
            let root = picture.root, size = root.bounds.size
            let whole = GalleryRender.bitmap(of: root, keys: false)
            let rects = [NSRect(x: size.width * 0.3, y: size.height * 0.4, width: size.width * 0.35, height: size.height * 0.12),
                         NSRect(x: 5, y: 7, width: 40, height: 9)]
            let region = GalleryRegion.render(root, covering: rects, name: picture.name)
            for rect in rects {
                for y in Int(rect.minY * region.scale)..<Int(rect.maxY * region.scale) where (0..<whole.pixelsHigh).contains(y) {
                    for x in Int(rect.minX * region.scale)..<Int(rect.maxX * region.scale) where (0..<whole.pixelsWide).contains(x) {
                        compared += 1
                        guard let a = region.srgb(x: x, y: y), let b = GalleryPixels.srgb(whole, x: x, y: y) else {
                            XCTFail("\(picture.name) (\(x), \(y)) is not there"); continue
                        }
                        if a == b { continue }
                        off += 1
                        worst = max(worst, abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent),
                                    abs(a.blueComponent - b.blueComponent), abs(a.alphaComponent - b.alphaComponent))
                    }
                }
            }
        }
        XCTAssertGreaterThan(pictures, 5)
        XCTAssertGreaterThan(compared, 100_000)
        XCTAssertLessThan(Double(off) / Double(compared), 1e-5, "\(off) of \(compared) pixels differ")
        XCTAssertLessThanOrEqual(worst, 1.0 / 255 + 1e-6, "and by no more than a level")
    }

    /// A pixel the rule did not say it reads is a failure, not a nothing.
    func testAPixelOutsideTheRegionIsAFailure() throws {
        let label = NSTextField(labelWithString: "a region")
        let window = GalleryHost.window(label, size: NSSize(width: 200, height: 100), look: .day)
        let region = GalleryRegion.render(label, covering: [NSRect(x: 10, y: 10, width: 20, height: 10)], name: "probe")
        XCTAssertNotNil(region.srgb(x: 30, y: 30))
        XCTAssertNil(region.srgb(x: 5000, y: 30), "outside the picture is nothing, as ever")
        XCTExpectFailure("a read outside the region is reported") {
            XCTAssertNil(region.srgb(x: 300, y: 150))
        }
        _ = window
    }
}
