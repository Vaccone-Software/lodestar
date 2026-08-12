import Foundation

/// ⌘K's write path: mutate the graph subtree of the config tree, leaving
/// every other key exactly as read — the canonical emitter owns the
/// formatting, so an edit is a tree operation, not a text operation.
public enum GraphJsonEditor {
    public enum EditError: Error, Equatable, CustomStringConvertible {
        /// An existing leaf sits on the path — nothing can live past it.
        case blockedByLeaf(String)
        case taken(String)
        case missing(String)

        public var description: String {
            switch self {
            case .blockedByLeaf(let path): return "hyper \(path) is already a destination"
            case .taken(let path): return "hyper \(path) is already bound"
            case .missing(let path): return "hyper \(path) is not in the config"
            }
        }
    }

    /// The tree with `letters` → `target` added under graph. Free paths
    /// only: the exact path and every prefix must not already be a leaf.
    public static func addingPath(_ letters: [String], target: String,
                                  in root: [String: ConfigValue]) throws -> [String: ConfigValue] {
        precondition(!letters.isEmpty)
        var graph = root["graph"]?.table ?? [:]
        graph = try adding(letters, target: target, in: graph, walked: [])
        var out = root
        out["graph"] = .table(graph)
        return out
    }

    /// The tree with the leaf at `letters` removed; branches left
    /// childless are pruned so the graph never keeps dead letters.
    public static func deletingPath(_ letters: [String],
                                    in root: [String: ConfigValue]) throws -> [String: ConfigValue] {
        precondition(!letters.isEmpty)
        guard let graph = root["graph"]?.table,
              let updated = try deleting(letters, in: graph, walked: []) else {
            throw EditError.missing(describe(letters))
        }
        var out = root
        out["graph"] = .table(updated)
        return out
    }

    // MARK: - Internals

    private static func adding(_ letters: [String], target: String,
                               in table: [String: ConfigValue],
                               walked: [String]) throws -> [String: ConfigValue] {
        let letter = letters[0].lowercased()
        let path = walked + [letter]
        let existing = table.first { $0.key.lowercased() == letter }
        if letters.count == 1 {
            guard existing == nil else { throw EditError.taken(describe(path)) }
            var out = table
            out[letter] = .string(target)
            return out
        }
        var child: [String: ConfigValue] = [:]
        var key = letter
        if let existing {
            guard let branch = existing.value.table else { throw EditError.blockedByLeaf(describe(path)) }
            child = branch
            key = existing.key
        }
        var out = table
        out[key] = .table(try adding(Array(letters.dropFirst()), target: target,
                                     in: child, walked: path))
        return out
    }

    private static func deleting(_ letters: [String],
                                 in table: [String: ConfigValue],
                                 walked: [String]) throws -> [String: ConfigValue]? {
        let letter = letters[0].lowercased()
        let path = walked + [letter]
        guard let existing = table.first(where: { $0.key.lowercased() == letter }) else { return nil }
        var out = table
        if letters.count == 1 {
            guard existing.value.table == nil else {
                // A branch is not a leaf; deleting it would take children
                // the caller never named.
                throw EditError.missing(describe(path))
            }
            out.removeValue(forKey: existing.key)
            return out
        }
        guard let branch = existing.value.table,
              let updated = try deleting(Array(letters.dropFirst()), in: branch, walked: path) else {
            return nil
        }
        if updated.isEmpty {
            out.removeValue(forKey: existing.key)
        } else {
            out[existing.key] = .table(updated)
        }
        return out
    }

    private static func describe(_ letters: [String]) -> String {
        letters.map { $0.uppercased() }.joined(separator: " ")
    }
}
