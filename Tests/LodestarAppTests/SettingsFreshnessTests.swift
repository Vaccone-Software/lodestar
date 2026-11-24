import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// What the Keyboards page is drawn from can never be a memo.
///
/// The window sat open overnight naming a keyboard that had been
/// unpaired for hours and not the one under the hands, because the
/// machine state is sampled when a pane is drawn and nothing drew it
/// again. A device list is the one thing in Settings that changes with
/// no event behind it: every other row answers to the config, and a
/// config write renders.
///
/// Three things now stand between that and a repeat. The roster is asked
/// fresh rather than from the tap path's half-minute cache; the render
/// reads the boards outside the doctor's one-second memo, so opening the
/// page cannot draw a stale list; and `KeyboardWatch` redraws the page
/// while it stands. The third has its own tests, and its rule is a value
/// type. The first two are each one line somebody could take back out
/// without a single test going red — a regression that would be silent,
/// and visible only hours later to a person looking for a keyboard that
/// is plugged in. So they are held here, by name.
final class SettingsFreshnessTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/lodestar").appendingPathComponent(name)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertGreaterThan(text.count, 200, "\(name) was found")
        return text
    }

    /// Every render reads the boards for itself, after the memo is
    /// consulted for everything else.
    func testTheDeviceListIsReadOutsideTheDoctorsMemo() throws {
        let controller = try source("SettingsController.swift")
        XCTAssertTrue(controller.contains("machine.keyboards = attachedKeyboards()"),
                      "the render must read the boards fresh; a memoized list is how the page went stale")
        guard let memo = controller.range(of: "doctorCache = (machine, findings, now)"),
              let fresh = controller.range(of: "machine.keyboards = attachedKeyboards()") else {
            return XCTFail("the render's shape has moved; check the freshness still holds")
        }
        XCTAssertTrue(fresh.lowerBound > memo.lowerBound,
                      "the fresh read comes after the memo, so it wins on a cached turn too")
    }

    /// The boards have a closure of their own. Filling them into the
    /// memoized machine state is exactly the bug, wearing a new shape.
    func testTheMemoizedMachineStateCarriesNoBoards() throws {
        let main = try source("main.swift")
        XCTAssertFalse(main.contains("state.keyboards"),
                       "boards belong to attachedKeyboards, never to the memoized machine state")
        XCTAssertTrue(main.contains("settings.attachedKeyboards = "),
                      "and the window is given that closure")
    }

    /// Half a minute is the right answer for the tap, which charges a
    /// press to a board and does not care that a third one just arrived.
    /// It is the wrong answer for a person looking at a list.
    func testThePageAsksTheRosterFreshNotTheTapPathsCache() throws {
        let monitor = try source("HealthMonitor.swift")
        guard let range = monitor.range(of: "func attachedKeyboards()") else {
            return XCTFail("the monitor no longer offers the boards")
        }
        let line = monitor[range.lowerBound...].prefix(200)
        XCTAssertTrue(line.contains("roster.refresh()"),
                      "the page's read bypasses the cache the tap path shares")
    }
}
