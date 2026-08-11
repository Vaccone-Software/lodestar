import AppKit
import LodestarCore

/// The lodestar mark: an eight-pointed compass star, drawn as a template so
/// the menu bar styles it. While a chain is pending, the star sits knocked
/// out of a filled disc — the quiet ambient "you're in something".
enum StatusIcon {
    static let idle = make(active: false)
    static let active = make(active: true)

    private static func make(active: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let star = NSBezierPath()
            for i in 0..<16 {
                let angle = CGFloat(i) * .pi / 8 + .pi / 2
                let radius: CGFloat
                if i % 2 == 1 {
                    radius = 2.3
                } else if i % 4 == 0 {
                    radius = 8.2
                } else {
                    radius = 4.4
                }
                let point = NSPoint(x: center.x + cos(angle) * radius,
                                    y: center.y + sin(angle) * radius)
                if i == 0 { star.move(to: point) } else { star.line(to: point) }
            }
            star.close()

            NSColor.black.setFill()
            if active {
                let disc = NSBezierPath(ovalIn: NSRect(x: center.x - 8.6, y: center.y - 8.6,
                                                       width: 17.2, height: 17.2))
                disc.fill()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                star.fill()
            } else {
                star.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config = Config()
    private var model: WindowModel!
    private var parking: ParkingLot!
    private var layout: LayoutController!
    private var appIndex: AppIndex!
    private var store: StateStore!
    private var hud: HUD!
    private var actions: Actions!
    private var searcher: SearcherController!
    private var webBar: WebBarController!
    private var engine: HotkeyEngine!
    private var statusItem: NSStatusItem?
    private var menuBarHideTimer: Timer?
    private var signalSource: DispatchSourceSignal?
    private var trustPoll: Timer?
    private var displayReconcile: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("Lodestar \(Lodestar.version) starting (pid \(ProcessInfo.processInfo.processIdentifier))")
        takeOverPidFile()

        // One hung app must never freeze the switcher.
        setGlobalAXTimeout(1.0)

        let (loaded, problems) = Config.load()
        config = loaded
        Keys.apply(overrides: loaded.keyOverrides)
        ActivePolicy.mode = loaded.activeDisplayMode

        model = WindowModel()
        parking = ParkingLot()
        layout = LayoutController(model: model, parking: parking)
        appIndex = AppIndex()
        store = StateStore()
        hud = HUD()

        store.load()
        appIndex.refresh()
        appIndex.usageBoost = { [store] bundleID in store!.usageBoost(bundleID) }

        actions = Actions(model: model, parking: parking, layout: layout,
                          appIndex: appIndex, store: store, hud: hud)
        actions.attach()
        actions.adoptNewWindows = config.adoptNewWindows
        model.onTrace = { Log.info("model: \($0)") }
        searcher = SearcherController(appIndex: appIndex, actions: actions, model: model)
        rebuildGraphAddresses()
        searcher.graphAddress = { [weak self] name in self?.graphAddressByApp[name] }
        searcher.markPath = { [store] id in
            store!.state.marks.first { $0.windowID == UInt32(id) }?.path.uppercased()
        }
        searcher.graphChains = { [weak self] name in self?.graphChains(for: name) ?? [] }
        searcher.chainProblem = { [weak self] letters in self?.chainProblem(letters) }
        // No `self? … ??` here: these return nil on SUCCESS, and optional
        // chaining would flatten that nil into the error fallback.
        searcher.addToGraph = { [weak self] letters, entry in
            guard let self else { return "lodestar is shutting down" }
            return self.addAppToGraph(letters, entry: entry)
        }
        searcher.removeFromGraph = { [weak self] letters in
            guard let self else { return "lodestar is shutting down" }
            return self.removeChainFromGraph(letters)
        }
        webBar = WebBarController()
        webBar.config = config
        webBar.mostRecentProfile = { [weak self] in self?.mostRecentBrowserProfile() }
        webBar.perform = { [weak self] url, profile, beside in
            self?.actions.openWeb(url: url, profile: profile, beside: beside)
        }
        engine = HotkeyEngine(config: config, actions: actions, hud: hud, searcher: searcher,
                              webBar: webBar, menuSearch: MenuSearchController(),
                              scroller: ScrollController(model: model),
                              hints: HintsController(model: model))

        model.start()
        layout.reconcileDisplays() // learn the connected monitors' identities
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Reconfigurations arrive in bursts; act once they settle.
            self?.displayReconcile?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.layout.reconcileDisplays() }
            self?.displayReconcile = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
        }
        if config.showMenuBar { createStatusItem() }
        actions.revealLodestar = { [weak self] in self?.revealMenuBar() }
        installSignalHandler()

        ConfigDoctor.emitSchema()
        updateConfigWatcher()
        reconcileLoginItem()

        guard Permissions.isTrusted else {
            // A freshly installed bundle has its own TCC identity. Prompt,
            // then wake up on our own the moment the grant lands — no
            // relaunch dance.
            Log.error("not trusted for Accessibility — prompting and waiting for the grant")
            Permissions.requestIfNeeded()
            hud.flash("Lodestar needs Accessibility. Grant it in System Settings and it wakes up on its own", seconds: 8)
            trustPoll = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
                guard let self, Permissions.isTrusted else { return }
                self.trustPoll?.invalidate()
                self.trustPoll = nil
                Log.info("accessibility granted — waking up")
                self.model.stop()
                self.model.start()
                if self.engine.start() {
                    self.hud.flash("⌖ Lodestar ready · hyper space to begin", seconds: 2.5)
                    Log.info("ready: \(self.model.windows.count) windows tracked")
                }
            }
            return
        }
        if engine.start() {
            hud.flash("⌖ Lodestar ready · hyper space to begin", seconds: 2.5)
            Log.info("ready: \(model.windows.count) windows tracked, \(config.graph.children.count) graph roots")
        } else {
            hud.flash("✕ Lodestar could not install its event tap", seconds: 6)
        }
        if let warning = store.bootWarning {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [hud] in
                hud?.flash("⚠ \(warning)", seconds: 8)
            }
        }
        let allProblems = problems
            + ConfigDoctor.groundTruthProblems(config)
            + ConfigDoctor.semanticWarnings(config, appIndex: appIndex)
        for problem in allProblems {
            Log.error("config", ["problem": problem])
        }
        if !allProblems.isEmpty {
            hud.flash("config: \(allProblems[0])\(allProblems.count > 1 ? " (+\(allProblems.count - 1) more, see log)" : "")", seconds: 4)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info("terminating: restoring parked windows")
        actions?.restoreAllParked()
        store?.save() // flush any coalesced write before the process dies
        try? FileManager.default.removeItem(at: Self.pidFile)
    }

    @objc private func reportIssue() {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let body = """
        <!-- Please run `lodestar diagnose` in a terminal, review the output \
        (the log tail may contain window titles), and paste it here. -->

        lodestar \(Lodestar.version) · macOS \(os)
        displays: \(Displays.ordered().count) · trusted: \(Permissions.isTrusted)

        **What happened:**

        **What I expected:**
        """
        var components = URLComponents(string: Lodestar.issuesURL)!
        components.queryItems = [URLQueryItem(name: "body", value: body)]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    // MARK: - Status item

    private func createStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = StatusIcon.idle
        statusItem = item
        engine.onChainActive = { [weak self] active in
            self?.statusItem?.button?.image = active ? StatusIcon.active : StatusIcon.idle
        }

        let menu = NSMenu()
        let header = NSMenuItem(title: "Lodestar \(Lodestar.version) · destination over process", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        menu.addItem(makeItem("Report an Issue…", #selector(reportIssue), key: ""))
        menu.addItem(.separator())
        menu.addItem(makeItem("Edit Config…", #selector(editConfig), key: ""))
        menu.addItem(makeItem("Reveal Config in Finder", #selector(revealConfig), key: ""))
        menu.addItem(makeItem("Reload Config", #selector(reloadConfig), key: ""))
        menu.addItem(makeItem("Open Log", #selector(openLog), key: ""))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit lodestar", #selector(quit), key: "q"))
        item.menu = menu
    }

    private func removeStatusItem() {
        menuBarHideTimer?.invalidate()
        menuBarHideTimer = nil
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
    }

    /// "Going to lodestar": with the menu bar hidden, materialize the status
    /// item for a minute — menu popped open, ready to use. Visible mode just
    /// pops the menu.
    private func revealMenuBar() {
        createStatusItem()
        menuBarHideTimer?.invalidate()
        menuBarHideTimer = nil
        if !config.showMenuBar {
            hud.flash("☰ menu bar revealed for 60s")
            menuBarHideTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
                guard let self, !self.config.showMenuBar else { return }
                self.removeStatusItem()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.statusItem?.button?.performClick(nil)
        }
        Log.info("menu-bar", ["action": "revealed", "temporary": !config.showMenuBar])
    }

    private func makeItem(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// lowercased app name -> graph chain display ("proton mail" -> "E P"),
    /// shown as teaching chips in the searcher.
    private var graphAddressByApp: [String: String] = [:]

    private func rebuildGraphAddresses() {
        var map: [String: String] = [:]
        func walk(_ node: GraphNode, path: [String]) {
            for (letter, child) in node.children {
                let deeper = path + [letter.uppercased()]
                if let target = child.target, child.children.isEmpty {
                    if case .app(let name) = target {
                        let key = name.lowercased()
                        let address = deeper.joined(separator: " ")
                        if map[key].map({ $0.count > address.count }) ?? true {
                            map[key] = address
                        }
                    }
                } else {
                    walk(child, path: deeper)
                }
            }
        }
        walk(config.graph, path: [])
        graphAddressByApp = map
    }

    // MARK: - Graph editing (⌘K in the searcher)

    /// Every chain bound to an app, shortest first — the card's remove rows.
    private func graphChains(for name: String) -> [[String]] {
        var chains: [[String]] = []
        func walk(_ node: GraphNode, path: [String]) {
            for (letter, child) in node.children {
                if let target = child.target, child.children.isEmpty {
                    if case .app(let app) = target, app.lowercased() == name {
                        chains.append(path + [letter])
                    }
                } else {
                    walk(child, path: path + [letter])
                }
            }
        }
        walk(config.graph, path: [])
        return chains.sorted { ($0.count, $0.joined()) < ($1.count, $1.joined()) }
    }

    /// Why a chain can't be added, or nil when it's free. Judged against
    /// the live trie, so sugar keys and merged branches are all visible.
    private func chainProblem(_ letters: [String]) -> String? {
        guard let first = letters.first else { return nil }
        if Config.reservedTopLevel.contains(first) {
            return "\(first.uppercased()) is reserved — O X Z are fixed verbs"
        }
        for depth in 1...letters.count {
            let prefix = Array(letters[0..<depth])
            let shown = prefix.map { $0.uppercased() }.joined(separator: " ")
            switch config.graph.resolve(prefix) {
            case .leaf(let target):
                return "hyper \(shown) is \(target.label)"
            case .deeper:
                if depth == letters.count { return "hyper \(shown) leads deeper — add a letter" }
            case .miss:
                return nil
            }
        }
        return nil
    }

    private func addAppToGraph(_ letters: [String], entry: AppIndex.Entry) -> String? {
        if let problem = chainProblem(letters) { return problem }
        let shown = letters.map { $0.uppercased() }.joined(separator: " ")
        return rewriteGraph(flash: "✓ hyper \(shown) → \(entry.name)") {
            try GraphFileEditor.addingPath(letters, target: entry.name, in: $0)
        }
    }

    private func removeChainFromGraph(_ letters: [String]) -> String? {
        let shown = letters.map { $0.uppercased() }.joined(separator: " ")
        return rewriteGraph(flash: "✓ removed hyper \(shown)") {
            try GraphFileEditor.deletingPath(letters, in: $0)
        }
    }

    /// Read-edit-write the config file, then apply it. The HUD confirms
    /// with `flash` unless the reload surfaces problems.
    private func rewriteGraph(flash: String, edit: (String) throws -> String) -> String? {
        guard let text = try? String(contentsOf: Config.file, encoding: .utf8) else {
            return "could not read \(Config.file.lastPathComponent)"
        }
        let updated: String
        do {
            updated = try edit(text)
        } catch let error as GraphFileEditor.EditError {
            return error.description
        } catch {
            return "\(error)"
        }
        do {
            try updated.write(to: Config.file, atomically: true, encoding: .utf8)
        } catch {
            return "could not write the config: \(error.localizedDescription)"
        }
        Log.info("graph-edit", ["edit": flash])
        applyConfigReload(successFlash: flash)
        return nil
    }

    @objc private func reloadConfig() {
        applyConfigReload(successFlash: "✓ config reloaded")
    }

    private func applyConfigReload(successFlash: String) {
        let (loaded, loadProblems) = Config.load()
        let problems = loadProblems
            + ConfigDoctor.groundTruthProblems(loaded)
            + ConfigDoctor.semanticWarnings(loaded, appIndex: appIndex)
        config = loaded
        Keys.apply(overrides: loaded.keyOverrides)
        ActivePolicy.mode = loaded.activeDisplayMode
        actions.adoptNewWindows = loaded.adoptNewWindows
        engine.config = loaded
        webBar.config = loaded
        rebuildGraphAddresses()
        ConfigDoctor.emitSchema()
        updateConfigWatcher()
        reconcileLoginItem()
        if config.showMenuBar {
            menuBarHideTimer?.invalidate()
            menuBarHideTimer = nil
            createStatusItem()
        } else if menuBarHideTimer == nil {
            removeStatusItem()
        }
        for problem in problems { Log.error("config", ["problem": problem]) }
        if problems.isEmpty {
            hud.flash(successFlash)
        } else {
            hud.flash("config: \(problems[0])\(problems.count > 1 ? " (+\(problems.count - 1) more, see log)" : "")", seconds: 4)
        }
        Log.info("config-reload", [
            "graph": graphAddressByApp.count, "links": loaded.webLinks.count,
            "routes": loaded.webRoutes.count, "profiles": loaded.browserProfiles.count,
            "problems": problems.count, "auto-reload": loaded.autoReload,
            "start-at-login": loaded.startAtLogin,
        ])
    }

    // MARK: - Auto-reload watcher

    private var configWatcher: DispatchSourceFileSystemObject?
    private var reloadDebounce: DispatchWorkItem?

    private func updateConfigWatcher() {
        configWatcher?.cancel()
        configWatcher = nil
        guard config.autoReload else { return }
        let fd = open(Config.file.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main
        )
        source.setEventHandler { [weak self] in self?.scheduleAutoReload() }
        source.setCancelHandler { close(fd) }
        source.resume()
        configWatcher = source
    }

    private func scheduleAutoReload() {
        reloadDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Log.info("config-autoreload", ["trigger": "file-saved"])
            self?.reloadConfig() // re-arms the watcher (editors save atomically via rename)
        }
        reloadDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: - Login item reconciliation (installed app only)

    private func reconcileLoginItem() {
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix("lodestar.app") else { return }
        // Gatekeeper translocation: a quarantined app opened from its
        // download spot runs from a randomized read-only path. Pinning the
        // agent (or anything) to that path breaks every future login —
        // tell the user the one move that fixes it, and touch nothing.
        if bundlePath.contains("/AppTranslocation/") {
            hud.flash("Move Lodestar to Applications, then open it again", seconds: 10)
            Log.error("running translocated — asked the user to move the app")
            return
        }
        // The zip install path has no installer: the app maintains its own
        // CLI link in a writable bin, best effort.
        for bin in ["/opt/homebrew/bin", "/usr/local/bin"] {
            guard FileManager.default.isWritableFile(atPath: bin) else { continue }
            let link = bin + "/lodestar"
            let target = bundlePath + "/Contents/MacOS/lodestar"
            let existing = try? FileManager.default.destinationOfSymbolicLink(atPath: link)
            if existing != target {
                try? FileManager.default.removeItem(atPath: link)
                try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
            }
            break
        }
        let agent = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.vaccone.lodestar.plist")
        let exists = FileManager.default.fileExists(atPath: agent.path)
        if config.startAtLogin {
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
            \t<key>Label</key>
            \t<string>com.vaccone.lodestar</string>
            \t<key>ProgramArguments</key>
            \t<array>
            \t\t<string>\(bundlePath)/Contents/MacOS/lodestar</string>
            \t</array>
            \t<key>RunAtLoad</key>
            \t<true/>
            \t<key>KeepAlive</key>
            \t<dict>
            \t\t<key>SuccessfulExit</key>
            \t\t<false/>
            \t</dict>
            \t<key>ThrottleInterval</key>
            \t<integer>10</integer>
            </dict>
            </plist>
            """
            let current = try? String(contentsOf: agent, encoding: .utf8)
            if current != plist {
                try? plist.write(to: agent, atomically: true, encoding: .utf8)
                Log.info("login-item", ["action": exists ? "updated" : "installed"])
            }
        } else if !config.startAtLogin && exists {
            // Delete the plist without unloading: the running session
            // continues; nothing loads at the next login.
            try? FileManager.default.removeItem(at: agent)
            Log.info("login-item", ["action": "removed"])
        }
    }

    /// The registry profile of the most recently focused browser window,
    /// by title suffix, across every browser the config declares.
    private func mostRecentBrowserProfile() -> BrowserProfile? {
        let browsers = Set(config.browserProfiles.values.map(\.browser))
        let windows = browsers
            .flatMap { model.aliveWindows(bundleID: $0.bundleID) }
            .sorted { ($0.lastFocused ?? .distantPast, $0.id) > ($1.lastFocused ?? .distantPast, $1.id) }
        for window in windows {
            for profile in config.browserProfiles.values
            where profile.browser.bundleID == window.bundleID
                && profile.browser.windowMatches(title: window.title, profile: profile.display) {
                return profile
            }
        }
        return nil
    }


    @objc private func editConfig() {
        ensureConfigOnDisk()
        if !NSWorkspace.shared.open(Config.file) {
            // No app claims .yaml — TextEdit always opens plain text.
            NSWorkspace.shared.open([Config.file],
                                    withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                    configuration: NSWorkspace.OpenConfiguration())
        }
    }

    @objc private func revealConfig() {
        ensureConfigOnDisk()
        NSWorkspace.shared.activateFileViewerSelecting([Config.file])
    }

    /// The file can vanish between launch and the click; load() rewrites it.
    private func ensureConfigOnDisk() {
        if !FileManager.default.fileExists(atPath: Config.file.path) { _ = Config.load() }
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(Log.file)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Process management

    private static let pidFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/lodestar/lodestar.pid")

    private func takeOverPidFile() {
        if let text = try? String(contentsOf: Self.pidFile, encoding: .utf8),
           let oldPid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           oldPid != ProcessInfo.processInfo.processIdentifier,
           kill(oldPid, 0) == 0 {
            Log.info("replacing running lodestar (pid \(oldPid))")
            kill(oldPid, SIGTERM)
            usleep(600_000)
        }
        try? "\(ProcessInfo.processInfo.processIdentifier)".write(
            to: Self.pidFile, atomically: true, encoding: .utf8
        )
    }

    private func installSignalHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            Log.info("SIGTERM — shutting down gracefully")
            NSApp.terminate(nil)
        }
        source.resume()
        signalSource = source

        // SIGUSR1 dumps a state snapshot to the log — the E2E harness's eyes.
        signal(SIGUSR1, SIG_IGN)
        let dump = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        dump.setEventHandler { [weak self] in self?.dumpState() }
        dump.resume()
        dumpSource = dump

        // SIGUSR2 reloads the config — the scriptable Reload Config.
        signal(SIGUSR2, SIG_IGN)
        let reload = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        reload.setEventHandler { [weak self] in
            Log.info("config-reload", ["trigger": "SIGUSR2"])
            self?.reloadConfig()
        }
        reload.resume()
        reloadSource = reload
    }

    private var reloadSource: DispatchSourceSignal?

    private var dumpSource: DispatchSourceSignal?

    private func dumpState() {
        let focused = model.focusedWindow
        for info in Displays.ordered() {
            let members = layout.orderedByPosition(on: info.id).map { id -> String in
                let w = model.window(id)
                return "\(id):\(w?.appName ?? "?"):'\(String((w?.title ?? "").prefix(24)))'@\(w.map { fmt($0.frame) } ?? "?")"
            }
            let active = layout.activeDisplay()?.id == info.id ? "*" : ""
            Log.info("DUMP display\(active)=\(info.id) layout[\(layout.orientation(on: info.id).rawValue)]=[\(members.joined(separator: " | "))]")
        }
        Log.info("DUMP v=\(Lodestar.version) focused=\(focused.map { "\($0.id):\($0.appName)" } ?? "none") parked=\(parking.snapshot().keys.sorted()) tracked=\(model.windows.values.filter(\.isAlive).count) paused=\(engine.isPaused) searcher=\(searcher.isVisible) webbar=\(webBar.isVisible) engine=\(engine.stateDescription)")
        // menu search visibility is engine-owned; log via its trace lines
    }

    private func fmt(_ r: CGRect) -> String {
        "(\(Int(r.minX)),\(Int(r.minY)))\(Int(r.width))x\(Int(r.height))"
    }
}

let cliArguments = CommandLine.arguments.dropFirst()

func printUsage() {
    print("""
    Lodestar \(Lodestar.version): keyboard navigation for macOS
    usage: lodestar <command>

      check [--json]   validate the config (schema, references, ground truth)
      reload           apply the config to the running instance
      diagnose         print a support report (paste this into bug reports)
      reset-config     back up the current config, write fresh defaults
      uninstall        remove lodestar (--dry-run to preview, --purge for data)
      schema           print the config JSON Schema
      config-path      print the config file path
      apps             list every app name the graph can bind

    The app itself is started by its login agent (scripts/install-app.sh).
    Reference: GUIDE.md · agents: AGENTS.md
    """)
}

if !cliArguments.isEmpty {
    Log.stdoutEnabled = false // CLI verbs own stdout
}
// Bare `lodestar` from a shell or script is a CLI asking for help; only
// launchd starts the app (LaunchAgent, Finder, `open` — all ppid 1).
// Parentage, not TTY: piped shells and agents have no TTY either, and a
// bare invocation must never take over the running instance.
if cliArguments.isEmpty && getppid() != 1 {
    printUsage()
    exit(0)
}
if cliArguments.contains("--check") || cliArguments.contains("check") {
    runConfigCheck(json: cliArguments.contains("--json"))
}
if cliArguments.contains("diagnose") {
    runDiagnose()
}
if cliArguments.contains("reload") {
    runReload()
}
if cliArguments.contains("schema") {
    print(ConfigSchema.jsonSchema(for: Config.schema, title: "lodestar configuration"))
    exit(0)
}
if cliArguments.contains("config-path") {
    print(Config.file.path)
    exit(0)
}
if cliArguments.contains("apps") {
    runApps()
}
if cliArguments.contains("reset-config") {
    runResetConfig()
}
if cliArguments.contains("uninstall") {
    runUninstall(dryRun: cliArguments.contains("--dry-run"),
                 purge: cliArguments.contains("--purge"))
}
if cliArguments.contains("--help") || cliArguments.contains("help") || cliArguments.contains("-h") {
    Log.stdoutEnabled = true
    printUsage()
    exit(0)
}
if let stray = cliArguments.first(where: { !$0.hasPrefix("-NS") && !$0.hasPrefix("-psn") && !$0.hasPrefix("-App") }) {
    Log.stdoutEnabled = true
    print("unknown command: \(stray)\n")
    printUsage()
    exit(64)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
