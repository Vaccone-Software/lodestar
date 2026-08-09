import Foundation

/// A deliberate YAML subset — enough for lodestar.yaml, owned instead of
/// depended on. Supports nested maps by two-or-more-space indentation,
/// `key: value` scalars (unquoted strings, "quoted strings", numbers,
/// booleans), `key:` opening a nested map, and `#` comments. No anchors, no
/// flow syntax, no sequences, no multi-line scalars, no tabs.
public struct YamlError: Error, CustomStringConvertible {
    public let line: Int
    public let message: String
    public var description: String { "yaml line \(line): \(message)" }
}

public enum Yaml {
    private final class Node {
        var children: [String: Node] = [:]
        var scalar: ConfigValue?
    }

    public static func parse(_ text: String) throws -> [String: ConfigValue] {
        let root = Node()
        // (indent of the keys directly inside this node, node)
        var stack: [(indent: Int, node: Node)] = [(-1, root)]

        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let lineNo = index + 1
            if rawLine.contains("\t") {
                throw YamlError(line: lineNo, message: "tabs are not allowed; indent with spaces")
            }
            let uncommented = stripComment(rawLine)
            let content = uncommented.trimmingCharacters(in: .whitespaces)
            if content.isEmpty { continue }

            let indent = uncommented.prefix { $0 == " " }.count

            while stack.count > 1 && indent <= stack[stack.count - 1].indent {
                stack.removeLast()
            }
            let parent = stack[stack.count - 1].node

            guard let colon = content.firstIndex(of: ":") else {
                throw YamlError(line: lineNo, message: "expected 'key: value' or 'key:'")
            }
            let key = String(content[..<colon]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { throw YamlError(line: lineNo, message: "empty key") }
            guard parent.children[key] == nil else {
                throw YamlError(line: lineNo, message: "duplicate key '\(key)'")
            }
            let rest = String(content[content.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            let child = Node()
            parent.children[key] = child
            if rest.isEmpty {
                // Opens a nested map; children must be indented deeper.
                stack.append((indent, child))
            } else {
                child.scalar = try scalarValue(rest, line: lineNo)
            }
        }
        return convert(root)
    }

    /// Walk a dotted path from the root; nil when any hop is missing.
    public static func value(at path: [String], in root: [String: ConfigValue]) -> ConfigValue? {
        var current: ConfigValue = .table(root)
        for hop in path {
            guard let table = current.table, let next = table[hop] else { return nil }
            current = next
        }
        return current
    }

    // MARK: - Internals

    private static func convert(_ node: Node) -> [String: ConfigValue] {
        var out: [String: ConfigValue] = [:]
        for (key, child) in node.children {
            if let scalar = child.scalar {
                out[key] = scalar
            } else {
                out[key] = .table(convert(child))
            }
        }
        return out
    }

    private static func stripComment(_ line: String) -> String {
        var inQuotes = false
        var previous: Character = " "
        for (offset, ch) in line.enumerated() {
            if ch == "\"" && previous != "\\" { inQuotes.toggle() }
            if ch == "#" && !inQuotes {
                return String(line.prefix(offset))
            }
            previous = ch
        }
        return line
    }

    private static func scalarValue(_ text: String, line: Int) throws -> ConfigValue {
        if text.hasPrefix("\"") {
            var result = ""
            var escaped = false
            var closed = false
            for ch in text.dropFirst() {
                if closed { throw YamlError(line: line, message: "trailing characters after string") }
                if escaped {
                    switch ch {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    case "\"": result.append("\"")
                    case "\\": result.append("\\")
                    default: throw YamlError(line: line, message: "unsupported escape \\\(ch)")
                    }
                    escaped = false
                    continue
                }
                if ch == "\\" { escaped = true; continue }
                if ch == "\"" { closed = true; continue }
                result.append(ch)
            }
            guard closed else { throw YamlError(line: line, message: "unterminated string") }
            return .string(result)
        }
        if text == "true" { return .bool(true) }
        if text == "false" { return .bool(false) }
        if let intValue = Int(text) { return .int(intValue) }
        if let doubleValue = Double(text) { return .double(doubleValue) }
        return .string(text)
    }
}
