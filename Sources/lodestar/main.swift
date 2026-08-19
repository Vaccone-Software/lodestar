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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var config = Config()
    private var model: WindowModel!
    private var parking: ParkingLot!
    private var layout: LayoutController!
    private var appIndex: AppIndex!
    private var store: StateStore!
    private var observationStore: ObservationStore!
    private var hud: HUD!
    private var actions: Actions!
    private var searcher: SearcherController!
    private var webBar: WebBarController!
    private var engine: HotkeyEngine!
    private var coach: CoachController!
    private var updater: UpdateController!
    private var clipboardController: ClipboardController!
    private var statusItem: NSStatusItem?
    private var coachSuggestionItem: NSMenuItem?
    private var menuBarHideTimer: Timer?
    private var signalSource: DispatchSourceSignal?
    private var trustPoll: Timer?
    private var displayReconcile: DispatchWorkItem?
    private var clickHandler: ClickHandler?
    /// Links that arrived before the handler existed. A URL open can be the
    /// reason we were launched, so the event can beat our own setup; the queue
    /// is what stops that link from being the one that vanishes.
    private var pendingClicks: [URL] = []
    private var defaultBrowserItem: NSMenuItem?
    private let onboarding = OnboardingController()

    /// Links clicked in other apps land here. Deliberately the shortest path
    /// in the app: it needs the config and nothing else — not the window
    /// model, not the app index, and not Accessibility, so it answers while
    /// the rest of Lodestar is still waking up or waiting on a grant.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let clickHandler else {
            pendingClicks.append(contentsOf: urls)
            return
        }
        clickHandler.open(urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("Lodestar \(Lodestar.version) starting (pid \(ProcessInfo.processInfo.processIdentifier))")
        takeOverPidFile()

        // One hung app must never freeze the switcher.
        setGlobalAXTimeout(1.0)

        // Before anything opens a file: settle where files live.
        Paths.migrateIfNeeded()
        Config.migrateIfNeeded()
        let (loaded, problems) = Config.load()
        config = loaded
        Keys.apply(overrides: loaded.keyOverrides)
        ActivePolicy.mode = loaded.activeDisplayMode

        // Stood up here, first thing after the config, and above everything
        // heavy: the model, the index, the clipboard, and the Accessibility
        // guard all come later, and a clicked link must not wait for any of
        // them. Anything that arrived before now goes out immediately.
        installClickHandler()

        model = WindowModel()
        parking = ParkingLot()
        layout = LayoutController(model: model, parking: parking)
        appIndex = AppIndex()
        store = StateStore()
        observationStore = ObservationStore()
        if observationStore.consumeClearRequest() {
            observationStore.clear()
        } else {
            observationStore.load()
        }
        observationStore.setEnabled(loaded.observationsEnabled)
        hud = HUD()

        store.load()
        appIndex.refresh()
        appIndex.usageBoost = { [store] bundleID in store!.usageBoost(bundleID) }

        actions = Actions(model: model, parking: parking, layout: layout,
                          appIndex: appIndex, store: store, hud: hud)
        actions.attach()
        actions.observations = observationStore
        model.onTrace = { Log.info("model: \($0)") }
        searcher = SearcherController(appIndex: appIndex, actions: actions, model: model)
        searcher.observations = observationStore
        rebuildGraphAddresses()
        searcher.graphAddress = { [weak self] name in self?.graphAddressByApp[name] }
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
        clipboardController = ClipboardController()
        clipboardController.flash = { [weak self] text in self?.hud.flash(text) }
        clipboardController.excludedApps = config.clipboardExcludedApps
        clipboardController.excludedPatterns = config.clipboardExcludePatterns
        clipboardController.maxBytes = config.clipboardMaxBytes
        clipboardController.setEnabled(config.clipboardEnabled)

        webBar = WebBarController()
        webBar.config = config
        webBar.mostRecentProfile = { [weak self] in self?.mostRecentBrowserProfile() }
        webBar.perform = { [weak self] url, profile, beside, row in
            self?.actions.openWeb(url: url, profile: profile, beside: beside, row: row)
        }
        // Returns nil on SUCCESS, so no optional chaining here either.
        webBar.addLink = { [weak self] name, url, profileKey in
            guard let self else { return "lodestar is shutting down" }
            return self.addWebLink(name: name, url: url, profileKey: profileKey)
        }
        webBar.removeLink = { [weak self] name in
            guard let self else { return "lodestar is shutting down" }
            return self.removeWebLink(name: name)
        }
        webBar.addRoute = { [weak self] pattern, profileKey in
            guard let self else { return "lodestar is shutting down" }
            return self.addWebRoute(pattern: pattern, profileKey: profileKey)
        }
        webBar.removeRoute = { [weak self] pattern in
            guard let self else { return "lodestar is shutting down" }
            return self.removeWebRoute(pattern: pattern)
        }
        let selectController = SelectController(model: model)
        selectController.flash = { [weak self] text in self?.hud.flash(text) }
        selectController.observations = observationStore
        engine = HotkeyEngine(config: config, actions: actions, hud: hud, searcher: searcher,
                              webBar: webBar, menuSearch: MenuSearchController(),
                              scroller: ScrollController(model: model),
                              hints: HintsController(model: model),
                              select: selectController,
                              clipboard: clipboardController)

        engine.observations = observationStore

        // The coach: decisions in LodestarCore, this wiring is the coat.
        coach = CoachController()
        coach.observations = observationStore
        coach.enabled = loaded.coachEnabled
        coach.contextInputs = { [weak self] in
            guard let self else { return nil }
            let identityToKey = Dictionary(self.config.browserProfiles.map {
                ("\($0.value.browser.rawValue):\($0.value.display)", $0.key)
            }, uniquingKeysWith: { first, _ in first })
            return (observations: self.observationStore.observations,
                    leaves: self.config.graph.leaves().map {
                        Advisor.Leaf(chain: $0.chain, label: $0.target.label,
                                     value: $0.target.configValue)
                    },
                    webRoutes: self.config.webRoutes,
                    profileKeys: identityToKey,
                    logFile: self.observationStore.log.file)
        }
        coach.applyEdit = { [weak self] edit in
            guard let self else { return "lodestar is shutting down" }
            switch edit {
            case .bindTarget(let chain, let target):
                return self.addTargetToGraph(chain, target: target)
            case .removeChain(let chain):
                return self.removeChainFromGraph(chain)
            case .addRoute(let pattern, let profileKey):
                return self.addWebRoute(pattern: pattern, profileKey: profileKey)
            }
        }
        coach.engineQuiet = { [weak self] in self?.engine.isQuiet ?? false }
        coach.showChip = { [weak self] chip in
            // The keycap names the gesture the way the scroll guide's
            // "G G" does: two lodes, tapped. A blank cap read as a row
            // with no way in.
            self?.hud.showGuide(title: "⌖ coach",
                                rows: [GuideRow(key: "lode lode", label: chip.headline)],
                                footer: "\(chip.evidence)   ·   \(chip.footer)")
        }
        coach.hideChip = { [weak self] in self?.hud.hide() }
        coach.flash = { [weak self] text in self?.hud.flash(text) }
        engine.onLodeDoubleTap = { [weak self] in self?.coach.lodeDoubleTapped() }
        engine.coachDelete = { [weak self] in self?.coach.lodeDelete() ?? false }
        engine.onSurfaceClaimed = { [weak self] in self?.coach.surfaceClaimed() }
        actions.coachBoundary = { [weak self] app in self?.coach.noteBoundary(app: app) }
        actions.coachWebOpen = { [weak self] host in self?.coach.noteWebOpen(host: host) }
        // First pass once the boot dust settles; boundaries keep it fresh.
        coach.scheduleRefresh(after: 120)
        #if DEBUG
        armCoachDemoIfRequested()
        #endif

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
        engine.onExcludeApp = { [weak self] bundleID in self?.excludeAppFromClipboard(bundleID) }
        installSignalHandler()

        ConfigDoctor.emitSchema()
        updateConfigWatcher()
        reconcileLoginItem()

        // The updater runs regardless of trust — an install stuck at the
        // Accessibility prompt still deserves fixes.
        updater = UpdateController()
        updater.enabled = config.autoUpdate
        updater.engineQuiet = { [weak self] in self?.engine.isQuiet ?? false }
        updater.lastActivity = { [weak self] in self?.engine.lastActivityAt ?? Date() }
        updater.flash = { [weak self] text, seconds in self?.hud.flash(text, seconds: seconds) }
        updater.requiresRouting = { [weak self] in self?.config.webHandleClicks ?? false }
        updater.start()
        rememberDefaultBrowser()
        adoptBrowserRoleIfNeeded()
        confirmClickRoutingHealthy()
        installOnboarding()

        guard Permissions.isTrusted else {
            // A freshly installed bundle has its own TCC identity. Prompt,
            // then wake up on our own the moment the grant lands — no
            // relaunch dance.
            Log.error("not trusted for Accessibility — waiting for the grant")
            // The walkthrough's first card asks for this, with a button and a
            // screen it clears for the settings pane. Prompting here too put
            // the macOS dialog behind a full screen backdrop.
            if !onboarding.isVisible {
                Permissions.requestIfNeeded()
                hud.flash("Lodestar needs Accessibility. Grant it in System Settings and it wakes up on its own", seconds: 8)
            }
            trustPoll = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
                guard let self, Permissions.isTrusted else { return }
                self.trustPoll?.invalidate()
                self.trustPoll = nil
                Log.info("accessibility granted — waking up")
                self.model.stop()
                self.model.start()
                if self.engine.start() {
                    self.hud.flash("⌖ Lodestar ready · lode space to begin", seconds: 2.5)
                    Log.info("ready: \(self.model.windows.count) windows tracked")
                }
            }
            return
        }
        if engine.start() {
            hud.flash("⌖ Lodestar ready · lode space to begin", seconds: 2.5)
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
        observationStore?.flush()
        // Only clear the pid file while it is still ours — in a takeover
        // (manual reinstall or self-update) the successor has already
        // written its own pid, and deleting it would blind the update
        // watchdog into rolling back a healthy build.
        if let text = try? String(contentsOf: Self.pidFile, encoding: .utf8),
           Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
               == ProcessInfo.processInfo.processIdentifier {
            try? FileManager.default.removeItem(at: Self.pidFile)
        }
    }

    @objc private func checkForUpdates() {
        updater.check(force: true)
    }

    /// The menu asked for the parked suggestion: the cue wait is over.
    @objc private func presentCoachSuggestion() {
        coach?.presentParked()
    }

    #if DEBUG
    /// Debug builds only: `coach.demo-request` beside the observations
    /// arms a rehearsal — a synthetic offer, so the chip, both gestures,
    /// and the config write can be walked end to end before the first
    /// real finding exists. Checked at boot and at every reload, so
    /// re-arming is touch-the-flag and reload. The file-as-a-flag is the
    /// clipboard's handshake, reused.
    private func armCoachDemoIfRequested() {
        let flag = Paths.data.appendingPathComponent("coach.demo-request")
        guard FileManager.default.fileExists(atPath: flag.path) else { return }
        try? FileManager.default.removeItem(at: flag)
        let taken = Set(config.graph.leaves().compactMap { $0.chain.first })
        let free = "abcdefghijklmnopqrstuvwxyz".map(String.init).filter { !taken.contains($0) }
        for name in ["Calculator", "Preview", "Notes", "Music", "FaceTime"] {
            guard let entry = appIndex.entry(named: name) else { continue }
            let letters = name.lowercased().filter(\.isLetter).map(String.init)
            guard let slot = letters.first(where: { !taken.contains($0) }) ?? free.first
            else { continue }
            let rec = Recommendation(
                kind: .bind, target: entry.name.lowercased(),
                detail: "a rehearsal · this is how a real finding will arrive",
                secondsPerWeek: 42, probability: 0.97,
                evidence: ["synthetic, for the dress rehearsal"],
                edit: .bindTarget(chain: [slot], target: entry.name))
            coach.armDemo(rec)
            Log.info("coach", ["demo": "armed", "slot": slot, "app": entry.name])
            return
        }
        Log.error("coach: demo requested but no candidate app was installed")
    }
    #endif

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
        menu.addItem(makeItem("How Lodestar Works…", #selector(showOnboarding), key: ""))
        menu.addItem(makeItem("Check for Updates…", #selector(checkForUpdates), key: ""))
        menu.addItem(makeItem("Report an Issue…", #selector(reportIssue), key: ""))
        menu.addItem(.separator())
        // Title set at menu-open time, since it names what the item will do
        // and that depends on where the role currently sits.
        let browserItem = makeItem("", #selector(toggleDefaultBrowser), key: "")
        defaultBrowserItem = browserItem
        menu.addItem(browserItem)
        // The coach's inbox of at most one: a suggestion whose moment was
        // missed parks here instead of being lost. Hidden when empty.
        let coachItem = makeItem("", #selector(presentCoachSuggestion), key: "")
        coachItem.isHidden = true
        coachSuggestionItem = coachItem
        menu.addItem(coachItem)
        menu.delegate = self
        menu.addItem(.separator())
        menu.addItem(makeItem("Edit Config…", #selector(editConfig), key: ""))
        menu.addItem(makeItem("Reveal Config in Finder", #selector(revealConfig), key: ""))
        menu.addItem(makeItem("Reload Config", #selector(reloadConfig), key: ""))
        menu.addItem(makeItem("Open Log", #selector(openLog), key: ""))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit lodestar", #selector(quit), key: "q"))
        item.menu = menu
    }

    /// The browser item reads the world each time the menu opens: it says what
    /// pressing it does, not what state you are in.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if let coachItem = coachSuggestionItem {
            if let headline = coach?.parkedHeadline {
                coachItem.isHidden = false
                coachItem.title = "Coach: \(headline)"
            } else {
                coachItem.isHidden = true
            }
        }
        guard let item = defaultBrowserItem else { return }
        // Reality, not config: the role can be handed to us or taken away in
        // System Settings without going through this menu, and an item that
        // offered to "give links back" while we do not hold them would be
        // describing a world that no longer exists.
        guard holdsBrowserRole() else {
            item.title = "Route Clicked Links Through Lodestar…"
            return
        }
        let saved = config.webClickBrowser
        item.title = saved.isEmpty
            ? "Stop Routing Clicked Links"
            : "Give Links Back to \(Self.shortBrowserName(saved))"
    }

    /// com.brave.Browser reads as Brave. A bundle id in a menu is furniture.
    private static func shortBrowserName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return url.deletingPathExtension().lastPathComponent
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
        for (chain, target) in config.graph.leaves() {
            guard case .app(let name) = target else { continue }
            let key = name.lowercased()
            let address = chain.map { $0.uppercased() }.joined(separator: " ")
            // Shortest chain wins; ties break on the sorted walk, so the
            // chip an app shows is stable across launches.
            if map[key].map({ $0.count > address.count }) ?? true {
                map[key] = address
            }
        }
        graphAddressByApp = map
    }

    // MARK: - Onboarding

    private func installOnboarding() {
        onboarding.config = config
        onboarding.acceptGraph = { [weak self] proposals in
            self?.acceptStarterGraph(proposals)
        }
        onboarding.onFinished = { [weak self] in
            guard let self else { return }
            self.engine.interceptor = nil
            self.store.markOnboarded(version: Lodestar.version)
        }

        // Once, on the first run that ever gets this far, and never again on its
        // own. Keyed to the version it was a full screen modal every release:
        // the updater applies while you are idle and suppresses the deck for
        // that boot, so the next launch opened it over whatever you were doing,
        // because a version number changed rather than because anybody asked.
        // Anyone who wants it back has How Lodestar Works in the menu bar, and
        // the walkthrough now owns the keyboard while it is up, which makes an
        // unrequested takeover the wrong kind of surprise.
        guard store.onboardedVersion == nil, !updater.justUpdated else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.showOnboarding()
        }
    }

    @objc private func showOnboarding() {
        guard !onboarding.isVisible else { return }
        onboarding.config = config
        engine.interceptor = { [weak self] key, held, shift, other in
            // Dead-man: if the deck is gone by any road that skipped
            // onFinished, the interceptor removes itself instead of
            // holding the keyboard hostage forever.
            guard let self, self.onboarding.isVisible else {
                self?.engine.interceptor = nil
                return false
            }
            return self.onboarding.handle(key: key, held: held, shift: shift, other: other)
        }
        onboarding.show()
    }


    /// The drafted graph, accepted. Written one address at a time through the
    /// same editor ⌘K uses, so what onboarding produces is indistinguishable
    /// from what a hand edit would have.
    private func acceptStarterGraph(_ proposals: [StarterGraph.Proposal]) -> String? {
        guard !proposals.isEmpty else { return nil }
        let shown = proposals.map { $0.letter.uppercased() }.joined(separator: " ")
        return rewriteConfig(flash: "✓ graph: \(shown)", logged: "starter graph \(proposals.count)") { tree in
            var updated = tree
            for proposal in proposals {
                updated = try GraphJsonEditor.addingPath([proposal.letter],
                                                         target: proposal.app, in: updated)
            }
            return updated
        }
    }

    // MARK: - Clicked links

    private func installClickHandler() {
        let handler = ClickHandler()
        handler.context = { [weak self] in
            WebContext(config: self?.config ?? Config(), mostRecent: nil)
        }
        handler.savedBrowser = { [weak self] in self?.config.webClickBrowser ?? "" }
        handler.trace = { [weak self] in self?.config.webTraceClicks ?? false }
        // The HUD is not up yet at install time, and a link is not worth
        // waiting for one; failures flash if there is anything to flash with.
        handler.flash = { [weak self] text in self?.hud?.flash(text, seconds: 5) }
        handler.adoptIfUnconfigured = { [weak self] in self?.adoptBrowserRoleIfNeeded() }
        // The store does not exist yet at install time; the closure looks
        // it up per link, so early clicks simply go unobserved.
        handler.observe = { [weak self] host, profile in
            self?.observationStore?.webOpened(host: host, profile: profile ?? "pass",
                                              source: "clicked")
        }
        clickHandler = handler
        if !pendingClicks.isEmpty {
            let queued = pendingClicks
            pendingClicks = []
            handler.open(queued)
        }
    }

    /// Prove the click path works, or say nothing and let the watchdog put the
    /// last build back. Two things have to hold: the router answers correctly,
    /// and there is a real browser to hand an unrouted link to. Either one
    /// failing means links would break, which is not a thing to discover from
    /// a bug report.
    private func confirmClickRoutingHealthy() {
        guard config.webHandleClicks else { return }
        let hasBrowser = !config.webClickBrowser.isEmpty
            && NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: config.webClickBrowser) != nil
        guard ClickRouter.selfCheck(), hasBrowser else {
            Log.error("click", ["self-check": "failed",
                                "router": ClickRouter.selfCheck(),
                                "browser": hasBrowser])
            hud.flash("⚠ Lodestar is your browser but cannot route links — check web.clicks", seconds: 8)
            return
        }
        updater.confirmRoutingHealthy()
        Log.info("click", ["self-check": "ok"])
    }

    /// The bundle id of whatever answers for https right now, us included.
    private func httpsHandler() -> String? {
        guard let probe = URL(string: "https://example.com"),
              let application = NSWorkspace.shared.urlForApplication(toOpen: probe) else {
            return nil
        }
        return Bundle(url: application)?.bundleIdentifier
    }

    /// Whether macOS is handing links to us at this moment. Asked rather than
    /// remembered: the role can change in System Settings without telling us,
    /// and a menu that reports config instead of reality lies.
    private func holdsBrowserRole() -> Bool {
        httpsHandler() == Bundle.main.bundleIdentifier
    }

    /// The browser to give the role back to — the question you can only ask
    /// *before* taking it, because afterwards the answer is us.
    private func currentDefaultBrowser() -> String? {
        guard let handler = httpsHandler(),
              handler != Bundle.main.bundleIdentifier else { return nil }
        return handler
    }

    /// Note which browser answers for links, whenever that answer is not us.
    ///
    /// Lodestar runs continuously, so by the time the role is handed over —
    /// through the menu or through System Settings — the answer is already on
    /// file and nothing has to be inferred. Inference was the first attempt
    /// and it failed in the worst way: LaunchServices ranks the *current*
    /// default first, so asking "what else could open this" reshuffles the
    /// moment we take the role. The browser you were using drops out of first
    /// place, Apple's own rises, and the guess is wrong exactly when it
    /// matters. Remembering costs one query at boot and is never wrong.
    private func rememberDefaultBrowser() {
        guard let handler = httpsHandler(),
              handler != Bundle.main.bundleIdentifier,
              handler != config.webClickBrowser else { return }
        Log.info("click", ["remembered-browser": handler])
        persistClickBrowser(handler)
    }

    /// A one-key write: no reload, no flash. Observing which browser you use is
    /// not an event worth announcing.
    private func persistClickBrowser(_ bundleID: String) {
        config.webClickBrowser = bundleID
        guard let text = try? String(contentsOf: Config.file, encoding: .utf8),
              let tree = try? Json.parse(text),
              let updated = Json.setting(tree, path: ["web", "clicks", "browser"],
                                         to: .string(bundleID)) else { return }
        try? Config.write(tree: updated)
    }

    /// We hold the role but routing is off and no browser is recorded: Lodestar
    /// was picked in System Settings and this session never saw the handover.
    /// Adopt what that choice implies, so the rules actually apply. Deliberately
    /// narrow: a recorded browser with routing off is the documented
    /// pass-through state, and this must not stomp it.
    private func adoptBrowserRoleIfNeeded() {
        guard holdsBrowserRole(), !config.webHandleClicks else { return }
        // Remembered, from before the switch — the answer that is never a
        // guess. Discovery is the last resort, and it says so out loud.
        var browser = config.webClickBrowser
        var guessed = false
        if browser.isEmpty {
            guard let discovered = ClickHandler.discoverBrowser(),
                  let bundleID = Bundle(url: discovered)?.bundleIdentifier else {
                hud.flash("⚠ Lodestar is your default browser but no browser is set — see web.clicks.browser", seconds: 8)
                Log.error("click", ["adopt": "no browser to hand off to"])
                return
            }
            browser = bundleID
            guessed = true
        }
        Log.info("click", ["adopted-role": "true", "handoff": browser, "guessed": guessed])
        recordClickSettings(enabled: true, browser: browser)
        let name = Self.shortBrowserName(browser)
        hud.flash(guessed
            ? "⌖ Routing links · unrouted go to \(name)? change it with web.clicks.browser"
            : "⌖ Routing links · unrouted go to \(name)", seconds: 6)
    }

    @objc private func toggleDefaultBrowser() {
        // Same question the label asked, so the item always does what it says.
        holdsBrowserRole() ? standDownAsBrowser() : becomeDefaultBrowser()
    }

    /// Where macOS keeps the choice, since macOS will not let us make it. The
    /// pane is Desktop & Dock on Ventura and later; the flash says what to look
    /// for, because the setting is a long way down that page.
    private func openDefaultBrowserSettings() {
        let pane = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")
        if let pane { NSWorkspace.shared.open(pane) }
        hud.flash("Choose “lodestar” as your default web browser, then links follow your rules",
                  seconds: 9)
    }

    /// Take the role, or take you to where it is taken.
    ///
    /// `setDefaultApplication` is asked first, because when it works it is one
    /// keystroke and no detour. On this machine it has never worked: it refuses
    /// with permErr regardless of rank, activation policy, bundle identity, or
    /// how the process was launched, while the System Settings picker accepts
    /// the same app happily. Rather than keep failing at the user, a refusal
    /// falls through to opening that picker. The important half — remembering
    /// which browser you were using — happens here either way, before the role
    /// changes hands and the answer becomes unobtainable.
    private func becomeDefaultBrowser() {
        rememberDefaultBrowser()
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        // Deployment target is 13; activate() is 14-only.
        NSApp.activate(ignoringOtherApps: true)
        NSWorkspace.shared.setDefaultApplication(
            at: Bundle.main.bundleURL, toOpenURLsWithScheme: "https"
        ) { [weak self] error in
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(policy)
                guard let self else { return }
                if let error {
                    // The whole error, not its polite summary: LaunchServices
                    // hides the real reason in the underlying OSStatus, and
                    // "The file couldn't be opened" describes nothing.
                    let wrapped = error as NSError
                    let underlying = wrapped.userInfo[NSUnderlyingErrorKey] as? NSError
                    Log.error("default-browser", [
                        "asked-for": Bundle.main.bundleURL.path,
                        "bundle-id": Bundle.main.bundleIdentifier ?? "nil",
                        "domain": wrapped.domain,
                        "code": wrapped.code,
                        "underlying": underlying.map { "\($0.domain) \($0.code)" } ?? "-",
                        "message": (underlying?.userInfo["_LSErrorMessage"] as? String) ?? error.localizedDescription,
                    ])
                    self.openDefaultBrowserSettings()
                    return
                }
                // http usually follows https as one role; ask separately only
                // if it did not, so the common case shows one panel.
                if self.currentDefaultBrowser() != nil {
                    NSWorkspace.shared.setDefaultApplication(
                        at: Bundle.main.bundleURL, toOpenURLsWithScheme: "http"
                    ) { _ in }
                }
                let previous = self.config.webClickBrowser
                self.recordClickSettings(enabled: true, browser: previous)
                self.hud.flash("⌖ Links now route through Lodestar · unrouted go to "
                    + Self.shortBrowserName(previous), seconds: 4)
                Log.info("default-browser", ["took-over-from": previous])
            }
        }
    }

    /// Give the role back. Routing stops **first** and unconditionally, which
    /// is the half we can guarantee: from that moment every link goes straight
    /// to your browser untouched, whether or not macOS lets us hand the role
    /// back. Then try to hand it back, and take you to the picker if the API
    /// refuses, as it does here.
    private func standDownAsBrowser() {
        let saved = config.webClickBrowser
        recordClickSettings(enabled: false, browser: saved)
        let name = saved.isEmpty ? "your browser" : Self.shortBrowserName(saved)
        Log.info("default-browser", ["stood-down-to": saved.isEmpty ? "-" : saved])
        guard !saved.isEmpty,
              let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: saved) else {
            openDefaultBrowserSettings()
            return
        }
        NSWorkspace.shared.setDefaultApplication(at: application,
                                                 toOpenURLsWithScheme: "https") { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if error != nil {
                    self.openDefaultBrowserSettings()
                    return
                }
                NSWorkspace.shared.setDefaultApplication(at: application,
                                                         toOpenURLsWithScheme: "http") { _ in }
                self.hud.flash("Links go straight to \(name) again", seconds: 4)
            }
        }
    }

    private func recordClickSettings(enabled: Bool, browser: String) {
        var root = (try? Json.parse((try? String(contentsOf: Config.file, encoding: .utf8)) ?? "{}")) ?? [:]
        guard let withFlag = Json.setting(root, path: ["web", "clicks", "enabled"], to: .bool(enabled)),
              let withBrowser = Json.setting(withFlag, path: ["web", "clicks", "browser"],
                                             to: .string(browser)) else {
            Log.error("default-browser", ["write": "web.clicks is not a section"])
            return
        }
        root = withBrowser
        do {
            try Config.write(tree: root)
        } catch {
            Log.error("default-browser", ["write-failed": error.localizedDescription])
            return
        }
        applyConfigReload(successFlash: "✓ config reloaded")
    }

    // MARK: - Config editing (⌘K in the searcher and the web bar)

    /// Every chain bound to an app, shortest first — the card's remove rows.
    private func graphChains(for name: String) -> [[String]] {
        config.graph.chains(toAppNamed: name)
    }

    /// Why a chain can't be added, or nil when it's free. Judged against
    /// the live trie, so sugar keys and merged branches are all visible.
    private func chainProblem(_ letters: [String]) -> String? {
        guard let first = letters.first else { return nil }
        // Empty as of 0.17, so this never fires today. It stays as a guard
        // in case a verb ever moves back onto a letter — which is exactly
        // why the message no longer names particular letters.
        if Config.reservedTopLevel.contains(first) {
            return "\(first.uppercased()) is reserved for a fixed verb"
        }
        for depth in 1...letters.count {
            let prefix = Array(letters[0..<depth])
            let shown = prefix.map { $0.uppercased() }.joined(separator: " ")
            switch config.graph.resolve(prefix) {
            case .leaf(let target):
                return "lode \(shown) is \(target.label)"
            case .deeper:
                if depth == letters.count { return "lode \(shown) leads deeper — add a letter" }
            case .miss:
                return nil
            }
        }
        return nil
    }

    /// "Never save from this app", chosen from a card's panel: written to
    /// the config so the choice survives a restart, the same as any other
    /// deliberate setting.
    private func excludeAppFromClipboard(_ bundleID: String) {
        var root = (try? Json.parse((try? String(contentsOf: Config.file, encoding: .utf8)) ?? "{}")) ?? [:]
        guard let updated = Json.setting(root, path: ["clipboard", "exclude-apps", bundleID.lowercased()],
                                         to: .bool(true)) else { return }
        root = updated
        try? Config.write(tree: root)
        Log.info("clipboard", ["excluded-app": bundleID])
    }

    /// Bind whatever a config line would write. A browser-profile reference
    /// ("brave:xonar") names an entry in the profiles registry rather than an
    /// installed app, so it binds exactly as written; a plain app name is
    /// checked against what is actually installed first. Sending a profile
    /// through the app index instead would miss the exact match, fuzzy-rank
    /// its way to the plain browser, and bind the wrong thing in silence.
    private func addTargetToGraph(_ letters: [String], target: String) -> String? {
        let lowered = target.lowercased()
        guard let browser = ChromiumBrowser.allCases.first(where: {
            lowered.hasPrefix("\($0.rawValue):")
        }) else {
            guard let entry = appIndex.entry(named: target) else {
                return "\(target) is not installed any more"
            }
            return addAppToGraph(letters, entry: entry)
        }
        let key = String(lowered.dropFirst(browser.rawValue.count + 1))
            .trimmingCharacters(in: .whitespaces)
        guard let profile = config.browserProfiles[key], profile.browser == browser else {
            return "\(target) is not a profile you have declared"
        }
        if let problem = chainProblem(letters) { return problem }
        let shown = letters.map { $0.uppercased() }.joined(separator: " ")
        let name = GraphTarget.browserProfile(key: key, profile: profile).label
        return rewriteConfig(flash: "✓ lode \(shown) → \(name)") {
            try GraphJsonEditor.addingPath(letters, target: "\(browser.rawValue):\(key)", in: $0)
        }
    }

    private func addAppToGraph(_ letters: [String], entry: AppIndex.Entry) -> String? {
        if let problem = chainProblem(letters) { return problem }
        let shown = letters.map { $0.uppercased() }.joined(separator: " ")
        return rewriteConfig(flash: "✓ lode \(shown) → \(entry.name)") {
            try GraphJsonEditor.addingPath(letters, target: entry.name, in: $0)
        }
    }

    private func removeChainFromGraph(_ letters: [String]) -> String? {
        let shown = letters.map { $0.uppercased() }.joined(separator: " ")
        return rewriteConfig(flash: "✓ removed lode \(shown)") {
            try GraphJsonEditor.deletingPath(letters, in: $0)
        }
    }

    /// ⌘K in the web bar: a typed destination promoted to a named link. The
    /// URL is stored as typed — the scheme is added when it opens — so this
    /// lands in web.links as the same two lines a hand edit would write.
    private func addWebLink(name: String, url: String, profileKey: String?) -> String? {
        let key = WebJsonEditor.normalizeName(name)
        if let problem = WebJsonEditor.nameProblem(key, url: url, existing: config.webLinks) {
            return problem
        }
        // The flash shows the URL on screen and then is gone; the log line
        // rewriteConfig writes keeps the name only. The config file holds the
        // destination because that is its job — the log is paste-able, and
        // must not become a list of where you go.
        return rewriteConfig(flash: "✓ lode ⏎ \(key) → \(url)", logged: "link \(key)") {
            try WebJsonEditor.addingLink(name: key, url: url, profileKey: profileKey, in: $0)
        }
    }

    private func removeWebLink(name: String) -> String? {
        let key = WebJsonEditor.normalizeName(name)
        return rewriteConfig(flash: "✓ removed \(key)") {
            try WebJsonEditor.removingLink(name: key, in: $0)
        }
    }

    /// The other promotion: not this site by name, but every link that
    /// matches a pattern, wherever it came from.
    private func addWebRoute(pattern: String, profileKey: String) -> String? {
        let key = WebJsonEditor.normalizePattern(pattern)
        if let problem = WebJsonEditor.patternProblem(key, profileKey: profileKey,
                                                      existing: config.webRoutes) {
            return problem
        }
        // A pattern is a host, so it stays out of the log for the same
        // reason a URL does — the profile it chose is the part worth keeping.
        return rewriteConfig(flash: "✓ \(key) → \(profileKey)",
                             logged: "route → \(profileKey)") {
            try WebJsonEditor.addingRoute(pattern: key, profileKey: profileKey, in: $0)
        }
    }

    /// Undoing a route from the card that told you it was there. The pattern
    /// stays out of the log for the same reason a URL does.
    private func removeWebRoute(pattern: String) -> String? {
        let key = WebJsonEditor.normalizePattern(pattern)
        return rewriteConfig(flash: "✓ removed route \(key)", logged: "route removed") {
            try WebJsonEditor.removingRoute(pattern: key, in: $0)
        }
    }

    /// Read-edit-write the config tree, then apply it. The edit is a tree
    /// operation; the canonical emitter owns every byte of formatting.
    /// The HUD confirms with `flash` unless the reload surfaces problems.
    /// `logged` is what the log records — the same as the flash by default,
    /// and something quieter when the flash names a destination.
    private func rewriteConfig(flash: String, logged: String? = nil,
                               edit: ([String: ConfigValue]) throws -> [String: ConfigValue]) -> String? {
        Config.migrateIfNeeded() // an edit is a write; writes happen in the new format
        guard let text = try? String(contentsOf: Config.file, encoding: .utf8),
              let tree = try? Json.parse(text) else {
            return "could not read \(Config.file.lastPathComponent)"
        }
        let updated: [String: ConfigValue]
        do {
            updated = try edit(tree)
        } catch let error as GraphJsonEditor.EditError {
            return error.description
        } catch let error as WebJsonEditor.EditError {
            return error.description
        } catch {
            return "\(error)"
        }
        do {
            try Config.write(tree: updated)
        } catch {
            return "could not write the config: \(error.localizedDescription)"
        }
        Log.info("config-edit", ["edit": logged ?? flash])
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
        recordGraphEpochs(old: config, new: loaded)
        config = loaded
        Keys.apply(overrides: loaded.keyOverrides)
        ActivePolicy.mode = loaded.activeDisplayMode
        engine.config = loaded
        webBar.config = loaded
        updater.enabled = loaded.autoUpdate
        clipboardController.excludedApps = loaded.clipboardExcludedApps
        clipboardController.excludedPatterns = loaded.clipboardExcludePatterns
        clipboardController.maxBytes = loaded.clipboardMaxBytes
        clipboardController.setEnabled(loaded.clipboardEnabled)
        observationStore?.setEnabled(loaded.observationsEnabled)
        if observationStore?.consumeClearRequest() == true {
            observationStore?.clear()
            hud.flash("⌂ observations cleared")
        }
        coach?.enabled = loaded.coachEnabled
        // A config edit changes the world the advisor reasons about —
        // including edits the coach itself just wrote.
        coach?.scheduleRefresh(after: 2)
        #if DEBUG
        armCoachDemoIfRequested()
        #endif
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

    /// Every graph edit is a natural experiment — the only causal data a
    /// single-user, no-A/B design will ever have. The epoch stamp is what
    /// makes it readable as one: learning curves restart at the stamp,
    /// interference on neighbors is measured against it, and a pending
    /// recommendation whose target appears here is marked adopted.
    private func recordGraphEpochs(old: Config, new: Config) {
        guard let store = observationStore else { return }
        let oldLeaves = Dictionary(old.graph.leaves().map {
            (Observations.key($0.chain), $0.target.label)
        }, uniquingKeysWith: { first, _ in first })
        let newLeaves = Dictionary(new.graph.leaves().map {
            (Observations.key($0.chain), $0.target.label)
        }, uniquingKeysWith: { first, _ in first })
        for (key, label) in newLeaves {
            let chain = key.split(separator: " ").map(String.init)
            if oldLeaves[key] == nil {
                store.epochBumped(address: chain, change: "added")
            } else if oldLeaves[key] != label {
                store.epochBumped(address: chain, change: "retargeted")
            }
        }
        for (key, _) in oldLeaves where newLeaves[key] == nil {
            store.epochBumped(address: key.split(separator: " ").map(String.init),
                              change: "removed")
        }
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
            // No app claims .json — TextEdit always opens plain text.
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

    private static let pidFile = Paths.pidFile

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
        Log.info("DUMP v=\(Lodestar.version) focused=\(focused.map { "\($0.id):\($0.appName)" } ?? "none") parked=\(parking.snapshot().keys.sorted()) tracked=\(model.windows.values.filter(\.isAlive).count) searcher=\(searcher.isVisible) webbar=\(webBar.isVisible) engine=\(engine.stateDescription)")
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
      config           print the effective config (defaults + your file)
      config get <path>          read one value, dotted path
      config set <path> <value>  validated write, applied live
      config unset <path>        back to the default
      diagnose         print a support report (paste this into bug reports)
      reset-config     back up the current config, write fresh defaults
      uninstall        remove lodestar (--dry-run to preview, --purge for data)
      schema           print the config JSON Schema
      clipboard clear  erase the clipboard history
      observations         what Lodestar has noticed about how you reach things
      observations engine  the fitted models behind it, working shown
      observations clear   delete everything noticed so far
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
if cliArguments.first == "config" {
    runConfigVerb(Array(cliArguments.dropFirst()))
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
    // Serialized, not described: printing the dictionary emits Swift's debug
    // form, which no editor or agent can parse — and this verb exists to be
    // piped somewhere.
    let schema = ConfigSchema.jsonSchema(for: Config.schema, title: "lodestar configuration")
    guard let data = try? JSONSerialization.data(withJSONObject: schema,
                                                 options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
        FileHandle.standardError.write(Data("✕ could not serialize the schema\n".utf8))
        exit(70)
    }
    print(text)
    exit(0)
}
if cliArguments.contains("observations") {
    runObservations(clear: cliArguments.contains("clear"),
                    engine: cliArguments.contains("engine"))
}
if cliArguments.contains("clipboard") {
    if cliArguments.contains("clear") {
        Log.stdoutEnabled = false
        let store = ClipboardStore()
        store.clearAll()
        // A running instance holds the index in memory; tell it too.
        store.requestClear()
        print("✓ clipboard history cleared")
        exit(0)
    }
    print("usage: lodestar clipboard clear")
    exit(64)
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
#if DEBUG
// Visual harness for the clipboard strip; compiled out of release builds.
if let i = cliArguments.firstIndex(of: "__strip-preview") {
    StripPreview.run(cliArguments.indices.contains(i + 1) ? (Int(cliArguments[i + 1]) ?? 1) : 1)
}
#endif

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
