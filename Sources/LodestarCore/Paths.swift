import Foundation

/// Where Lodestar keeps things, in one place so it never scatters again.
///
/// The split is not tidiness. **`~/.config` is what people commit to
/// dotfiles repositories**, tracked wholesale, and Lodestar's audience is
/// exactly the crowd that does it. So the config directory holds only what
/// a human writes, and everything Lodestar accumulates about you — saved
/// layouts, a log carrying window titles, and clipboard history most of all
/// — lives somewhere a `git add .` will never reach.
public enum Paths {
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    /// What you write: the config file and the schema it points at.
    public static let config = home.appendingPathComponent(".config/lodestar", isDirectory: true)

    /// What Lodestar accumulates: state, log, clipboard.
    public static let data = home.appendingPathComponent(".local/share/lodestar", isDirectory: true)

    public static let clipboard = data.appendingPathComponent("clipboard", isDirectory: true)

    /// The pid file and update staging deliberately stay in `config`.
    ///
    /// They hold no content worth protecting — an integer and a transient
    /// download — and moving them would break the handover they exist to
    /// coordinate: an update watchdog spawned by the *previous* release
    /// polls the path that release knew, so a successor writing its pid
    /// somewhere new looks dead and gets rolled back. Not worth it for a
    /// file containing one number.
    public static let pidFile = config.appendingPathComponent("lodestar.pid")
    public static let update = config.appendingPathComponent("update", isDirectory: true)

    /// Create both roots, and keep the data directory out of backups and
    /// off other users' reach — clipboard history has no business in a
    /// Time Machine snapshot.
    public static func prepare() {
        let fm = FileManager.default
        try? fm.createDirectory(at: config, withIntermediateDirectories: true)
        try? fm.createDirectory(
            at: data, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // `createDirectory` leaves an existing directory's mode alone, so
        // a data directory made before the mode was asked for stayed
        // world-readable for months. Set it every launch, and sweep the
        // files inside: the behavioral record — app switches, hosts, the
        // hands' pulse — is browser-history-grade, and nothing on this
        // machine but you has business reading it.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: data.path)
        if let names = try? fm.contentsOfDirectory(atPath: data.path) {
            for name in names {
                let item = data.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: item.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else { continue }
                restrict(item)
            }
        }
        var directory = data
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
    }

    /// Owner-only. Atomic writes replace the inode, and the fresh file
    /// takes the process umask — 0644 — so every writer of the record
    /// calls this after the write, and `prepare` sweeps at boot.
    public static func restrict(_ file: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: file.path)
    }

    /// One-way move of the files that predate the split. Runs at boot,
    /// before anything opens them; a file already at its new home is left
    /// alone, so this is safe to run every launch.
    public static func migrateIfNeeded() {
        prepare()
        let fm = FileManager.default
        for name in ["state.json", "state.json.bak", "lodestar.log",
                     "lodestar.log.1", "lodestar.log.2"] {
            let old = config.appendingPathComponent(name)
            let new = data.appendingPathComponent(name)
            guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { continue }
            do {
                try fm.moveItem(at: old, to: new)
            } catch {
                // A move that fails silently would strand the file at a path
                // nothing reads any more — breaths would simply appear gone.
                // Copy instead, so the data exists at the new home even if
                // the old one lingers, and say so.
                try? fm.copyItem(at: old, to: new)
                Log.error("paths: could not move \(name) (\(error)) — copied instead, old file left in place")
            }
        }
    }
}
