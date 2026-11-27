import CoreGraphics

/// Whether the window the keys go to wears the focus outline, and where.
///
/// The outline is drawn only where Lodestar is being used as it is meant
/// to be: the focused window is one of two or more that a layout placed
/// side by side, and it is still exactly where the layout left it. A drag,
/// a resize or an app moving its own window ends it, and nothing but a
/// layout verb brings it back, because that is the one deterministic way
/// back into the layout. Nothing is remembered about how a window got where
/// it is: membership, the frame the last retile came to rest on, the
/// window's frame now and the window server's stack answer it every time.
public enum FocusOutline {
    /// How far a window may stand from where its retile left it and still
    /// be there: accessibility reads whole points and some apps round.
    public static let tolerance: CGFloat = 2

    /// The frame to outline (Quartz coordinates, top-left origin), or nil
    /// for no outline.
    ///
    /// - Parameters:
    ///   - focused: the window the keys go to.
    ///   - members: the layout of the display that window belongs to.
    ///   - placed: where that layout's last retile left it.
    ///   - stack: the window server's on-screen windows, front to back.
    public static func frame(focused: WindowModel.Window?, members: [CGWindowID],
                             placed: CGRect?, stack: [CGWindowRecord]) -> CGRect? {
        guard let focused, focused.isAlive, !focused.isMinimized,
              members.count >= 2, members.contains(focused.id),
              let placed, stands(focused.frame, at: placed) else { return nil }
        // Off this Space, hidden with its app, or behind a full-screen app:
        // not on screen, so nothing to outline.
        guard let index = stack.firstIndex(where: { $0.id == focused.id }) else { return nil }
        // Another app's window over it means the layout is no longer what is
        // on screen. Its own sheets, popovers and status bubbles belong to it,
        // and anything above the normal layer (palettes, menus, Lodestar's own
        // bars) stands over the outline too, so neither hides it.
        let inner = focused.frame.insetBy(dx: tolerance, dy: tolerance)
        let covered = stack[..<index].contains { record in
            record.layer == 0 && record.pid != focused.pid && record.bounds.intersects(inner)
        }
        return covered ? nil : focused.frame
    }

    /// Is `frame` where `placed` says, within the tolerance on every edge?
    public static func stands(_ frame: CGRect, at placed: CGRect) -> Bool {
        abs(frame.minX - placed.minX) <= tolerance && abs(frame.minY - placed.minY) <= tolerance
            && abs(frame.width - placed.width) <= tolerance && abs(frame.height - placed.height) <= tolerance
    }
}
