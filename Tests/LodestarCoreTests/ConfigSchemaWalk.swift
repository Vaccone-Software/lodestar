import StoicJSON
import StoicSchema
@testable import LodestarCore

/// A path of keys.
func jsonPath(_ keys: String...) -> JSONPath {
    JSONPath(keys.map { .key($0) })
}

/// The config schema's node tree, walked: the one place the coverage tests
/// (`ConfigCoverageTests`, `SettingsCoverageTests`) learn what the schema
/// declares, so that neither keeps a list of its own.
enum ConfigSchemaWalk {
    /// One addressable leaf: a value a person can set.
    struct Leaf {
        /// The dotted address, a key the person chooses written `<key>`.
        let address: String
        /// What the schema says the leaf is, in words; nil when it says nothing.
        let doc: String?
        let node: StoicSchema.SchemaNode
    }

    /// Every leaf, free-form keys as `<key>`.
    ///
    /// Descends through a dictionary into its value, or the guard has a hole
    /// where the schema is richest: stopping at `web.links.<key>` would let
    /// `web.links.<key>.profile` be added, or stop being read, with nothing
    /// failing. The graph (held as JSON, checked by `GraphNode`) is one leaf,
    /// `graph.<key>`, a slot for the whole trie.
    static func leaves() -> [Leaf] {
        var out: [Leaf] = []
        walk(ConfigFile.schema.node, at: [], doc: nil, into: &out)
        return out
    }

    static func leafAddresses() -> Set<String> {
        Set(leaves().map(\.address))
    }

    private static func walk(_ node: StoicSchema.SchemaNode, at path: [String], doc: String?, into out: inout [Leaf]) {
        switch node {
        case .object(let object):
            for field in object.fields {
                walk(field.node, at: path + [field.key], doc: field.doc, into: &out)
            }
        case .dictionary(let value, _):
            walk(value, at: path + ["<key>"], doc: description(of: value), into: &out)
        case .optional(let wrapped, _):
            walk(wrapped, at: path, doc: doc, into: &out)
        case .transformed:
            // A dictionary that drops its bad entries, a number that clamps, a
            // value that is documented: the same node, said another way.
            if case .dictionary = unwrapped(node) {
                walk(unwrapped(node), at: path, doc: doc, into: &out)
            } else {
                out.append(Leaf(address: path.joined(separator: "."), doc: doc, node: node))
            }
        case .json:
            out.append(Leaf(address: (path + ["<key>"]).joined(separator: "."), doc: doc, node: node))
        default:
            out.append(Leaf(address: path.joined(separator: "."), doc: doc, node: node))
        }
    }

    /// What a dictionary's values are documented as: the `description` of
    /// `documented(_:)`, or an object value's own documentation.
    private static func description(of value: StoicSchema.SchemaNode) -> String? {
        switch value {
        case .transformed(let transform):
            return transform.keywords["description"]?.string ?? description(of: transform.base)
        case .object(let object):
            return object.doc
        case .dictionary(let inner, _):
            return description(of: inner)
        default:
            return nil
        }
    }

    /// The schema address a concrete path falls under: `web.routes.github.com`
    /// is `web.routes.<key>`, `gestures.scroll` is itself.
    static func address(of path: [String]) -> String {
        var node = ConfigFile.schema.node
        var out: [String] = []
        for segment in path {
            switch unwrapped(node) {
            case .object(let object):
                out.append(segment)
                guard let field = object.fields.first(where: { $0.key == segment }) else { return out.joined(separator: ".") }
                node = field.node
            case .dictionary(let value, _):
                out.append("<key>")
                node = value
            case .json:
                // Nested graph letters are all user-chosen, all the way down.
                out.append("<key>")
            default:
                out.append(segment)
            }
        }
        return out.joined(separator: ".")
    }

    private static func unwrapped(_ node: StoicSchema.SchemaNode) -> StoicSchema.SchemaNode {
        switch node {
        case .optional(let wrapped, _): unwrapped(wrapped)
        case .transformed(let transform): unwrapped(transform.base)
        default: node
        }
    }

    /// The inclusive bounds of the number at `path`, if it has them.
    static func bounds(at path: [String]) -> (min: Double, max: Double)? {
        guard let leaf = leaves().first(where: { $0.address == path.joined(separator: ".") }) else { return nil }
        for constraint in leaf.node.constraints {
            if case .range(let range) = constraint.kind,
               let lower = range.lower?.value.double, let upper = range.upper?.value.double {
                return (lower, upper)
            }
        }
        return nil
    }

    /// Every object in the schema, with the path to it.
    static func objects() -> [(path: [String], object: ObjectNode)] {
        var out: [(path: [String], object: ObjectNode)] = []
        func visit(_ node: StoicSchema.SchemaNode, _ path: [String]) {
            switch node {
            case .object(let object):
                out.append((path, object))
                for field in object.fields { visit(field.node, path + [field.key]) }
            case .dictionary(let value, _): visit(value, path + ["<key>"])
            case .optional(let wrapped, _): visit(wrapped, path)
            case .transformed(let transform): visit(transform.base, path)
            default: break
            }
        }
        visit(ConfigFile.schema.node, [])
        return out
    }
}
