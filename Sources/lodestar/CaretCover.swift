import AppKit
import LodestarCore

/// Whether Keep, as it opens, stands over the place the hand is about to
/// paste into. Keep opens at the bars' height so a full-window terminal's
/// prompt at the bottom stays clear; this is the record that says how
/// often anything else is covered, read once per open, off the main
/// thread, and kept as a word, never as a position or a field's text.
enum CaretCover {
    /// "caret" when the insertion point itself could be placed, "field"
    /// when only the focused element's frame could, then whether Keep
    /// covers it; "unknown" when neither answered.
    static func verdict(block: NSRect, primaryHeight: CGFloat) -> String {
        let system = AX.systemWide()
        guard let focused = AX.element(system, kAXFocusedUIElementAttribute as String) else { return "unknown" }
        // Accessibility measures from the top-left of the primary display;
        // Keep was placed from its bottom-left.
        func flipped(_ rect: CGRect) -> NSRect {
            NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        }
        if let caret = caretBounds(focused), caret.width >= 0, caret.height > 0 {
            return flipped(caret).insetBy(dx: -1, dy: 0).intersects(block) ? "caret covered" : "caret clear"
        }
        if let origin = AX.point(focused, kAXPositionAttribute as String),
           let size = AX.size(focused, kAXSizeAttribute as String), size.width > 0, size.height > 0 {
            return flipped(CGRect(origin: origin, size: size)).intersects(block) ? "field covered" : "field clear"
        }
        return "unknown"
    }

    /// The insertion point's own rectangle, where the field will draw one.
    private static func caretBounds(_ element: AXUIElement) -> CGRect? {
        guard let raw = AX.copy(element, kAXSelectedTextRangeAttribute as String),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { return nil }
        var probe = CFRange(location: range.location, length: max(range.length, 1))
        guard let parameter = AXValueCreate(.cfRange, &probe) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &out) == .success,
              let value = out, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }
}
