import Darwin
import Foundation
import SQLite3

/// Firefox's profiles, read the way Firefox 161 keeps them (the 2026-11-28
/// probes). profiles.ini names each install's profile group by `StoreID`;
/// the group's database, `Profile Groups/<StoreID>.sqlite`, is the list a
/// person sees in the profile menu — names and folders both. profiles.ini's
/// own `Name=` lines are not: one probed Mac had "default-release" on the
/// folder the database calls "Test Profile", and the database's "Original
/// profile" missing from the file entirely. So the file's names are read
/// only on an install with no group at all, the old profile manager.
///
/// Every read here is another app's data, which macOS refuses (EPERM, at
/// once, no prompt) until Firefox is turned on for Lodestar in Files &
/// Folders.
public enum FirefoxProfiles {
    /// One `[ProfileN]` section of profiles.ini.
    public struct INIEntry: Equatable, Sendable {
        public var name: String?
        public var path: String?
        public var isRelative = true
        public var storeID: String?
    }

    public static func root(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Firefox", isDirectory: true)
    }

    /// The `[Profile…]` sections of a profiles.ini, in file order.
    public static func parse(profilesINI text: String) -> [INIEntry] {
        var entries: [INIEntry] = []
        var current: INIEntry?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                if let current { entries.append(current) }
                current = line.lowercased().hasPrefix("[profile") ? INIEntry() : nil
                continue
            }
            guard current != nil, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].lowercased()
            let value = String(line[line.index(after: equals)...])
            switch key {
            case "name": current?.name = value
            case "path": current?.path = value
            case "isrelative": current?.isRelative = value != "0"
            case "storeid": current?.storeID = value.isEmpty ? nil : value
            default: break
            }
        }
        if let current { entries.append(current) }
        return entries
    }

    /// An absolute profile directory from a path as Firefox writes it.
    public static func absolute(_ path: String, isRelative: Bool, root: URL) -> String {
        let resolved = isRelative ? root.appendingPathComponent(path).path : path
        return (resolved as NSString).standardizingPath
    }

    /// (name, path) rows of a profile group's database, read-only. Firefox
    /// keeps it in WAL mode. While it runs, the -wal and -shm files are
    /// there and a read-only open reads beside it (measured on Firefox 161).
    /// With them gone a read-only open cannot start, since it may not make
    /// the -shm, so it is asked once more as immutable: with no -shm there
    /// is no writer to read beside, and immutable makes no file at all.
    public static func groupRows(database path: String) throws -> [(name: String, path: String)] {
        do {
            return try rows(opening: path, flags: SQLITE_OPEN_READONLY)
        } catch let first as GroupError {
            guard !FileManager.default.fileExists(atPath: path + "-shm"),
                  let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { throw first }
            return try rows(opening: "file:\(encoded)?immutable=1", flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI)
        }
    }

    private static func rows(opening path: String, flags: Int32) throws -> [(name: String, path: String)] {
        var db: OpaquePointer?
        let opened = sqlite3_open_v2(path, &db, flags, nil)
        defer { sqlite3_close(db) }
        guard opened == SQLITE_OK else {
            throw GroupError(code: opened, message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "open")
        }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, "SELECT name, path FROM Profiles ORDER BY id", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard prepared == SQLITE_OK else {
            throw GroupError(code: prepared, message: String(cString: sqlite3_errmsg(db)))
        }
        var rows: [(String, String)] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw GroupError(code: step, message: String(cString: sqlite3_errmsg(db)))
            }
            guard let name = sqlite3_column_text(statement, 0), let folder = sqlite3_column_text(statement, 1) else {
                continue
            }
            rows.append((String(cString: name), String(cString: folder)))
        }
        return rows
    }

    public struct GroupError: Error, CustomStringConvertible {
        public let code: Int32
        public let message: String
        public var description: String { "sqlite \(code): \(message)" }
    }

    /// Every profile Firefox lists, each with its absolute directory as the
    /// locator.
    public static func listing(root: URL) -> ProfileListing {
        let text: String
        do {
            text = try String(contentsOf: root.appendingPathComponent("profiles.ini"), encoding: .utf8)
        } catch {
            return ProfileListing.failure(error)
        }
        let entries = parse(profilesINI: text)
        var seen = Set<String>()
        var listed: [ListedProfile] = []
        func add(_ name: String, _ directory: String) {
            guard seen.insert(directory).inserted else { return }
            listed.append(ListedProfile(name: name, locator: directory))
        }
        let stores = entries.compactMap(\.storeID).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if stores.isEmpty {
            for entry in entries {
                guard let name = entry.name, let path = entry.path else { continue }
                add(name, absolute(path, isRelative: entry.isRelative, root: root))
            }
            return .profiles(listed)
        }
        for store in stores {
            let database = root.appendingPathComponent("Profile Groups/\(store).sqlite").path
            let access = open(database, O_RDONLY)
            guard access >= 0 else { return ProfileListing.failure(errno: errno) }
            close(access)
            do {
                for row in try groupRows(database: database) {
                    // The database writes paths relative to the root, as
                    // profiles.ini does; an absolute one stays as it is.
                    add(row.name, absolute(row.path, isRelative: !row.path.hasPrefix("/"), root: root))
                }
            } catch {
                return .unreadable("\(store).sqlite: \(error)")
            }
        }
        return .profiles(listed)
    }

    /// The profile directory a Firefox process holds, from the paths it has
    /// open: the folder of a `.parentlock` that is one of the listed
    /// profiles. Firefox holds a lock in its temporary folder first
    /// (`$TMPDIR/firefox/.parentlock`) while it starts, so only a known
    /// directory counts.
    public static func profileDirectory(lockPaths: [String], known: Set<String>) -> String? {
        for path in lockPaths where path.hasSuffix("/.parentlock") {
            let directory = ((path as NSString).deletingLastPathComponent as NSString).standardizingPath
            if known.contains(directory) { return directory }
            // /private/var and /var are one place; a lock read through the
            // kernel carries the resolved form.
            let resolved = (directory as NSString).resolvingSymlinksInPath
            if let match = known.first(where: { ($0 as NSString).resolvingSymlinksInPath == resolved }) {
                return match
            }
        }
        return nil
    }

    /// The `.parentlock` files a process holds open, through libproc. Empty
    /// when the process is gone or will not say.
    public static func lockPaths(pid: pid_t) -> [String] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride)
        let filled = descriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return [] }
        var paths: [String] = []
        for descriptor in descriptors.prefix(Int(filled) / stride)
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let read = proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO,
                                      &info, Int32(MemoryLayout<vnode_fdinfowithpath>.size))
            guard read > 0 else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            if path.hasSuffix("/.parentlock") { paths.append(path) }
        }
        return paths
    }
}
