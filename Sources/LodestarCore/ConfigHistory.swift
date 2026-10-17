import Foundation
import StoicJSON

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
    public struct Entry: Equatable, Sendable {
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
    ///
    /// The difference is Stoic's (`JSONChange.between`): the deepest paths at
    /// which the two trees differ, a key on one side only being one change
    /// at that key with its whole value, and `1800` and `1800.0` being the
    /// same number.
    public static func changes(from old: [String: ConfigValue], to new: [String: ConfigValue])
        -> [(path: [String], old: ConfigValue?, new: ConfigValue?)] {
        JSONChange.between(ConfigStore.json(old), ConfigStore.json(new)).compactMap { change in
            let path = change.path.components.compactMap { component -> String? in
                if case .key(let key) = component { return key }
                return nil
            }
            // The root differing as a whole cannot happen between two trees;
            // the stamps are the file's, not the person's.
            guard !path.isEmpty, !(path.count == 1 && (path[0] == "$schema" || path[0] == "version")) else {
                return nil
            }
            return (path, change.old.flatMap(Json.value), change.new.flatMap(Json.value))
        }
    }

    /// The tree with one path set to a value, or removed for nil — tables
    /// made on the way, emptied tables left for the writer to prune.
    ///
    /// Stoic's `JSONValue.applying(_:overwriting: true)`: the entry's value
    /// goes where its path says whatever is there now, which is what undoing
    /// an edit that has since been changed again means. A value in the way
    /// of a section (a scalar where the path needs a table) is replaced by
    /// the table, as it always was.
    public static func applying(_ value: ConfigValue?, at path: [String],
                                to tree: [String: ConfigValue]) -> [String: ConfigValue] {
        guard !path.isEmpty else { return tree }
        var json = ConfigStore.json(tree)
        let change = JSONChange(path: JSONPath(path.map { .key($0) }), old: nil,
                                new: value.flatMap { ConfigStore.json($0) })
        for _ in 0...path.count {
            do {
                json = try json.applying(change, overwriting: true)
                break
            } catch JSONChange.ApplyError.blocked(let step) {
                // A scalar sits where a section must be: the section wins.
                let blocking = JSONPath(Array(step.components.dropLast()))
                guard let cleared = try? json.setting(.object(JSONObject()), at: blocking) else { break }
                json = cleared
            } catch {
                break
            }
        }
        var ignored: [String] = []
        return Json.tree(of: json, problems: &ignored) ?? tree
    }

    /// Which side of its entries a group is written back to.
    public enum Side { case old, new }

    /// A group of entries' old (or new) values written back to the tree, as
    /// one edit: undoing takes them last to first, redoing first to last.
    public static func restoring(_ entries: [Entry], to side: Side, in tree: [String: ConfigValue])
        -> [String: ConfigValue] {
        let ordered = side == .old ? Array(entries.reversed()) : entries
        return ordered.reduce(tree) { applying(side == .old ? $1.old : $1.new, at: $1.path, to: $0) }
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
        // An O_APPEND open that creates the file when it is not there and
        // never replaces it when it is: the old fallback wrote a new file
        // holding only these lines over a history that merely failed to open.
        do {
            try DurableFile.append(Data(lines.utf8), to: file)
        } catch {
            Log.error("config history: could not append to \(file.lastPathComponent)",
                      ["error": "\(error)"])
            return
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
        DurableFile.save(Data(kept.utf8), to: file, as: "config history", newFileMode: 0o600)
        Paths.restrict(file)
    }
}
