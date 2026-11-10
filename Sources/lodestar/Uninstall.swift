import AppKit
import Foundation
import LodestarCore

/// Removing Lodestar from the machine: one plan of named steps, run by
/// the CLI verb, by the menu item under Quit, and shown before either
/// touches anything. A clean exit is part of professionalism: the
/// browser role goes back, the alert sound goes with the app and the
/// alert returns to the Mac's default when it named ours, the links and
/// the agent go, and the running instance is the last thing to stop, so
/// every step before it runs to the end. Config, breaths and the
/// clipboard stay unless asked, because they survive a reinstall, and so
/// do the keys in the login keychain that open the sealed ones: a plain
/// uninstall keeps data nothing could read without them. `--purge` removes
/// both, the data first and then the keys, and a key the keychain would
/// not give up is reported rather than passed over.
///
/// The Trash is the other door. Finder refuses to trash a running app, so
/// the app cannot watch itself go; instead the login agent runs through
/// a stub that, finding the app gone at the next login, removes the
/// agent and the alert sound and stops. See `LoginAgent`.
struct UninstallPlan {
    struct Step {
        let name: String
        /// Does the work; answers what could not be done (nil when all of it
        /// was). A step that fails never stops the ones after it: the person
        /// is told at the end, with everything else done.
        let work: () -> [String]

        /// A step that cannot fail in a way worth telling.
        init(name: String, run: @escaping () -> Void) {
            self.name = name
            work = { run(); return [] }
        }

        /// A step that answers what it could not do.
        static func reporting(_ name: String, work: @escaping () -> [String]) -> Step {
            Step(name: name, work: work)
        }

        private init(name: String, work: @escaping () -> [String]) {
            self.name = name
            self.work = work
        }

        @discardableResult
        func run() -> [String] { work() }
    }

    let steps: [Step]
    /// What stays when not purging, for the message.
    let kept: [URL]

    /// What the plan reads and touches, so a test can point it at a
    /// scratch home and a dry run can describe the real one.
    struct World {
        var agentPlist: URL
        /// App bundles to remove, the running one first.
        var bundles: [URL]
        var links: [URL]
        var alertSound: URL
        var alertSelected: Bool
        var dataRoots: [URL]
        /// The keychain items Lodestar's sealed records are keyed by, named
        /// for the plan ("com.vaccone.lodestar: health, logbook, …"). Empty
        /// when there is nothing to name, and then no step is made.
        var keychainItems: String
        var pidFile: URL
        /// The lock a running copy holds, by which it is found (`SingleInstance`).
        var lockFile: URL
        var bundleID: String
        var browserToRestore: String?
        var exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }

        /// Where the running copy is found.
        var instance: SingleInstance.Files { .init(lock: lockFile, pid: pidFile) }
    }

    /// Side effects the steps perform, replaceable by tests.
    struct Actions {
        var remove: (URL) -> Void = { try? FileManager.default.removeItem(at: $0) }
        var restoreBrowser: () -> Void = {}
        var forgetPermissions: (String) -> Void = UninstallPlan.forgetPermissions
        var resetAlertSelection: () -> Void = AlertSound.resetSelection
        var stopAgent: () -> Void = UninstallPlan.stopAgent
        var stopInstance: (SingleInstance.Files) -> Void = { UninstallPlan.stopInstance($0) }
        /// Wait for the running instance to be gone; false if it is still
        /// there after a while.
        var awaitInstanceExit: (SingleInstance.Files) -> Bool = { UninstallPlan.awaitInstanceExit($0) }
        /// Delete every key Lodestar keeps in the login keychain; answers one
        /// line for each it could not delete.
        var deleteKeys: () -> [String] = UninstallPlan.deleteKeys
    }

    static func make(world: World, purge: Bool, actions: Actions = Actions()) -> UninstallPlan {
        var steps: [Step] = []
        if let browser = world.browserToRestore {
            steps.append(Step(name: "restore \(browser) as your default browser", run: actions.restoreBrowser))
        }
        // While the bundle still exists: macOS looks the identifier up.
        steps.append(Step(name: "ask macOS to forget Lodestar's permissions") {
            actions.forgetPermissions(world.bundleID)
        })
        if world.exists(world.alertSound) {
            let name = world.alertSelected
                ? "remove the Lodestar alert sound and return the alert to the Mac's default"
                : "remove the Lodestar alert sound"
            steps.append(Step(name: name) {
                if world.alertSelected { actions.resetAlertSelection() }
                actions.remove(world.alertSound)
            })
        }
        for link in world.links where world.exists(link) {
            steps.append(Step(name: "remove \(link.path)") { actions.remove(link) })
        }
        for bundle in world.bundles where world.exists(bundle) {
            steps.append(Step(name: "remove \(bundle.path)") { actions.remove(bundle) })
        }
        if purge {
            // Before the data goes, not after: an instance that is still running
            // saves on its way out, and would put the state and its sealed files
            // back, under keys that are gone a moment later. (The plan run by the
            // app itself skips its own pid and relies on `AppDelegate.purged`.)
            if world.exists(world.pidFile) {
                steps.append(.reporting("stop the running Lodestar, so it cannot save over what is removed") {
                    actions.stopInstance(world.instance)
                    return actions.awaitInstanceExit(world.instance)
                        ? [] : ["Lodestar is still running and may write files again when it quits; quit it, then run lodestar uninstall --purge again"]
                })
            }
            for root in world.dataRoots where world.exists(root) {
                steps.append(Step(name: "remove \(root.path)") { actions.remove(root) })
            }
            // After the data, never before: a key deleted first would leave
            // sealed files nothing can open if the next step were cut short.
            // Always a step, whatever the data directory held: the keys are
            // in the keychain, which the plan does not look into.
            if !world.keychainItems.isEmpty {
                steps.append(.reporting("remove Lodestar's keys from your login keychain (\(world.keychainItems))",
                                        work: actions.deleteKeys))
            }
        }
        if world.exists(world.agentPlist) {
            steps.append(Step(name: "remove \(world.agentPlist.path)") { actions.remove(world.agentPlist) })
        }
        // Last: this may be the process running the plan.
        steps.append(Step(name: "stop Lodestar") {
            actions.stopAgent()
            actions.stopInstance(world.instance)
        })
        return UninstallPlan(steps: steps, kept: purge ? [] : world.dataRoots)
    }

    // MARK: - The real world

    static let agentLabel = "com.vaccone.lodestar"

    static func world() -> World {
        let home = Paths.userHome
        var bundles: [URL] = []
        let running = Bundle.main.bundleURL
        if running.path.hasSuffix("lodestar.app"), !running.path.contains("/AppTranslocation/") {
            bundles.append(running.standardizedFileURL)
        }
        for known in [home.appendingPathComponent("Applications/lodestar.app"),
                      URL(fileURLWithPath: "/Applications/lodestar.app")]
        where !bundles.contains(known.standardizedFileURL) {
            bundles.append(known.standardizedFileURL)
        }
        // The recorded browser, or the system's best other answer. A
        // config that recorded *us* is dropped to empty at load, and
        // skipping the restore on empty is how somebody ends up with the
        // http handler deleted and every link opening nothing.
        let (config, _) = Config.load()
        let browser: String? = config.webHandleClicks ? restoreTarget(config)
            .map { $0.deletingPathExtension().lastPathComponent } : nil
        return World(
            agentPlist: home.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist"),
            bundles: bundles,
            // Only a link to a Lodestar app is Lodestar's to remove: another
            // tool's `lodestar` in the same folder stays.
            links: ["/opt/homebrew/bin/lodestar", "/usr/local/bin/lodestar"]
                .filter(CLILink.isLodestars).map { URL(fileURLWithPath: $0) },
            alertSound: AlertSound.installed,
            alertSelected: AlertSound.isSelected(AlertSound.installed, selection: AlertSound.currentSelection()),
            // The third root is the Core ML cache the dictation model's
            // first load compiles into: Lodestar's, so it leaves with it.
            dataRoots: [Paths.config, Paths.data]
                + (Bundle.main.bundleIdentifier.map {
                    [home.appendingPathComponent("Library/Caches/\($0)", isDirectory: true)]
                } ?? []),
            keychainItems: keychainItemsNote,
            pidFile: Paths.pidFile,
            lockFile: Paths.lockFile,
            bundleID: Bundle.main.bundleIdentifier ?? agentLabel,
            browserToRestore: browser)
    }

    static func live(purge: Bool) -> UninstallPlan {
        let (config, _) = Config.load()
        var actions = Actions()
        if let browser = restoreTarget(config) {
            actions.restoreBrowser = { handBrowserRole(to: browser) }
        }
        return make(world: world(), purge: purge, actions: actions)
    }

    private static func restoreTarget(_ config: Config) -> URL? {
        ClickRouter.handoffBrowser(config.webClickBrowser)
            .flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            ?? ClickHandler.discoverBrowser()
    }

    /// Give the browser role back first, while we are still here to do it.
    private static func handBrowserRole(to browser: URL) {
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.setDefaultApplication(at: browser, toOpenURLsWithScheme: "https") { _ in
            NSWorkspace.shared.setDefaultApplication(at: browser, toOpenURLsWithScheme: "http") { _ in
                done.signal()
            }
        }
        _ = done.wait(timeout: .now() + 5)
    }

    /// Best effort: `tccutil` resets what it may for the bundle; what it
    /// may not is left in Privacy & Security, and the closing line says so.
    private static func forgetPermissions(_ bundleID: String) {
        run("/usr/bin/tccutil", ["reset", "All", bundleID])
    }

    /// The keychain items the plan names: the service, then each ring.
    static var keychainItemsNote: String {
        "\(Vault.keychainService): " + Vault.RingName.allCases.map(\.rawValue).joined(separator: ", ")
    }

    /// Every ring's item, deleted from the login keychain through the vault
    /// the app itself keeps them with. Answers one line per ring left behind.
    static func deleteKeys() -> [String] {
        let vault: Vault
        do {
            vault = try Vault.system()
        } catch {
            return ["could not reach the login keychain (\(error)); delete the \(Vault.keychainService) items in Keychain Access"]
        }
        return vault.eraseAllKeys().compactMap { erasure in
            erasure.failure.map { "the \(erasure.ring.rawValue) key is still in your login keychain (\($0)); delete "
                + "\(erasure.ring.custodyName) under \(Vault.keychainService) in Keychain Access" }
        }
    }

    private static func stopAgent() {
        run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(agentLabel)"])
    }

    /// An instance launchd does not supervise, found by the lock it holds (or,
    /// for an older build that holds none, by the pid file it wrote). Never a
    /// process that only has the number a stale pid file names.
    static func stopInstance(_ files: SingleInstance.Files, processes: any InstanceProcesses = SystemProcesses()) {
        SingleInstance.stopRunningCopy(files: files, processes: processes)
    }

    /// Whether the running instance is gone (or is this process), waiting up
    /// to ten seconds: a quitting instance restores parked windows, which is
    /// unbounded work in other apps.
    static func awaitInstanceExit(_ files: SingleInstance.Files, processes: any InstanceProcesses = SystemProcesses()) -> Bool {
        SingleInstance.awaitNoRunningCopy(files: files, processes: processes)
    }

    private static func run(_ executable: String, _ arguments: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        guard (try? SystemEvents.run(task)) != nil else { return }
        task.waitUntilExit()
    }

    /// The sentence after the steps, for the terminal and the sheet.
    static let closing = "If Lodestar still appears in Privacy & Security, remove it there."
}

/// The login agent's job description. The program is a stub: with the
/// app in place it becomes the app (`exec`, so launchd's pid is the
/// app's); with the app gone for longer than any install takes, the Trash
/// was the uninstall, and the stub takes the agent and the alert sound
/// with it and stops, instead of asking launchd for a missing binary
/// every ten seconds until the end of time. The app puts both back the
/// next time it boots from anywhere, so a moved app heals itself.
///
/// `Interactive`, because the hand is waiting on this process. With no
/// ProcessType launchd runs a job as a throttled daemon: every thread at
/// priority 20, under the 31 of any ordinary process, and QoS asked from
/// inside clamped to it. On a Mac at load 170 the same main-thread work
/// took 6.1 s that way and 0.92 s as Interactive with a user-interactive
/// main thread (2026-11-03), and at load 450 a launch starved past the
/// watchdog's ceiling and the keys were gone for 87 s.
enum LoginAgent {
    /// How long a missing app is waited for, in seconds. A package manager
    /// replaces the app by removing it first, and a crash during that
    /// removal brought the stub here with the install still under way: it
    /// took the agent with it, and nothing brought Lodestar back. A real
    /// uninstall loses nothing by waiting.
    static let patience = 120

    static func stub(patience: Int = patience) -> String {
        """
        if [ -x "$1" ]; then exec "$1"; fi
        waited=0
        while [ "$waited" -lt \(patience) ]; do
            /bin/sleep 1
            waited=$((waited + 1))
            if [ -x "$1" ]; then exec "$1"; fi
        done
        plist="$HOME/Library/LaunchAgents/\(UninstallPlan.agentLabel).plist"
        sound="$HOME/Library/Sounds/\(AlertSound.name).aiff"
        if [ "$(defaults read -g \(AlertSound.selectionKey) 2>/dev/null)" = "$sound" ]; then
            defaults delete -g \(AlertSound.selectionKey)
        fi
        rm -f "$plist" "$sound"
        launchctl bootout "gui/$(id -u)/\(UninstallPlan.agentLabel)"
        exit 0
        """
    }

    static func job(binary: String, patience: Int = patience) -> [String: Any] {
        [
            "Label": UninstallPlan.agentLabel,
            "ProgramArguments": ["/bin/sh", "-c", stub(patience: patience), "lodestar", binary],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 10,
            "ProcessType": "Interactive",
        ]
    }

    /// launchd keeps the definition a job was loaded with, whatever the
    /// file says now, and `kickstart` starts that one: a rewritten job
    /// reaches launchd only by being unloaded and loaded again. Unloading
    /// stops the job's process, which may be the one asking, so this runs
    /// in a session of its own (see `DetachedProcess`). A process being
    /// shut down holds the label until it is gone, which launchd allows
    /// twenty seconds for, and a load before then is refused, so the load
    /// is asked again until a minute has passed.
    static let reload = """
    launchctl bootout "gui/$(id -u)/\(UninstallPlan.agentLabel)" 2>/dev/null
    tries=0
    until launchctl bootstrap "gui/$(id -u)" "$1" 2>/dev/null; do
        tries=$((tries + 1))
        if [ "$tries" -ge 60 ]; then exit 1; fi
        /bin/sleep 1
    done
    """
}

extension LoginAgent {
    /// What launchd says about the agent job. Three answers, because a read
    /// that failed is not the answer "not loaded": acting on it as if it
    /// were bootstraps a job that may be running.
    enum State: Equatable {
        /// Loaded in this session: the pid it runs, 0 when it is loaded and idle.
        case loaded(pid: pid_t)
        /// launchd says there is no such job.
        case notLoaded
        /// launchctl could not be run, or what it answered could not be read.
        case unknown(String)
    }

    /// `launchctl list <label>`'s exit status is 113 for a label that is not
    /// loaded ("Could not find service"), 0 with the job's description when
    /// it is, and anything else is a failure to ask.
    static let notLoadedStatus: Int32 = 113

    /// The state from what `launchctl list <label>` did. `output` is nil when
    /// it printed bytes that are not text.
    static func state(exitStatus: Int32, output: String?) -> State {
        if exitStatus == notLoadedStatus { return .notLoaded }
        guard exitStatus == 0 else { return .unknown("launchctl list exited \(exitStatus)") }
        guard let output else { return .unknown("launchctl list printed what could not be read") }
        for line in output.split(separator: "\n") where line.contains("\"PID\"") {
            if let pid = Int32(line.filter(\.isNumber)) { return .loaded(pid: pid) }
        }
        return .loaded(pid: 0)
    }

    /// What the instance that finds the agent file in place does about
    /// launchd's side of it.
    enum Readoption: Equatable {
        /// The agent is the one running this instance, or launchd cannot be read.
        case nothing
        /// The definition was rewritten and the job is loaded: load it again.
        case reload(agentPid: pid_t)
        /// The job is loaded and is not this instance: launchd starts its own.
        case kickstart(agentPid: pid_t)
        /// The job is not loaded: load it, which starts it.
        case bootstrap
        /// launchd could not be read: change nothing and say so.
        case unreadable(String)
    }

    static func readoption(state: State, definitionChanged: Bool, me: pid_t) -> Readoption {
        switch state {
        case .unknown(let why): return .unreadable(why)
        case .notLoaded: return .bootstrap
        case .loaded(let pid):
            if definitionChanged { return .reload(agentPid: pid) }
            return pid == me ? .nothing : .kickstart(agentPid: pid)
        }
    }
}

/// The `lodestar` command on the PATH, which the zip install has no
/// installer to make: the app keeps a link to itself in a writable bin.
enum CLILink {
    enum Outcome: Equatable {
        case current
        case created
        /// Was a link to another Lodestar app (or to nothing), now this one.
        case replaced(was: String)
        /// Something that is not a link to a Lodestar app is there, and stays.
        case leftAlone(String)
        case failed(String)
    }

    /// What a link of ours points at: the binary of an app bundle named lodestar.app.
    private static let bundleBinarySuffix = "/lodestar.app/contents/macos/lodestar"

    /// Whether `destination` is the binary of a lodestar.app, in any case:
    /// the volume a Mac starts from ignores case, so `Lodestar.app` is the
    /// same app.
    private static func isBundleBinary(_ destination: String) -> Bool {
        destination.lowercased().hasSuffix(bundleBinarySuffix)
    }

    /// Whether `path` is a symbolic link to a Lodestar app's binary.
    static func isLodestars(_ path: String) -> Bool {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return false }
        return isBundleBinary(destination)
    }

    /// Makes `link` point at `target`, replacing only what is Lodestar's to
    /// replace: nothing at all, a link to a Lodestar app, or a link whose
    /// destination is gone. A file, a folder or a link to anything else is
    /// another tool's and is left alone. The replacement is a link made beside
    /// and renamed over, so there is never a moment with no link.
    static func maintain(link: String, target: String, fileManager: FileManager = .default) -> Outcome {
        var info = stat()
        guard lstat(link, &info) == 0 else {
            if errno == ENOENT { return place(target, at: link, replacing: nil) }
            return .failed("could not look at \(link): \(String(cString: strerror(errno)))")
        }
        guard (info.st_mode & S_IFMT) == S_IFLNK else { return .leftAlone("it is not a link") }
        let destination: String
        do {
            destination = try fileManager.destinationOfSymbolicLink(atPath: link)
        } catch {
            return .failed("could not read the link: \(error)")
        }
        if destination == target { return .current }
        let resolved = URL(fileURLWithPath: destination, relativeTo: URL(fileURLWithPath: link).deletingLastPathComponent()).path
        if isBundleBinary(destination) || !fileManager.fileExists(atPath: resolved) {
            return place(target, at: link, replacing: destination)
        }
        return .leftAlone("it links to \(destination)")
    }

    private static func place(_ target: String, at link: String, replacing was: String?) -> Outcome {
        let beside = link + ".lodestar-new"
        unlink(beside)
        guard symlink(target, beside) == 0 else {
            return .failed("could not make the link: \(String(cString: strerror(errno)))")
        }
        guard rename(beside, link) == 0 else {
            let why = String(cString: strerror(errno))
            unlink(beside)
            return .failed("could not put the link in place: \(why)")
        }
        return was.map { .replaced(was: $0) } ?? .created
    }
}

/// A process that outlives this one: `posix_spawn` with SETSID, so it
/// leads its own session, immune to the process-group teardown launchd
/// performs when this job exits.
enum DetachedProcess {
    /// The child's pid, or nil when it could not be started.
    @discardableResult
    static func spawn(_ arguments: [String]) -> pid_t? {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        let result = posix_spawn(&pid, arguments[0], nil, &attributes, &argv, environ)
        argv.forEach { free($0) }
        posix_spawnattr_destroy(&attributes)
        guard result == 0 else {
            Log.error("detached spawn failed", ["program": arguments[0], "errno": result])
            return nil
        }
        return pid
    }
}
