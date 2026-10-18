import Foundation
import StoicJSON

/// The config's home format: strict JSON in, canonical JSON out, and the
/// sparse discipline — the file holds only what differs from defaults, so
/// a config reads as pure user intent and upgrades rarely touch it.
/// Documentation lives in the schema, never the file; every writer (⌘K,
/// the config verbs, a hand edit that gets rewritten) converges on the
/// same canonical bytes.
public enum Json {
    /// Why the config text could not be read, and where: `lodestar.json:3:5:
    /// …`, the shape editors and terminals link.
    public struct ParseError: Error, CustomStringConvertible {
        /// The file's name, as the message spells it.
        public let file: String
        /// Where the parser stopped; nil when the problem is the whole file's.
        public let line: Int?
        public let column: Int?
        public let message: String

        public init(file: String = Json.fileName, line: Int? = nil, column: Int? = nil, message: String) {
            self.file = file
            self.line = line
            self.column = column
            self.message = message
        }

        public var description: String {
            if let line, let column { return "\(file):\(line):\(column): \(message)" }
            return "\(file): \(message)"
        }
    }

    /// What the config's errors call the file.
    public static let fileName = "lodestar.json"

    /// How the config is read: exactly as the hand-edited store reads it
    /// (`ConfigStore.handEdited`): trailing commas and a byte order mark
    /// accepted, comments refused on purpose because a canonical rewrite would
    /// drop the note, and a repeated key resolved to the last one.
    public static var parseOptions: JSONParseOptions { ConfigStore.handEdited.parseOptions }

    /// Strict JSON → the shared ConfigValue tree. The top level must be an
    /// object. Comments are a parse error on purpose: anything a
    /// canonical rewrite would destroy is refused up front.
    public static func parse(_ text: String, file: String = Json.fileName) throws -> [String: ConfigValue] {
        var ignored: [String] = []
        return try parse(Array(text.utf8), file: file, problems: &ignored)
    }

    public static func parse(_ text: String, file: String = Json.fileName,
                             problems: inout [String]) throws -> [String: ConfigValue] {
        try parse(Array(text.utf8), file: file, problems: &problems)
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
    public static func parse(_ bytes: [UInt8], file: String = Json.fileName,
                             problems: inout [String]) throws -> [String: ConfigValue] {
        let document: JSONDocument
        do {
            document = try JSONDocument(parsing: bytes, options: parseOptions)
        } catch {
            throw ParseError(file: file, line: error.location.line, column: error.location.column,
                             message: error.message)
        }
        guard case .object = document.value else {
            let start = document.range.start
            throw ParseError(file: file, line: start.line, column: start.column,
                             message: "the top level must be an object")
        }
        return tree(of: document.value, problems: &problems) ?? [:]
    }

    /// The config tree a parsed document holds, with what this config cannot
    /// hold left out and reported (see `parse`). Nil when the value is not an
    /// object.
    public static func tree(of value: JSONValue, problems: inout [String]) -> [String: ConfigValue]? {
        guard case .object(let object) = value else { return nil }
        return convertTable(object, at: [], problems: &problems)
    }

    /// A single JSON value ("true", "1800", "\"pointer\"") for the config
    /// verbs; a bare word that fails JSON parsing reads as a string, so
    /// `config set lode.trigger raw-hyper` works unquoted.
    public static func parseFragment(_ text: String) -> ConfigValue {
        var ignored: [String] = []
        if let document = try? JSONDocument(parsing: text, options: .strict),
           let value = convert(document.value, at: [], problems: &ignored) {
            return value
        }
        return .string(text)
    }

    /// One parsed value as the config holds it: nil for what it cannot hold
    /// (a list) and for `null`.
    static func value(_ value: JSONValue) -> ConfigValue? {
        var ignored: [String] = []
        return convert(value, at: [], problems: &ignored)
    }

    private static func convertTable(_ object: JSONObject, at path: [String],
                                     problems: inout [String]) -> [String: ConfigValue] {
        var out: [String: ConfigValue] = [:]
        for member in object {
            if let converted = convert(member.value, at: path + [member.key], problems: &problems) {
                out[member.key] = converted
            }
        }
        return out
    }

    private static func convert(_ value: JSONValue, at path: [String],
                                problems: inout [String]) -> ConfigValue? {
        let address = path.isEmpty ? "the value" : path.joined(separator: ".")
        switch value {
        case .bool(let bool):
            return .bool(bool)
        case .number(let number):
            // The parser refuses what a Double cannot hold, so this guard is
            // belt and braces: carrying -infinity into the tree once meant the
            // next canonical write emitted the bare token `-inf`, which is
            // not JSON — the file stopped parsing, and the config was gone.
            guard let double = number.double, double.isFinite else {
                problems.append("\(address) is not a finite number — ignored")
                return nil
            }
            if double.rounded() == double, abs(double) < 1e15 { return .int(Int(double)) }
            return .double(double)
        case .string(let string):
            return .string(string)
        case .object(let object):
            return .table(convertTable(object, at: path, problems: &problems))
        case .array:
            problems.append("\(address) is a list — this config has no lists, so it was ignored")
            return nil
        case .null:
            return nil // null: an empty section, meaning all-defaults
        }
    }

    // MARK: - Canonical emission

    /// Top-level section order: the header, then the sections as the file
    /// has them (`ConfigStore.sectionOrder`); everything unknown trails
    /// alphabetically, where validation's complaints and the reader's eye
    /// both land last. `config` prints with this; the file is written by the
    /// store with the same order.
    private static let sectionOrder = ["$schema", "version"] + ConfigStore.sectionOrder

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

    // MARK: - The effective view

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

    // MARK: - Entry edits (free-table rows, case-folded on the last hop)

    /// The tree without one free-table entry. The last path component is
    /// matched case-insensitively: the loader folds link names, route
    /// patterns, and bundle ids, so the parsed key an editor holds may not
    /// be the file's spelling — and the file's spelling is the one to
    /// delete. Everything else in the table survives untouched, including
    /// entries the loader rejected: an editor removing one row has no
    /// business deciding a sibling's fate.
    public static func removingEntry(_ root: [String: ConfigValue],
                                     path: [String]) -> [String: ConfigValue] {
        guard let last = path.last?.lowercased() else { return root }
        let parentPath = Array(path.dropLast())
        guard let parent = root.value(at: parentPath)?.table else { return root }
        let doomed = parent.keys.filter { $0.lowercased() == last }
        guard !doomed.isEmpty else { return root }
        var updated = parent
        for key in doomed { updated.removeValue(forKey: key) }
        return setting(root, path: parentPath, to: .table(updated)) ?? root
    }

    /// One free-table entry written in place, replacing any case-variant
    /// of its key first so "Gmail" and "gmail" can never coexist as two
    /// rows. Nil when a value blocks the parent path.
    public static func settingEntry(_ root: [String: ConfigValue], path: [String],
                                    to value: ConfigValue) -> [String: ConfigValue]? {
        setting(removingEntry(root, path: path), path: path, to: value)
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
