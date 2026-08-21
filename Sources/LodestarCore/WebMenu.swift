import Foundation

/// The web bar's ⌘K card, as a state machine.
///
/// Everything about the card that isn't drawing lives here: which options a
/// row offers, what a key does in each state, what the prefill should be,
/// what the verdict says, and which write a return commits. The panel above
/// it translates keystrokes into `Key`, draws what `rendering` returns, and
/// performs the `Effect` it hands back — so the part with the decisions in it
/// can be tested without an app running.
public struct WebMenu {
    // MARK: - The world the card acts on

    public enum RowKind: Equatable {
        /// A saved link.
        case link
        /// Something typed that looks like a destination.
        case domain
        /// Anything else: a web search.
        case search
    }

    /// The row the card was opened on — all it needs from the bar.
    public struct Row: Equatable {
        public let kind: RowKind
        /// What was typed, or the link's stored url: before normalizing, so
        /// the config keeps the line you would have written by hand.
        public let raw: String
        /// The link's name, when this row is one: what a remove targets.
        public let name: String?
        /// The link's pinned profile, when it has one.
        public let pinnedProfileKey: String?

        public init(kind: RowKind, raw: String, name: String? = nil,
                    pinnedProfileKey: String? = nil) {
            self.kind = kind
            self.raw = raw
            self.name = name
            self.pinnedProfileKey = pinnedProfileKey
        }

        /// What the rules are matched against. A link brings its name along,
        /// so a rule can be written against either.
        var routingText: String {
            if let name { return "\(name) \(raw)" }
            return raw
        }
    }

    /// What the card is making. Both are promotions of the destination in
    /// front of you, answering different questions: a link is *this site, by
    /// this name*, a route is *everything like this, from anywhere*.
    public enum Kind: Equatable {
        case link
        case route
    }

    /// A link or a route being composed.
    public struct Draft: Equatable {
        public let kind: Kind
        public let row: Row
        /// The link's name, or the route's pattern.
        public var text: String
        /// The prefill is untouched, so the first keystroke replaces it whole
        /// — the way typing into a selected field does.
        public var pristine = true
        /// For a link, nil means unpinned: it resolves through the rules and
        /// the fallback every time it opens, instead of freezing today's
        /// answer. A route has to name one.
        public var profileKey: String?
        /// Why the last write failed, when one did.
        public var error: String?
    }

    public enum State: Equatable {
        case closed
        case options(Row)
        case compose(Draft)
        /// The profile list, one card further out.
        case profiles(Draft)
    }

    /// A keystroke, already lifted out of AppKit.
    public enum Key: Equatable {
        case character(Character)
        case tab
        case enter
        case delete
        case escape
    }

    /// What the card wants done to the world. Every write goes back to the
    /// caller, so the state machine never touches a file.
    public enum Effect: Equatable {
        case nothing
        /// The card closed itself; the bar should redraw without it.
        case dismissed
        case addLink(name: String, url: String, profileKey: String?)
        case removeLink(name: String)
        case addRoute(pattern: String, profileKey: String)
        case removeRoute(pattern: String)
    }

    // MARK: - What to draw

    /// One keyed row, in terms the card can draw however it likes.
    public struct Item: Equatable {
        public enum Role: Equatable {
            case addLink
            case route
            case removeLink
            case removeRoute
            /// The profile setting on a compose card.
            case profile(pinned: Bool)
            /// One value in the profile list.
            case choice(selected: Bool)

            /// Whether this one does not undo.
            public var isDestructive: Bool {
                switch self {
                case .removeLink, .removeRoute: return true
                default: return false
                }
            }
        }

        public let key: String
        public let title: String
        public let role: Role
        /// A word that qualifies the row: a profile's browser, a setting's
        /// current value.
        public let detail: String?
    }

    public struct Options: Equatable {
        public let items: [Item]
        /// Something was asked for and denied.
        public let error: String?
        /// Nothing was asked for; this is what the card would need.
        public let note: String?
    }

    public struct Compose: Equatable {
        public let header: String
        public let text: String
        public let placeholder: String
        /// What ⏎ commits, or why it can't.
        public let verdict: String
        public let problem: Bool
        public let control: Item?
        /// Where it will open, and why there.
        public let detail: String?
        public let footer: String
    }

    public struct Profiles: Equatable {
        public let header: String
        public let items: [Item]
        public let footer: String
    }

    /// Both cards at once: the compose card keeps its place while the profile
    /// list is open beside it, because the list is a detour and you can see
    /// what it is choosing for.
    public struct Rendering: Equatable {
        public var options: Options?
        public var compose: Compose?
        public var profiles: Profiles?
    }

    // MARK: - State

    public private(set) var state: State = .closed

    /// Why the last action fired from the options card failed. A refusal has
    /// to land somewhere: the compose card has a verdict line to take it, and
    /// this is where a remove's does. It stays up until the card moves on.
    private var optionsFailure: String?

    public init() {}

    public var isOpen: Bool { state != .closed }

    /// ⌘K: open the card on this row, or close it if it is already open.
    /// A row that offers nothing at all never opens one.
    public mutating func toggle(on row: Row?, in context: WebContext) {
        guard case .closed = state else {
            state = .closed
            return
        }
        guard let row, !options(for: row, in: context).items.isEmpty else { return }
        optionsFailure = nil
        state = .options(row)
    }

    public mutating func close() {
        optionsFailure = nil
        state = .closed
    }

    /// Put the reason a write failed onto the card, so it stays open with
    /// the problem where the verdict was.
    public mutating func failed(_ message: String) {
        switch state {
        case .compose(var draft), .profiles(var draft):
            draft.error = message
            state = .compose(draft)
        case .options:
            optionsFailure = message
        case .closed:
            break
        }
    }

    /// A key while the card is open.
    public mutating func handle(_ key: Key, in context: WebContext) -> Effect {
        switch state {
        case .closed:
            return .nothing
        case .options(let row):
            return handleOptions(key, row: row, in: context)
        case .compose(let draft):
            return handleCompose(key, draft: draft, in: context)
        case .profiles(let draft):
            return handleProfiles(key, draft: draft, in: context)
        }
    }

    private mutating func handleOptions(_ key: Key, row: Row,
                                        in context: WebContext) -> Effect {
        switch key {
        case .escape:
            state = .closed
            return .dismissed
        case .enter:
            // The first option is the primary one — Add on a domain, Route on
            // a search — and never the destructive one, which is why the
            // removes are always listed last.
            guard let first = options(for: row, in: context).items.first else { return .nothing }
            return fire(first.role, row: row, in: context)
        case .character(let character):
            let typed = String(character).lowercased()
            guard let item = options(for: row, in: context).items
                .first(where: { $0.key == typed }) else { return .nothing }
            return fire(item.role, row: row, in: context)
        case .tab, .delete:
            return .nothing
        }
    }

    private mutating func fire(_ role: Item.Role, row: Row, in context: WebContext) -> Effect {
        switch role {
        case .addLink:
            begin(.link, on: row, in: context)
            return .nothing
        case .route:
            begin(.route, on: row, in: context)
            return .nothing
        case .removeLink:
            guard let name = row.name else { return .nothing }
            return .removeLink(name: name)
        case .removeRoute:
            guard let pattern = routePattern(for: row, in: context) else { return .nothing }
            return .removeRoute(pattern: pattern)
        case .profile, .choice:
            return .nothing
        }
    }

    private mutating func begin(_ kind: Kind, on row: Row, in context: WebContext) {
        let prefill: String
        switch (kind, row.kind) {
        case (.link, _):
            prefill = WebJsonEditor.suggestedName(for: row.raw)
        case (.route, .search):
            prefill = WebJsonEditor.suggestedPattern(forSearch: row.raw)
        case (.route, _):
            prefill = WebJsonEditor.suggestedPattern(for: row.raw)
        }
        // A route has to name a profile, and wherever this destination
        // already goes is the best guess at which — it is usually what you
        // are making the rule to keep.
        let seed: String? = kind == .route
            ? (resolvedKey(for: row, in: context) ?? context.profileKeys.first)
            : nil
        optionsFailure = nil
        state = .compose(Draft(kind: kind, row: row, text: prefill, profileKey: seed))
    }

    private mutating func handleCompose(_ key: Key, draft: Draft,
                                        in context: WebContext) -> Effect {
        var draft = draft
        switch key {
        case .escape:
            state = .options(draft.row)
            return .nothing
        case .tab:
            guard !context.profiles.isEmpty else { return .nothing }
            state = .profiles(draft)
            return .nothing
        case .delete:
            guard !draft.text.isEmpty else { return .nothing }
            // The prefill is a suggestion, not typing: ⌫ clears it whole, the
            // way it clears a selected field.
            draft.text = draft.pristine ? "" : String(draft.text.dropLast())
            draft.pristine = false
            draft.error = nil
            state = .compose(draft)
            return .nothing
        case .character(let character):
            let added = draft.kind == .link
                ? WebJsonEditor.normalizeName(String(character))
                : WebJsonEditor.normalizePattern(String(character))
            guard !added.isEmpty else { return .nothing }
            draft.text = (draft.pristine ? "" : draft.text) + added
            draft.pristine = false
            draft.error = nil
            state = .compose(draft)
            return .nothing
        case .enter:
            guard problem(for: draft, in: context) == nil else { return .nothing }
            switch draft.kind {
            case .link:
                return .addLink(name: WebJsonEditor.normalizeName(draft.text),
                                url: draft.row.raw, profileKey: draft.profileKey)
            case .route:
                return .addRoute(pattern: WebJsonEditor.normalizePattern(draft.text),
                                 profileKey: draft.profileKey ?? "")
            }
        }
    }

    private mutating func handleProfiles(_ key: Key, draft: Draft,
                                         in context: WebContext) -> Effect {
        var draft = draft
        switch key {
        // ⇥ toggles the list the way ⌘K toggles the card; esc and ⏎ both
        // land back on the compose card, where the verdict now reads the new
        // profile and ⏎ commits.
        case .escape, .tab, .enter:
            state = .compose(draft)
            return .nothing
        case .delete:
            return .nothing
        case .character(let character):
            guard let index = Int(String(character)) else { return .nothing }
            if index == 0 {
                // A route has to name a profile, so inherit is not on offer
                // there and 0 does nothing.
                guard draft.kind == .link else { return .nothing }
                draft.profileKey = nil
            } else if context.profileKeys.indices.contains(index - 1) {
                draft.profileKey = context.profileKeys[index - 1]
            } else {
                return .nothing
            }
            state = .compose(draft)
            return .nothing
        }
    }

    // MARK: - Options

    /// What a row can become. A domain offers both promotions; a search only
    /// the pattern, since there is no site to name; a link the way back out.
    /// A row that got where it is going by a rule can also undo that rule —
    /// the card already knows which pattern matched, so the reason it is
    /// showing you is the thing it offers to remove.
    public func options(for row: Row, in context: WebContext) -> Options {
        var items: [Item] = []
        if row.kind == .domain {
            items.append(Item(key: "a", title: "Add link", role: .addLink, detail: nil))
        }
        let verb = row.kind == .search ? "Route this search" : "Route this host"
        items.append(Item(key: "r", title: verb, role: .route, detail: nil))
        if row.kind == .link {
            items.append(Item(key: "d", title: "Remove link", role: .removeLink, detail: nil))
        }
        if let pattern = routePattern(for: row, in: context) {
            items.append(Item(key: "x", title: "Remove route", role: .removeRoute,
                              detail: pattern))
        }
        let note = row.kind == .search
            ? "routes match what you type, so there is nothing to name"
            : nil
        return Options(items: items, error: nil, note: note)
    }

    /// The pattern that sends this row where it goes, when a rule is what
    /// decided it.
    private func routePattern(for row: Row, in context: WebContext) -> String? {
        context.resolve(pinned: row.pinnedProfileKey, routedOn: row.routingText)
            .source.routePattern
    }

    /// The registry key of the profile a row opens in, when it is one of the
    /// registered ones.
    private func resolvedKey(for row: Row, in context: WebContext) -> String? {
        let resolved = context.resolve(pinned: row.pinnedProfileKey, routedOn: row.routingText)
        return context.profileKeys.first { context.profiles[$0] == resolved.profile }
    }

    /// Why the draft can't be committed, or nil when it's ready.
    public func problem(for draft: Draft, in context: WebContext) -> String? {
        if let error = draft.error { return error }
        switch draft.kind {
        case .link:
            return WebJsonEditor.nameProblem(draft.text, url: draft.row.raw,
                                             existing: context.links)
        case .route:
            return WebJsonEditor.patternProblem(draft.text, profileKey: draft.profileKey,
                                                existing: context.routes)
        }
    }

    // MARK: - Rendering

    public func rendering(in context: WebContext) -> Rendering {
        switch state {
        case .closed:
            return Rendering()
        case .options(let row):
            var options = options(for: row, in: context)
            if let optionsFailure {
                options = Options(items: options.items, error: optionsFailure, note: options.note)
            }
            return Rendering(options: options)
        case .compose(let draft):
            return Rendering(compose: compose(draft, in: context))
        case .profiles(let draft):
            return Rendering(compose: compose(draft, in: context),
                             profiles: profiles(draft, in: context))
        }
    }

    /// The compose card. The verdict prints what ⏎ would make, the profile
    /// sits under it as a row you can see is a control, and the last line
    /// says where the thing will actually open and why there.
    private func compose(_ draft: Draft, in context: WebContext) -> Compose {
        let problem = problem(for: draft, in: context)
        switch draft.kind {
        case .link:
            let name = WebJsonEditor.normalizeName(draft.text)
            let resolved = context.resolve(pinned: draft.profileKey, routedOn: draft.row.raw)
            return Compose(
                header: "Add a link",
                text: name,
                placeholder: "type a name",
                // "add" carries its weight: the address itself contains ⏎, and
                // without a verb between them the ↵ prefix reads as part of it.
                verdict: problem ?? "add lode ⏎ \(name) → \(WebRouting.normalize(draft.row.raw))",
                problem: problem != nil,
                control: profileControl(draft, in: context),
                detail: "opens in \(resolved.profile.display) · \(resolved.source.phrase)",
                footer: "⌫ back up    esc back"
            )
        case .route:
            let pattern = WebJsonEditor.normalizePattern(draft.text)
            let target = draft.profileKey.flatMap { context.profiles[$0] }
            return Compose(
                header: "Route by pattern",
                text: pattern,
                placeholder: "type a pattern",
                verdict: problem
                    ?? "anything matching \(pattern) opens in \(target?.display ?? draft.profileKey ?? "")",
                problem: problem != nil,
                control: profileControl(draft, in: context),
                detail: target.map { "opens in \($0.display) · \($0.browser.label)" },
                footer: "⌫ back up    esc back"
            )
        }
    }

    /// The profile setting, as a row rather than a footer hint. Its value is
    /// what the config would store — `Inherit` for a link with no pin —
    /// so the row says what the setting *is*, and the line beneath says what
    /// that works out to today.
    private func profileControl(_ draft: Draft, in context: WebContext) -> Item? {
        guard !context.profiles.isEmpty else { return nil }
        let pinned = draft.profileKey.flatMap { context.profiles[$0] }
        return Item(key: "⇥", title: "Profile",
                    role: .profile(pinned: draft.profileKey != nil),
                    detail: pinned?.display ?? draft.profileKey ?? "Inherit")
    }

    /// The profile list: for a link, inherit leads, because it is the answer
    /// that keeps following your rules and fallback instead of freezing one
    /// of them. A route has to name a profile, so it has no inherit row.
    private func profiles(_ draft: Draft, in context: WebContext) -> Profiles {
        var items: [Item] = []
        if draft.kind == .link {
            let inherited = context.resolve(pinned: nil, routedOn: draft.row.raw)
            items.append(Item(key: "0", title: "Inherit",
                              role: .choice(selected: draft.profileKey == nil),
                              detail: "\(inherited.profile.display) · \(inherited.source.label)"))
        }
        // Nine at most: past that the digits run out, and a machine with
        // more profiles than that is a config file's problem, not a card's.
        for (index, key) in context.profileKeys.prefix(9).enumerated() {
            guard let profile = context.profiles[key] else { continue }
            items.append(Item(key: "\(index + 1)", title: profile.display,
                              role: .choice(selected: draft.profileKey == key),
                              detail: profile.browser.label))
        }
        return Profiles(header: "Opens in", items: items, footer: "⇥ back    esc cancel")
    }
}
