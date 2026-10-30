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
}
