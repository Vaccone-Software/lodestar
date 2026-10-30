import AppKit
import CoreGraphics
import XCTest

// The tripwire behind "no window may appear on a real display under test".
// Surfaces are laid out on the stand-in display (Screens.standIn), far off
// every real one; this is what fails the test that put a window anywhere
// else. It is in both test bundles (LodestarCoreTests links to it) and is
// wired in by LeakGuard's invokeTest wrapper.

/// Every window this process has on a real display.
///
/// It reads `NSScreen` directly, which no code in Sources may: the real
/// displays are exactly what a test must stay off, so they are asked for
/// here and nowhere else.
enum OffScreenGuard {
    /// A window found where a person would see it.
    struct Finding: Hashable {
        let window: String
        let frame: NSRect
        let display: NSRect

        var message: String {
            "\(window) is at \(Self.show(frame)), on a real display (\(Self.show(display))). Under a test run a "
                + "surface is laid out on the stand-in display (Screens.standIn, Stage.screen); route the window "
                + "through it, never around the guard."
        }

        private static func show(_ rect: NSRect) -> String {
            "(\(Int(rect.minX)), \(Int(rect.minY)), \(Int(rect.width)) by \(Int(rect.height)))"
        }
    }

    /// The real displays, in AppKit's coordinates, and the primary's height
    /// (what Quartz's top-left origin is flipped against).
    static var realDisplays: (frames: [NSRect], primaryHeight: CGFloat) {
        let screens = NSScreen.screens
        return (screens.map(\.frame), screens.first?.frame.maxY ?? 0)
    }

    /// Windows of this process that intersect one of `displays`.
    ///
    /// Two views of the same fact, because neither alone is all of it:
    /// the windows AppKit says are visible, and everything the window
    /// server has on screen for this process, which also holds layers that
    /// are not an `NSWindow` (an overlay another framework made, a status
    /// item). The server's list is of what is on a display: a window parked
    /// far off every display is not in it, which is the point.
    static func findings(
        windows: [NSWindow] = NSApp?.windows ?? [],
        displays: [NSRect] = realDisplays.frames,
        primaryHeight: CGFloat = realDisplays.primaryHeight,
        server: [[String: Any]] = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    ) -> [Finding] {
        func crossing(_ frame: NSRect) -> NSRect? { displays.first { $0.intersects(frame) } }
        var found: [Finding] = []
        var known = Set<Int>()
        for window in windows {
            known.insert(window.windowNumber)
            guard window.isVisible, let display = crossing(window.frame) else { continue }
            let title = window.title.isEmpty ? "" : " \"\(window.title)\""
            found.append(Finding(window: "\(type(of: window))\(title)", frame: window.frame, display: display))
        }
        for entry in server {
            guard let pid = entry[kCGWindowOwnerPID as String] as? Int32, pid == getpid(),
                  let number = entry[kCGWindowNumber as String] as? Int, !known.contains(number),
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let quartz = CGRect(dictionaryRepresentation: bounds) else { continue }
            let frame = NSRect(x: quartz.minX, y: primaryHeight - quartz.maxY, width: quartz.width, height: quartz.height)
            guard let display = crossing(frame) else { continue }
            let name = entry[kCGWindowName as String] as? String ?? ""
            let layer = entry[kCGWindowLayer as String] as? Int ?? 0
            found.append(Finding(window: "window \(number)\(name.isEmpty ? "" : " \"\(name)\"") on layer \(layer) (not an NSWindow)",
                                 frame: frame, display: display))
        }
        return found
    }

    /// What the main run loop has seen between a test's start and its end:
    /// a window shown and put away again inside the test is gone by the time
    /// the test is over, so the loop is watched at every turn.
    nonisolated(unsafe) private static var seen = Set<Finding>()
    nonisolated(unsafe) private static var watching = false

    static func watch() {
        guard !watching else { return }
        watching = true
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue, true, 0
        ) { _, _ in
            guard NSApp != nil else { return }
            // Only AppKit's own list here: cheap enough for every turn.
            let displays = realDisplays.frames
            for window in NSApp.windows where window.isVisible {
                if let display = displays.first(where: { $0.intersects(window.frame) }) {
                    let title = window.title.isEmpty ? "" : " \"\(window.title)\""
                    seen.insert(Finding(window: "\(type(of: window))\(title)", frame: window.frame, display: display))
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// Forget what was seen before the test about to begin.
    static func begin() { seen.removeAll() }

    /// One line for each window the test showed on a real display, now or
    /// at any turn of the run loop since `begin`.
    ///
    /// A window that is still there is put away, as LeakGuard puts a static
    /// back: the next test would otherwise be named for it.
    static func violations() -> [String] {
        let all = Set(findings()).union(seen)
        seen.removeAll()
        let displays = realDisplays.frames
        for window in NSApp?.windows ?? [] where window.isVisible && displays.contains(where: { $0.intersects(window.frame) }) {
            window.orderOut(nil)
        }
        return all.map(\.message).sorted()
    }
}
