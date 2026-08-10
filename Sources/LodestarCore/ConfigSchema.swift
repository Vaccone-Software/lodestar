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
