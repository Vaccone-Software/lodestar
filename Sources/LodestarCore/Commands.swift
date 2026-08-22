import Foundation

/// The commands bar's rows: verbs from any feed, each wearing its source.
///
/// Ask answers "where to?"; commands answer "what now?". Today the one feed is
/// the focused app's menus; system commands join as a second feed, and
/// the merge holds to three commitments decided up front. Every row
/// wears its source, so the eye knows what it is about to fire. ⌘K will
/// offer only what a row can become — a system command can join the
/// graph, a menu item lives in its app, and the card says so. And at
/// equal match quality, system rows outrank menu rows: a dozen curated
/// verbs must never drown under an app's three hundred menu items.
public enum Commands {
    public struct Row {
        /// What firing the row does.
        public enum Verb {
            case menu(MenuItems.Item)
            // case command(...) — the second feed, when it lands.
        }

        public let verb: Verb
        public let title: String
        public let crumb: String
        public let shortcut: String?
        /// Who owns the verb: the app name for a menu item, "system"
        /// for a Lodestar command. Worn as a chip only when the visible
        /// rows mix sources — a qualifier exists to tell rows apart,
        /// and rows that cannot be confused need no telling.
        public let source: String
        /// What the fuzzy ranking reads.
        public let searchKey: String
    }

    /// The menus feed, rowed.
    public static func rows(menus: [MenuItems.Item], app: String) -> [Row] {
        menus.map { item in
            Row(verb: .menu(item),
                title: item.path.last ?? "",
                crumb: item.path.dropLast().joined(separator: " › "),
                shortcut: item.shortcut,
                source: app,
                searchKey: item.path.joined(separator: " "))
        }
    }

    /// Whether the rows on show need their source chips: only a mixed
    /// list does.
    public static func mixedSources(_ rows: [Row]) -> Bool {
        guard let first = rows.first?.source else { return false }
        return rows.contains { $0.source != first }
    }
}
