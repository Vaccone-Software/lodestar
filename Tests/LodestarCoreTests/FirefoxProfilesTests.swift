import SQLite3
import XCTest
@testable import LodestarCore

/// Firefox's profiles as Firefox 161 keeps them, from files shaped like the
/// ones probed on a real Mac (2026-11-28), and the process lock that tells
/// one profile's windows from another's.
final class FirefoxProfilesTests: XCTestCase {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("firefox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Profile Groups"),
                                                withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// profiles.ini as the probed Mac had it: its `Name=` lines disagree with
    /// the profile menu, and one of the menu's profiles is not in it at all.
    private let probedINI = """
    [General]
    StartWithLastProfile=1
    Version=2

    [Profile0]
    Name=default-release
    IsRelative=1
    Path=Profiles/yIFHcY8b.Profile 1
    StoreID=2dc15780
    ShowSelector=1

    [Install2656FF1E876E9973]
    Default=Profiles/yIFHcY8b.Profile 1
    Locked=1

    [Profile1]
    Name=default
    IsRelative=1
    Path=Profiles/evwxqiuj.default
    Default=1
    """

    /// A profile-group database with Firefox's `Profiles` table. `wal`
    /// leaves it in WAL mode with a writer still connected, as a running
    /// Firefox does; the returned handle is closed at teardown.
    @discardableResult
    private func makeGroup(_ root: URL, store: String, rows: [(String, String)], wal: Bool = false) throws -> OpaquePointer? {
        let path = root.appendingPathComponent("Profile Groups/\(store).sqlite").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        var statements = ["CREATE TABLE Profiles (id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, name TEXT NOT NULL, avatar TEXT, themeId TEXT)"]
        if wal { statements.insert("PRAGMA journal_mode=WAL", at: 0) }
        for (index, row) in rows.enumerated() {
            statements.append("INSERT INTO Profiles (id, path, name) VALUES (\(index + 1), '\(row.1)', '\(row.0)')")
        }
        for statement in statements {
            XCTAssertEqual(sqlite3_exec(db, statement, nil, nil, nil), SQLITE_OK, statement)
        }
        if wal {
            addTeardownBlock { sqlite3_close(db) }
            return db
        }
        sqlite3_close(db)
        return nil
    }

    func testINIParsesProfileSectionsOnly() {
        let entries = FirefoxProfiles.parse(profilesINI: probedINI)
        XCTAssertEqual(entries.count, 2, "[General] and [Install…] are not profiles")
        XCTAssertEqual(entries[0].name, "default-release")
        XCTAssertEqual(entries[0].storeID, "2dc15780")
        XCTAssertEqual(entries[1].path, "Profiles/evwxqiuj.default")
        XCTAssertNil(entries[1].storeID)
    }

    /// The probed case: names and folders come from the group's database
    /// alone, so "default-release" (profiles.ini's wrong name for Test
    /// Profile's folder) and the legacy "default" never appear.
    func testGroupDatabaseIsTheListWhenThereIsOne() throws {
        let root = try scratch()
        try probedINI.write(to: root.appendingPathComponent("profiles.ini"), atomically: true, encoding: .utf8)
        try makeGroup(root, store: "2dc15780", rows: [
            ("Original profile", "Profiles/gn8a3f5d.default-release"),
            ("Test Profile", "Profiles/yIFHcY8b.Profile 1"),
        ])
        let listing = FirefoxProfiles.listing(root: root)
        XCTAssertEqual(listing.profiles.map(\.name), ["Original profile", "Test Profile"])
        XCTAssertEqual(listing.profiles[1].locator,
                       (root.appendingPathComponent("Profiles/yIFHcY8b.Profile 1").path as NSString).standardizingPath)
    }

    /// Firefox holds the database open in WAL mode while it runs; a
    /// read-only read sees every row and makes no file of its own.
    func testGroupDatabaseReadsWhileFirefoxWrites() throws {
        let root = try scratch()
        try "[Profile0]\nName=x\nPath=Profiles/a\nStoreID=s1\n"
            .write(to: root.appendingPathComponent("profiles.ini"), atomically: true, encoding: .utf8)
        try makeGroup(root, store: "s1", rows: [("Work", "Profiles/a"), ("Home", "Profiles/b")], wal: true)
        let before = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Profile Groups").path).sorted()
        XCTAssertEqual(FirefoxProfiles.listing(root: root).profiles.map(\.name), ["Work", "Home"])
        let after = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Profile Groups").path).sorted()
        XCTAssertEqual(before, after)
    }

    func testOldInstallWithoutGroupsReadsININames() throws {
        let root = try scratch()
        try """
        [Profile0]
        Name=default-release
        IsRelative=1
        Path=Profiles/abc.default-release

        [Profile1]
        Name=Elsewhere
        IsRelative=0
        Path=/Volumes/Data/firefox-profile
        """.write(to: root.appendingPathComponent("profiles.ini"), atomically: true, encoding: .utf8)
        let listing = FirefoxProfiles.listing(root: root)
        XCTAssertEqual(listing.profiles.map(\.name), ["default-release", "Elsewhere"])
        XCTAssertEqual(listing.profiles[1].locator, "/Volumes/Data/firefox-profile")
    }

    func testNoFirefoxIsNotInstalled() throws {
        XCTAssertEqual(FirefoxProfiles.listing(root: try scratch().appendingPathComponent("nope")), .notInstalled)
    }

    func testRefusedINIIsRefused() throws {
        let root = try scratch()
        let ini = root.appendingPathComponent("profiles.ini")
        try probedINI.write(to: ini, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: ini.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ini.path) }
        XCTAssertEqual(FirefoxProfiles.listing(root: root), .refused)
    }

    func testRefusedGroupDatabaseIsRefused() throws {
        let root = try scratch()
        try probedINI.write(to: root.appendingPathComponent("profiles.ini"), atomically: true, encoding: .utf8)
        try makeGroup(root, store: "2dc15780", rows: [("Test Profile", "Profiles/yIFHcY8b.Profile 1")])
        let database = root.appendingPathComponent("Profile Groups/2dc15780.sqlite").path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: database)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: database) }
        XCTAssertEqual(FirefoxProfiles.listing(root: root), .refused)
    }

    // MARK: - Which profile a process runs

    /// Firefox holds `$TMPDIR/firefox/.parentlock` while it starts, before
    /// its profile's; only a listed profile's folder counts.
    func testOnlyAListedProfilesLockCounts() {
        let known: Set = ["/Users/a/Library/Application Support/Firefox/Profiles/x.Work"]
        XCTAssertNil(FirefoxProfiles.profileDirectory(
            lockPaths: ["/private/var/folders/1b/T/firefox/.parentlock"], known: known))
        XCTAssertEqual(FirefoxProfiles.profileDirectory(
            lockPaths: ["/private/var/folders/1b/T/firefox/.parentlock",
                        "/Users/a/Library/Application Support/Firefox/Profiles/x.Work/.parentlock"], known: known),
            "/Users/a/Library/Application Support/Firefox/Profiles/x.Work")
    }

    /// libproc, for real: a lock this process holds open is one it reports.
    func testLockPathsReadsThisProcess() throws {
        let profile = try scratch().appendingPathComponent("Profiles/x.Work", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let lock = profile.appendingPathComponent(".parentlock").path
        let descriptor = open(lock, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        let held = FirefoxProfiles.lockPaths(pid: getpid())
        let directory = FirefoxProfiles.profileDirectory(lockPaths: held, known: [profile.standardizedFileURL.path])
        XCTAssertNotNil(directory, "held: \(held)")
    }
}
