import AppKit
import LodestarCore

/// Silent self-update for the installed app. The cycle: check the releases
/// feed daily, download and unpack the zip in the background, verify it,
/// then swap bundles only in a quiet moment — the engine idle, no panel
/// up, ten minutes since the last gesture — and let the ordinary pid-file
/// takeover hand the session to the new build. A detached watchdog blesses
/// the successor or puts the old bundle back; the successor flashes once,
/// so the change is quiet but never hidden.
///
/// The verification bar: a zip this process downloads carries no
/// quarantine, so Gatekeeper never assesses it — we are the gate. Nothing
/// touches the install path unless codesign verifies the staged bundle
/// strictly AND its signature chains to Apple with this bundle id and
/// this team, AND its Info.plist version matches the release tag.
final class UpdateController {
    /// The install this instance runs from; nil for dev builds and
    /// translocated copies — the updater stands down entirely.
    private let installURL: URL?

    private static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/lodestar/update", isDirectory: true)
    private static let feedURL = URL(string: Lodestar.repository
        .replacingOccurrences(of: "https://github.com/", with: "https://api.github.com/repos/")
        + "/releases?per_page=1")!
    private static let requirement = """
        anchor apple generic and identifier "com.vaccone.lodestar" \
        and certificate leaf[subject.OU] = "\(Lodestar.teamID)"
        """

    var enabled = true
    var engineQuiet: () -> Bool = { false }
    var lastActivity: () -> Date = { .distantPast }
    var flash: (String, TimeInterval) -> Void = { _, _ in }

    private var staged: (bundle: URL, version: String)?
    private var checking = false
    private var firstCheck: Timer?
    private var dailyCheck: Timer?
    private var applyPoll: Timer?
    private let worker = DispatchQueue(label: "lodestar.update", qos: .utility)

    init() {
        let path = Bundle.main.bundlePath
        installURL = path.hasSuffix("lodestar.app") && !path.contains("/AppTranslocation/")
            ? Bundle.main.bundleURL : nil
    }

    func start() {
        announceMarkers()
        guard installURL != nil else { return }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        worker.async { self.clearStaging() }
        // First check well clear of the login rush; the leftover .previous
        // bundle from the last swap is long past its watchdog by then.
        firstCheck = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { [weak self] _ in
            guard let self else { return }
            if let install = self.installURL {
                let previous = install.deletingLastPathComponent()
                    .appendingPathComponent("lodestar.app.previous")
                try? FileManager.default.removeItem(at: previous)
            }
            self.check(force: false)
        }
        dailyCheck = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            self?.check(force: false)
        }
        applyPoll = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.tryApply(force: false)
        }
    }

    // MARK: - Boot markers (the successor speaks; the watchdog wrote)

    private func announceMarkers() {
        let updated = Self.directory.appendingPathComponent("updated-to")
        let rolledBack = Self.directory.appendingPathComponent("rolled-back")
        if let version = try? String(contentsOf: updated, encoding: .utf8),
           version == Lodestar.version {
            try? FileManager.default.removeItem(at: updated)
            Log.info("update", ["phase": "completed", "version": version])
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [flash] in
                flash("⌖ Lodestar \(version) · updated", 3)
            }
        }
        if let version = try? String(contentsOf: rolledBack, encoding: .utf8) {
            try? FileManager.default.removeItem(at: rolledBack)
            Log.error("update rolled back: \(version) never took the pid file")
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [flash] in
                flash("⚠ update to \(version) failed — rolled back, still on \(Lodestar.version)", 8)
            }
        }
    }

    // MARK: - Check, download, verify

    /// force: the menu item — check now, tell the user either way, and
    /// apply immediately instead of waiting for quiet.
    func check(force: Bool) {
        guard installURL != nil else {
            if force { flash("updates manage the installed app only", 3) }
            return
        }
        guard enabled || force else { return }
        if staged != nil {
            tryApply(force: force)
            return
        }
        guard !checking else { return }
        checking = true
        Log.info("update", ["phase": "checking", "force": "\(force)"])
        var request = URLRequest(url: Self.feedURL, timeoutInterval: 30)
        request.setValue("lodestar/\(Lodestar.version)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }
            guard let data, error == nil, let release = Updater.parseFeed(data) else {
                self.finishCheck(force: force, note: "✕ update check failed — see log",
                                 log: "feed unreadable (\(error.map(String.init(describing:)) ?? "no release with a zip"))")
                return
            }
            let local = Updater.parseVersion(Lodestar.version) ?? []
            guard Updater.isNewer(release.version, than: local) else {
                self.finishCheck(force: force, note: "⌖ up to date · \(Lodestar.version)", log: nil)
                return
            }
            self.worker.async { self.download(release, force: force) }
        }.resume()
    }

    private func finishCheck(force: Bool, note: String, log message: String?) {
        if let message { Log.error("update check: \(message)") }
        DispatchQueue.main.async {
            self.checking = false
            if force { self.flash(note, 3) }
        }
    }

    private func download(_ release: Updater.Release, force: Bool) {
        guard let url = URL(string: release.zipURL) else {
            finishCheck(force: force, note: "✕ update check failed — see log", log: "bad asset url")
            return
        }
        Log.info("update", ["phase": "downloading", "asset": release.zipName])
        let semaphore = DispatchSemaphore(value: 0)
        var fetched: URL?
        URLSession.shared.downloadTask(with: url) { location, _, _ in
            if let location {
                let kept = Self.directory.appendingPathComponent("download.zip")
                try? FileManager.default.removeItem(at: kept)
                if (try? FileManager.default.moveItem(at: location, to: kept)) != nil {
                    fetched = kept
                }
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        guard let zip = fetched else {
            finishCheck(force: force, note: "✕ update download failed — see log", log: "download failed")
            return
        }
        stage(zip: zip, release: release, force: force)
    }

    private func stage(zip: URL, release: Updater.Release, force: Bool) {
        let staging = Self.directory.appendingPathComponent("staged", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        guard run("/usr/bin/ditto", "-x", "-k", zip.path, staging.path) else {
            failStage(force: force, log: "unpack failed")
            return
        }
        try? FileManager.default.removeItem(at: zip)
        let bundle = staging.appendingPathComponent("lodestar.app")

        // The gate, in three locks: integrity, identity, and the version
        // actually being the one the release claims.
        guard run("/usr/bin/codesign", "--verify", "--strict", "--deep", bundle.path) else {
            failStage(force: force, log: "codesign integrity check failed")
            return
        }
        guard run("/usr/bin/codesign", "--verify", "-R=\(Self.requirement)", bundle.path) else {
            failStage(force: force, log: "signature is not this team's Developer ID")
            return
        }
        let plist = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        guard let stagedVersion = plist?["CFBundleShortVersionString"] as? String,
              Updater.parseVersion(stagedVersion) == release.version else {
            failStage(force: force, log: "staged bundle version does not match the release tag")
            return
        }

        Log.info("update", ["phase": "staged", "version": stagedVersion])
        DispatchQueue.main.async {
            self.staged = (bundle, stagedVersion)
            self.checking = false
            self.tryApply(force: force)
        }
    }

    private func failStage(force: Bool, log message: String) {
        Log.error("update staging: \(message)")
        clearStaging()
        DispatchQueue.main.async {
            self.checking = false
            if force { self.flash("✕ update failed verification — see log", 4) }
        }
    }

    private func clearStaging() {
        try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent("download.zip"))
        try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent("staged"))
    }

    private func run(_ launchPath: String, _ arguments: String...) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // MARK: - The swap

    private func tryApply(force: Bool) {
        guard let staged, let installURL else { return }
        if !force {
            guard enabled, Updater.mayApply(
                engineQuiet: engineQuiet(),
                secondsSinceActivity: Date().timeIntervalSince(lastActivity())
            ) else { return }
        }
        let parent = installURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            Log.error("update: \(parent.path) is not writable — leaving the manual lanes to it")
            self.staged = nil
            worker.async { self.clearStaging() }
            return
        }
        if force { flash("⌖ updating to \(staged.version)…", 3) }
        Log.info("update", ["phase": "applying", "to": staged.version])

        let previous = parent.appendingPathComponent("lodestar.app.previous")
        let marker = Self.directory.appendingPathComponent("updated-to")
        try? FileManager.default.removeItem(at: previous)
        try? staged.version.write(to: marker, atomically: true, encoding: .utf8)
        do {
            try FileManager.default.moveItem(at: installURL, to: previous)
            try FileManager.default.moveItem(at: staged.bundle, to: installURL)
        } catch {
            // Put the world back exactly as it was and stand down.
            if !FileManager.default.fileExists(atPath: installURL.path),
               FileManager.default.fileExists(atPath: previous.path) {
                try? FileManager.default.moveItem(at: previous, to: installURL)
            }
            try? FileManager.default.removeItem(at: marker)
            Log.error("update swap failed: \(error)")
            self.staged = nil
            worker.async { self.clearStaging() }
            return
        }

        spawnWatchdog(app: installURL, previous: previous, version: staged.version)
        self.staged = nil
        // The successor's boot takes over the pid file and SIGTERMs this
        // process — the same handoff every manual reinstall already uses.
        NSWorkspace.shared.openApplication(at: installURL,
                                           configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    // MARK: - The watchdog (bless or roll back)

    /// A detached observer, in its own session so neither our exit nor
    /// launchd's process-group cleanup takes it down. It never decides
    /// health itself — the pid file changing hands is the verdict.
    private func spawnWatchdog(app: URL, previous: URL, version: String) {
        let script = """
        #!/bin/bash
        # lodestar update watchdog: bless the new build or put the old one back.
        APP="$1"; PREVIOUS="$2"; OLDPID="$3"; VERSION="$4"; MARKERS="$5"; PIDFILE="$6"
        for _ in 1 2 3 4 5 6 7 8 9; do
            sleep 5
            PID=$(cat "$PIDFILE" 2>/dev/null)
            if [ -n "$PID" ] && [ "$PID" != "$OLDPID" ] && kill -0 "$PID" 2>/dev/null; then
                rm -rf "$PREVIOUS"
                exit 0
            fi
        done
        rm -rf "$APP"
        mv "$PREVIOUS" "$APP"
        rm -f "$MARKERS/updated-to"
        printf '%s' "$VERSION" > "$MARKERS/rolled-back"
        open "$APP"
        """
        let path = Self.directory.appendingPathComponent("watchdog.sh")
        try? script.write(to: path, atomically: true, encoding: .utf8)
        let pidFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/lodestar/lodestar.pid")
        spawnDetached(["/bin/bash", path.path, app.path, previous.path,
                       "\(ProcessInfo.processInfo.processIdentifier)", version,
                       Self.directory.path, pidFile.path])
    }

    /// posix_spawn with SETSID: the child leads its own session, immune to
    /// the process-group teardown launchd performs when this job exits.
    private func spawnDetached(_ arguments: [String]) {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        let result = posix_spawn(&pid, arguments[0], nil, &attributes, &argv, environ)
        argv.forEach { free($0) }
        posix_spawnattr_destroy(&attributes)
        if result != 0 { Log.error("update watchdog spawn failed (\(result))") }
    }
}
