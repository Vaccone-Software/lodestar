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
    private var draftController: DraftController?
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
    private let walk = WalkController()
    private let meetings = MeetingController()
    private let linkChip = LinkChip()
    private let presenting = Presenting()
    private let control = ControlSocket()
    private let settings = SettingsController()
    private let health = HealthMonitor()

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
        var (loaded, problems) = Config.load()
        // What the browsers actually have joins what the config references,
        // so pickers and most-recent resolution see every real profile.
        loaded.registerDetected(ChromiumProfiles.detected())
        config = loaded
        // Layout first, overrides second: both layers live in Keys, and
        // the config's `keys:` stays the user's last word over either.
        KeyboardLayout.install()
        Keys.apply(overrides: loaded.keyOverrides)
        ActivePolicy.mode = loaded.activeDisplayMode
        // A layout switched at lunch renames the keys by the afternoon:
        // the overlay recomputes the moment the input source changes.
        NotificationCenter.default.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil, queue: .main
        ) { _ in
            KeyboardLayout.install()
        }

        // Stood up here, first thing after the config, and above everything
        // heavy: the model, the index, the clipboard, and the Accessibility
        // guard all come later, and a clicked link must not wait for any of
        // them. Anything that arrived before now goes out immediately.
        installClickHandler()

        model = WindowModel()
        parking = ParkingLot()
        // The serial queue is what takes the AX conversation off the tap's
        // run loop: a wedged app now stalls a retile, never the keyboard.
        layout = LayoutController(model: model, parking: parking,
                                  moveQueue: DispatchQueue(label: "lodestar.moves",
                                                           qos: .userInteractive))
        appIndex = AppIndex()
        store = StateStore()
        observationStore = ObservationStore()
        if observationStore.consumeClearRequest() {
            observationStore.clear()
        } else {
            observationStore.load()
        }
        observationStore.setEnabled(loaded.observationsEnabled)
        observationStore.setHealthEnabled(loaded.observationsHealth)
        layout.onMoves = { [weak self] seconds, members in
            // Only batches big enough to mean anything: a single window's
            // move is noise, and the latency line is for regressions.
            guard members > 0 else { return }
            self?.observationStore?.latency(surface: "retile", seconds: seconds)
        }
        // Month ends arrive without reboots on a machine that only ever
        // sleeps: the archive checks daily, and add-only makes every
        // check but the first of the month nearly free.
        Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) {
            [weak observationStore] _ in
            observationStore?.rollupSoon()
        }
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
        searcher.browserBindings = { [weak self] browser, name in
            guard let self else { return [] }
            return self.config.graph.chains(toBrowser: browser, appNamed: name) { alias in
                self.appIndex.entry(named: alias)?.bundleID == browser.bundleID
            }
        }
        searcher.chainProblem = { [weak self] letters in self?.chainProblem(letters) }
        // No `self? … ??` here: these return nil on SUCCESS, and optional
        // chaining would flatten that nil into the error fallback.
        searcher.addToGraph = { [weak self] letters, entry, profile in
            guard let self else { return "lodestar is shutting down" }
            guard let profile else { return self.addAppToGraph(letters, entry: entry) }
            return self.addTargetToGraph(letters, target: profile.reference)
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
        let scroller = ScrollController(model: model)
        scroller.latency = { [weak self] surface, seconds in
            self?.observationStore?.latency(surface: surface, seconds: seconds)
        }
        let draft = DraftController(speech: AnalyzerSpeechSession())
        draft.flash = { [weak self] text in self?.hud.flash(text) }
        draft.observations = observationStore
        draft.words = config.draftWords
        draft.inputDevice = config.draftInput.isEmpty ? nil : config.draftInput
        draft.playback = PlaybackPause()
        draft.chooseInput = { [weak self] name in
            guard let self else { return }
            let flash = name.map { "✓ microphone: \($0)" } ?? "✓ microphone: system default"
            if let problem = self.rewriteConfig(flash: flash, logged: "draft.input") { tree in
                guard let updated = Json.setting(tree, path: ["draft", "input"],
                                                 to: .string(name ?? "")) else {
                    throw Config.EditError.unparsed("draft.input")
                }
                return updated
            } {
                self.hud.flash("✕ \(problem)")
            }
        }
        // The model is loaded at boot only once the grant exists; the
        // first `lode .` asks for it, and every launch after pays nothing.
        if AVCaptureDevicePermission.granted {
            // After the tap is up: building the audio engine costs the main
            // thread a second, and the first gesture must not wait on it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak draft] in draft?.warmSpeech() }
        }
        draftController = draft
        engine = HotkeyEngine(config: config, actions: actions, hud: hud, searcher: searcher,
                              webBar: webBar, commandsBar: CommandsBarController(),
                              scroller: scroller,
                              select: selectController,
                              clipboard: clipboardController,
                              draft: draft)

        engine.observations = observationStore

        // The hands' pulse: keys from the main tap, clicks and scroll
        // bursts from its own listen-only tap. Gated by both switches —
        // health watches more than Lodestar's gestures, so it answers to
        // its own config line as well as the master.
        health.observations = observationStore
        engine.onHumanKey = { [weak self] backspace in
            self?.health.noteKey(backspace: backspace)
        }
        health.setEnabled(loaded.observationsEnabled && loaded.observationsHealth)

        // The coach: decisions in LodestarCore, this wiring is the coat.
        coach = CoachController()
        coach.observations = observationStore
        coach.enabled = loaded.coachEnabled
        coach.contextInputs = { [weak self] in
            guard let self else { return nil }
            // Observed profile identity → the reference a route would
            // store. The identity IS the reference now; the map survives
            // to fold casing.
            let identityToKey = Dictionary(self.config.browserProfiles.map {
                ($0.value.reference, $0.value.reference)
            }, uniquingKeysWith: { first, _ in first })
            return (observations: self.observationStore.observations,
                    leaves: self.config.graph.leaves().map {
                        Advisor.Leaf(chain: $0.chain, label: $0.target.label,
                                     value: $0.target.configValue)
                    },
                    webRoutes: self.config.webRoutes,
                    profileKeys: identityToKey,
                    meetingsEnabled: self.config.meetingsEnabled,
                    breathPaths: self.store.state.breaths.map(\.path))
        }
        coach.applyEdit = { [weak self] edit in
            guard let self else { return "lodestar is shutting down" }
            switch edit {
            case .bindTarget(let chain, let target):
                return self.addTargetToGraph(chain, target: target)
            case .removeChain(let chain):
                return self.removeChainFromGraph(chain)
            case .supersede(let old, let new, let target):
                return self.supersedeInGraph(old: old, new: new, target: target)
            case .addRoute(let pattern, let profileKey):
                return self.addWebRoute(pattern: pattern, profileKey: profileKey)
            case .enableMeetings:
                // Exactly one config line, honoring the coach's contract.
                // The meetings controller notices enabled-but-unauthorized
                // on the reload and runs its own prime-then-prompt.
                return self.setMeetingsEnabled(true)
            case .composeBreath(let apps, let path):
                // State, not config: the pair arranges side by side and
                // the layout saves at the address. The flash it earns is
                // its own — nothing here reloads the config.
                return self.actions.composeBreath(apps: apps, path: path)
            }
        }
        // Everything the engine, the glass, and the coach say to each other
        // is wired in `SurfaceWiring`, once, with the scenario harness on
        // it. Every voice on the floor shares the lode-lode grammar, so the
        // floor has one owner at a time: walk, then meeting, then the link
        // chip, then the coach. An assent can only ever mean one thing.
        SurfaceWiring.wire(engine: engine, hud: hud, coach: coach, voices: [
            Voice(assent: { [weak self] in
                      guard let self, self.walk.cardVisible else { return false }
                      self.walk.assent()
                      return true
                  },
                  dismiss: { [weak self] in self?.walk.pass() ?? false }),
            Voice(assent: { [weak self] in self?.meetings.join() ?? false },
                  dismiss: { [weak self] in self?.meetings.dismiss() ?? false }),
            Voice(assent: { [weak self] in self?.linkChip.take() ?? false },
                  dismiss: { [weak self] in self?.linkChip.dismiss() ?? false }),
        ])
        coach.standingSinceFor = { [weak self] id in
            self?.store.coachStandingSince(id) ?? Date()
        }
        // A link you just clicked outranks a suggestion about links in
        // general: the chip is answering a thing the hand did seconds ago,
        // and the coach can wait the minute out.
        //
        // Both also yield to a call. The rule is that Lodestar holds what
        // it *initiates* and never what you asked for: an offer waits, a
        // placement you set in motion by clicking a link still happens, and
        // the meeting chip itself is exempt because it is the one surface
        // that is about the meeting.
        coach.suppressed = { [weak self] in
            guard let self else { return false }
            return self.walk.isUp || self.meetings.chipVisible || self.linkChip.isUp
                || self.presenting.isOn
        }
        meetings.suppressed = { [weak self] in self?.walk.isUp ?? false }
        linkChip.suppressed = { [weak self] in
            guard let self else { return false }
            return self.walk.isUp || self.meetings.chipVisible || self.presenting.isOn
        }
        presenting.meetingInProgress = { [weak self] in self?.meetings.inProgress ?? false }
        // Suppression only gates what has not been drawn yet. A chip already
        // standing when the call starts has to be told to go, or the one
        // case this exists for — you join, and the suggestion from four
        // minutes ago is still sitting on the shared screen — is the one it
        // misses. Unrecorded on purpose: nobody declined anything.
        presenting.onChange = { [weak self] on in
            guard on, let self else { return }
            self.coach.surfaceClaimed()
            self.linkChip.hide()
        }
        presenting.start()
        // The coach and the link chip live on separate panels, so a coach
        // chip already standing has to be told to go — the same debt the
        // meeting chip pays through `onChipShown`.
        linkChip.onShown = { [weak self] in self?.coach.surfaceClaimed() }
        actions.onLinkHeld = { [weak self] target in
            guard let self else { return }
            // Bound per showing, because the destination is per link.
            self.linkChip.summon = { [weak self] in
                self?.actions?.summon(target, beside: false, via: .other)
            }
            self.linkChip.show(destination: target.label,
                               icon: self.icon(for: target))
        }
        actions.onLinkSpent = { [weak self] in self?.linkChip.hide() }
        engine.walkSignal = { [weak self] signal in self?.walk.notice(signal) }
        actions.walkPick = { [weak self] in self?.walk.notice(.launcherPick) }
        actions.coachBoundary = { [weak self] app in self?.coach.noteBoundary(app: app) }
        actions.coachWebOpen = { [weak self] host in self?.coach.noteWebOpen(host: host) }
        // First pass once the boot dust settles; boundaries keep it fresh.
        coach.scheduleRefresh(after: 120)
        #if DEBUG
        armCoachDemoIfRequested()
        #endif

        // Opened last, after every piece a verb can reach exists. The
        // handler is built per request from the live references rather than
        // captured once, so a config reload is visible to the next verb.
        control.handle = { [weak self] arguments in
            guard let self, self.actions != nil else {
                return ["ok": false, "error": "lodestar is still starting up"]
            }
            return ControlVerbs(actions: self.actions, appIndex: self.appIndex,
                                model: self.model, layout: self.layout,
                                parking: self.parking,
                                config: { self.config },
                                mostRecentProfile: { self.mostRecentBrowserProfile() },
                                presenting: { self.presenting.isOn },
                                draft: { self.draftController }).run(arguments)
        }
        control.start()
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
        // Browser-role bookkeeping belongs to the bundle that can actually
        // hold the role. A `swift build` binary is not registered with
        // LaunchServices and will never be handed a link, but it still asks
        // "who answers for https?" and gets the *installed* app back — so it
        // sees a stranger holding the role, faithfully writes that stranger
        // down as your browser, and the stranger is us. That one dev-run
        // write is what put a loop in a real config. `reconcileLoginItem`
        // already refuses to touch the LaunchAgent for the same reason.
        if isInstalledBundle {
            rememberDefaultBrowser()
            adoptBrowserRoleIfNeeded()
            confirmClickRoutingHealthy()
        } else {
            Log.info("click", ["browser-role": "skipped — not running from the app bundle"])
        }
        installWalk()
        installMeetings()
        installSettings()

        guard Permissions.isTrusted else {
            // A freshly installed bundle has its own TCC identity. Prompt,
            // then wake up on our own the moment the grant lands — no
            // relaunch dance.
            Log.error("not trusted for Accessibility — waiting for the grant")
            // The walk's door asks for this, with a button and instructions
            // that stay on screen beside the settings pane. Prompting here
            // too would race it, so the bare prompt is only for the boot
            // the walk is not coming to: a finished walk on a machine whose
            // grant was later revoked.
            if walk.isUp == false, store.walkCompletedVersion != nil {
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
        for warning in [store.bootWarning, clipboardController?.bootWarning].compactMap({ $0 }) {
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
        // A draft still open keeps its text on the pasteboard, as every
        // other exit does.
        draftController?.cancel(reason: "quit")
        // The door shuts first. Unparking below is seconds of AX work, and
        // a verb accepted during it would be answered by an instance on its
        // way out — worse than being told nobody is home, which is what a
        // closed socket says.
        control.stop()
        presenting.stop()
        // State first, unparking second. Restoring is unbounded AX work —
        // a second per unresponsive app — and a successor process that
        // starts reading while we are still in the middle of it must find
        // a state file that is already complete. The second save records
        // the emptied parking map when the restore does finish.
        store?.save()
        health.flush()
        observationStore?.flush()
        Log.info("terminating: restoring parked windows")
        actions?.restoreAllParked()
        store?.save() // flush any coalesced write before the process dies
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
        menu.addItem(makeItem("How Lodestar Works…", #selector(showWalk), key: ""))
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
        // Verbs and state machines only. Preferences live in Settings, and
        // the file reloads itself on save — the menu carries nothing a
        // window or a watcher already does.
        menu.addItem(makeItem("Settings…", #selector(openSettingsWindow), key: ""))
        menu.addItem(makeItem("Edit Config…", #selector(editConfig), key: ""))
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
            // A profile binding is an address for its browser's row: the
            // chip teaches the shortest way to some window of the app.
            let key: String
            switch target {
            case .app(let name): key = name.lowercased()
            case .browserProfile(let profile): key = profile.browser.appName.lowercased()
            }
            let address = chain.map { $0.uppercased() }.joined(separator: " ")
            // Shortest chain wins; ties break on the sorted walk, so the
            // chip an app shows is stable across launches.
            if map[key].map({ $0.count > address.count }) ?? true {
                map[key] = address
            }
        }
        graphAddressByApp = map
    }

    // MARK: - The walk

    private func installWalk() {
        walk.config = config
        walk.acceptGraph = { [weak self] proposals in
            self?.acceptStarterGraph(proposals)
        }
        walk.persistStep = { [weak self] step in self?.store.setWalkStep(step) }
        walk.markCompleted = { [weak self] in
            self?.store.markWalkCompleted(version: Lodestar.version)
        }

        // Once, until it is finished: an unfinished walk resumes on the
        // next boot rather than restarting, and a completed one never comes
        // back on its own — only through the menu. Deliberately not keyed
        // to the old deck's flag: everyone sees the walk once, because what
        // the deck taught was not this. Suppressed for the boot right after
        // an update, which arrives while you are idle: a launch that opens
        // a tutorial over whatever you were doing, because a version number
        // changed rather than because anybody asked, is the wrong surprise.
        guard store.walkCompletedVersion == nil, !updater.justUpdated else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.showWalk()
        }
    }

    private func installMeetings() {
        meetings.observations = observationStore
        meetings.flash = { [weak self] text in self?.hud.flash(text, seconds: 8) }
        meetings.onChipShown = { [weak self] in self?.coach.surfaceClaimed() }
        meetings.openWeb = { [weak self] url, profile in
            self?.actions.openWeb(url: url, profile: profile, beside: false)
        }
        meetings.resolveWeb = { [weak self] url in
            guard let self else { return nil }
            let context = WebContext(config: self.config,
                                     mostRecent: self.mostRecentBrowserProfile())
            let resolution = context.resolve(pinned: nil, routedOn: url)
            return (resolution.profile, resolution.source.label)
        }
        meetings.setEnabled = { [weak self] enabled in self?.setMeetingsEnabled(enabled) }
        meetings.loadSpent = { [weak self] in self?.store.meetingSpent ?? [] }
        meetings.saveSpent = { [weak self] spent in self?.store.setMeetingSpent(spent) }
        meetings.config = config
    }

    /// The one config line both doors write. The controller reconciles
    /// intent with authorization on the reload this triggers.
    private func setMeetingsEnabled(_ enabled: Bool) -> String? {
        rewriteConfig(flash: enabled ? "✓ meetings on" : "✓ meetings off",
                      logged: "meetings.enabled \(enabled)") { tree in
            guard let updated = Json.setting(tree, path: ["meetings", "enabled"],
                                             to: .bool(enabled)) else {
                throw Config.EditError.unparsed("meetings.enabled")
            }
            return updated
        }
    }

    private func installSettings() {
        settings.config = config
        settings.apply = { [weak self] dottedPath, value in
            guard let self else { return "lodestar is shutting down" }
            // The clicks toggle is a state machine wearing a switch:
            // turning it on has to *take* the browser role, and off has
            // to give it back — the same doors the menu item opens. A raw
            // config write here would claim a role macOS never granted.
            // Only when the role already matches is this the documented
            // pass-through switch, which is an ordinary write.
            if dottedPath == "web.clicks.enabled", let wanted = value.bool,
               wanted != self.holdsBrowserRole() {
                wanted ? self.becomeDefaultBrowser() : self.standDownAsBrowser()
                // When macOS sends the user to its picker instead, nothing
                // was written — re-render so the switch shows reality, not
                // the click.
                self.settings.config = self.config
                return nil
            }
            let path = dottedPath.split(separator: ".").map(String.init)
            return self.rewriteConfig(flash: "✓ \(dottedPath)",
                                      logged: "settings \(dottedPath)") { tree in
                guard let updated = Json.setting(tree, path: path, to: value) else {
                    throw Config.EditError.unparsed(dottedPath)
                }
                return updated
            }
        }
        settings.applyEntries = { [weak self] removals, sets in
            guard let self else { return "lodestar is shutting down" }
            // The flash and the log name the table, never the entry: a
            // route pattern or a link's key is the user's business, and
            // the log is paste-able.
            let tables = Set((removals + sets.map(\.0)).map {
                $0.dropLast().joined(separator: ".")
            }).sorted().joined(separator: " ")
            return self.rewriteConfig(flash: "✓ \(tables)",
                                      logged: "settings \(tables)") { tree in
                var out = tree
                for path in removals { out = Json.removingEntry(out, path: path) }
                for (path, value) in sets {
                    guard let updated = Json.settingEntry(out, path: path, to: value) else {
                        throw Config.EditError.unparsed(path.dropLast().joined(separator: "."))
                    }
                    out = updated
                }
                return out
            }
        }
        settings.machineState = { [weak self] in
            var state = SettingsModel.MachineState()
            state.inputDevices = AudioInput.inputDevices().map(\.name)
            state.defaultInput = AudioInput.defaultInputName
            state.accessibility = Permissions.isTrusted ? "Granted" : "Not granted"
            state.screenRecording = CGPreflightScreenCaptureAccess()
                ? "Granted" : "Not asked yet"
            state.calendars = {
                switch self?.meetings.authorization {
                case .some(let status):
                    if #available(macOS 14.0, *), status == .fullAccess { return "Granted" }
                    if status == .authorized { return "Granted" }
                    if status == .notDetermined { return "Not asked yet" }
                    return "Denied"
                case nil: return "unknown"
                }
            }()
            state.browserRole = (self?.holdsBrowserRole() ?? false)
                ? "Lodestar holds the role now." : "Your browser holds the role."
            if let saved = self?.config.webClickBrowser, !saved.isEmpty {
                let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: saved)
                    .map { FileManager.default.displayName(atPath: $0.path)
                        .replacingOccurrences(of: ".app", with: "") }
                state.savedBrowser = name ?? saved
                state.savedBrowserID = saved
            }
            var detected: [SettingsModel.DetectedProfile] = []
            for browser in ChromiumBrowser.allCases {
                for name in ChromiumProfiles.displayNames(for: browser) {
                    detected.append(SettingsModel.DetectedProfile(
                        browser: browser.rawValue, browserLabel: browser.label, name: name))
                }
            }
            state.detectedProfiles = detected
            return state
        }
        settings.problems = {
            let (loaded, loadProblems) = Config.load()
            return loadProblems + ConfigDoctor.groundTruthProblems(loaded)
        }
        settings.appDisplayName = { bundleID in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            else { return nil }
            return FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        }
        settings.calendarChoices = { [weak self] in
            self?.meetings.calendarNames() ?? []
        }
        settings.appChoices = {
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { app in
                    guard let name = app.localizedName, let id = app.bundleIdentifier
                    else { return nil }
                    return (name: name, bundleID: id)
                }
                .sorted { $0.name < $1.name }
        }
        engine.onOpenSettings = { [weak self] in self?.settings.toggle() }
    }

    @objc private func openSettingsWindow() {
        settings.open()
    }

    @objc private func showWalk() {
        walk.config = config
        let resume = store.walkCompletedVersion == nil ? store.walkStep : nil
        walk.show(resumeAt: resume)
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
        // Same lazy shape as `observe`, and for the same reason: this is
        // installed before the model, the layout, or Accessibility exist,
        // so a link that arrives during boot simply settles nowhere rather
        // than waiting for a world that is not up yet.
        handler.arrived = { [weak self] target in
            self?.actions?.linkArrived(target)
        }
        clickHandler = handler
        if !pendingClicks.isEmpty {
            let queued = pendingClicks
            pendingClicks = []
            handler.open(queued)
        }
    }

    /// The app a link target wears, for the chip. A profile is still the
    /// browser's icon — Chromium does not give one per profile, and the
    /// chip already says which profile in words.
    private func icon(for target: GraphTarget) -> NSImage? {
        switch target {
        case .app(let name):
            return actions?.icon(forAppNamed: name)
        case .browserProfile(let profile):
            return actions?.icon(forAppNamed: profile.browser.appName)
        }
    }

    /// Prove the click path works, or say nothing and let the watchdog put the
    /// last build back.
    ///
    /// Two questions, deliberately no longer asked as one. "Can this build
    /// route?" is about the code, and a build that cannot is exactly what the
    /// watchdog exists to roll back. "Is there a browser on file?" is about
    /// your config, and answering it with a rollback would be a trap: the
    /// config comes forward untouched into the replacement, so every release
    /// from then on would install, fail its handover, and be rolled back —
    /// once a day, forever. That is precisely the loop 0.18.0 fixed on the
    /// tombstone path, and it must not be reintroduced here.
    ///
    /// Nothing is stranded by the softer answer, either: a browser that is
    /// missing, uninstalled, or refused for naming us falls through to
    /// discovery and then Safari, so the link still opens. It is a warning,
    /// and it is raised *after* the marker is written so a rollback can never
    /// hinge on it.
    private func confirmClickRoutingHealthy() {
        guard config.webHandleClicks else { return }
        guard ClickRouter.selfCheck() else {
            Log.error("click", ["self-check": "failed", "router": false])
            hud.flash("⚠ Lodestar is your browser but cannot route links", seconds: 8)
            return
        }
        updater.confirmRoutingHealthy()
        Log.info("click", ["self-check": "ok"])

        let onFile = !config.webClickBrowser.isEmpty
            && NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: config.webClickBrowser) != nil
        if !onFile {
            Log.error("click", ["browser": config.webClickBrowser.isEmpty
                                    ? "none on file — falling back to discovery"
                                    : "not installed: \(config.webClickBrowser)"])
            hud.flash("⚠ Lodestar is your browser but no browser is set — see web.clicks.browser",
                      seconds: 8)
        }
    }

    /// Whether this process is the app bundle macOS can hand links to.
    /// False for a `swift build` binary, whose `Bundle.main` has no
    /// identifier at all — see `Lodestar.bundleID` for what that cost.
    private var isInstalledBundle: Bool {
        Bundle.main.bundleIdentifier == Lodestar.bundleID
    }

    /// The bundle id of whatever answers for https right now, us included.
    private func httpsHandler() -> String? {
        handler(forScheme: "https")
    }

    private func handler(forScheme scheme: String) -> String? {
        guard let probe = URL(string: "\(scheme)://example.com"),
              let application = NSWorkspace.shared.urlForApplication(toOpen: probe) else {
            return nil
        }
        return Bundle(url: application)?.bundleIdentifier
    }

    /// Whether macOS is handing links to us at this moment. Asked rather than
    /// remembered: the role can change in System Settings without telling us,
    /// and a menu that reports config instead of reality lies.
    private func holdsBrowserRole() -> Bool {
        httpsHandler() == Lodestar.bundleID
    }

    /// The browser to give the role back to — the question you can only ask
    /// *before* taking it, because afterwards the answer is us.
    private func currentDefaultBrowser() -> String? {
        guard let handler = httpsHandler(),
              handler != Lodestar.bundleID else { return nil }
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
              handler != Lodestar.bundleID,
              handler != config.webClickBrowser else { return }
        Log.info("click", ["remembered-browser": handler])
        persistClickBrowser(handler)
    }

    /// A browser Lodestar is willing to write down.
    ///
    /// Guarded at the write rather than at each caller, because the callers
    /// are exactly where this went wrong: `rememberDefaultBrowser` weighed
    /// its candidate against `Bundle.main.bundleIdentifier`, nil outside a
    /// .app, and let our own id straight through. There is no reading of
    /// "hand unrouted links to Lodestar" that is not a loop, so this is the
    /// last place to stop one before the file remembers it and every boot
    /// after inherits it. Nil is written as "nothing recorded", which the
    /// click path already survives — discovery, then Safari.
    private func writableClickBrowser(_ bundleID: String) -> String? {
        guard bundleID != Lodestar.bundleID else {
            Log.error("click", ["refused-browser": bundleID,
                                "why": "that is Lodestar — clicked links would loop back to us"])
            return nil
        }
        return bundleID
    }

    /// A one-key write: no reload, no flash. Observing which browser you use is
    /// not an event worth announcing.
    private func persistClickBrowser(_ bundleID: String) {
        guard let bundleID = writableClickBrowser(bundleID) else { return }
        config.webClickBrowser = bundleID
        do {
            try Config.edit { tree in
                guard let updated = Json.setting(tree, path: ["web", "clicks", "browser"],
                                                 to: .string(bundleID)) else {
                    throw Config.EditError.unparsed("web.clicks is not a section")
                }
                return updated
            }
        } catch {
            Log.error("default-browser", ["persist-failed": "\(error)"])
        }
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
                // http usually follows https as one role; ask *http itself*
                // and claim separately only if it did not follow, so the
                // common case shows one panel. Probing https here answered
                // "us" the moment the claim above landed, which skipped the
                // http claim exactly in the case it exists for.
                if let http = self.handler(forScheme: "http"),
                   http != Lodestar.bundleID {
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
        // The switch is still worth recording even when the browser is not:
        // standing down with no browser on file is a real, handled state,
        // and standing down while recording ourselves is not.
        let browser = writableClickBrowser(browser) ?? ""
        do {
            try Config.edit { tree in
                guard let withFlag = Json.setting(tree, path: ["web", "clicks", "enabled"],
                                                  to: .bool(enabled)),
                      let withBrowser = Json.setting(withFlag, path: ["web", "clicks", "browser"],
                                                     to: .string(browser)) else {
                    throw Config.EditError.unparsed("web.clicks is not a section")
                }
                return withBrowser
            }
        } catch {
            Log.error("default-browser", ["write-failed": "\(error)"])
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
        do {
            try Config.edit { tree in
                guard let updated = Json.setting(tree,
                                                 path: ["clipboard", "exclude-apps", bundleID.lowercased()],
                                                 to: .bool(true)) else {
                    throw Config.EditError.unparsed("clipboard.exclude-apps is not a section")
                }
                return updated
            }
        } catch {
            Log.error("clipboard", ["exclude-failed": "\(error)"])
            hud.flash("⚠ could not save that — \(error)", seconds: 5)
            return
        }
        Log.info("clipboard", ["excluded-app": bundleID])
    }

    /// Bind whatever a config line would write. A browser-profile reference
    /// ("brave:xonar") names an entry in the profiles registry rather than an
    /// installed app, so it binds exactly as written; a plain app name is
    /// checked against what is actually installed first. Sending a profile
    /// through the app index instead would miss the exact match, fuzzy-rank
    /// its way to the plain browser, and bind the wrong thing in silence.
    /// What a recommendation's `target` string means on this machine: the
    /// value a config line would carry, and the name a person would
    /// recognise — or the problem to report instead.
    private enum ResolvedTarget {
        case ok(value: String, label: String)
        case problem(String)
    }

    private func resolveGraphTarget(_ target: String) -> ResolvedTarget {
        guard let parsed = BrowserProfile.parse(reference: target) else {
            guard let entry = appIndex.entry(named: target) else {
                return .problem("\(target) is not installed any more")
            }
            return .ok(value: entry.name, label: entry.name)
        }
        // Detection is the authority; the merged map holds it after load.
        guard let profile = config.browserProfiles[parsed.canonical] else {
            return .problem("\(parsed.browser.label) has no profile named '\(parsed.display)'")
        }
        return .ok(value: profile.reference,
                   label: GraphTarget.browserProfile(profile).label)
    }

    private func addTargetToGraph(_ letters: [String], target: String) -> String? {
        switch resolveGraphTarget(target) {
        case .problem(let problem): return problem
        case .ok(let value, let label):
            if let problem = chainProblem(letters) { return problem }
            let shown = letters.map { $0.uppercased() }.joined(separator: " ")
            return rewriteConfig(flash: "✓ lode \(shown) → \(label)") {
                try GraphJsonEditor.addingPath(letters, target: value, in: $0)
            }
        }
    }

    private func addAppToGraph(_ letters: [String], entry: AppIndex.Entry) -> String? {
        if let problem = chainProblem(letters) { return problem }
        let shown = letters.map { $0.uppercased() }.joined(separator: " ")
        return rewriteConfig(flash: "✓ lode \(shown) → \(entry.name)") {
            try GraphJsonEditor.addingPath(letters, target: entry.name, in: $0)
        }
    }

    /// Bind the new address and drop the old one in a single write, so a
    /// failure between them cannot leave the graph holding both or
    /// neither. The flash names the move rather than the addition: what
    /// the user agreed to was a replacement.
    private func supersedeInGraph(old: [String], new: [String], target: String) -> String? {
        let value: String, label: String
        switch resolveGraphTarget(target) {
        case .problem(let problem): return problem
        case .ok(let resolved, let name): (value, label) = (resolved, name)
        }
        if let problem = chainProblem(new) { return problem }
        let from = old.map { $0.uppercased() }.joined(separator: " ")
        let to = new.map { $0.uppercased() }.joined(separator: " ")
        return rewriteConfig(flash: "✓ lode \(from) → lode \(to) · \(label)") {
            // Old out first. A replacement is not required to be shorter,
            // so the two addresses can share a prefix — superseding X with
            // X Y, say — and adding first would then bind the new address
            // inside a branch the delete is about to take with it. Config
            // .edit runs the whole transform before it writes anything, so
            // a throw between the two leaves the file untouched.
            let pruned = try GraphJsonEditor.deletingPath(old, in: $0)
            return try GraphJsonEditor.addingPath(new, target: value, in: pruned)
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
        do {
            try Config.edit(edit)
        } catch let error as GraphJsonEditor.EditError {
            return error.description
        } catch let error as WebJsonEditor.EditError {
            return error.description
        } catch let error as Config.EditError {
            return error.description
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
        var (loaded, loadProblems) = Config.load()
        // Re-read Local State rather than re-serve the boot snapshot: a
        // reload is the one moment the world is being asked again, and the
        // doctor's ground truth below must not grade against stale caches.
        ChromiumProfiles.invalidate()
        let problems = loadProblems
            + ConfigDoctor.groundTruthProblems(loaded)
            + ConfigDoctor.semanticWarnings(loaded, appIndex: appIndex)
        loaded.registerDetected(ChromiumProfiles.detected())
        recordGraphEpochs(old: config, new: loaded, problems: loadProblems)
        config = loaded
        Keys.apply(overrides: loaded.keyOverrides)
        ActivePolicy.mode = loaded.activeDisplayMode
        engine.config = loaded
        webBar.config = loaded
        updater.enabled = loaded.autoUpdate
        clipboardController.excludedApps = loaded.clipboardExcludedApps
        clipboardController.excludedPatterns = loaded.clipboardExcludePatterns
        draftController?.words = loaded.draftWords
        draftController?.inputDevice = loaded.draftInput.isEmpty ? nil : loaded.draftInput
        clipboardController.maxBytes = loaded.clipboardMaxBytes
        clipboardController.setEnabled(loaded.clipboardEnabled)
        observationStore?.setEnabled(loaded.observationsEnabled)
        observationStore?.setHealthEnabled(loaded.observationsHealth)
        health.setEnabled(loaded.observationsEnabled && loaded.observationsHealth)
        if observationStore?.consumeClearRequest() == true {
            observationStore?.clear()
            hud.flash("⌂ observations cleared")
        }
        coach?.enabled = loaded.coachEnabled
        meetings.config = loaded
        settings.config = loaded
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
            "problems": problems.count,
            "start-at-login": loaded.startAtLogin,
        ])
    }

    /// The last graph whose parse had no problems — the only baseline an
    /// epoch diff may run against. Seeded from the pre-reload config on
    /// the first diff, then advanced only by clean parses.
    private var epochGraphBaseline: [String: String]?

    /// Every graph edit is a natural experiment — the only causal data a
    /// single-user, no-A/B design will ever have. The epoch stamp is what
    /// makes it readable as one: learning curves restart at the stamp,
    /// interference on neighbors is measured against it, and a pending
    /// recommendation whose target appears here is marked adopted.
    ///
    /// The diff runs against the last *cleanly parsed* graph: a load whose
    /// problems dropped leaves is a wounded read, not an edit. Diffing one
    /// stamped three false removals the night an old binary met a new
    /// config format — and every false epoch restarts real learning
    /// curves, so a problem parse holds the baseline and says so.
    private func recordGraphEpochs(old: Config, new: Config, problems: [String]) {
        guard let store = observationStore else { return }
        func leafMap(_ config: Config) -> [String: String] {
            Dictionary(config.graph.leaves().map {
                (Observations.key($0.chain), $0.target.label)
            }, uniquingKeysWith: { first, _ in first })
        }
        let oldLeaves = epochGraphBaseline ?? leafMap(old)
        // A whole-file parse failure is the deepest wound of all: the "new"
        // graph is the empty default, and diffing against it would stamp
        // every binding removed the moment a typo lands.
        guard !problems.contains(where: {
            $0.hasPrefix("graph") || $0.hasPrefix("config parse failed")
        }) else {
            epochGraphBaseline = oldLeaves
            Log.info("config-epochs", ["held": "graph parse had problems"])
            return
        }
        let newLeaves = leafMap(new)
        epochGraphBaseline = newLeaves
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
            guard let self else { return }
            // Watching is simply how the config works now — but a file
            // that does not parse is a save in progress or a mistake, and
            // either way the running config is the last good one. Say so
            // once and keep it.
            if let contents = try? String(contentsOf: Config.file, encoding: .utf8),
               (try? Json.parse(contents)) == nil {
                Log.error("config-autoreload: the file does not parse — keeping the last good config")
                self.hud.flash("Config not applied: the file does not parse. Fix it and save again.",
                               seconds: 6)
                self.updateConfigWatcher() // re-arm; the fix deserves a reload too
                return
            }
            Log.info("config-autoreload", ["trigger": "file-saved"])
            self.reloadConfig() // re-arms the watcher (editors save atomically via rename)
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
            // Serialized, not interpolated. The path comes from wherever
            // the app was installed, and an `&` or `<` anywhere in it made
            // the XML malformed — launchd then refused the job, so start
            // at login quietly stopped working while the log said
            // "installed".
            let job: [String: Any] = [
                "Label": "com.vaccone.lodestar",
                "ProgramArguments": ["\(bundlePath)/Contents/MacOS/lodestar"],
                "RunAtLoad": true,
                "KeepAlive": ["SuccessfulExit": false],
                "ThrottleInterval": 10,
            ]
            guard let plist = try? PropertyListSerialization.data(
                fromPropertyList: job, format: .xml, options: 0
            ) else {
                Log.error("login-item", ["error": "could not build the job description"])
                return
            }
            if (try? Data(contentsOf: agent)) != plist {
                do {
                    try plist.write(to: agent, options: .atomic)
                    Log.info("login-item", ["action": exists ? "updated" : "installed"])
                } catch {
                    Log.error("login-item", ["write-failed": "\(error)"])
                }
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
            // Wait for it to actually go, rather than for a number that
            // was never long enough: the outgoing process restores parked
            // windows on its way out, which is unbounded AX work, so a
            // fixed 600ms routinely left two instances holding state.json,
            // observations.json and events.jsonl at once — last writer
            // wins, and a coalesced write is simply lost.
            let deadline = Date().addingTimeInterval(5)
            while kill(oldPid, 0) == 0, Date() < deadline {
                usleep(25_000)
            }
            if kill(oldPid, 0) == 0 {
                Log.error("previous lodestar (pid \(oldPid)) did not exit in 5s — continuing anyway")
            } else {
                Log.info("previous lodestar exited; taking over")
            }
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
        // commands bar visibility is engine-owned; log via its trace lines
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

    Scripted verbs — these drive the running instance:

      go <chain|app> [--beside]   summon, exactly as the keys would
      web <url> [--profile b:N]   open a destination in a profile
      layout undo|redo|flip|fill|index <n>
      breath <address>            restore; save/delete <address> also
      state                       what is on screen, as JSON, parked included
      draft speak|edit|close|commit|state
      draft type <text> · key <name> [--shift] · audio <file>
                                  drive the draft; audio feeds a file in place of the mic

    Add --json to any of them for the whole answer rather than a line.

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
// The scripted verbs, matched on the *first* word rather than by searching
// the whole line the way the older commands do. `lodestar go check` must be
// a summon and not a config check, and a url is allowed to contain any word
// this file has ever used.
if let first = cliArguments.first, ControlClient.verbs.contains(first) {
    ControlClient.run(Array(cliArguments))
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
