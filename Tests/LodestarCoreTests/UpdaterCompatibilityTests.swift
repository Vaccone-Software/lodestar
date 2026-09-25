import XCTest
@testable import LodestarCore

/// The updater refuses a build this Mac cannot run, from the bundle's own
/// architectures and minimum macOS.
final class UpdaterCompatibilityTests: XCTestCase {
    private let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0)
    private let ventura = OperatingSystemVersion(majorVersion: 13, minorVersion: 6, patchVersion: 0)

    func testAnAppleSiliconBuildIsRefusedOnIntel() {
        XCTAssertEqual(Updater.incompatibility(architectures: ["arm64"], minimumSystem: "14.0",
                                               appleSilicon: false, system: sonoma),
                       "needs a Mac with Apple silicon")
        XCTAssertNil(Updater.incompatibility(architectures: ["arm64", "x86_64"], minimumSystem: "13.0",
                                             appleSilicon: false, system: ventura), "a universal build runs")
    }

    func testANewerMacOSIsRefusedOnAnOlderOne() {
        XCTAssertEqual(Updater.incompatibility(architectures: ["arm64"], minimumSystem: "14.0",
                                               appleSilicon: true, system: ventura), "needs macOS 14")
        XCTAssertEqual(Updater.incompatibility(architectures: ["arm64"], minimumSystem: "14.0",
                                               appleSilicon: false, system: ventura),
                       "needs a Mac with Apple silicon and macOS 14")
        XCTAssertNil(Updater.incompatibility(architectures: ["arm64"], minimumSystem: "14.0",
                                             appleSilicon: true, system: sonoma))
        XCTAssertNil(Updater.incompatibility(architectures: ["arm64"], minimumSystem: nil,
                                             appleSilicon: true, system: ventura))
    }
}
