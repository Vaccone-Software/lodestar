import AppKit

/// Where is "here"? The single answer every surface consults — layouts
/// place there, panels present there. Pointer by default; keyboard focus
/// as the configurable alternative (app.active-display).
public enum ActivePolicy {
    public enum Mode: String {
        case pointer
        case focus
    }

    public static var mode: Mode = .pointer

    /// The active display as an NSScreen, for panel positioning
    /// (AppKit coordinates). NSScreenNumber is the CGDirectDisplayID.
    public static func appKitScreen(fallbackFrom layout: LayoutController?) -> NSScreen? {
        if mode == .pointer, let location = CGEvent(source: nil)?.location,
           let display = Displays.display(containing: CGRect(origin: location, size: CGSize(width: 1, height: 1))),
           let screen = screen(for: display.id) {
            return screen
        }
        if let display = layout?.activeDisplay(), let screen = screen(for: display.id) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    public static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }

    /// Shared by every panel: the visible frame to center on.
    public static var presentationFrame: NSRect {
        (appKitScreen(fallbackFrom: nil) ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }
}
