import Foundation
import StoicJSON
import StoicSchema
import StoicSettings
import StoicStore

/// The config file as a hand-edited Stoic settings store: one per path per
/// process, holding the file as a `ConfigFile`.
///
/// What the store gives the config, all of it promises the file made before
/// it was a store: a file that does not parse is never written over (not by
/// the settings window, not by the CLI, not by a reset); an update reads the
/// file again under `<path>.lock` and applies its change to what is there; a
/// write is atomic, durable and keeps the file's mode; two writers holding
/// the same value write the same bytes; an edit made while the app runs
/// arrives through `reload()` and the watch.
///
/// What it does not do is say what the file may hold: that is `ConfigFile.schema`,
/// whose problems (`sentence(for:)`) are what the person is told, whose
/// defaults are what a write leaves out, and which reads the old spellings.
public enum ConfigStore {
    public typealias Store = SettingsStore<ConfigFile>

    /// The top-level sections in the order a person reads the file: what they
    /// edit most first, then the rest alphabetically (`appearance`, `draft`,
    /// `health`). `$schema` and `version` come before them, as the file's
    /// header. `ConfigFile.schema` declares them in this order, and the layout
    /// is the schema's; this is the order `Json.emit` writes a tree in, which
    /// `lodestar config` prints, held to the schema's by a test.
    public static let sectionOrder = [
        "lode", "app", "gestures", "web", "scroll",
        "select", "meetings", "clipboard", "editor", "observations", "coach", "keys", "graph",
    ]

    /// The config's file header: written first by every update, ignored on
    /// read, never part of the value.
    public static var header: SettingsFileHeader {
        ["$schema": "lodestar-schema.json", "version": .string(Lodestar.version)]
    }

    /// How the file is read and written, as one value, so that the store and
    /// the text parser (`Json.parseOptions`) mean the same by it.
    ///
    /// - The layout is the canonical one: the schema's declared order, which
    ///   is Lodestar's (sections as a person reads them, every section's keys
    ///   alphabetical), then keys it does not declare.
    /// - `comments: .refused`: the config's parser has always refused them, so
    ///   a canonical rewrite never drops a note it was not told of.
    /// - `duplicateKeys: .lastWins`: a key said twice is the person's later
    ///   line, which every reader before this one took; the file still loads,
    ///   and the repeat is a warning (`ConfigStore.repeatedKeys`, in `check`
    ///   and the reload's flash), never a fall back to the defaults.
    /// - `lockTimeout: 2 s`: the wait `Config.edit` has always made.
    public static let handEdited = HandEditedOptions(
        fileHeader: header,
        comments: .refused,
        duplicateKeys: .lastWins,
        lockTimeout: .seconds(2))

    /// How the store reads and writes the file.
    public static func options() -> Store.Options {
        Store.Options(handEdited: handEdited)
    }

    static let schema: Schema<ConfigFile> = ConfigFile.schema

    /// What the store held at one moment: the value the config was built from
    /// and the problem the file had.
    public struct Snapshot: Equatable {
        public var value: ConfigFile
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

    // MARK: - The tree and the JSON

    /// The tree Lodestar's editors (the graph's, the web bar's, the settings
    /// window's) read and change: the file as it differs from the defaults,
    /// sparse. What the config cannot hold in a tree (a list in the graph, a
    /// number that is not finite) is left out.
    public static func tree(of file: ConfigFile) -> [String: ConfigValue] {
        var ignored: [String] = []
        return Json.tree(of: schema.encode(file, style: .sparse), problems: &ignored) ?? [:]
    }

    /// The file a tree says, read strictly: an edit that makes the file say
    /// something the schema refuses is refused with what is wrong with it.
    /// (Keys the schema does not declare are not an error here, and are not
    /// in the value: what the store carries is the file's, not an edit's.)
    static func file(from tree: [String: ConfigValue]) throws -> ConfigFile {
        let decoded = schema.decode(json(tree), options: .strict)
        guard let file = decoded.value else {
            throw Config.EditError.invalid(decoded.errors.map(ConfigFile.sentence(for:)).joined(separator: "; "))
        }
        return file
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
            return try store.blockingMaterialize(waitingUpTo: .seconds(2))
        } catch let error as Store.UpdateError {
            if case .durabilityUnknown(let failure) = error {
                Log.error("config: written, but not known to be durable", ["error": "\(failure)"])
                return true
            }
            // Another process holding the lock for two seconds is writing the
            // file, and is the one that creates it.
            if case .busy = error { return false }
            throw editError(error, file: name, waited: 2)
        }
    }

    // MARK: - Errors

    /// What a refused update is, in the config's own terms.
    static func editError(_ error: Store.UpdateError, file: String, waited: TimeInterval) -> Config.EditError {
        switch error {
        case .busy:
            return .busy("waited \(Int(waited)) s for the lock on \(file)")
        case .fileUnusable(let problem):
            if problem.isNotUTF8 { return .unreadable(file) }
            if case .unreadable = problem { return .unreadable(file) }
            return .unparsed(describe(problem, file: file))
        case .storage(let failure):
            return .storage("\(failure)")
        case .durabilityUnknown(let failure):
            return .storage("\(failure)")
        case .invalid(let issues):
            return .invalid(issues.map(ConfigFile.sentence(for:)).joined(separator: "; "))
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
        var message = issue.message
        if issue.code == .parseError, message.hasPrefix("invalid JSON: ") {
            message = String(message.dropFirst("invalid JSON: ".count))
        }
        guard let position else { return "\(file): \(message)" }
        return "\(file):\(position): \(message)"
    }

    /// What a key said twice in one object is, for the person who wrote it: a
    /// warning, one for each repeat, with the line and column of the repeat
    /// and what the store did (the last one is used, and the next write keeps
    /// only that). The file loads: this is never a reason to fall back to the
    /// defaults. In the same words as a problem, for `check` and the flash.
    static func repeatedKeys(in issues: [Issue], file: String) -> [String] {
        issues.filter { $0.code == .repeatedKey }.map {
            "config warning: " + describe($0, file: file) + ($0.parameters["note"]?.string.map { " — \($0)" } ?? "")
        }
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
        let fresh = ConfigFile()
        do {
            let copy = try store.blockingReplaceUnusableFile(
                with: fresh, keepingCopyAt: backup.path, waitingUpTo: .seconds(2), source: "lodestar reset-config")
            return URL(fileURLWithPath: copy)
        } catch let error as ConfigStore.Store.ReplaceError {
            switch error {
            case .fileIsUsable:
                break // the ordinary road, below
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
        } catch {
            throw ResetError.writeFailed(reason: "\(error)", backup: nil)
        }
        do {
            try fm.copyItem(at: target, to: backup)
        } catch {
            throw ResetError.backupFailed(file: name, reason: error.localizedDescription)
        }
        do {
            try store.blockingUpdate(waitingUpTo: .seconds(2), source: "lodestar reset-config") { $0 = fresh }
        } catch let error as ConfigStore.Store.UpdateError {
            if case .durabilityUnknown = error { return backup }
            throw ResetError.writeFailed(reason: "\(ConfigStore.editError(error, file: name, waited: 2))", backup: backup)
        } catch {
            throw ResetError.writeFailed(reason: "\(error)", backup: backup)
        }
        return backup
    }
}
