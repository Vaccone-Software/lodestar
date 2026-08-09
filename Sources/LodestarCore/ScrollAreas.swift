import ApplicationServices
import CoreGraphics
import Foundation

/// Scroll-pane discovery and end-jumps for scroll mode.
public enum ScrollAreas {
    public struct Pane {
        public let element: AXUIElement
        public let frame: CGRect
    }

    /// Bounded breadth-first walk of a window's AX tree collecting
    /// AXScrollArea panes. Bounded hard — visit and child caps keep one
    /// enormous web view from stalling the mode's entry.
    public static func panes(of window: AXUIElement) -> [Pane] {
        var found: [Pane] = []
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0

        while !queue.isEmpty, visited < 600, found.count < 10 {
            let (element, depth) = queue.removeFirst()
            visited += 1

            if AX.string(element, kAXRoleAttribute) == "AXScrollArea" {
                if let position = AX.point(element, kAXPositionAttribute),
                   let size = AX.size(element, kAXSizeAttribute),
                   size.width > 80, size.height > 80 {
                    found.append(Pane(element: element, frame: CGRect(origin: position, size: size)))
                }
                // Nested scroll areas exist (web views) but cycling wants the
                // outer panes; don't descend.
                continue
            }
            if depth < 8, let children = AX.elements(element, kAXChildrenAttribute) {
                for child in children.prefix(40) {
                    queue.append((child, depth + 1))
                }
            }
        }
        return found
    }

    /// Jump a pane to its top or bottom by setting the vertical scrollbar's
    /// value directly — deterministic, instant, immune to the window
    /// server's wheel-event acceleration and coalescing heuristics.
    @discardableResult
    public static func jumpToEnd(_ pane: AXUIElement, bottom: Bool) -> Bool {
        guard let bar = AX.element(pane, kAXVerticalScrollBarAttribute) else { return false }
        let value = NSNumber(value: bottom ? 1.0 : 0.0)
        return AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, value) == .success
    }
}
