import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// Where a surface goes is read off `Screens`, which is the stand-in display
/// under a test run. A direct read of `NSScreen` would be the real display
/// again, and the tripwire (OffScreenGuard) would find out only when a test
/// happened to show that surface, so no source reads it but the files here.
final class ScreensTests: XCTestCase {
    private static let allowed: [String: String] = [
        "Screens.swift": "the seam itself",
        "Displays.swift": "where another application's windows go (Mover, Layout, Parking), never one of ours",
        "Environment.swift": "the record of what screens the Mac has, which places nothing",
        "HealthMonitor.swift": "the count of screens in that record",
        "SplitPreview.swift": "a command-line harness that photographs the real display on purpose",
        "StripPreview.swift": "a command-line harness that photographs the real display on purpose",
        "Ceramic.swift": "the parameter type of AppKit's constrainFrameRect, which the panel overrides to ignore",
    ]

    func testNothingReadsNSScreenButTheFilesThatAreAllowedTo() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        var offenders: [String] = []
        var seen = Set<String>()
        for case let url as URL in try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)) {
            guard url.pathExtension == "swift" else { continue }
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (number, line) in lines.enumerated()
            where line.contains("NSScreen") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                seen.insert(url.lastPathComponent)
                if Self.allowed[url.lastPathComponent] == nil { offenders.append("\(url.lastPathComponent):\(number + 1)") }
            }
        }
        XCTAssertEqual(offenders, [], "read the screens through Screens, which is the stand-in under a test run")
        XCTAssertEqual(seen.symmetricDifference(Self.allowed.keys), [], "a file that no longer reads NSScreen comes off the list")
    }

    func testAPointIsOnTheScreenThatHoldsIt() {
        let inside = NSPoint(x: Screens.standIn.midX, y: Screens.standIn.midY)
        XCTAssertEqual(Screens.screen(containing: inside)?.frame, Screens.standIn)
        XCTAssertNil(Screens.screen(containing: NSPoint(x: 10, y: 10)), "a point on no screen is on none")
        XCTAssertNil(Screens.screen(for: 1), "the stand-in has no display id")
    }
}
