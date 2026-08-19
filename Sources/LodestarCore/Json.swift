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
        var ignored: [String] = []
        return try parse(text, problems: &ignored)
    }

    /// The same parse, reporting what it had to drop.
    ///
    /// A value this config cannot hold — an array, a number that is not
    /// finite — used to vanish between the file and the tree, so the
    /// schema walk that runs next saw nothing to complain about and
    /// `check` reported a clean config for a line that does nothing. Worse,
    /// the next canonical write removed the line from disk. Dropping is
    /// still the behaviour; being quiet about it is not.
    ///
    /// `null` is the exception, and stays silent: a section written with
    /// no keys is how the config spells "all defaults here", and the
    /// emitted JSON Schema explicitly admits it.
    public static func parse(_ text: String, problems: inout [String]) throws -> [String: ConfigValue] {
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
        return convertTable(table, at: [], problems: &problems)
    }

    /// A single JSON value ("true", "1800", "\"pointer\"") for the config
    /// verbs; a bare word that fails JSON parsing reads as a string, so
    /// `config set lode.trigger raw-hyper` works unquoted.
    public static func parseFragment(_ text: String) -> ConfigValue {
        let data = Data(text.utf8)
        var ignored: [String] = []
        if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let value = convert(object, at: [], problems: &ignored) {
            return value
        }
        return .string(text)
    }

    private static func convertTable(_ table: [String: Any], at path: [String],
                                     problems: inout [String]) -> [String: ConfigValue] {
        var out: [String: ConfigValue] = [:]
        for (key, value) in table {
            if let converted = convert(value, at: path + [key], problems: &problems) {
                out[key] = converted
            }
        }
        return out
    }

    private static func convert(_ value: Any, at path: [String],
                                problems: inout [String]) -> ConfigValue? {
        let address = path.isEmpty ? "the value" : path.joined(separator: ".")
        if let number = value as? NSNumber {
            // Booleans are NSNumbers too; CFBoolean is the honest test.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            let double = number.doubleValue
            // JSONSerialization accepts a negative overflow (-1e400) and
            // hands back -infinity. Carrying that into the tree meant the
            // next canonical write emitted the bare token `-inf`, which is
            // not JSON — the file stopped parsing, and the config was gone.
            guard double.isFinite else {
                problems.append("\(address) is not a finite number — ignored")
                return nil
            }
            if double.rounded() == double, abs(double) < 1e15 { return .int(Int(double)) }
            return .double(double)
        }
        if let string = value as? String { return .string(string) }
        if let table = value as? [String: Any] {
            return .table(convertTable(table, at: path, problems: &problems))
        }
        if value is [Any] {
            problems.append("\(address) is a list — this config has no lists, so it was ignored")
            return nil
        }
        return nil // null: an empty section, meaning all-defaults
    }

    // MARK: - Canonical emission

    /// Top-level section order; everything unknown trails alphabetically,
    /// where validation's complaints and the reader's eye both land last.
    private static let sectionOrder = [
        "$schema", "version", "lode", "gestures", "app", "profiles",
        "graph", "web", "scroll", "hints", "clipboard", "double-tap", "keys",
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
            // The parser refuses non-finite values, so reaching here means
            // one was computed. `inf`/`nan` are not JSON tokens and would
            // make the file we just wrote unreadable, taking the config
            // with it — emit null instead, which is valid, reads back as
            // "key absent" (so the default returns), and says so in the log.
            guard double.isFinite else {
                Log.error("json: refusing to emit a non-finite number", ["key": key ?? "?"])
                return ["\(pad)\(label)null\(comma)"]
            }
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
            guard double.isFinite else { return "null" }
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
    /// What a removal found. `unset` used to read nil as "already the
    /// default" and exit 0, which it also printed for a path it could not
    /// reach — so a key that stayed in the file reported success.
    public enum Removal: Equatable {
        /// The key was there; here is the tree without it.
        case removed([String: ConfigValue])
        /// Nothing at that path — it is already the default.
        case absent
        /// A value sits where the path expected a section, naming the
        /// prefix that blocked the walk.
        case blocked(String)
    }

    public static func removing(_ root: [String: ConfigValue], path: [String]) -> Removal {
        removing(root, path: path, walked: [])
    }

    private static func removing(_ root: [String: ConfigValue], path: [String],
                                 walked: [String]) -> Removal {
        guard let head = path.first else { return .absent }
        guard let existing = root[head] else { return .absent }
        var out = root
        if path.count == 1 {
            out.removeValue(forKey: head)
            return .removed(out)
        }
        guard case .table(let table) = existing else {
            return .blocked((walked + [head]).joined(separator: "."))
        }
        switch removing(table, path: Array(path.dropFirst()), walked: walked + [head]) {
        case .removed(let updated):
            if updated.isEmpty {
                out.removeValue(forKey: head)
            } else {
                out[head] = .table(updated)
            }
            return .removed(out)
        case .absent: return .absent
        case .blocked(let where_): return .blocked(where_)
        }
    }
}
