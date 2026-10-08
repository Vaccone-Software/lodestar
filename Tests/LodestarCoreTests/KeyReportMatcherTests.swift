import XCTest
@testable import LodestarCore

/// A press matched to the one keyboard report that produced it: inside two
/// milliseconds, from one physical device, consumed once. The usage is
/// compared and forgotten; only outcome counts survive.
final class KeyReportMatcherTests: XCTestCase {
    private let base = 9_000_000_000_000.0   // monotonic nanoseconds
    private let a: Int64 = 0                  // keycode for the A position
    private let usageA: UInt32 = 0x04

    func testAReportInsideTheToleranceNamesItsKeyboard() {
        var matcher = KeyReportMatcher()
        matcher.report(usage: usageA, device: "kb", virtual: false, stamp: base)
        XCTAssertEqual(matcher.match(keycode: a, stamp: base + 300_000), .device("kb"))
    }

    func testAReportIsMatchedOnce() {
        var matcher = KeyReportMatcher()
        matcher.report(usage: usageA, device: "kb", virtual: false, stamp: base)
        _ = matcher.match(keycode: a, stamp: base)
        XCTAssertEqual(matcher.match(keycode: a, stamp: base), .missing)
    }

    func testOutsideTheToleranceIsNoMatch() {
        var matcher = KeyReportMatcher()
        matcher.report(usage: usageA, device: "kb", virtual: false, stamp: base)
        XCTAssertEqual(matcher.match(keycode: a, stamp: base + 2_500_000), .missing)
        XCTAssertEqual(matcher.match(keycode: a, stamp: nil), .missing, "a press with no stamp cannot be matched")
    }

    func testAnotherKeyIsNoMatch() {
        var matcher = KeyReportMatcher()
        matcher.report(usage: 0x05, device: "kb", virtual: false, stamp: base)
        XCTAssertEqual(matcher.match(keycode: a, stamp: base), .missing)
    }

    func testTwoKeyboardsInsideTheToleranceAreAmbiguous() {
        var matcher = KeyReportMatcher()
        matcher.report(usage: usageA, device: "one", virtual: false, stamp: base)
        matcher.report(usage: usageA, device: "two", virtual: false, stamp: base + 1_000_000)
        XCTAssertEqual(matcher.match(keycode: a, stamp: base + 500_000), .ambiguous)
    }

    /// A remapper that seizes the board re-emits from a virtual keyboard:
    /// its report is not a board's, so nothing is charged by it.
    func testAVirtualKeyboardsReportIsNotABoard() {
        var matcher = KeyReportMatcher()
        matcher.report(usage: usageA, device: "karabiner", virtual: true, stamp: base)
        XCTAssertEqual(matcher.match(keycode: a, stamp: base), .virtual)
    }

    func testAKeycodeWithNoUsageIsUnmapped() {
        var matcher = KeyReportMatcher()
        XCTAssertEqual(matcher.match(keycode: 63, stamp: base), .unmapped, "fn lives on Apple's own page")
    }

    func testOldReportsAreForgotten() {
        var matcher = KeyReportMatcher()
        matcher.report(usage: usageA, device: "kb", virtual: false, stamp: base)
        matcher.report(usage: usageA, device: "kb", virtual: false,
                       stamp: base + (KeyReportMatcher.retention + 1) * 1e9)
        XCTAssertEqual(matcher.match(keycode: a, stamp: base), .missing)
    }

    func testOnlyOutcomesAreCounted() {
        var matcher = KeyReportMatcher()
        matcher.report(usage: usageA, device: "kb", virtual: false, stamp: base)
        _ = matcher.match(keycode: a, stamp: base)
        _ = matcher.match(keycode: a, stamp: base)
        XCTAssertEqual(matcher.outcomes, ["exact": 1, "missing": 1])
    }

    func testTheTableMapsPositionsToKeyboardUsages() {
        XCTAssertEqual(KeyReportMatcher.usage(forKeycode: 0), 0x04, "A")
        XCTAssertEqual(KeyReportMatcher.usage(forKeycode: 49), 0x2C, "space")
        XCTAssertEqual(KeyReportMatcher.usage(forKeycode: 54), 0xE7, "right command")
        XCTAssertEqual(KeyReportMatcher.usage(forKeycode: 36), 0x28, "return")
        // Every position the hand table names as a letter or digit has one.
        for keycode in Keys.letters.union(Keys.digits) {
            XCTAssertNotNil(KeyReportMatcher.usage(forKeycode: keycode), "keycode \(keycode)")
        }
    }
}
