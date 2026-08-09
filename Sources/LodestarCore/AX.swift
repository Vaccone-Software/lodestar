import ApplicationServices
import CoreGraphics

/// Thin, synchronous wrappers over the C Accessibility API.
///
/// Known trap: every one of these calls blocks on the
/// target app's event loop. `setGlobalAXTimeout` caps the damage for now; the
/// real switcher will need a cached model so one hung app can never freeze it.
public enum AX {
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
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    public static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    public static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
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

/// Default messaging timeout for every AX call from this process. Without it,
/// a single hung app blocks callers for the system default (several seconds).
public func setGlobalAXTimeout(_ seconds: Float) {
    AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
}
