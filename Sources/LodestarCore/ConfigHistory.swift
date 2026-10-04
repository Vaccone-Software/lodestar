import Foundation

/// Every change to the config, whoever made it: the settings window, the
/// coach, the editor learning a word, ⌘K, a hand edit in the file. The
/// config is the one truth and every writer reloads it, so the history is
/// taken at the reload, as the difference between the file before and the
/// file after, one entry per leaf, each with its old value, its new value,
/// the moment and who wrote it. A change can be undone from its entry:
/// the old value written back, or the line removed when there was none.
///
/// One small file beside the record, a line per entry, the newest last,
/// trimmed to the last `keep` once it holds twice that.
public enum ConfigHistory {
    public struct Entry: Equatable {
        /// `<group>-<index>`: unique, and stable across reads.
        public let id: String
        /// The reload that recorded it, in milliseconds: one write, one group.
        public let group: Int
        public let at: Date
        public let path: [String]
        public let old: ConfigValue?
        public let new: ConfigValue?
        public let source: String

        public init(group: Int, index: Int, at: Date, path: [String],
                    old: ConfigValue?, new: ConfigValue?, source: String) {
            self.id = "\(group)-\(index)"
            self.group = group
            self.at = at
            self.path = path
            self.old = old
            self.new = new
            self.source = source
        }
    }

    public static let defaultFile = Paths.data.appendingPathComponent("config-history.jsonl")
    public static let keep = 500

    /// The leaves that differ between two config trees, in path order. The
    /// file's own stamps (`$schema`, `version`) are not changes.
    public static func changes(from old: [String: ConfigValue], to new: [String: ConfigValue])
        -> [(path: [String], old: ConfigValue?, new: ConfigValue?)] {
        var out: [(path: [String], old: ConfigValue?, new: ConfigValue?)] = []
        func walk(_ a: [String: ConfigValue], _ b: [String: ConfigValue], _ at: [String]) {
            for key in Set(a.keys).union(b.keys).sorted() {
                if at.isEmpty, key == "$schema" || key == "version" { continue }
                let path = at + [key]
                switch (a[key], b[key]) {
                case (.table(let x)?, .table(let y)?):
                    walk(x, y, path)
                case (let x, let y) where x != y:
                    out.append((path, x, y))
                default:
                    break
                }
            }
        }
        walk(old, new, [])
        return out
    }

    /// The tree with one path set to a value, or removed for nil — tables
    /// made on the way, emptied tables left for the writer to prune.
    public static func applying(_ value: ConfigValue?, at path: [String],
                                to tree: [String: ConfigValue]) -> [String: ConfigValue] {
        guard let head = path.first else { return tree }
        var out = tree
        if path.count == 1 {
            out[head] = value
            return out
        }
        let child = out[head]?.table ?? [:]
        out[head] = .table(applying(value, at: Array(path.dropFirst()), to: child))
        return out
    }

    public static func append(_ entries: [Entry], to file: URL = defaultFile) {
        guard !entries.isEmpty else { return }
        var lines = ""
        for entry in entries {
            var object: [String: Any] = [
                "t": entry.at.timeIntervalSince1970, "g": entry.group,
                "p": entry.path, "s": entry.source,
            ]
            if let old = entry.old { object["o"] = Json.emitFragment(old) }
            if let new = entry.new { object["n"] = Json.emitFragment(new) }
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let line = String(data: data, encoding: .utf8) else { continue }
            lines += line + "\n"
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(lines.utf8))
        } else {
            try? Data(lines.utf8).write(to: file, options: .atomic)
            Paths.restrict(file)
        }
        trim(file)
    }

    /// Every entry, oldest first.
    public static func read(from file: URL = defaultFile) -> [Entry] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        var entries: [Entry] = []
        var indexInGroup: [Int: Int] = [:]
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let t = object["t"] as? Double, let group = object["g"] as? Int,
                  let path = object["p"] as? [String], let source = object["s"] as? String else { continue }
            let index = indexInGroup[group, default: 0]
            indexInGroup[group] = index + 1
            entries.append(Entry(group: group, index: index, at: Date(timeIntervalSince1970: t), path: path,
                                 old: (object["o"] as? String).map(Json.parseFragment),
                                 new: (object["n"] as? String).map(Json.parseFragment),
                                 source: source))
        }
        return entries
    }

    private static func trim(_ file: URL) {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > keep * 2 else { return }
        let kept = lines.suffix(keep).joined(separator: "\n") + "\n"
        try? Data(kept.utf8).write(to: file, options: .atomic)
        Paths.restrict(file)
    }
}
