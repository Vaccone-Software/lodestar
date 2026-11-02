import Foundation

extension Draft {
    /// What the app in front showed when asked what has the focus, as far
    /// as a paste is concerned.
    public enum Target: Equatable, Sendable {
        /// The app answered and positively has no focused element.
        case noFocus
        /// A focused element: its Accessibility role, and whether it
        /// shows any sign of taking text (a caret, a settable value).
        case focus(role: String, text: Bool)
        /// The question went unanswered or failed: an error, a timeout, an
        /// app that does not speak Accessibility.
        case unknown
    }

    /// Roles that hold things to choose and look at, never characters.
    /// A paste into one of them goes nowhere.
    static let roleWithoutText: Set<String> = ["AXList", "AXOutline", "AXTable", "AXBrowser", "AXImage"]

    /// Whether ⏎ should post the paste. Only a positive answer says no:
    /// an app with nothing focused, or with a list, an outline, a table, a
    /// browser or an image focused and no sign of a caret. Everything
    /// uncertain pastes, as it always did. A terminal's text area may not
    /// look like a field, a web area is not a role to judge, and a refused
    /// paste into the app the words were meant for is far worse than one
    /// that landed nowhere.
    public static func pastes(into target: Target) -> Bool {
        switch target {
        case .noFocus: return false
        case .unknown: return true
        case .focus(let role, let text): return text || !roleWithoutText.contains(role)
        }
    }
}
