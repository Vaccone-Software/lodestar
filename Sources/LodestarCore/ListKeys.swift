import AppKit

/// Which way a key walks a highlighted list — decided once, because three
/// panels run one: the launcher, the web bar, and menu search.
///
/// The arrows are the answer everyone already knows, and ⌃N/⌃P arrive as
/// those same two selectors without us asking, because macOS binds them
/// there in its own key table. ⌃J/⌃K are ours to add, so that a hand
/// trained on lists elsewhere lands on its feet in ours.
///
/// The two additions are read differently, and deliberately. ⌃K reaches a
/// field editor as `deleteToEndOfParagraph:`, which nothing else produces;
/// in a one-line query field killing the tail was never a keystroke worth
/// having, so the selector alone is taken as the intent — including from
/// whatever a personal key binding file has put on it. ⌃J is unbound in
/// the system table and arrives as `noop:`, the bucket every unclaimed
/// control key falls into, so that one is taken only when the event itself
/// says the letter was J. Everything else in the bucket passes through
/// untouched.
public enum ListKeys {
    /// +1 next, -1 previous, nil when the key was not about the list.
    public static func delta(for selector: Selector, letter: String?, control: Bool) -> Int? {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            return 1
        case #selector(NSResponder.moveUp(_:)):
            return -1
        case #selector(NSResponder.deleteToEndOfParagraph(_:)):
            return -1
        case Self.noop:
            guard control, letter?.lowercased() == "j" else { return nil }
            return 1
        default:
            return nil
        }
    }

    /// `noop:` is declared on NSResponder but not surfaced to Swift, so the
    /// selector is named rather than referenced.
    static let noop = NSSelectorFromString("noop:")
}
