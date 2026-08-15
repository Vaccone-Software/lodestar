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
        try? FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: data, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var directory = data
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
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
            try? fm.moveItem(at: old, to: new)
        }
    }
}
