import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The process runs on the suite's own settings, set when the bundle loads
/// (LeakRegistry.pinEnvironment), whatever the Mac it runs on is set to. The
/// guard puts each back after a test that changed it, so these hold at the
/// start of every test in the process, whichever ran before.
final class EnvironmentPinTests: XCTestCase {
    /// Dark, or Light for a process started with `NSRequiresAquaSystemAppearance`
    /// (scripts/test.sh under TEST_LIGHT): never the Mac's own.
    func testTheLookIsTheSuitesAndNotTheMacs() {
        let light = UserDefaults.standard.bool(forKey: "NSRequiresAquaSystemAppearance")
        XCTAssertEqual(NSApp.appearance?.name, light ? .aqua : .darkAqua)
        XCTAssertEqual(NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), light ? .aqua : .darkAqua)
        XCTAssertEqual(Tone.systemDark, !light)
    }

    func testMotionAndContrastAreOff() {
        XCTAssertFalse(Accessibility.reduceMotion())
        XCTAssertFalse(Accessibility.increaseContrast())
    }

    func testEveryWindowReportsTheGalleryScale() {
        let window = NSWindow(contentRect: NSRect(origin: Screens.standIn.origin, size: NSSize(width: 10, height: 10)),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        XCTAssertEqual(window.backingScaleFactor, GalleryRender.scale)
    }

    func testTheOnlyDisplayIsTheStandIn() {
        XCTAssertEqual(Screens.all.map(\.frame), [Screens.standIn])
    }
}
