import AppKit
import Synchronization

/// Where is "here"? The single answer every surface consults — layouts
/// place there, panels present there. Pointer by default; keyboard focus
/// as the configurable alternative (app.active-display).
public enum ActivePolicy {
    public enum Mode: String, CaseIterable, Sendable {
        case pointer
        case focus
    }

    /// The setting is written from main (config load) and read wherever a
    /// panel or a layout asks where "here" is, so both live behind one lock.
    private struct State {
        var mode: Mode = .pointer
        var cachedPresentation: (frame: NSRect, at: Date)?
    }
    private static let state = Mutex(State())

    public static var mode: Mode {
        get { state.withLock { $0.mode } }
        set { state.withLock { $0.mode = newValue } }
    }

    /// The active display, for panel positioning (AppKit coordinates).
    public static func appKitScreen(fallbackFrom layout: LayoutController?) -> Screens.Screen? {
        if mode == .pointer, let location = CGEvent(source: nil)?.location,
           let display = Displays.display(containing: CGRect(origin: location, size: CGSize(width: 1, height: 1))),
           let screen = screen(for: display.id) {
            return screen
        }
        if let display = layout?.activeDisplay(), let screen = screen(for: display.id) {
            return screen
        }
        return Screens.main ?? Screens.primary
    }

    public static func screen(for id: CGDirectDisplayID) -> Screens.Screen? {
        Screens.screen(for: id)
    }

    /// Shared by every panel: the visible frame to center on.
    ///
    /// Memoized for a quarter second: every read costs a window-server
    /// pointer query plus a display walk, panels re-read it per keystroke,
    /// and the guide reads it twice per build. A pointer that crossed
    /// displays inside the window is 250ms of stale placement — below
    /// what a hand can notice, far below what the queries were costing.
    public static var presentationFrame: NSRect {
        if let frameOverride { return frameOverride }
        let now = Date()
        if let cached = state.withLock({ $0.cachedPresentation }), now.timeIntervalSince(cached.at) < 0.25 {
            return cached.frame
        }
        let frame = (appKitScreen(fallbackFrom: nil) ?? Screens.primary)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        state.withLock { $0.cachedPresentation = (frame, now) }
        return frame
    }

    /// A fixed frame standing in for the screen. The harness sets it: how
    /// many cards the strip draws, where a panel sits, and what fits are
    /// all read off the display, and a test that ran on the developer's
    /// 1920-wide screen failed on a CI runner's narrower virtual one for
    /// three days, on the oldest clip's card being off the strip.
    ///
    /// Unlocked on purpose: only tests set it, on main, before the panel that
    /// reads it exists.
    nonisolated(unsafe) public static var frameOverride: NSRect?
}
