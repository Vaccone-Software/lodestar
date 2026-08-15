import ApplicationServices
import CoreGraphics

/// A live window: an AX element paired with its window-server ID.
///
/// Coordinates are Quartz global coordinates — origin at the top-left of the
/// primary display, y growing downward — the same space CGWindowList uses.
public struct AXWindow {
    public let element: AXUIElement
    public let id: CGWindowID

    public init?(element: AXUIElement) {
        guard let id = windowID(of: element) else { return nil }
        self.element = element
        self.id = id
    }

    public var title: String? { AX.string(element, kAXTitleAttribute) }
    public var subrole: String? { AX.string(element, kAXSubroleAttribute) }
    public var isMinimized: Bool { AX.bool(element, kAXMinimizedAttribute) ?? false }

    public var position: CGPoint? { AX.point(element, kAXPositionAttribute) }
    public var size: CGSize? { AX.size(element, kAXSizeAttribute) }
    public var frame: CGRect? {
        guard let position, let size else { return nil }
        return CGRect(origin: position, size: size)
    }

    @discardableResult
    public func setPosition(_ point: CGPoint) -> Bool {
        withoutMoveAnimation { AX.set(element, kAXPositionAttribute, to: point) }
    }

    /// Cross display truth: set size, then position, then size again —
    /// macOS clamps sizes to the display the window currently sits on, so a
    /// cross-display move needs the second size pass.
    @discardableResult
    public func setFrame(_ frame: CGRect) -> Bool {
        withoutMoveAnimation {
            let sizedFirst = AX.set(element, kAXSizeAttribute, to: frame.size)
            let positioned = AX.set(element, kAXPositionAttribute, to: frame.origin)
            let sizedAgain = AX.set(element, kAXSizeAttribute, to: frame.size)
            return sizedFirst && positioned && sizedAgain
        }
    }

    /// When an assistive client (VoiceOver and similar AX tools) has
    /// flipped `AXEnhancedUserInterface` on an app, macOS
    /// ANIMATES AX window moves — summons slide up out of the parked sliver
    /// instead of snapping. Drop the flag for the duration of the mutation
    /// and restore it, so assistive tech keeps its semantics.
    private func withoutMoveAnimation(_ mutate: () -> Bool) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return mutate() }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let enhanced = AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &value) == .success
            && (value as? Bool) == true
        guard enhanced else { return mutate() }
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        let result = mutate()
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        return result
    }

    @discardableResult
    public func raise() -> Bool {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success
    }

    @discardableResult
    public func setMinimized(_ minimized: Bool) -> Bool {
        AX.set(element, kAXMinimizedAttribute, to: minimized)
    }

    /// Make this the app's main window, so activating the app fronts it.
    @discardableResult
    public func makeMain() -> Bool {
        AX.set(element, kAXMainAttribute, to: true)
    }
}
