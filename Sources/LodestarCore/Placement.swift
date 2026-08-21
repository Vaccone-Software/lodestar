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
    /// event (dialog, palette, popover) that happens on top of one? Born
    /// for adoption and sweep (FINDINGS §6), both since retired; its one
    /// remaining station is the intent queue, where it matters just as
    /// much — a launch whose app fronts a login dialog or a splash first
    /// must not full-screen the event and park the world around it. A
    /// missing subrole is treated as standard — some apps never set one.
    public static func isPlace(subrole: String?) -> Bool {
        subrole == nil || subrole == "AXStandardWindow"
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
