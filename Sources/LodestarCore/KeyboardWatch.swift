import Foundation

/// Whether the Keyboards page needs drawing again.
///
/// It is the one settings surface whose content changes with nothing to
/// prompt a render. Every other row answers to the config, and a config
/// write renders; a keyboard plugged in, or gone to sleep, answers to
/// nobody — so a window left open goes on showing the set of boards that
/// stood when it was drawn. It did: overnight, naming a keyboard that had
/// been unpaired for hours and not the one under the hands.
///
/// So while the page stands the attached ids are watched, and this is the
/// rule for when that watch has something to say. It lives here, away
/// from the window, because a rule inside a timer inside a panel can only
/// be tested by standing a panel up — and the panel is not what is
/// interesting about it.
public struct KeyboardWatch: Equatable {
    /// The ids the page was last drawn from, or nil when the page is not
    /// standing. Nil is the whole of "not watching": a watch with nothing
    /// to compare against has nothing to say.
    private var drawn: [String]?

    public init() {}

    public var isWatching: Bool { drawn != nil }

    /// The page has just been drawn from these. Whatever it was drawn
    /// from is what the next turn compares against, so a render the watch
    /// itself caused does not ask for a second one.
    public mutating func drew(_ ids: [String]) { drawn = ids }

    /// The page, or the window, has gone.
    public mutating func stopped() { drawn = nil }

    /// One turn: true when the devices differ from what the page was
    /// drawn from, and the page should be drawn again. False whenever
    /// nothing moved — a page that redrew on every turn would tear down
    /// a popup the hand had open.
    public mutating func shouldRedraw(_ ids: [String]) -> Bool {
        guard let drawn, ids != drawn else { return false }
        self.drawn = ids
        return true
    }
}
