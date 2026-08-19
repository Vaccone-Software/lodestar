import Foundation

/// The config schema — one table that drives both reload-time validation
/// (unknown keys, types, enums, ranges) and JSON Schema emission for
/// editors. Parser, validator, and editor hints descend from this single
/// source of truth, so they cannot drift apart.
public indirect enum SchemaNode {
    /// A table with a fixed set of known keys.
    case table([String: SchemaNode], description: String)
    /// A table whose keys are user-chosen; every value shares one schema.
    case freeTable(value: SchemaNode, description: String)
    /// The graph: values are strings or nested graphs, recursively.
    case graph(description: String)
    case string(allowed: [String]?, description: String)
    case boolean(description: String)
    case number(min: Double, max: Double, description: String)
}

public enum ConfigSchema {
    /// Walk a parsed config against a schema; every finding is a warning
    /// string with its dotted path.
    public static func validate(_ root: [String: ConfigValue], against schema: SchemaNode) -> [String] {
        var findings: [String] = []
        walk(.table(root), node: schema, path: [], findings: &findings)
        return findings
    }

    private static func walk(_ value: ConfigValue, node: SchemaNode, path: [String], findings: inout [String]) {
        let where_ = path.isEmpty ? "top level" : path.joined(separator: ".")
        switch node {
        case .table(let known, _):
            guard let table = value.table else {
                findings.append("\(where_) should be a section with keys, not a value")
                return
            }
            for (key, child) in table {
                if let childSchema = known[key] {
                    walk(child, node: childSchema, path: path + [key], findings: &findings)
                } else {
                    let hint = closestKey(to: key, in: Array(known.keys)).map { " — did you mean '\($0)'?" } ?? ""
                    findings.append("unknown key '\((path + [key]).joined(separator: "."))'\(hint)")
                }
            }
        case .freeTable(let valueSchema, _):
            guard let table = value.table else {
                findings.append("\(where_) should be a section with keys, not a value")
                return
            }
            for (key, child) in table {
                walk(child, node: valueSchema, path: path + [key], findings: &findings)
            }
        case .graph:
            switch value {
            case .string:
                break
            case .table(let table):
                for (key, child) in table {
                    walk(child, node: .graph(description: ""), path: path + [key], findings: &findings)
                }
            default:
                findings.append("\(where_) should be an app name or a nested block")
            }
        case .string(let allowed, _):
            guard let text = value.string else {
                findings.append("\(where_) should be text")
                return
            }
            if let allowed, !allowed.contains(text) {
                findings.append("\(where_) is '\(text)' — expected one of: \(allowed.joined(separator: " | "))")
            }
        case .boolean:
            if value.bool == nil {
                findings.append("\(where_) should be true or false")
            }
        case .number(let min, let max, _):
            guard let number = value.double else {
                findings.append("\(where_) should be a number")
                return
            }
            if number < min || number > max {
                findings.append("\(where_) is \(number) — allowed range is \(Int(min))–\(Int(max))")
            }
        }
    }

    /// A small edit-distance hint for typo'd keys.
    private static func closestKey(to key: String, in candidates: [String]) -> String? {
        var best: (String, Int)?
        for candidate in candidates {
            let distance = editDistance(key.lowercased(), candidate.lowercased())
            if distance <= 2, best == nil || distance < best!.1 {
                best = (candidate, distance)
            }
        }
        return best?.0
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var previous = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(b.count, 1) where !b.isEmpty {
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[b.count]
    }

    // MARK: - Dotted addresses

    /// Split a dotted address into path components, letting a user-chosen
    /// key keep its dots.
    ///
    /// Splitting on every dot is wrong wherever the schema says the keys
    /// are the user's: `web.routes` keys are hostnames and
    /// `clipboard.exclude-apps` keys are bundle ids, so
    /// `web.routes.github.com` has to mean the key `github.com`, not a
    /// section `github` holding `com`. Getting that wrong made every such
    /// key unwritable through `config set`, and made `config unset` print
    /// a check mark for a key it never found.
    ///
    /// The schema already knows where a free-form key begins, so it
    /// decides. Inside a free table the shortest key that leaves a
    /// resolvable remainder wins, which addresses both
    /// `web.routes.github.com` (the whole remainder is the key) and
    /// `web.links.my.site.url` (the key is `my.site`, `url` is a field).
    public static func path(for address: String, in schema: SchemaNode) -> [String] {
        let segments = address.split(separator: ".").map(String.init)
        guard !segments.isEmpty else { return [] }
        var out: [String] = []
        var node = schema
        var index = 0
        while index < segments.count {
            switch node {
            case .table(let children, _):
                let key = segments[index]
                out.append(key)
                index += 1
                guard let next = children[key] else {
                    // An unknown section: the rest is addressed literally
                    // and the schema walk reports it.
                    out.append(contentsOf: segments[index...])
                    return out
                }
                node = next
            case .freeTable(let value, _):
                let remaining = Array(segments[index...])
                let width = (1...remaining.count).first { width in
                    resolves(value, Array(remaining[width...]))
                } ?? remaining.count
                out.append(remaining[..<width].joined(separator: "."))
                index += width
                node = value
            case .graph:
                // Graph keys are letters; a dot never belongs to one.
                out.append(segments[index])
                index += 1
            case .string, .boolean, .number:
                out.append(contentsOf: segments[index...])
                return out
            }
        }
        return out
    }

    /// Whether `segments` addresses something inside `node`.
    private static func resolves(_ node: SchemaNode, _ segments: [String]) -> Bool {
        guard let head = segments.first else { return true }
        switch node {
        case .table(let children, _):
            guard let next = children[head] else { return false }
            return resolves(next, Array(segments.dropFirst()))
        case .freeTable(let value, _):
            return (1...segments.count).contains { width in
                resolves(value, Array(segments[width...]))
            }
        case .graph:
            return true
        case .string, .boolean, .number:
            return false
        }
    }

    // MARK: - JSON Schema emission

    /// Emit a JSON Schema document for editors (yaml-language-server).
    public static func jsonSchema(for schema: SchemaNode, title: String) -> [String: Any] {
        var document = jsonNode(schema)
        document["$schema"] = "http://json-schema.org/draft-07/schema#"
        document["title"] = title
        document["definitions"] = [
            "graphNode": [
                "oneOf": [
                    ["type": "string", "description": "An app name, or brave:<profile registry key>"],
                    ["type": "object", "additionalProperties": ["$ref": "#/definitions/graphNode"]],
                ],
            ] as [String: Any],
        ]
        return document
    }

    private static func jsonNode(_ node: SchemaNode) -> [String: Any] {
        switch node {
        // Containers accept null: a section holding only comments (the
        // default file's shape) parses as null and means all-defaults.
        case .table(let known, let description):
            var properties: [String: Any] = [:]
            for (key, child) in known {
                properties[key] = jsonNode(child)
            }
            return [
                "type": ["object", "null"],
                "description": description,
                "properties": properties,
                "additionalProperties": false,
            ]
        case .freeTable(let value, let description):
            return [
                "type": ["object", "null"],
                "description": description,
                "additionalProperties": jsonNode(value),
            ]
        case .graph(let description):
            return [
                "type": ["object", "null"],
                "description": description,
                "additionalProperties": ["$ref": "#/definitions/graphNode"],
            ]
        case .string(let allowed, let description):
            var out: [String: Any] = ["type": "string", "description": description]
            if let allowed { out["enum"] = allowed }
            return out
        case .boolean(let description):
            return ["type": "boolean", "description": description]
        case .number(let min, let max, let description):
            return ["type": "number", "minimum": min, "maximum": max, "description": description]
        }
    }
}
