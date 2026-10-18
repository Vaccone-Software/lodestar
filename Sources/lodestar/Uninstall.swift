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
        var bundleID: String
        var browserToRestore: String?
        var exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Side effects the steps perform, replaceable by tests.
    struct Actions {
        var remove: (URL) -> Void = { try? FileManager.default.removeItem(at: $0) }
        var restoreBrowser: () -> Void = {}
        var forgetPermissions: (String) -> Void = UninstallPlan.forgetPermissions
        var resetAlertSelection: () -> Void = AlertSound.resetSelection
        var stopAgent: () -> Void = UninstallPlan.stopAgent
        var stopInstance: (URL) -> Void = UninstallPlan.stopInstance
        /// Wait for the instance the pid file names to be gone; false if it is
        /// still there after a while.
        var awaitInstanceExit: (URL) -> Bool = UninstallPlan.awaitInstanceExit
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
                    actions.stopInstance(world.pidFile)
                    return actions.awaitInstanceExit(world.pidFile)
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
            actions.stopInstance(world.pidFile)
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
            links: ["/opt/homebrew/bin/lodestar", "/usr/local/bin/lodestar"].map { URL(fileURLWithPath: $0) },
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

    /// An instance launchd does not supervise, found by the pid file.
    private static func stopInstance(_ pidFile: URL) {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid != ProcessInfo.processInfo.processIdentifier, kill(pid, 0) == 0
        else { return }
        kill(pid, SIGTERM)
    }

    /// Whether the instance the pid file names is gone (or is this process),
    /// waiting up to ten seconds: a quitting instance restores parked windows,
    /// which is unbounded work in other apps.
    static func awaitInstanceExit(_ pidFile: URL) -> Bool {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid != ProcessInfo.processInfo.processIdentifier
        else { return true }
        let deadline = Date().addingTimeInterval(10)
        while kill(pid, 0) == 0, Date() < deadline { usleep(50_000) }
        return kill(pid, 0) != 0
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
/// app's); with the app gone, the Trash was the uninstall, and the stub
/// takes the agent and the alert sound with it and stops, instead of
/// asking launchd for a missing binary every ten seconds until the end
/// of time. The app puts both back the next time it boots from
/// anywhere, so a moved app heals itself.
enum LoginAgent {
    static let stub = """
    if [ -x "$1" ]; then exec "$1"; fi
    plist="$HOME/Library/LaunchAgents/\(UninstallPlan.agentLabel).plist"
    sound="$HOME/Library/Sounds/\(AlertSound.name).aiff"
    if [ "$(defaults read -g \(AlertSound.selectionKey) 2>/dev/null)" = "$sound" ]; then
        defaults delete -g \(AlertSound.selectionKey)
    fi
    rm -f "$plist" "$sound"
    launchctl bootout "gui/$(id -u)/\(UninstallPlan.agentLabel)"
    exit 0
    """

    static func job(binary: String) -> [String: Any] {
        [
            "Label": UninstallPlan.agentLabel,
            "ProgramArguments": ["/bin/sh", "-c", stub, "lodestar", binary],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 10,
        ]
    }
}
