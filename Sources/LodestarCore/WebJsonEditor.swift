import Foundation

/// ⌘K's write path for the web bar, over the two tables it edits — the named
/// links under `web.links` and the pattern → profile routes under
/// `web.routes` — leaving every other key exactly as read. The canonical
/// emitter owns the formatting, so an edit is a tree operation, not a text
/// operation.
///
/// A URL is stored as typed. The scheme is added when the link is opened
/// (`WebRouting.normalize`), never when it is saved, so a link added here and
/// one added by hand are the same two lines in the file — which is what keeps
/// the config the editing surface of record.
public enum WebJsonEditor {
    public enum EditError: Error, Equatable, CustomStringConvertible {
        case emptyName
        case emptyPattern
        /// The name or pattern is bound already; overwriting it silently
        /// would take an address the user never pointed at.
        case taken(name: String, target: String)
        case missing(String)
        case blocked(String)
        case noProfile

        public var description: String {
            switch self {
            case .emptyName: return "a link needs a name"
            case .emptyPattern: return "a route needs a pattern"
            case .taken(let name, let target): return "\(name) is already \(target)"
            case .missing(let name): return "\(name) is not in the config"
            case .blocked(let path): return "\(path) in the config is not a section"
            case .noProfile: return "pick a profile — a route has to name one"
            }
        }
    }

    // MARK: - Names and patterns

    /// The characters a name may hold. The name is what you type into the
    /// web bar to reach the link, so it is held to that grammar: lowercase,
    /// no spaces, nothing a URL would fight over.
    public static func normalizeName(_ raw: String) -> String {
        String(raw.lowercased().filter {
            ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-"
        })
    }

    /// A pattern is matched as a substring of whatever you typed, so it keeps
    /// the punctuation a host has and the spaces a phrase has — only case and
    /// stray runs of whitespace go.
    public static func normalizePattern(_ raw: String) -> String {
        raw.lowercased().split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// The name to offer for a URL: the host's first distinguishing label —
    /// `youtube.com` → "youtube", `docs.google.com` → "docs" — which is most
    /// often the handle you would have typed anyway. Prefilled rather than
    /// required, so the common add is one keystroke and a rename is still
    /// just typing.
    public static func suggestedName(for url: String) -> String {
        normalizeName(String(host(of: url).split(separator: ".").first ?? ""))
    }

    /// The pattern to offer for a URL: the whole host. A route is about where
    /// a site opens, and the host is the part of a link that says which site
    /// it is — the path changes every time you paste one.
    public static func suggestedPattern(for url: String) -> String {
        normalizePattern(host(of: url))
    }

    /// The pattern to offer for a search: its first word. "acme deploy" is
    /// this afternoon's question; "acme" is the thing you actually want in
    /// the work profile from now on — and the whole phrase as a pattern
    /// would match almost nothing.
    public static func suggestedPattern(forSearch query: String) -> String {
        normalizePattern(String(query.split(separator: " ").first ?? ""))
    }

    /// Host, with scheme, path, and `www.` stripped.
    private static func host(of url: String) -> String {
        var host = url.trimmingCharacters(in: .whitespaces).lowercased()
        for scheme in ["https://", "http://"] where host.hasPrefix(scheme) {
            host = String(host.dropFirst(scheme.count))
        }
        host = String(host.split(separator: "/").first ?? "")
        host = String(host.split(separator: ":").first ?? "") // a port is not a name
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return host
    }

    // MARK: - Live verdicts

    /// Why this link name can't be added, or nil when it's free. The card
    /// shows this live, the way the graph card shows a chain's problem, so a
    /// refusal arrives before ⏎ rather than after it.
    public static func nameProblem(_ name: String, url: String,
                                   existing: [Config.WebLink]) -> String? {
        let key = normalizeName(name)
        if key.isEmpty { return EditError.emptyName.description }
        guard let clash = existing.first(where: { $0.name == key }) else { return nil }
        if WebRouting.normalize(clash.url) == WebRouting.normalize(url) {
            return "\(key) already points here"
        }
        return EditError.taken(name: key, target: clash.url).description
    }

    /// Why this route can't be added, or nil when it's free. A route with no
    /// profile is the one shape that means nothing, so it is refused here
    /// rather than written and puzzled over later.
    public static func patternProblem(_ pattern: String, profileKey: String?,
                                      existing: [String: String]) -> String? {
        let key = normalizePattern(pattern)
        if key.isEmpty { return EditError.emptyPattern.description }
        guard let profileKey, !profileKey.isEmpty else { return EditError.noProfile.description }
        if let clash = existing[key] {
            return clash == profileKey
                ? "\(key) already goes to \(profileKey)"
                : EditError.taken(name: key, target: clash).description
        }
        return nil
    }

    // MARK: - Links

    /// The tree with `name` → url added under web.links, plus the pinned
    /// profile when there is one. An unpinned link carries no `profile` key
    /// at all: it then resolves through the routes and the fallback at open
    /// time, so it keeps following those settings instead of freezing a
    /// decision made once.
    public static func addingLink(name: String, url: String, profileKey: String?,
                                  in root: [String: ConfigValue]) throws -> [String: ConfigValue] {
        let key = normalizeName(name)
        guard !key.isEmpty else { throw EditError.emptyName }
        var links = try table(at: "links", in: root)
        if let clash = links.first(where: { $0.key.lowercased() == key }) {
            throw EditError.taken(name: key,
                                  target: clash.value.table?["url"]?.string ?? "bound")
        }
        var entry: [String: ConfigValue] = [
            "url": .string(url.trimmingCharacters(in: .whitespaces)),
        ]
        if let profileKey, !profileKey.isEmpty {
            entry["profile"] = .string(profileKey)
        }
        links[key] = .table(entry)
        return try writing(links, to: "links", in: root)
    }

    /// The tree without `name` under web.links; an emptied table is pruned so
    /// removing the last link leaves no husk behind.
    public static func removingLink(name: String,
                                    in root: [String: ConfigValue]) throws -> [String: ConfigValue] {
        let key = normalizeName(name)
        var links = try table(at: "links", in: root)
        guard let existing = links.first(where: { $0.key.lowercased() == key }) else {
            throw EditError.missing(key)
        }
        links.removeValue(forKey: existing.key)
        return try writing(links, to: "links", in: root)
    }

    // MARK: - Routes

    /// The tree with `pattern` → profile added under web.routes.
    public static func addingRoute(pattern: String, profileKey: String,
                                   in root: [String: ConfigValue]) throws -> [String: ConfigValue] {
        let key = normalizePattern(pattern)
        guard !key.isEmpty else { throw EditError.emptyPattern }
        guard !profileKey.isEmpty else { throw EditError.noProfile }
        var routes = try table(at: "routes", in: root)
        if let clash = routes.first(where: { $0.key.lowercased() == key }) {
            throw EditError.taken(name: key, target: clash.value.string ?? "bound")
        }
        routes[key] = .string(profileKey)
        return try writing(routes, to: "routes", in: root)
    }

    /// The tree without `pattern` under web.routes.
    public static func removingRoute(pattern: String,
                                     in root: [String: ConfigValue]) throws -> [String: ConfigValue] {
        let key = normalizePattern(pattern)
        var routes = try table(at: "routes", in: root)
        guard let existing = routes.first(where: { $0.key.lowercased() == key }) else {
            throw EditError.missing(key)
        }
        routes.removeValue(forKey: existing.key)
        return try writing(routes, to: "routes", in: root)
    }

    // MARK: - Internals

    private static func table(at key: String,
                              in root: [String: ConfigValue]) throws -> [String: ConfigValue] {
        guard let existing = root["web"]?.table?[key] else { return [:] }
        guard let table = existing.table else { throw EditError.blocked("web.\(key)") }
        return table
    }

    private static func writing(_ table: [String: ConfigValue], to key: String,
                                in root: [String: ConfigValue]) throws -> [String: ConfigValue] {
        // An emptied table is pruned: the file is sparse on purpose, and the
        // next canonical write would drop it anyway.
        let path = ["web", key]
        let updated: [String: ConfigValue]?
        if table.isEmpty {
            switch Json.removing(root, path: path) {
            case .removed(let pruned): updated = pruned
            case .absent: updated = root
            case .blocked: updated = nil
            }
        } else {
            updated = Json.setting(root, path: path, to: .table(table))
        }
        guard let updated else { throw EditError.blocked("web") }
        return updated
    }
}
