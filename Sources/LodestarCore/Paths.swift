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

    /// Create both roots, and keep the data directory off other users'
    /// reach. Backups are decided file by file, not for the directory:
    /// the *behavioral* record — the event ring, the observations, the
    /// clipboard, the log, the state — is browser-history-grade and
    /// stays out of Time Machine; the *health* record — the raw presses
    /// and reaches, the archived pulses and windows, the monthly rollup
    /// — is a baseline nothing can recompute, and one disk must not be
    /// the only copy of it.
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
        // The directory itself used to carry the backup exclusion, which
        // kept the health record out with everything else. Cleared here
        // and re-applied to the behavioral files one by one, every
        // launch, so a data directory made under the old rule comes
        // right on its own.
        var directory = data
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try? directory.setResourceValues(values)
        if let names = try? fm.contentsOfDirectory(atPath: data.path) {
            for name in names {
                let item = data.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: item.path, isDirectory: &isDirectory) else { continue }
                if isBehavioral(name) { excludeFromBackup(item) }
                guard !isDirectory.boolValue else { continue }
                restrict(item)
            }
        }
        excludeFromBackup(clipboard)
    }

    /// The files of the behavioral record, by name: what a backup must
    /// not carry. Everything else in the data directory is the health
    /// record or harmless, and is backed up.
    public static func isBehavioral(_ name: String) -> Bool {
        if name == "clipboard" { return true }
        for prefix in ["events", "observations", "lodestar.log", "state.json"]
        where name == prefix || name.hasPrefix(prefix + ".") || name.hasPrefix(prefix + "-") {
            return true
        }
        return false
    }

    /// Keep one file out of Time Machine. Called by every writer of a
    /// behavioral file after it creates one, because a fresh inode does
    /// not inherit the flag.
    public static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
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
