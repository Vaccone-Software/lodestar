import CoreGraphics

/// What should happen on screen once a clicked link is on its way to the
/// browser.
///
/// The click path used to answer this by doing nothing at all, on the rule
/// that a link someone sent you is not a request to rearrange your layout.
/// That rule was right about arrangements and wrong about everything else,
/// because it was written as though doing nothing left the browser where it
/// was. It does not. Lodestar parks what it is not showing, so the window a
/// link just landed in is a one-pixel sliver in a corner, and declining to
/// act is not neutrality — it is the one outcome that cannot happen on a
/// Mac without Lodestar running. Measured over thirteen days on the author's
/// machine: the browser was parked for 83% of clicked links, and half of
/// those were followed within a couple of seconds by summoning it by hand.
///
/// So the rule keeps what it was protecting and drops what it was not:
/// **a link brings the browser in when there is nothing to disturb, and
/// never touches an arrangement you built.** One window on the display is
/// not an arrangement; it is the display showing one thing, and replacing it
/// is what the hand does anyway. Two windows is something you made.
///
/// State-dependent, deliberately, and it survives the test that matters:
/// Raskin's modality criterion holds only when the deciding state is *not*
/// in the user's locus of attention. Here the state is how many windows are
/// on the screen in front of them — the most attended state there is.
public enum ClickArrival: Equatable, Sendable {
    /// Bring it in, exactly as a plain summon would.
    case place
    /// An arrangement is standing. Leave the screen alone; the chip carries
    /// the link instead.
    case chip
    /// The browser is already tiled where the eyes are. The tab appeared in
    /// a window they are looking at, and there is nothing left to say.
    case nothing
}

public enum ClickArrivalRule {
    /// The most windows a display can hold and still count as "nothing to
    /// disturb". One window is the display showing one thing; an empty
    /// display is nothing at all.
    public static let quietMembers = 1

    /// - Parameters:
    ///   - browserHome: the display whose layout the browser window belongs
    ///     to, or nil when it is parked, minimized, or not yet born.
    ///   - activeDisplay: where the eyes are.
    ///   - membersOnActiveDisplay: how many windows are tiled there now.
    public static func decide(browserHome: CGDirectDisplayID?,
                              activeDisplay: CGDirectDisplayID,
                              membersOnActiveDisplay: Int) -> ClickArrival {
        // Already tiled here: the tab opened in a window in front of them.
        // Placing would not be a raise — a plain summon on a member of the
        // active display resolves to `.replace`, which would park whatever
        // it is sitting beside. The visible case is the one where doing
        // nothing is genuinely right.
        if browserHome == activeDisplay { return .nothing }
        // Tiled on another display: visit-don't-pull already covers this,
        // and `Placement.decide` returns `.visit` for it, so placing costs
        // no layout change on either display.
        if browserHome != nil { return .place }
        return membersOnActiveDisplay <= quietMembers ? .place : .chip
    }
}
