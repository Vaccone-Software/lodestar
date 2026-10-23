import ApplicationServices
import CoreGraphics

/// Thin, synchronous wrappers over the C Accessibility API.
///
/// Known trap: every one of these calls blocks on the target app's event
/// loop, so one hung app can freeze whatever is calling. Two mitigations are
/// in place: `setGlobalAXTimeout` bounds each call, and `WindowModel` keeps
/// the cached model that answers most questions without calling at all.
public enum AX {
    /// The system-wide element, for asking what is focused or what is at
    /// a point. Never set a messaging timeout on it: that sets the whole
    /// process's (see `globalAXTimeout`). Set one on the element it returns.
    public static func systemWide() -> AXUIElement { AXUIElementCreateSystemWide() }

    public static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    public static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute) as? String
    }

    public static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        copy(element, attribute) as? Bool
    }

    public static func int(_ element: AXUIElement, _ attribute: String) -> Int? {
        copy(element, attribute) as? Int
    }

    public static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        copy(element, attribute) as? [AXUIElement]
    }

    public static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute) else { return nil }
        return AX.element(value)
    }

    /// An element the other app actually returned. The type tag is the
    /// check: a conditional cast to a CoreFoundation type does not
    /// inspect it, and Swift rejects the cast. A string or a number
    /// where an element was promised is skipped. The force-cast runs
    /// only after the tag matches.
    public static func element(_ value: CFTypeRef) -> AXUIElement? {
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return value as! AXUIElement
    }

    public static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = copy(element, attribute) else { return nil }
        return point(value)
    }

    /// A point boxed as an accessibility value, or nil when the box is a
    /// different type or a different shape.
    public static func point(_ value: CFTypeRef) -> CGPoint? {
        guard let ax = axValue(value) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(ax, .cgPoint, &point) else { return nil }
        return point
    }

    public static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = copy(element, attribute) else { return nil }
        return size(value)
    }

    /// A size boxed as an accessibility value, or nil when the box is a
    /// different type or a different shape.
    public static func size(_ value: CFTypeRef) -> CGSize? {
        guard let ax = axValue(value) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(ax, .cgSize, &size) else { return nil }
        return size
    }

    /// A rectangle boxed as an accessibility value, or nil when the box
    /// is a different type or a different shape.
    public static func rect(_ value: CFTypeRef) -> CGRect? {
        guard let ax = axValue(value) else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(ax, .cgRect, &rect) else { return nil }
        return rect
    }

    /// A text range boxed as an accessibility value, or nil when the box
    /// is a different type or a different shape.
    public static func range(_ value: CFTypeRef) -> CFRange? {
        guard let ax = axValue(value) else { return nil }
        var range = CFRange()
        guard AXValueGetValue(ax, .cfRange, &range) else { return nil }
        return range
    }

    /// An `AXValue`, or nil. The type tag is the check, for the same
    /// reason as `element`: the cast is unconditional and runs only
    /// after the tag matches, so a value of another type is skipped.
    private static func axValue(_ value: CFTypeRef) -> AXValue? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return value as! AXValue
    }

    @discardableResult
    public static func set(_ element: AXUIElement, _ attribute: String, to point: CGPoint) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(element, attribute as CFString, value) == .success
    }

    @discardableResult
    public static func set(_ element: AXUIElement, _ attribute: String, to size: CGSize) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(element, attribute as CFString, value) == .success
    }

    @discardableResult
    public static func set(_ element: AXUIElement, _ attribute: String, to flag: Bool) -> Bool {
        let value: CFBoolean = flag ? kCFBooleanTrue : kCFBooleanFalse
        return AXUIElementSetAttributeValue(element, attribute as CFString, value) == .success
    }
}

/// The process-wide messaging timeout, set once at launch.
///
/// A timeout set on a system-wide element is not that element's: it is the
/// default for every element in the process. Measured 2026-09-28 against a
/// hung app: 0.2 s set on a separate system-wide element cut an unrelated
/// app element's call from 1.52 s to 0.22 s. Four helpers once set their
/// own "short leash" that way (0.1 s and 0.25 s) and silently replaced
/// launch's 1 s for the whole app within the first 90 s of every run. One
/// value now, set in one place: 0.25 s is longer than what actually ran for
/// weeks, and short enough that tracking one hung app's window (about eleven
/// calls) stays well inside the main-thread watchdog.
public let globalAXTimeout: Float = 0.25

/// Sets `globalAXTimeout` for every AX call from this process. Without it,
/// a single hung app blocks callers for the system default (several seconds).
public func setGlobalAXTimeout(_ seconds: Float = globalAXTimeout) {
    AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
}

extension CGRect {
    /// Whether a frame another app reported can be turned into whole
    /// numbers. Accessibility frames are the other app's word: an infinite
    /// or absurd size passes a size minimum and an overlap test, and then
    /// traps at the first `Int(...)`. Nothing on a screen is a million
    /// points from its origin.
    public var isOnAScreensScale: Bool {
        [minX, minY, width, height].allSatisfy { $0.isFinite && abs($0) < 1_000_000 }
    }
}
