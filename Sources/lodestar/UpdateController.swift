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

    private static let directory = Paths.update
    /// Survives the rolled-back announcement: the tag we refuse to re-apply.
    private static let refusedFile = directory.appendingPathComponent("refused")
    private static let feedURL = URL(string: Lodestar.repository
        .replacingOccurrences(of: "https://github.com/", with: "https://api.github.com/repos/")
        + "/releases?per_page=1")!
    private static let requirement = """
        anchor apple generic and identifier "com.vaccone.lodestar" \
        and certificate leaf[subject.OU] = "\(Lodestar.teamID)"
        """

    /// Turning updates off mid-run also drops anything already staged: a
    /// bundle parked here for weeks would otherwise be installed, stale, by
    /// the next forced check.
    var enabled = true {
        didSet {
            guard !enabled, oldValue else { return }
            if case .ready = phase { standDown() }
        }
    }
    var engineQuiet: () -> Bool = { false }
    var lastActivity: () -> Date = { .distantPast }
    var flash: (String, TimeInterval) -> Void = { _, _ in }
    /// Whether a successor has to prove it can route clicked links before the
    /// watchdog blesses it. True exactly while Lodestar holds the http role.
    var requiresRouting: () -> Bool = { false }

    /// The successor's own voice, at boot: the router answered. Written with
    /// this process's pid so no earlier build's marker can stand in for it.
    func confirmRoutingHealthy() {
        let marker = Self.directory.appendingPathComponent("routes-ok")
        try? FileManager.default.createDirectory(at: Self.directory,
                                                withIntermediateDirectories: true)
        try? "\(ProcessInfo.processInfo.processIdentifier)"
            .write(to: marker, atomically: true, encoding: .utf8)
    }

    /// The single-flight rule, main-thread only: one run at a time, and
    /// `applying` is terminal — after a successful swap this process only
    /// waits to be taken over. Two racing pipelines destroyed an install
    /// once; the phase machine is why there can never be two. The version
    /// rides on the phase, so there is no second field to keep in step.
    private var phase: Updater.Phase = .idle
    /// The verified bundle waiting to be swapped in; set only while `.ready`.
    private var stagedBundle: URL?
    private var firstCheck: Timer?
    private var dailyCheck: Timer?
    private var applyPoll: Timer?
    /// A bounded session: URLSession.shared would let a trickling download
    /// hold the run in `.checking` for days, refusing every later check.
    private let network: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        return URLSession(configuration: configuration)
    }()
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
            // Only reap the leftover while nothing is in flight: a forced
            // check early in this session could still be mid-swap, and its
            // watchdog needs that bundle to roll back to.
            if case .idle = self.phase, let install = self.installURL {
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
            // The tombstone outlives the announcement: a release that could
            // not take the pid file must not be offered again, or every
            // check re-applies it and the watchdog rolls it back forever.
            try? version.write(to: Self.refusedFile, atomically: true, encoding: .utf8)
            Log.error("update rolled back: \(version) never took the pid file — refusing it until a newer release ships")
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [flash] in
                flash("⚠ update to \(version) failed — rolled back, still on \(Lodestar.version)", 8)
            }
        }
    }

    /// The tag of a release that already failed its handover, if any.
    private var refusedTag: String? {
        try? String(contentsOf: Self.refusedFile, encoding: .utf8)
    }

    // MARK: - Check, download, verify

    /// force: the menu item — check now, tell the user either way, and
    /// apply immediately instead of waiting for quiet. A repeated press
    /// joins the run in flight; it never starts a second one.
    func check(force: Bool) {
        guard let installURL else {
            if force { flash("updates manage the installed app only", 3) }
            return
        }
        guard enabled || force else { return }
        switch Updater.checkDecision(in: phase) {
        case .refuse(let note):
            if force { flash(note, 3) }
            return
        case .applyStaged:
            tryApply(force: force)
            return
        case .startCheck:
            break
        }
        // The swap's cheap preconditions, judged before the expensive part:
        // a read-only install directory would otherwise cost a download,
        // an unpack, and two signature passes on every daily check, every
        // day, only to be discarded. They are re-checked at swap time,
        // because a quiet-moment apply can run hours after this.
        guard canSwap(installURL: installURL, force: force) else { return }

        phase = .checking
        Log.info("update", ["phase": "checking", "force": "\(force)"])
        var request = URLRequest(url: Self.feedURL, timeoutInterval: 30)
        request.setValue("lodestar/\(Lodestar.version)", forHTTPHeaderField: "User-Agent")
        network.dataTask(with: request) { [weak self] data, _, error in
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
            guard Updater.shouldOffer(release, refusedTag: self.refusedTag) else {
                self.finishCheck(force: force,
                                 note: "⌖ \(release.tag) already failed to start — waiting for a newer release",
                                 log: "refusing \(release.tag): it was rolled back once")
                return
            }
            self.worker.async { self.download(release, force: force) }
        }.resume()
    }

    /// Can this process move bundles at all? Cheap stats only.
    private func canSwap(installURL: URL, force: Bool) -> Bool {
        let parent = installURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            Log.error("update: \(parent.path) is not writable — leaving the manual lanes to it")
            if force { flash("✕ update: install location not writable — see log", 4) }
            return false
        }
        guard FileManager.default.fileExists(atPath: installURL.path) else {
            Log.error("update: nothing at \(installURL.path) — standing down")
            if force { flash("✕ update: the install is missing — see log", 4) }
            return false
        }
        return true
    }

    private func finishCheck(force: Bool, note: String, log message: String?) {
        if let message { Log.error("update check: \(message)") }
        DispatchQueue.main.async {
            self.phase = .idle
            if force { self.flash(note, 3) }
        }
    }

    private func download(_ release: Updater.Release, force: Bool) {
        guard let url = URL(string: release.zipURL) else {
            finishCheck(force: force, note: "✕ update check failed — see log", log: "bad asset url")
            return
        }
        Log.info("update", ["phase": "downloading", "asset": release.zipName])
        if force {
            DispatchQueue.main.async { self.flash("⌖ \(release.tag) found — downloading…", 3) }
        }
        let semaphore = DispatchSemaphore(value: 0)
        var fetched: URL?
        network.downloadTask(with: url) { location, _, _ in
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
            self.stagedBundle = bundle
            self.phase = .ready(version: stagedVersion)
            self.tryApply(force: force)
        }
    }

    private func failStage(force: Bool, log message: String) {
        Log.error("update staging: \(message)")
        clearStaging()
        DispatchQueue.main.async {
            self.phase = .idle
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
        guard case .ready(let version) = phase, let bundle = stagedBundle, let installURL else { return }
        if !force {
            guard enabled, Updater.mayApply(
                engineQuiet: engineQuiet(),
                secondsSinceActivity: Date().timeIntervalSince(lastActivity())
            ) else { return }
        }
        guard canSwap(installURL: installURL, force: force) else {
            standDown()
            return
        }
        let parent = installURL.deletingLastPathComponent()

        // Preflight: the swap moves exactly two things, and both slots must
        // look untouched. A lingering .previous means some other actor — a
        // watchdog mid-verdict, a manual reinstall — is still mid-story;
        // deleting it from here is how an install died once. This one is
        // usually transient (a watchdog reaps it within ~45s), so the
        // verified bundle is kept and the 60s poll retries rather than
        // paying for the whole download again.
        let previous = parent.appendingPathComponent("lodestar.app.previous")
        guard !FileManager.default.fileExists(atPath: previous.path) else {
            Log.info("update", ["phase": "deferred", "reason": "an earlier swap is still unresolved"])
            if force { flash("⌖ an earlier update is still settling — retrying shortly", 4) }
            return
        }

        phase = .applying(version: version)
        if force { flash("⌖ updating to \(version) — the new build takes over shortly", 4) }
        Log.info("update", ["phase": "applying", "to": version])

        do {
            try FileManager.default.moveItem(at: installURL, to: previous)
            try FileManager.default.moveItem(at: bundle, to: installURL)
        } catch {
            // Put the world back exactly as it was and stand down.
            if !FileManager.default.fileExists(atPath: installURL.path),
               FileManager.default.fileExists(atPath: previous.path) {
                try? FileManager.default.moveItem(at: previous, to: installURL)
            }
            Log.error("update swap failed: \(error)")
            standDown(force: force, note: "✕ update failed — see log")
            return
        }

        let marker = Self.directory.appendingPathComponent("updated-to")
        try? version.write(to: marker, atomically: true, encoding: .utf8)
        spawnWatchdog(app: installURL, previous: previous, version: version)
        stagedBundle = nil
        // The successor's boot takes over the pid file and SIGTERMs this
        // process — the same handoff every manual reinstall already uses.
        // phase stays .applying: this process is done deciding things.
        //
        // createsNewApplicationInstance is the launch: by default
        // LaunchServices "opens" a running app by activating the running
        // process, so the swapped-in build would never start — the old
        // instance would just come forward, the pid file would never
        // change hands, and the watchdog would roll the swap back.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: installURL, configuration: configuration) { _, _ in }
    }

    /// Abandon the staged build and return to idle — a fresh check can
    /// start over from a clean slate. The manual check narrates every
    /// outcome, so a forced run that stands down says why.
    private func standDown(force: Bool = false, note: String? = nil) {
        stagedBundle = nil
        phase = .idle
        if force, let note { flash(note, 4) }
        worker.async { self.clearStaging() }
    }

    // MARK: - The watchdog (bless or roll back)

    /// A detached observer, in its own session so neither our exit nor
    /// launchd's process-group cleanup takes it down. It never decides health
    /// itself: the pid file changing hands is the verdict, plus the
    /// successor's word that its router answered when links depend on it.
    private func spawnWatchdog(app: URL, previous: URL, version: String) {
        let script = """
        #!/bin/bash
        # lodestar update watchdog: bless the new build or put the old one back.
        APP="$1"; PREVIOUS="$2"; OLDPID="$3"; VERSION="$4"; MARKERS="$5"; PIDFILE="$6"
        ROUTING="$7"
        for _ in 1 2 3 4 5 6 7 8 9; do
            sleep 5
            PID=$(cat "$PIDFILE" 2>/dev/null)
            if [ -n "$PID" ] && [ "$PID" != "$OLDPID" ] && kill -0 "$PID" 2>/dev/null; then
                # While Lodestar holds the browser role, booting is not proof.
                # The successor has to say its router answered, in its own
                # voice: the marker carries the new pid, so a stale one from
                # the build being replaced cannot bless anything.
                if [ "$ROUTING" = "1" ] && [ "$(cat "$MARKERS/routes-ok" 2>/dev/null)" != "$PID" ]; then
                    continue
                fi
                rm -rf "$PREVIOUS"
                exit 0
            fi
        done
        rm -f "$MARKERS/routes-ok"
        # The handover failed, whatever happens next: drop the success
        # marker first, above the rollback gate. Left behind, it would fire
        # a false "updated" flash whenever that version finally does boot.
        rm -f "$MARKERS/updated-to"
        # Roll back only while the old bundle is still there to restore.
        # If .previous is gone, another actor already resolved this swap —
        # deleting the app with nothing to put back is never the answer.
        [ -d "$PREVIOUS" ] || exit 0
        rm -rf "$APP"
        mv "$PREVIOUS" "$APP"
        printf '%s' "$VERSION" > "$MARKERS/rolled-back"
        # -n: launch a fresh instance even though the old process may still
        # be running — its boot takes the pid file and announces the marker.
        open -n "$APP"
        """
        let path = Self.directory.appendingPathComponent("watchdog.sh")
        try? script.write(to: path, atomically: true, encoding: .utf8)
        let pidFile = Paths.pidFile
        spawnDetached(["/bin/bash", path.path, app.path, previous.path,
                       "\(ProcessInfo.processInfo.processIdentifier)", version,
                       Self.directory.path, pidFile.path,
                       requiresRouting() ? "1" : "0"])
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
