import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// Under a test run a Lodestar panel is given the process's own keys
/// (TestKeys): it says it is the key window, draws its caret and is sent
/// AppKit's notices, and the window server, which would take the keys from
/// the app in front, never hears of it.
final class TestKeysTests: XCTestCase {
    private func panel() -> KeyablePanel {
        let panel = KeyablePanel(contentRect: NSRect(origin: GalleryRender.away, size: NSSize(width: 200, height: 100)),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        addTeardownBlock { panel.orderOut(nil) }
        return panel
    }

    @MainActor
    func testAPanelHasTheRunsKeysAndTheWindowServerIsNeverAsked() {
        let first = panel(), second = panel()
        let before = NSApp.keyWindow
        var notices: [String] = []
        let watch = [(first, "first"), (second, "second")].flatMap { window, name in
            [(NSWindow.didBecomeKeyNotification, "has"), (NSWindow.didResignKeyNotification, "lost")].map { note, verb in
                NotificationCenter.default.addObserver(forName: note, object: window, queue: nil) { _ in
                    notices.append("\(name) \(verb)")
                }
            }
        }
        defer { watch.forEach(NotificationCenter.default.removeObserver) }

        first.makeKeyAndOrderFront(nil)
        XCTAssertTrue(first.isKeyWindow)
        XCTAssertTrue(NSApp.keyWindow === before, "AppKit's key window is untouched")
        second.makeKey()
        XCTAssertFalse(first.isKeyWindow, "one window has the keys")
        XCTAssertTrue(second.isKeyWindow)
        second.orderOut(nil)
        XCTAssertFalse(second.isKeyWindow, "a panel put away gives them up")
        XCTAssertNil(TestKeys.holder)
        XCTAssertTrue(NSApp.keyWindow === before)
        XCTAssertEqual(notices, ["first has", "first lost", "second has", "second lost"])
    }

    /// The panels still are ones that take the keys: the app outside a
    /// test run asks AppKit, as before.
    func testAKeyablePanelIsStillOneThatTakesTheKeys() {
        XCTAssertTrue(panel().canBecomeKey)
    }
}
