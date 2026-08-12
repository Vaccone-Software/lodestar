import Foundation

/// The config's home format: strict JSON in, canonical JSON out, and the
/// sparse discipline — the file holds only what differs from defaults, so
/// a config reads as pure user intent and upgrades rarely touch it.
/// Documentation lives in the schema, never the file; every writer (⌘K,
/// the config verbs, a hand edit that gets rewritten) converges on the
/// same canonical bytes.
public enum Json {
    public struct ParseError: Error, CustomStringConvertible {
        public let message: String
        public var description: String { "json: \(message)" }
    }

    /// Strict JSON → the shared ConfigValue tree. The top level must be
    /// an object. Comments are a parse error on purpose: anything a
    /// canonical rewrite would destroy is refused up front.
    public static func parse(_ text: String) throws -> [String: ConfigValue] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        } catch {
            let ns = error as NSError
            let detail = (ns.userInfo[NSDebugDescriptionErrorKey] as? String) ?? ns.localizedDescription
            throw ParseError(message: detail)
        }
        guard let table = object as? [String: Any] else {
            throw ParseError(message: "the top level must be an object")
        }
        return convertTable(table)
    }

    /// A single JSON value ("true", "1800", "\"pointer\"") for the config
    /// verbs; a bare word that fails JSON parsing reads as a string, so
    /// `config set hyper.trigger raw-hyper` works unquoted.
    public static func parseFragment(_ text: String) -> ConfigValue {
        let data = Data(text.utf8)
        if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let value = convert(object) {
            return value
        }
        return .string(text)
    }

    private static func convertTable(_ table: [String: Any]) -> [String: ConfigValue] {
        var out: [String: ConfigValue] = [:]
        for (key, value) in table {
            if let converted = convert(value) { out[key] = converted }
        }
        return out
    }

    private static func convert(_ value: Any) -> ConfigValue? {
        if let number = value as? NSNumber {
            // Booleans are NSNumbers too; CFBoolean is the honest test.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            let double = number.doubleValue
            if double.rounded() == double, abs(double) < 1e15 { return .int(Int(double)) }
            return .double(double)
        }
        if let string = value as? String { return .string(string) }
        if let table = value as? [String: Any] { return .table(convertTable(table)) }
        return nil // arrays and nulls have no place in this config
    }

    // MARK: - Canonical emission

    /// Top-level section order; everything unknown trails alphabetically,
    /// where validation's complaints and the reader's eye both land last.
    private static let sectionOrder = [
        "$schema", "version", "hyper", "gestures", "app", "profiles",
        "graph", "web", "scroll", "hints", "double-tap", "keys",
    ]

    public static func emit(_ root: [String: ConfigValue]) -> String {
        var lines: [String] = ["{"]
        let known = sectionOrder.filter { root[$0] != nil }
        let unknown = root.keys.filter { !sectionOrder.contains($0) }.sorted()
        let keys = known + unknown
        for (index, key) in keys.enumerated() {
            let comma = index == keys.count - 1 ? "" : ","
            lines.append(contentsOf: emitValue(root[key]!, key: key, indent: 1, comma: comma))
        }
        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func emitValue(_ value: ConfigValue, key: String?, indent: Int, comma: String) -> [String] {
        let pad = String(repeating: "  ", count: indent)
        let label = key.map { "\(escape($0)): " } ?? ""
        switch value {
        case .table(let table):
            if table.isEmpty { return ["\(pad)\(label){}\(comma)"] }
            var lines = ["\(pad)\(label){"]
            let keys = table.keys.sorted()
            for (index, child) in keys.enumerated() {
                let childComma = index == keys.count - 1 ? "" : ","
                lines.append(contentsOf: emitValue(table[child]!, key: child, indent: indent + 1, comma: childComma))
            }
            lines.append("\(pad)}\(comma)")
            return lines
        case .string(let string):
            return ["\(pad)\(label)\(escape(string))\(comma)"]
        case .bool(let bool):
            return ["\(pad)\(label)\(bool)\(comma)"]
        case .int(let int):
            return ["\(pad)\(label)\(int)\(comma)"]
        case .double(let double):
            // Whole doubles canonicalize to integer form — 1800.0 and 1800
            // are the same setting and must be the same bytes.
            if double.rounded() == double, abs(double) < 1e15 {
                return ["\(pad)\(label)\(Int(double))\(comma)"]
            }
            return ["\(pad)\(label)\(double)\(comma)"]
        }
    }

    /// One value as JSON — what `config get` prints.
    public static func emitFragment(_ value: ConfigValue) -> String {
        switch value {
        case .table:
            let lines = emitValue(value, key: nil, indent: 0, comma: "")
            return lines.joined(separator: "\n")
        case .string(let string): return escape(string)
        case .bool(let bool): return "\(bool)"
        case .int(let int): return "\(int)"
        case .double(let double):
            if double.rounded() == double, abs(double) < 1e15 { return "\(Int(double))" }
            return "\(double)"
        }
    }

    private static func escape(_ string: String) -> String {
        var out = "\""
        for ch in string.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        return out + "\""
    }

    // MARK: - Sparse discipline

    /// True when two values mean the same setting — numeric kinds compare
    /// by value, so a hand-typed 1800.0 still prunes against 1800.
    public static func equivalent(_ a: ConfigValue, _ b: ConfigValue) -> Bool {
        if a == b { return true }
        if let da = a.double, let db = b.double,
           a.string == nil, b.string == nil, a.table == nil, b.table == nil,
           a.bool == nil, b.bool == nil {
            return da == db
        }
        return false
    }

    /// Drop every subtree that equals its default; empty tables vanish
    /// (an empty section and an absent one are the same statement).
    /// Unknown keys survive so validation can keep pointing at them.
    public static func pruned(_ root: [String: ConfigValue],
                              defaults: [String: ConfigValue]) -> [String: ConfigValue] {
        var out: [String: ConfigValue] = [:]
        for (key, value) in root {
            guard let fallback = defaults[key] else {
                if value.table?.isEmpty != true { out[key] = value }
                continue
            }
            if case .table(let table) = value, case .table(let defaultTable) = fallback {
                let kept = pruned(table, defaults: defaultTable)
                if !kept.isEmpty { out[key] = .table(kept) }
                continue
            }
            if !equivalent(value, fallback) { out[key] = value }
        }
        return out
    }

    /// The effective view: defaults with the file's deviations laid over
    /// them. Tables merge deep; scalars replace; unknown keys ride along.
    public static func merged(defaults: [String: ConfigValue],
                              overlay: [String: ConfigValue]) -> [String: ConfigValue] {
        var out = defaults
        for (key, value) in overlay {
            if case .table(let overlayTable) = value,
               case .table(let defaultTable)? = defaults[key] {
                out[key] = .table(merged(defaults: defaultTable, overlay: overlayTable))
            } else {
                out[key] = value
            }
        }
        return out
    }

    // MARK: - Dotted-path edits

    /// The tree with `value` at `path`, creating tables along the way.
    /// Nil when something on the path is a scalar — overwriting a leaf
    /// with a subtree is a decision, not a side effect.
    public static func setting(_ root: [String: ConfigValue], path: [String],
                               to value: ConfigValue) -> [String: ConfigValue]? {
        guard let head = path.first else { return nil }
        var out = root
        if path.count == 1 {
            out[head] = value
            return out
        }
        let child: [String: ConfigValue]
        switch root[head] {
        case .table(let table): child = table
        case nil: child = [:]
        default: return nil
        }
        guard let updated = setting(child, path: Array(path.dropFirst()), to: value) else { return nil }
        out[head] = .table(updated)
        return out
    }

    /// The tree without `path`; branches left childless are pruned. Nil
    /// when the path does not exist.
    public static func removing(_ root: [String: ConfigValue],
                                path: [String]) -> [String: ConfigValue]? {
        guard let head = path.first, let existing = root[head] else { return nil }
        var out = root
        if path.count == 1 {
            out.removeValue(forKey: head)
            return out
        }
        guard case .table(let table) = existing,
              let updated = removing(table, path: Array(path.dropFirst())) else { return nil }
        if updated.isEmpty {
            out.removeValue(forKey: head)
        } else {
            out[head] = .table(updated)
        }
        return out
    }
}
