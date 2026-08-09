import AppKit
import CoreGraphics

public enum Displays {
    /// The usable (menu-bar- and Dock-excluded) frame of the screen that
    /// contains `rect`, converted to Quartz coordinates. Falls back to the
    /// main screen when nothing contains it (e.g. a parked window).
    public static func visibleFrame(containing rect: CGRect) -> CGRect {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return unionBounds() }
        let primaryHeight = primary.frame.maxY

        func toQuartz(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
        }

        let candidate = screens.first { toQuartz($0.frame).intersects(rect) }
            ?? NSScreen.main
            ?? primary
        return toQuartz(candidate.visibleFrame)
    }

    /// Every active display's bounds, in Quartz global coordinates (top-left
    /// origin, y growing downward) — no AppKit coordinate flipping involved.
    public static func allBounds() -> [CGRect] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success, count > 0 else {
            return []
        }
        return (0..<Int(count)).map { CGDisplayBounds(ids[$0]) }
    }

    /// The bounding box of every display.
    public static func unionBounds() -> CGRect {
        allBounds().reduce(.null) { $0.union($1) }
    }

    public struct DisplayInfo: Equatable {
        public let id: CGDirectDisplayID
        public let bounds: CGRect
    }

    /// Active displays ordered by physical position, left to right.
    public static func ordered() -> [DisplayInfo] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success, count > 0 else {
            return []
        }
        return (0..<Int(count))
            .map { DisplayInfo(id: ids[$0], bounds: CGDisplayBounds(ids[$0])) }
            .sorted {
                if $0.bounds.minX != $1.bounds.minX { return $0.bounds.minX < $1.bounds.minX }
                return $0.bounds.minY < $1.bounds.minY
            }
    }

    /// The display owning a rect — by intersection area, else nearest center.
    public static func display(containing rect: CGRect) -> DisplayInfo? {
        let displays = ordered()
        if let best = displays.max(by: {
            area($0.bounds.intersection(rect)) < area($1.bounds.intersection(rect))
        }), area(best.bounds.intersection(rect)) > 0 {
            return best
        }
        return displays.min {
            distance($0.bounds, to: rect) < distance($1.bounds, to: rect)
        }
    }

    /// The monitor's stable hardware identity — CGDirectDisplayIDs can
    /// change across reconnects; the UUID survives, which is what lets a
    /// re-docked monitor reclaim its arrangement.
    public static func uuid(for id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// The neighbor display in a direction (+1 right, -1 left), wrapping.
    public static func neighbor(of display: DisplayInfo, direction: Int) -> DisplayInfo? {
        let displays = ordered()
        guard displays.count > 1,
              let index = displays.firstIndex(of: display) else { return nil }
        return displays[(index + direction + displays.count) % displays.count]
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull || rect.isEmpty ? 0 : rect.width * rect.height
    }

    private static func distance(_ bounds: CGRect, to rect: CGRect) -> CGFloat {
        let dx = bounds.midX - rect.midX
        let dy = bounds.midY - rect.midY
        return dx * dx + dy * dy
    }

    /// Where parked windows go: past the bottom-right corner of the union of
    /// all displays, so a hidden window can never peek onto any monitor —
    /// including a second one hanging off the primary at an odd offset.
    public static func parkingPosition(padding: CGFloat = 128) -> CGPoint {
        let union = unionBounds()
        return CGPoint(x: union.maxX + padding, y: union.maxY + padding)
    }
}
