import AppKit
import ApplicationServices

/// An app as the Accessibility API sees it.
public struct AXApplication {
    public let runningApplication: NSRunningApplication
    public let element: AXUIElement

    public init(_ app: NSRunningApplication) {
        self.runningApplication = app
        self.element = AXUIElementCreateApplication(app.processIdentifier)
    }

    public var pid: pid_t { runningApplication.processIdentifier }
    public var bundleID: String? { runningApplication.bundleIdentifier }
    public var name: String { runningApplication.localizedName ?? "pid \(pid)" }

    /// The app's AX windows that bridge to a window-server ID.
    /// nil means the windows attribute itself was unreadable (hung app, no AX
    /// support, or this process is not trusted) — distinct from "no windows".
    public func windows() -> [AXWindow]? {
        guard let elements = AX.elements(element, kAXWindowsAttribute) else { return nil }
        return elements.compactMap { AXWindow(element: $0) }
    }

    /// AX windows the private call could not bridge — probe diagnostics.
    public func unbridgedWindowCount() -> Int {
        guard let elements = AX.elements(element, kAXWindowsAttribute) else { return 0 }
        return elements.filter { windowID(of: $0) == nil }.count
    }

    public func focusedWindow() -> AXWindow? {
        guard let focused = AX.element(element, kAXFocusedWindowAttribute) else { return nil }
        return AXWindow(element: focused)
    }

    public func focusedOrFirstWindow() -> AXWindow? {
        focusedWindow() ?? windows()?.first
    }

    /// Every ordinary (Dock-visible) app currently running.
    public static func regularApps() -> [AXApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { AXApplication($0) }
    }

    /// Regular + accessory apps — anything that can own a window. Accessory
    /// apps (launcher panels, menu bar apps) have real windows too, so
    /// by-ID lookups must not skip them.
    public static func visibleApps() -> [AXApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited }
            .map { AXApplication($0) }
    }
}
