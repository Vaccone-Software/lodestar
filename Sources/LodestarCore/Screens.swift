import AppKit

/// The screens a surface is placed on, as AppKit counts them (bottom-left
/// origin, the primary's top edge at `frame.maxY`).
///
/// Every panel's position and size is read off a display, and a test that
/// read the real ones put its windows on the screen of whoever ran it. So no
/// surface asks `NSScreen` directly: it asks here. In the app this is
/// `NSScreen`, exactly; under a test run it is one stand-in display, far
/// off every real one, so a window laid out in a test is laid out, drawn and
/// captured without ever crossing a person's screen.
public enum Screens {
    /// A screen as a surface reads it.
    public struct Screen: Equatable, Sendable {
        public var frame: NSRect
        public var visibleFrame: NSRect
        /// The CGDirectDisplayID (`NSScreenNumber`); nil for the stand-in.
        public var id: CGDirectDisplayID?

        public init(frame: NSRect, visibleFrame: NSRect, id: CGDirectDisplayID?) {
            self.frame = frame
            self.visibleFrame = visibleFrame
            self.id = id
        }

        init(_ screen: NSScreen) {
            self.init(frame: screen.frame, visibleFrame: screen.visibleFrame,
                      id: (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value)
        }
    }

    /// The stand-in display of a test run: 1920 by 1050, with no menu bar or
    /// Dock, at a corner of the plane no real arrangement reaches.
    public static let standIn = NSRect(x: -40_000, y: -40_000, width: 1920, height: 1050)

    /// Every screen, the primary first: the Mac's under the app, the
    /// stand-in alone under a test run.
    public static var all: [Screen] {
        if TestRun.active { return [Screen(frame: standIn, visibleFrame: standIn, id: nil)] }
        return NSScreen.screens.map(Screen.init)
    }

    /// The primary screen, whose top edge is Quartz's zero.
    public static var primary: Screen? {
        if TestRun.active { return all.first }
        return NSScreen.screens.first.map(Screen.init)
    }

    /// The screen with the key window, or the primary when none has it.
    public static var main: Screen? {
        if TestRun.active { return primary }
        return NSScreen.main.map(Screen.init)
    }

    /// The height a Quartz y is taken from to make an AppKit one, or the
    /// reverse; zero when there is no screen.
    public static var primaryHeight: CGFloat { primary?.frame.maxY ?? 0 }

    public static func screen(for id: CGDirectDisplayID) -> Screen? {
        all.first { $0.id == id }
    }

    /// The screen whose frame holds `point` (AppKit coordinates).
    public static func screen(containing point: NSPoint) -> Screen? {
        all.first { NSMouseInRect(point, $0.frame, false) }
    }
}
