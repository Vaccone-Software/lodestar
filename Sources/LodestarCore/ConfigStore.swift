import Foundation
import StoicJSON
import StoicSchema
import StoicSettings
import StoicStore

/// The config file as a hand-edited Stoic settings store: one per path per
/// process, holding the file's tree as a `JSONValue`.
///
/// What the store gives the config, all of it promises the file made before
/// it was a store: a file that does not parse is never written over (not by
/// the settings window, not by the CLI, not by a reset); an update reads the
/// file again under `<path>.lock` and applies its change to what is there; a
/// write is atomic, durable and keeps the file's mode; two writers holding
/// the same value write the same bytes; an edit made while the app runs
/// arrives through `reload()` and the watch.
///
/// What it does not do, and the config keeps doing itself: `ConfigSchema` is
/// still the validator (the tree is read through `Config.build`, and a value
/// out of range is a problem the person is told of, not a refusal to load),
/// and `ConfigDefaults` still normalizes and prunes, inside the update.
public enum ConfigStore {
    public typealias Store = SettingsStore<JSONValue>

    /// The top-level sections in the order a person reads the file: what they
    /// edit most first. `$schema` and `version` come before them, as the
    /// file's header. Everything else trails alphabetically, where
    /// validation's complaints and the reader's eye both land last; so does
    /// the content of every section.
    public static let sectionOrder = [
        "lode", "app", "gestures", "web", "scroll",
        "select", "meetings", "clipboard", "editor", "observations", "coach", "keys", "graph",
    ]

    /// The config's file header: written first by every update, ignored on
    /// read, never part of the tree.
    public static var header: SettingsFileHeader {
        ["$schema": "lodestar-schema.json", "version": .string(Lodestar.version)]
    }

    /// How the store reads and writes the file.
    ///
    /// - `comments: .refused`: the config's parser has always refused them, so
    ///   a canonical rewrite never drops a note it was not told of.
    /// - `lockTimeout: 2 s`: the wait `Config.edit` has always made.
    public static func options() -> Store.Options {
        Store.Options(handEdited: HandEditedOptions(
            fileHeader: header,
            layout: .canonical(order: KeyOrder(root: sectionOrder)),
            comments: .refused,
            lockTimeout: .seconds(2)))
    }

    /// Any JSON object. A file whose top level is anything else is as
    /// unreadable as one that is not JSON.
    ///
    /// WORKAROUND (Stoic): `Schema.json()` takes any value, so a file that is
    /// `[1, 2]` or `5` would load as a good value and the app would then fail
    /// on the first lookup. A custom constraint says "an object"; the
    /// exporter and generators cannot see inside it. A built-in
    /// `Constraint.isObject` (or a `Schema.jsonObject()`) would remove it.
    static let schema: Schema<JSONValue> = .json(.custom(
        id: "object", description: "an object: the config is a table of sections",
        check: { if case .object = $0 { true } else { false } }))

    /// What the store held at one moment: the value the config was built from
    /// and the problem the file had.
    public struct Snapshot: Equatable {
        public var value: JSONValue
        public var problem: SettingsFileProblem?
    }

    // MARK: - One store per path

    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var stores: [String: Store] = [:]

        func store(at path: String, open: () throws(StoreError) -> Store) throws(StoreError) -> Store {
            lock.lock()
            defer { lock.unlock() }
            if let existing = stores[path] { return existing }
            let opened = try open()
            stores[path] = opened
            return opened
        }
    }

    private static let registry = Registry()

    /// The store for the config at `url`, opened the first time it is asked
    /// for and the same one every time after: a store is the process's one
    /// view of its file, so that an update, a reload and the watch all
    /// serialise through it. Opening reads the file once and never writes.
    ///
    /// Runs on whatever thread asks, and reads the file when it opens: the
    /// main thread's first call is the app's boot load, as before.
    public static func store(at url: URL = Config.file) throws(StoreError) -> Store {
        let path = url.standardizedFileURL.path
        return try registry.store(at: path) { () throws(StoreError) -> Store in
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            return try Store.open(at: path, schema: schema, format: .handEdited, options: options())
        }
    }

    // MARK: - Who wrote it

    /// Who is about to write which value, so that the history can say, once
    /// the store announces the change, who made it.
    ///
    /// A change from the stream says what changed and why (`.update`: the app
    /// did it), not *which part of the app*: the settings window, the coach,
    /// the editor learning a word, an undo. A writer names itself when it
    /// writes (`Config.edit(source:)`), inside the update's own critical
    /// section, so the entry is made only for an update that changes the value
    /// and is in commit order; the history claims it by the value it produced.
    final class Attributions: @unchecked Sendable {
        struct Entry { let id: UInt64; let new: JSONValue; let source: String }

        private let lock = NSLock()
        private var next: UInt64 = 0
        private var pending: [String: [Entry]] = [:]

        /// The most that wait for their change: a change the stream dropped
        /// (a reader that fell behind) leaves its entry here, and a bound
        /// keeps it from growing.
        static let bound = 64

        func expect(source: String, producing new: JSONValue, at path: String) -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            next += 1
            var entries = pending[path, default: []]
            entries.append(Entry(id: next, new: new, source: source))
            if entries.count > Self.bound { entries.removeFirst(entries.count - Self.bound) }
            pending[path] = entries
            return next
        }

        /// The update did not commit after all.
        func cancel(_ id: UInt64, at path: String) {
            lock.lock()
            defer { lock.unlock() }
            pending[path]?.removeAll { $0.id == id }
        }

        /// The writer of the update that produced `new`: the oldest entry for
        /// that value, which also settles the older entries (their changes
        /// were never announced to a reader that is still here).
        func claim(producing new: JSONValue, at path: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            guard let index = pending[path]?.firstIndex(where: { $0.new == new }) else { return nil }
            let source = pending[path]![index].source
            pending[path]!.removeSubrange(...index)
            return source
        }
    }

    static let attributions = Attributions()

    // MARK: - The tree and the JSON

    /// The tree Lodestar's own code reads and edits, from the store's value.
    /// What the config cannot hold (a list, a number that is not finite) is
    /// left out and reported in `problems`; `null` is silent.
    public static func tree(of value: JSONValue, problems: inout [String]) -> [String: ConfigValue] {
        Json.tree(of: value, problems: &problems) ?? [:]
    }

    /// The tree as the file would hold it: normalized to today's names, the
    /// header's keys left to the header, pruned sparse against the defaults.
    /// The one place every write's content is made, whoever writes.
    public static func canonical(_ tree: [String: ConfigValue]) -> JSONValue {
        var clean = ConfigDefaults.normalized(tree)
        clean.removeValue(forKey: "$schema")
        clean.removeValue(forKey: "version")
        return json(Json.pruned(clean, defaults: ConfigDefaults.tree))
    }

    /// A tree as JSON. A number that is not finite cannot be written, so its
    /// key is left out (the key reads as absent, and its default returns),
    /// and the log says so: the emitter wrote `null` for it, which read back
    /// the same.
    public static func json(_ tree: [String: ConfigValue]) -> JSONValue {
        var object = JSONObject()
        for key in tree.keys.sorted() {
            if let value = json(tree[key]!, key: key) { object[key] = value }
        }
        return .object(object)
    }

    static func json(_ value: ConfigValue, key: String = "value") -> JSONValue? {
        switch value {
        case .string(let string): return .string(string)
        case .bool(let bool): return .bool(bool)
        case .int(let int): return .number(JSONNumber(int))
        case .double(let double):
            // Whole doubles are integers in the file: 1800.0 and 1800 are
            // the same setting and the same bytes.
            if double.rounded() == double, abs(double) < 1e15 { return .number(JSONNumber(Int(double))) }
            guard let number = JSONNumber(double) else {
                Log.error("config: refusing to write a non-finite number", ["key": key])
                return nil
            }
            return .number(number)
        case .table(let table):
            return json(table)
        }
    }

    // MARK: - Writing the whole file, on purpose

    /// The first launch: leave the person a file to edit. Writes the sparse
    /// current value (the defaults) with the header when there is no file,
    /// and does nothing, reads nothing as a reason to write, when there is
    /// one. Does not wait for the lock: another process that is writing the
    /// file is writing it, and is the one that creates it.
    @discardableResult
    static func materialize(at url: URL) throws -> Bool {
        let name = url.lastPathComponent
        let store: Store
        do {
            store = try self.store(at: url)
        } catch {
            throw Config.EditError.unreadable(name)
        }
        do {
            return try store.materialize()
        } catch {
            if case .durabilityUnknown(let failure) = error {
                Log.error("config: written, but not known to be durable", ["error": "\(failure)"])
                return true
            }
            if case .busy = error { return false }
            throw editError(error, file: name, waited: 0)
        }
    }

    // MARK: - Errors

    /// What a refused update is, in the config's own terms.
    static func editError(_ error: Store.UpdateError, file: String, waited: TimeInterval) -> Config.EditError {
        switch error {
        case .busy:
            return .busy("waited \(Int(waited)) s for the lock on \(file)")
        case .fileUnusable(let problem):
            if isNotUTF8(problem) { return .unreadable(file) }
            if case .unreadable = problem { return .unreadable(file) }
            return .unparsed(describe(problem, file: file))
        case .storage(let failure):
            return .storage("\(failure)")
        case .durabilityUnknown(let failure):
            return .storage("\(failure)")
        case .invalid(let issues):
            return .unparsed(issues.map { describe($0, file: file) }.joined(separator: "; "))
        case .newerFormat:
            return .unparsed("\(file) was written by a newer Lodestar")
        }
    }

    /// The problem as `Config.load` reports it: the framing the config's
    /// parse errors have always had, with the file's own line and column.
    static func sentence(for problem: SettingsFileProblem, file: String, keepingLastGood: Bool) -> String {
        "config parse failed (\(describe(problem, file: file))); "
            + (keepingLastGood ? "keeping the last good config" : "using defaults")
            + " — \(file) left untouched"
    }

    // MARK: - Saying what is wrong with the file

    /// `lodestar.json:3:5: invalid JSON: …`, the shape editors link.
    static func describe(_ issue: Issue, file: String) -> String {
        let position = issue.source.map { "\($0.start.line):\($0.start.column)" }
        if issue.code == .custom, issue.parameters["id"]?.string == "object" {
            return "\(file):\(position ?? "1:1"): the top level must be an object"
        }
        var message = issue.message
        if issue.code == .parseError {
            if let code = issue.parameters["parseCode"]?.string, let text = issue.parameters["message"]?.string {
                message = Json.says(code, text)
            } else if message.hasPrefix("invalid JSON: ") {
                message = String(message.dropFirst("invalid JSON: ".count))
            }
        }
        guard let position else { return "\(file): \(message)" }
        return "\(file):\(position): \(message)"
    }

    /// The first thing wrong with the file, in the words `lodestar check`
    /// and the reload's flash use.
    static func describe(_ problem: SettingsFileProblem, file: String) -> String {
        switch problem {
        case .unparsable(let issues):
            let first = issues.first(where: { $0.severity == .error }) ?? issues.first
            return first.map { describe($0, file: file) } ?? "\(file): could not be read"
        case .unreadable(let error):
            return "\(file): could not be read (\(error))"
        }
    }

    /// The line and column the problem is at, when it is in the text.
    public static func location(of problem: SettingsFileProblem) -> (line: Int, column: Int)? {
        problem.location.map { ($0.line, $0.column) }
    }

    /// Whether the file's trouble is that it is not UTF-8: the one problem
    /// `Config.EditError` has always told apart (`unreadable`, not `unparsed`).
    static func isNotUTF8(_ problem: SettingsFileProblem) -> Bool {
        guard case .unparsable(let issues) = problem else { return false }
        return issues.contains { $0.parameters["parseCode"]?.string == "invalid_utf8" }
    }
}

// MARK: - Reset

extension Config {
    /// Why `reset` stopped. Both mean the same to the person: say it, and the
    /// config is as it was (or, for `writeFailed` with a backup, as it was and
    /// copied beside).
    public enum ResetError: Error, CustomStringConvertible {
        /// The copy of the person's file could not be made. Nothing changed.
        case backupFailed(file: String, reason: String)
        /// The fresh file could not be written. The old one is as it was.
        case writeFailed(reason: String, backup: URL?)

        public var description: String {
            switch self {
            case .backupFailed(let file, let reason):
                return "could not back up \(file) (\(reason)) — aborting, nothing changed"
            case .writeFailed(let reason, _):
                return "could not write the default config: \(reason)"
            }
        }
    }

    /// `lodestar reset-config`: the defaults, with the person's file kept
    /// first. Reset must never cost the user their registry, graph, or links.
    ///
    /// - A missing file is just created (nothing to keep).
    /// - A file that does not parse is Stoic's `replaceUnusableFile`: the
    ///   person's bytes are copied (checked) to `backup`, then replaced. This
    ///   is the one road over a file the store refuses to write over.
    /// - A file that parses is copied to `backup`, then replaced by an
    ///   ordinary update, so it waits for another writer's lock like any edit.
    ///
    /// Blocks the calling thread for up to 2 s waiting for the lock; it is the
    /// CLI's, never the app's.
    ///
    /// - Returns: Where the person's file was kept, or nil when there was none.
    @discardableResult
    public static func reset(at target: URL = Config.file, backingUpTo backup: URL) throws -> URL? {
        let name = target.lastPathComponent
        let store: ConfigStore.Store
        do {
            store = try ConfigStore.store(at: target)
        } catch {
            throw ResetError.writeFailed(reason: "\(error)", backup: nil)
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: target.path) else {
            do { try ConfigStore.materialize(at: target) } catch {
                throw ResetError.writeFailed(reason: "\(error)", backup: nil)
            }
            return nil
        }
        // The fresh file is the defaults, which the header makes a file.
        let fresh = JSONValue.object(JSONObject())
        let deadline = Date().addingTimeInterval(2)
        while true {
            do throws(ConfigStore.Store.ReplaceError) {
                let copy = try store.replaceUnusableFile(with: fresh, keepingCopyAt: backup.path)
                return URL(fileURLWithPath: copy)
            } catch {
                switch error {
                case .fileIsUsable:
                    break // the ordinary road, below
                case .busy where Date() < deadline:
                    Thread.sleep(forTimeInterval: 0.025)
                    continue
                case .copyFailed(let failure):
                    throw ResetError.backupFailed(file: name, reason: "\(failure)")
                case .backupExists(let path):
                    throw ResetError.backupFailed(file: name, reason: "\(path) already exists")
                case .storage(let failure, let copy):
                    throw ResetError.writeFailed(reason: "\(failure)", backup: URL(fileURLWithPath: copy))
                case .durabilityUnknown(_, let copy):
                    Log.error("config: reset, but not known to be durable")
                    return URL(fileURLWithPath: copy)
                default:
                    throw ResetError.writeFailed(reason: "\(error)", backup: nil)
                }
            }
            break
        }
        do {
            try fm.copyItem(at: target, to: backup)
        } catch {
            throw ResetError.backupFailed(file: name, reason: error.localizedDescription)
        }
        do {
            try store.blockingUpdate(waitingUpTo: .seconds(2)) { $0 = fresh }
        } catch let error as ConfigStore.Store.UpdateError {
            if case .durabilityUnknown = error { return backup }
            throw ResetError.writeFailed(reason: "\(ConfigStore.editError(error, file: name, waited: 2))", backup: backup)
        } catch {
            throw ResetError.writeFailed(reason: "\(error)", backup: backup)
        }
        return backup
    }
}
