import Foundation

public enum GraphTarget: Equatable {
    case app(String)
    /// A Chromium profile: the registry key and its resolved entry.
    case browserProfile(key: String, profile: BrowserProfile)

    public var label: String {
        switch self {
        case .app(let name): return name
        case .browserProfile(_, let profile):
            return "\(profile.browser.label) (\(profile.display))"
        }
    }
}

/// The chain trie. Built from config, so it is acyclic by construction; the
/// only structural error possible is a letter that is both a leaf and an
/// internal node, which the builder reports and resolves in favor of the
/// subdivision.
public final class GraphNode {
    public var children: [String: GraphNode] = [:]

    public init() {}
    public var target: GraphTarget?

    public static func build(from table: [String: ConfigValue], path: String,
                      registry: [String: BrowserProfile], problems: inout [String]) -> GraphNode {
        let node = GraphNode()
        // Singles first, then multi-letter sugar, alphabetical within each —
        // deterministic merging whatever the dictionary order.
        let ordered = table.keys.sorted { ($0.count, $0) < ($1.count, $1) }
        for key in ordered {
            let value = table[key]!
            let lowered = key.lowercased()
            guard !lowered.isEmpty, lowered.allSatisfy(\.isLetter) else {
                problems.append("graph key '\(path)\(key)' must be letters — ignored")
                continue
            }
            if lowered.count == 1 {
                switch value {
                case .string(let raw):
                    let child = GraphNode()
                    child.target = parseTarget(raw, at: path + lowered, registry: registry, problems: &problems)
                    if child.target == nil {
                        continue
                    }
                    if node.children[lowered] != nil {
                        problems.append("graph '\(path)\(lowered)' is bound twice — keeping the first")
                        continue
                    }
                    node.children[lowered] = child
                case .table(let sub):
                    let child = GraphNode.build(from: sub, path: path + lowered + ".",
                                                registry: registry, problems: &problems)
                    node.children[lowered] = child
                default:
                    problems.append("graph '\(path)\(lowered)' must be a string or a table — ignored")
                }
                continue
            }
            // Sugar: "eo: Outlook" is e → o. Valid only while no letter on
            // the way is already a destination — a leaf resolves instantly,
            // so nothing can live past it.
            guard case .string(let raw) = value else {
                problems.append("graph '\(path)\(lowered)' — multi-letter keys take a target, not a table")
                continue
            }
            var cursor = node
            var walked = ""
            var blocked = false
            for ch in lowered.dropLast() {
                walked.append(ch)
                let next = cursor.children[String(ch)] ?? {
                    let made = GraphNode()
                    cursor.children[String(ch)] = made
                    return made
                }()
                if next.target != nil {
                    problems.append("graph '\(path)\(lowered)' is shadowed by leaf '\(path)\(walked)' — ignored")
                    blocked = true
                    break
                }
                cursor = next
            }
            if blocked { continue }
            let last = String(lowered.last!)
            if cursor.children[last] != nil {
                problems.append("graph '\(path)\(lowered)' collides with existing '\(path)\(lowered)' — ignored")
                continue
            }
            let child = GraphNode()
            child.target = parseTarget(raw, at: path + lowered, registry: registry, problems: &problems)
            if child.target != nil {
                cursor.children[last] = child
            }
        }
        return node
    }

    private static func parseTarget(_ raw: String, at path: String,
                                    registry: [String: BrowserProfile], problems: inout [String]) -> GraphTarget? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            problems.append("graph '\(path)' has an empty target — ignored")
            return nil
        }
        for browser in ChromiumBrowser.allCases
        where trimmed.lowercased().hasPrefix("\(browser.rawValue):") {
            let key = String(trimmed.dropFirst(browser.rawValue.count + 1))
                .trimmingCharacters(in: .whitespaces).lowercased()
            guard let profile = registry[key] else {
                problems.append("graph '\(path)' references unknown profile '\(browser.rawValue):\(key)' — ignored (declare it under profiles.\(browser.rawValue))")
                return nil
            }
            guard profile.browser == browser else {
                problems.append("graph '\(path)': '\(key)' is declared under profiles.\(profile.browser.rawValue), not profiles.\(browser.rawValue) — ignored")
                return nil
            }
            return .browserProfile(key: key, profile: profile)
        }
        if trimmed.lowercased().hasPrefix("app:") {
            let name = String(trimmed.dropFirst("app:".count)).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                problems.append("graph '\(path)' has an empty target — ignored")
                return nil
            }
            return .app(name)
        }
        return .app(trimmed)
    }

    /// Walk a chain. Returns the outcome of the letters typed so far.
    public enum Resolution {
        case leaf(GraphTarget)
        case deeper(GraphNode)
        case miss
    }

    public func resolve(_ letters: [String]) -> Resolution {
        var node = self
        for letter in letters {
            guard let next = node.children[letter.lowercased()] else { return .miss }
            node = next
        }
        if let target = node.target, node.children.isEmpty { return .leaf(target) }
        if node.children.isEmpty { return .miss }
        return .deeper(node)
    }

    /// Every destination in the trie as (chain, target), depth-first and
    /// sorted at each level. The one walk the searcher's teaching chips and
    /// the ⌘K card both build on; sorting is what makes an app bound to two
    /// equal-length chains show the same address every run.
    public func leaves() -> [(chain: [String], target: GraphTarget)] {
        var found: [(chain: [String], target: GraphTarget)] = []
        func walk(_ node: GraphNode, path: [String]) {
            for letter in node.children.keys.sorted() {
                let child = node.children[letter]!
                let deeper = path + [letter]
                if let target = child.target, child.children.isEmpty {
                    found.append((deeper, target))
                } else {
                    walk(child, path: deeper)
                }
            }
        }
        walk(self, path: [])
        return found
    }

    /// Chains bound to one app, shortest first.
    public func chains(toAppNamed name: String) -> [[String]] {
        let lowered = name.lowercased()
        return leaves()
            .filter { if case .app(let app) = $0.target { return app.lowercased() == lowered }; return false }
            .map(\.chain)
            .sorted { ($0.count, $0.joined()) < ($1.count, $1.joined()) }
    }

    /// Guide rows for the persistent chain panel: keycap → destination.
    public func guideRows() -> [(String, String)] {
        children.keys.sorted().map { key in
            let child = children[key]!
            if let target = child.target, child.children.isEmpty {
                return (key.uppercased(), target.label)
            }
            let letters = child.children.keys.sorted().map { $0.uppercased() }.joined(separator: " ")
            return (key.uppercased(), "→ \(letters)")
        }
    }
}
