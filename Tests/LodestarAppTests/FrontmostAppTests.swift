import AppKit
import XCTest
@testable import lodestar

/// The app in front is told, not asked: an activation sets it, and the
/// editor's poll, which runs every second on the main thread, never makes
/// the LaunchServices round trip that stalled main under memory pressure.
final class FrontmostAppTests: XCTestCase {
    func testAnActivationSetsTheAppInFront() {
        let tracker = FrontmostApp.shared
        let me = NSRunningApplication.current
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                                                   userInfo: [NSWorkspace.applicationUserInfoKey: me])
        XCTAssertEqual(tracker.current?.pid, me.processIdentifier)
        XCTAssertEqual(tracker.current?.bundleID, me.bundleIdentifier)
        XCTAssertEqual(tracker.current?.name, me.localizedName)
    }

    func testTheEditorsPollNeverAsksLaunchServices() throws {
        let file = DesignDriftTests.appSources.appendingPathComponent("EditorController.swift")
        let code = DesignDriftTests.code(try String(contentsOf: file, encoding: .utf8))
        for asking in ["frontmostApplication", "NSRunningApplication(", "runningApplications"] {
            XCTAssertFalse(code.contains(asking), "EditorController asks LaunchServices (\(asking)); read FrontmostApp.shared")
        }
    }
}
