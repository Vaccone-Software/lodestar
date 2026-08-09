import CoreGraphics

/// The placement decisions, extracted pure so the seams that matter are
/// testable without a window server.
public enum PlacementAction: Equatable {
    /// Focus it where it lives — its arrangement untouched.
    case visit
    /// It becomes the active display's whole layout, full-screen.
    case replace
    /// It joins the active display's layout as an equal.
    case add
}

public enum Placement {
    /// Visit-don't-pull: beside always arranges on the active display; a
    /// plain summon visits a window living on another display, and replaces
    /// on the active display otherwise (hidden, parked, new, or local).
    public static func decide(beside: Bool,
                              memberOfDisplay: CGDirectDisplayID?,
                              activeDisplay: CGDirectDisplayID) -> PlacementAction {
        if beside { return .add }
        if let home = memberOfDisplay, home != activeDisplay { return .visit }
        return .replace
    }

    /// Is this window a place — somewhere the user goes — as opposed to an
    /// event (dialog, palette, popover) that happens on top of one? Places
    /// may be adopted and swept; events must never be moved, or a password
    /// prompt ends up slivered off-screen. A missing subrole is treated as
    /// standard — some apps never set one.
    public static func isPlace(subrole: String?) -> Bool {
        subrole == nil || subrole == "AXStandardWindow"
    }

    /// Should a window that appeared outside lodestar be adopted (summoned
    /// full-screen)? Places only, and tiny windows are excluded by size.
    public static func shouldAdopt(subrole: String?, size: CGSize) -> Bool {
        guard isPlace(subrole: subrole) else { return false }
        return size.width >= 400 && size.height >= 300
    }

    /// A window that materializes exactly atop a living sibling is a native
    /// tab (created or revealed), not a new destination — adopting it would
    /// collapse the arrangement its host lives in. Tolerance absorbs
    /// half-pixel AX rounding.
    public static func looksLikeTab(frame: CGRect, siblingFrames: [CGRect]) -> Bool {
        siblingFrames.contains { sibling in
            abs(sibling.minX - frame.minX) < 2 && abs(sibling.minY - frame.minY) < 2
                && abs(sibling.width - frame.width) < 2 && abs(sibling.height - frame.height) < 2
        }
    }

    /// Insert-and-shift reorder: the window slides into the digit's position
    /// (9 = last), the others shift. nil when the move is meaningless —
    /// window absent, position out of range, or a no-op.
    public static func reorder(_ ordered: [CGWindowID],
                               move id: CGWindowID,
                               toDigit digit: Int) -> [CGWindowID]? {
        guard let from = ordered.firstIndex(of: id) else { return nil }
        let target: Int
        if digit == 9 {
            target = ordered.count - 1
        } else {
            guard digit >= 1, digit <= ordered.count else { return nil }
            target = digit - 1
        }
        guard target != from else { return nil }
        var result = ordered
        result.remove(at: from)
        result.insert(id, at: target)
        return result
    }
}
