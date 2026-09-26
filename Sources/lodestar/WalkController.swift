import AppKit
import LodestarCore

/// The first launch's two surfaces. Neither decides anything — `Walk`
/// (LodestarCore) owns the sequence; these draw it and translate clicks.
///
/// **The door** (act one) is a centered card, mouse-first and keyable,
/// because before the Accessibility grant there is no event tap and AppKit
/// is all there is. It opens on the welcome, which asks what the person
/// would like to do first, Write, Switch, Keep or Speak, and then asks for
/// exactly one permission, in words that name what that door needs it for.
/// While the user is inside System Settings it parks at the screen edge and
/// *stays visible*, so the instructions are never left behind.
///
/// **The companion** (act two) is never key and swallows nothing. It issues
/// one instruction and watches the engine for the real gesture happening in
/// the real world; focus loss is not a failure mode, it is the point — the
/// user is actually using their machine, and the card narrates. The whole
/// class of "the tutorial ate my keyboard" bugs is structurally impossible
/// on a surface that owns no keys.
final class WalkController: NSObject {
    var config = Config()
    /// Accept the drafted graph. An error string, or nil on success.
    var acceptGraph: ([StarterGraph.Proposal]) -> String? = { _ in "the graph is unavailable" }
    var persistStep: ((Int) -> Void)?
    var persistDoor: ((Walk.Door) -> Void)?
    var markCompleted: (() -> Void)?
    /// The door chosen and the grant in hand: whatever the door's walk
    /// needs switched on before its first step (the editor, for Write).
    var openDoor: ((Walk.Door) -> Void)?
    /// The engine the Write walk offers after its first fix, when this Mac
    /// can run something closer than spelling, and how to name it.
    var grammarOffer: () -> String? = { nil }
    var describeEngine: (String) -> String = { $0 }
    /// Assent on the grammar step: the editor reads with this engine.
    var chooseEngine: ((String) -> Void)?
    /// The curriculum's answers, wired to its record.
    var lessonCompleted: ((Curriculum.Lesson) -> Void)?
    var lessonPassed: ((Curriculum.Lesson) -> Void)?
    /// The editor lesson's assent: the editor turned on, which asks its
    /// own consent before it reads anything.
    var enableEditor: (() -> Void)?

    private var walk: Walk?
    /// The door the welcome has selected. Nothing is selected until the
    /// person chooses: the app never learns it from the download.
    private var chosen: Walk.Door?
    /// A lesson standing on the card, after the walk is done. The card is
    /// the same one; the sequence is the curriculum's.
    private var lesson: Curriculum.Lesson?
    private var lessonDone = false
    private var lessonHide: DispatchWorkItem?

    // MARK: - Windows

    /// The door: keyable on purpose — pre-grant, AppKit key handling is
    /// the only keyboard there is.
    private let door = KeyablePanel(
        contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let doorRoot = NSView()

    /// The companion: a floating glass card that can never become key.
    private let card = Glass.makePanel(level: .floating)
    private let cardRoot = NSView()

    private static let welcomeWidth: CGFloat = 660
    private static let doorWidth: CGFloat = 480
    private static let cardWidth: CGFloat = 340
    private static let inset: CGFloat = 26
    private static let cardText: CGFloat = cardWidth - 40

    /// Which of the door's pages is showing.
    private enum Page { case welcome, permission, waiting }
    private var page: Page = .welcome

    // MARK: - Grant flow

    /// macOS shows its Accessibility prompt once per app. After that the
    /// only way through is the settings pane, so the button offers that.
    private var prompted = false
    private var awaitingGrant = false
    /// Whether the pane on screen is one this asking opened, judged by
    /// whether System Settings was already running when we asked — a window
    /// somebody was already working in is not ours to close.
    private var settingsIsOurs = false
    private static let settingsBundleID = "com.apple.systempreferences"
    private var sawSettings = false
    private var waited: Double = 0
    private var trustPoll: Timer?
    private var noteCopied = false

    #if DEBUG
    /// The door's untrusted copy, on a machine that granted long ago — the
    /// one state a preview cannot reach by looking.
    private var forceUntrusted = false
    private var forceStandardAccount = false
    #endif

    /// The one state that cannot be reached by looking: a machine that has
    /// not granted Accessibility. Debug builds can be told to believe it.
    private var trusted: Bool {
        #if DEBUG
        if forceUntrusted { return false }
        if ProcessInfo.processInfo.environment["LODESTAR_UNTRUSTED"] != nil { return false }
        #endif
        return Permissions.isTrusted
    }

    private var administrator: Bool {
        #if DEBUG
        if forceStandardAccount { return false }
        #endif
        return Permissions.isAdministrator
    }

    override init() {
        super.init()
        door.level = .modalPanel
        door.isOpaque = false
        door.backgroundColor = .clear
        door.hasShadow = true
        door.isReleasedWhenClosed = false
        door.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        door.contentView = doorRoot
        _ = Glass.installBackdrop(in: doorRoot, cornerRadius: BarTheme.glassRadius)
        door.onKeyDown = { [weak self] event in
            guard let self, let key = Keys.name(for: Int64(event.keyCode)) else { return false }
            return self.doorKey(key)
        }
        card.contentView = cardRoot
        _ = Glass.installBackdrop(in: cardRoot, cornerRadius: BarTheme.glassRadius)
        Movable.enable(door)
        Movable.enable(card)
    }

    // MARK: - Entry

    var doorVisible: Bool { door.isVisible }
    var cardVisible: Bool { card.isVisible }
    /// The coach yields while any walk surface is up.
    var isUp: Bool { doorVisible || cardVisible }

    /// From the boot trigger or the menu. `resumeAt` and `door` are an
    /// unfinished walk's persisted place; without both it begins at the
    /// welcome.
    func show(resumeAt: Int? = nil, door resumeDoor: Walk.Door? = nil) {
        guard !isUp else {
            // Asked for again while the grant is pending: bring the door
            // back rather than decline, or the walk is unreachable until
            // the grant lands.
            if awaitingGrant { stopWaiting(granted: false) }
            return
        }
        #if DEBUG
        if let jump = ProcessInfo.processInfo.environment["LODESTAR_WALK_STEP"], let step = Int(jump) {
            let named = ProcessInfo.processInfo.environment["LODESTAR_WALK_DOOR"].flatMap(Walk.Door.init(rawValue:))
            beginWalk(named ?? .switcher, at: step)
            return
        }
        #endif
        if trusted, let resumeDoor, let step = resumeAt, step > 0 {
            // Mid-walk: straight back to the step they left. The welcome
            // is for arrivals, not returns.
            chosen = resumeDoor
            beginWalk(resumeDoor, at: step)
        } else {
            chosen = nil
            page = .welcome
            showDoor()
        }
    }

    private func hideAll() {
        trustPoll?.invalidate(); trustPoll = nil
        awaitingGrant = false
        settingsIsOurs = false
        door.orderOut(nil)
        card.orderOut(nil)
        lesson = nil
        lessonDone = false
        lessonHide?.cancel(); lessonHide = nil
    }

    // MARK: - Lessons (the curriculum's cards)

    /// Show one lesson. Only when nothing else of the walk's is up.
    func showLesson(_ lesson: Curriculum.Lesson) {
        guard !isUp else { return }
        self.lesson = lesson
        lessonDone = false
        renderCard()
        Log.info("walk", ["lesson": lesson.rawValue])
    }

    private func noticeLesson(_ lesson: Curriculum.Lesson, _ signal: Walk.Signal) {
        guard !lessonDone, signal == Self.completion(of: lesson) else { return }
        lessonDone = true
        lessonCompleted?(lesson)
        Log.info("walk", ["lesson": lesson.rawValue, "completed": true])
        if lesson == .editor { enableEditor?() }
        renderCard()
        // The finished card is seen, then goes: unlike the walk's close it
        // has no decision on it, and a card that outstays its gesture is
        // clutter.
        let work = DispatchWorkItem { [weak self] in self?.hideLesson() }
        lessonHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }

    private func hideLesson() {
        lessonHide?.cancel(); lessonHide = nil
        lesson = nil
        lessonDone = false
        card.orderOut(nil)
    }

    /// The real gesture that proves each lesson. The editor's is the assent
    /// itself: turning it on is the whole of that lesson.
    static func completion(of lesson: Curriculum.Lesson) -> Walk.Signal {
        switch lesson {
        case .launcher: return .launcherPick
        case .editor: return .assent
        case .inside: return .hintsEnded
        case .web: return .webBarOpened
        case .clipboard: return .clipboardOpened
        case .sheet: return .cheatOpened
        case .draft: return .draftOpened
        case .select: return .selectEnded
        case .commands: return .commandsOpened
        case .scroll: return .scrollEnded
        }
    }

    // MARK: - Signals (the companion's only sense)

    func notice(_ signal: Walk.Signal) {
        if let lesson, cardVisible {
            noticeLesson(lesson, signal)
            return
        }
        guard cardVisible, walk != nil, walk?.isDone != true else { return }
        let effects = walk!.handle(signal)
        guard !effects.isEmpty else { return }
        for effect in effects {
            switch effect {
            case .acceptProposals(let proposals):
                if let problem = acceptGraph(proposals) {
                    Log.error("walk", ["graph": problem])
                }
            case .chooseEngine(let engine):
                chooseEngine?(engine)
            case .stepChanged:
                persistStep?(walk!.stepIndex)
            case .completed:
                // The closing card is not on a clock. It stays until the
                // user closes it, and a restart clears it, because the
                // walk is complete and never auto shows again.
                markCompleted?()
                Log.info("walk", ["completed": Lodestar.version, "door": walk!.door.rawValue])
            }
        }
        renderCard()
    }

    // MARK: - The walk itself

    private func beginWalk(_ chosenDoor: Walk.Door, at index: Int) {
        door.orderOut(nil)
        persistDoor?(chosenDoor)
        openDoor?(chosenDoor)
        switch chosenDoor {
        case .switcher:
            // The offer appears while the graph is still thin, fewer than
            // four bound apps, and proposes only from unbound running apps.
            // A built graph is a person who knows how to add letters.
            let leaves = config.graph.leaves()
            let running = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap(\.localizedName)
            let proposals = leaves.count < 4
                ? StarterGraph.propose(running: running, existing: config.graph,
                                       reserved: Config.reservedTopLevel)
                : []
            // A few of their own addresses for the graph card, shortest
            // first. The card offers and never prescribes.
            let existing = leaves
                .sorted { ($0.chain.count, $0.target.label) < ($1.chain.count, $1.target.label) }
                .prefix(4)
                .map { Walk.GraphChoice(path: $0.chain.joined(separator: " "), label: $0.target.label) }
            walk = Walk(door: .switcher, proposals: proposals, existing: Array(existing), resumeAt: index)
        case .write:
            walk = Walk(door: .write, grammar: grammarOffer(), resumeAt: index)
        case .keep, .speak:
            walk = Walk(door: chosenDoor, resumeAt: index)
        }
        persistStep?(walk!.stepIndex)
        Log.info("walk", ["door": chosenDoor.rawValue, "step": walk!.stepIndex])
        renderCard()
    }

    /// Lode ⌫, routed here by the app while the walk is up: the coach's
    /// "not this one", meaning skip the current step. Never a dismissal.
    /// The card persists until the walk is done, by decision. On the
    /// finished card the same gesture is the close.
    func pass() -> Bool {
        if let lesson, cardVisible {
            // "Not this one": the lesson retries days later, then parks.
            // On a finished lesson the same gesture is the close.
            if !lessonDone { lessonPassed?(lesson) }
            hideLesson()
            return true
        }
        guard cardVisible, let walk else { return false }
        if walk.isDone {
            hideAll()
            self.walk = nil
            return true
        }
        notice(.pass)
        return true
    }

    @objc private func donePressed() {
        hideAll()
        walk = nil
    }

    /// Lode-lode, routed here while the walk is up. The offer, the grammar
    /// step and the editor's lesson answer it.
    func assent() {
        notice(.assent)
    }

    // MARK: - Door state machine

    private func doorKey(_ key: String) -> Bool {
        guard doorVisible else { return false }
        // Nothing is swallowed while the keyboard is somebody else's: the
        // user followed the grant into System Settings, and a card that
        // keeps eating keys then is a locked keyboard in another app.
        guard door.isKeyWindow else { return false }
        switch (page, key) {
        case (.welcome, "1"), (.welcome, "2"), (.welcome, "3"), (.welcome, "4"):
            choose(Walk.Door.allCases[Int(key)! - 1])
        case (.welcome, "left"), (.welcome, "right"):
            let doors = Walk.Door.allCases
            let at = chosen.flatMap { doors.firstIndex(of: $0) } ?? (key == "left" ? doors.count : -1)
            choose(doors[(at + (key == "left" ? doors.count - 1 : 1)) % doors.count])
        case (.welcome, "return"):
            proceed()
        case (.permission, "return"), (.permission, "space"):
            grantAccess()
        case (.waiting, "escape"):
            stopWaiting(granted: false)
        case (.permission, "escape"):
            page = .welcome
            renderDoor()
        case (.welcome, "escape"):
            notNow()
        default:
            break
        }
        return true
    }

    private func showDoor() {
        renderDoor()
        door.makeKeyAndOrderFront(nil)
        pollTrust()
    }

    private func choose(_ selected: Walk.Door) {
        chosen = selected
        renderDoor()
    }

    /// Continue from the welcome: straight into the door's walk when the
    /// grant is already here, else the one permission.
    private func proceed() {
        guard let chosen else { return }
        Log.info("walk", ["chose": chosen.rawValue])
        if trusted {
            beginWalk(chosen, at: 0)
        } else {
            page = .permission
            renderDoor()
        }
    }

    @objc private func continuePressed() { proceed() }
    @objc private func grantPressed() { grantAccess() }
    @objc private func notNowPressed() { notNow() }
    @objc private func skipPressed() { _ = pass() }
    @objc private func tilePressed(_ sender: NSButton) {
        let doors = Walk.Door.allCases
        guard doors.indices.contains(sender.tag) else { return }
        choose(doors[sender.tag])
    }

    /// The note an administrator needs, on the pasteboard: what Lodestar
    /// is, the one permission, and why.
    @objc private func copyNotePressed() {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(Self.itNote, forType: .string)
        noteCopied = true
        renderDoor()
    }

    static let itNote = "Could Lodestar be allowed on my Mac? It is a free app from "
        + "lodestar.vaccone.software, signed with a Developer ID and notarized by Apple. "
        + "It needs one permission, Accessibility (System Settings, Privacy & Security, "
        + "Accessibility), to read the text field being typed in and to bring windows "
        + "forward. It asks for nothing else to start."

    /// "Not now" leaves the walk unfinished on purpose: nothing is marked,
    /// so the next boot offers the welcome again, and the menu always can.
    private func notNow() {
        hideAll()
    }

    /// Ask, without leaving. The prompt comes first because a permission
    /// you can grant from where you are standing is the point of asking;
    /// macOS spends that prompt once per app, so from the second press
    /// this opens the pane instead. Either way the door parks at the
    /// screen's edge and waits where the instructions stay readable.
    private func grantAccess() {
        guard !trusted else {
            if let chosen { beginWalk(chosen, at: 0) }
            return
        }
        awaitingGrant = true
        page = .waiting
        settingsIsOurs = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.settingsBundleID).isEmpty
        if !prompted {
            prompted = true
            _ = Permissions.requestIfNeeded()
        } else if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        renderDoor()
        pollTrust()
    }

    private func stopWaiting(granted: Bool) {
        awaitingGrant = false
        if granted, settingsIsOurs {
            // Only the pane we opened; one somebody was using is theirs.
            for app in NSRunningApplication.runningApplications(
                withBundleIdentifier: Self.settingsBundleID) {
                app.terminate()
            }
        }
        settingsIsOurs = false
        if granted {
            Log.info("walk", ["accessibility": "granted"])
            // The card said it would continue the moment the switch moved.
            if let chosen {
                beginWalk(chosen, at: 0)
                return
            }
            page = .welcome
        } else {
            page = chosen == nil ? .welcome : .permission
        }
        renderDoor()
        door.makeKeyAndOrderFront(nil)
    }

    /// The one clock. The grant can arrive because we asked or because they
    /// went and granted it themselves; both endings are the same. It also
    /// watches the asking: a door that parked at the edge has to come back
    /// to the middle on its own when the answer is no.
    private func pollTrust() {
        guard !trusted else { return }
        trustPoll?.invalidate()
        sawSettings = false
        waited = 0
        trustPoll = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.trusted {
                self.trustPoll?.invalidate(); self.trustPoll = nil
                if self.awaitingGrant || self.page == .permission { self.stopWaiting(granted: true) }
                return
            }
            guard self.awaitingGrant else { return }
            self.waited += 0.8
            let settingsRunning = !NSRunningApplication.runningApplications(
                withBundleIdentifier: Self.settingsBundleID).isEmpty
            if settingsRunning {
                self.sawSettings = true
                return
            }
            // The pane was open and is gone, or the prompt was dismissed
            // without opening it. Either way the answer is not yet.
            if self.sawSettings || self.waited > 8 { self.stopWaiting(granted: false) }
        }
    }

    // MARK: - Door copy

    /// What each door needs Accessibility for, said before macOS asks.
    static func permissionReason(_ door: Walk.Door) -> String {
        switch door {
        case .write:
            return "To read the field you are writing in and draw a line under a word, "
                + "macOS asks you to allow Accessibility. The reading happens on this Mac, "
                + "and nothing you write is kept."
        case .switcher:
            return "To bring a window forward and arrange your windows, macOS asks you "
                + "to allow Accessibility."
        case .keep:
            return "To paste where you are typing, macOS asks you to allow Accessibility."
        case .speak:
            return "To put your words where your cursor is, macOS asks you to allow "
                + "Accessibility. The microphone comes later, the first time you speak."
        }
    }

    static let standardAccountNote = "This account is not an administrator, so turning it on "
        + "needs an administrator's name and password. On a Mac from work, that is usually "
        + "your IT team."

    /// Each door's line on the welcome.
    static func doorLine(_ door: Walk.Door) -> String {
        switch door {
        case .write: return "Checks your spelling and grammar as you type"
        case .switcher: return "Any app or window, with one key and a letter"
        case .keep: return "Everything you copy, ready to paste again"
        case .speak: return "Say it, shape it, and it lands where you were"
        }
    }

    // MARK: - Door drawing

    private func renderDoor() {
        for view in doorRoot.subviews where view is NSStackView { view.removeFromSuperview() }
        let width = page == .welcome ? Self.welcomeWidth : Self.doorWidth
        let text = width - Self.inset * 2
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        switch page {
        case .welcome:
            stack.addArrangedSubview(heading("Welcome to Lodestar"))
            stack.addArrangedSubview(voice("What would you like to do first? Lodestar starts with that one.", width: text))
            stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!)
            stack.addArrangedSubview(tiles(width: text))
            stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!)
            let footer = NSStackView()
            footer.orientation = .horizontal
            footer.spacing = 12
            footer.addArrangedSubview(wrapped(chosen == nil
                    ? "Choose one. The other three wait until they would help."
                    : "The other three wait. Lodestar brings up each one later, when it would help.",
                size: BarTheme.Scale.meta, color: BarTheme.secondaryColor, alignment: .left, width: text - 150))
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            footer.addArrangedSubview(spacer)
            let go = bigButton("Continue", action: #selector(continuePressed))
            go.isEnabled = chosen != nil
            footer.addArrangedSubview(go)
            footer.widthAnchor.constraint(equalToConstant: text).isActive = true
            stack.addArrangedSubview(footer)
            stack.addArrangedSubview(smallLink("not now", action: #selector(notNowPressed)))
        case .permission:
            stack.addArrangedSubview(heading("One permission"))
            stack.addArrangedSubview(wrapped(Self.permissionReason(chosen ?? .switcher), size: BarTheme.Scale.body,
                                             color: .labelColor, alignment: .left, width: text))
            if !administrator {
                stack.addArrangedSubview(wrapped(Self.standardAccountNote, size: BarTheme.Scale.body,
                                                 color: BarTheme.secondaryColor, alignment: .left, width: text))
            }
            stack.addArrangedSubview(wrapped(
                "Nothing else is asked for now. Anything more is asked the first time you use the thing that needs it.",
                size: BarTheme.Scale.meta, color: BarTheme.secondaryColor, alignment: .left, width: text))
            stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)
            stack.addArrangedSubview(bigButton(prompted ? "Open System Settings" : "Allow Accessibility",
                                               action: #selector(grantPressed)))
            if !administrator {
                stack.addArrangedSubview(smallLink(noteCopied ? "note copied, paste it to your IT team" : "copy a note for IT",
                                                   action: #selector(copyNotePressed)))
            }
            stack.addArrangedSubview(smallLink("not now", action: #selector(notNowPressed)))
        case .waiting:
            stack.addArrangedSubview(heading("Turn on Lodestar"))
            stack.addArrangedSubview(wrapped(
                "In System Settings, switch Lodestar on in the Accessibility list. "
                    + "This card continues the moment you do.",
                size: BarTheme.Scale.body, color: .labelColor, alignment: .left, width: text))
            stack.addArrangedSubview(wrapped("No restart needed.", size: BarTheme.Scale.meta,
                                             color: BarTheme.secondaryColor, alignment: .left, width: text))
            stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)
            stack.addArrangedSubview(smallLink("cancel", action: #selector(notNowPressed)))
        }

        doorRoot.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doorRoot.topAnchor, constant: Self.inset),
            stack.leadingAnchor.constraint(equalTo: doorRoot.leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(equalTo: doorRoot.trailingAnchor, constant: -Self.inset),
        ])
        doorRoot.layoutSubtreeIfNeeded()
        presentDoor(width: width, height: stack.fittingSize.height + Self.inset * 2)
    }

    /// Centered to be read; parked at the trailing edge to wait, so System
    /// Settings has the middle of the screen and the instructions stay on it.
    private func presentDoor(width: CGFloat, height: CGFloat) {
        let size = NSSize(width: width, height: height)
        let visible = ActivePolicy.presentationFrame
        let origin = page == .waiting
            ? NSPoint(x: visible.maxX - size.width - 20, y: visible.midY - size.height / 2)
            : NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2 + 40)
        door.setFrame(NSRect(origin: origin, size: size), display: true)
        door.orderFrontRegardless()
    }

    /// The four doors, side by side: each its picture, its name and one
    /// line, the chosen one ringed in the accent. Clickable, and 1 to 4
    /// and the arrows choose from the keys.
    private func tiles(width: CGFloat) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.distribution = .fillEqually
        let tileWidth = (width - 30) / 4
        for (index, option) in Walk.Door.allCases.enumerated() {
            let selected = option == chosen
            let column = NSStackView()
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 4
            column.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 12, right: 10)
            if let picture = Self.picture(option) {
                let image = NSImageView(image: picture)
                image.imageScaling = .scaleProportionallyUpOrDown
                image.translatesAutoresizingMaskIntoConstraints = false
                image.widthAnchor.constraint(equalToConstant: tileWidth - 20).isActive = true
                image.heightAnchor.constraint(equalToConstant: (tileWidth - 20) * 0.75).isActive = true
                column.addArrangedSubview(image)
            }
            column.addArrangedSubview(label(option.name, size: BarTheme.Scale.body, weight: .semibold,
                                            color: .labelColor))
            column.addArrangedSubview(wrapped(Self.doorLine(option), size: BarTheme.Scale.meta,
                                              color: BarTheme.secondaryColor, alignment: .left, width: tileWidth - 20))
            column.wantsLayer = true
            column.layer?.cornerRadius = BarTheme.surfaceRadius
            column.layer?.borderWidth = selected ? 1.5 : 1
            column.layer?.borderColor = (selected ? BarTheme.accent : NSColor.labelColor.withAlphaComponent(0.1)).cgColor
            column.layer?.backgroundColor = (selected ? BarTheme.accent.withAlphaComponent(0.08)
                                                      : NSColor.labelColor.withAlphaComponent(0.03)).cgColor
            column.translatesAutoresizingMaskIntoConstraints = false
            column.widthAnchor.constraint(equalToConstant: tileWidth).isActive = true

            // The whole tile is the target: a borderless button over it.
            let hit = HandButton(title: "", target: self, action: #selector(tilePressed(_:)))
            hit.isBordered = false
            hit.tag = index
            hit.setAccessibilityLabel(option.name)
            hit.translatesAutoresizingMaskIntoConstraints = false
            column.addSubview(hit)
            NSLayoutConstraint.activate([
                hit.leadingAnchor.constraint(equalTo: column.leadingAnchor),
                hit.trailingAnchor.constraint(equalTo: column.trailingAnchor),
                hit.topAnchor.constraint(equalTo: column.topAnchor),
                hit.bottomAnchor.constraint(equalTo: column.bottomAnchor),
            ])
            row.addArrangedSubview(column)
        }
        // Four tiles, one height: a door whose line wraps longer does not
        // stand taller than the rest.
        row.alignment = .top
        for column in row.arrangedSubviews {
            column.heightAnchor.constraint(equalTo: row.heightAnchor).isActive = true
        }
        return row
    }

    /// The door's picture, rendered from the same scene as the website's,
    /// shipped in the app's resources. Absent (a test run, a bare build),
    /// the tile is its name and line alone.
    private static func picture(_ door: Walk.Door) -> NSImage? {
        guard let url = Bundle.main.url(forResource: "door-\(door.rawValue)", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }

    // MARK: - Companion copy

    private struct CardContent {
        var title: String
        var body: String
        var illustration: NSView?
        /// The gesture that answers this card, shown as caps + meaning
        /// rows. A row carrying an action is pressable as well as typable —
        /// which matters most on the first cards, where the gesture being
        /// taught has not been learned yet.
        var keys: [KeyRow] = []
    }

    private struct KeyRow {
        let cap: String
        let meaning: String
        let action: (() -> Void)?

        init(_ cap: String, _ meaning: String, action: (() -> Void)? = nil) {
            self.cap = cap
            self.meaning = meaning
            self.action = action
        }
    }

    private func content(for step: Walk.Step, door chosenDoor: Walk.Door) -> CardContent {
        switch step {
        case .launcher:
            return CardContent(
                title: "Hold right ⌘ and press space",
                body: "That key is lode, Lodestar's own. Type a few letters of any app, "
                    + "then press return. It opens filling the screen, and ⇧⏎ puts it "
                    + "beside what you have instead.",
                illustration: keyboardRow())
        case .graphOffer(let proposals):
            return CardContent(
                title: "A letter for each app",
                body: "Apps you open often can each have a letter of their own. These are "
                    + "suggestions, drafted from the apps you have open.",
                illustration: proposalList(proposals),
                keys: [KeyRow("lode lode", "tap lode twice to keep these",
                              action: { [weak self] in self?.assent() }),
                       KeyRow("lode ⌫", "not these",
                              action: { [weak self] in _ = self?.pass() })])
        case .graphGo(let options):
            return CardContent(
                title: "Hold right ⌘ and press a letter",
                body: "The app comes forward from anywhere, and opens if it is closed. "
                    + "Every app keeps its letter, so your hand learns it once.",
                illustration: choiceList(options))
        case .typo:
            return CardContent(
                title: "Try it anywhere",
                body: "Type a word wrong, in any app. A thin line appears under it.\n\n"
                    + "Lodestar reads the field you are writing in, on this Mac, and keeps none of it.")
        case .fix:
            return CardContent(
                title: "Rest the pointer on the line",
                body: "The fix appears. Accept puts it right, and Keep as written leaves it alone.",
                keys: [KeyRow("lode ⇥", "or put a letter on each mark from the keys")])
        case .grammar(let engine):
            return CardContent(
                title: "Fixed where you wrote it",
                body: "No line means nothing needs your attention.\n\n"
                    + "For grammar, Lodestar can read each sentence closely with a language "
                    + "model that runs on this Mac. A download continues in the background.",
                keys: [KeyRow("lode lode", describeEngine(engine),
                              action: { [weak self] in self?.assent() }),
                       KeyRow("lode ⌫", "spelling only for now",
                              action: { [weak self] in _ = self?.pass() })])
        case .copy:
            return CardContent(
                title: "Copy anything",
                body: "Select some text and press ⌘C, as always. Lodestar keeps it.")
        case .strip:
            return CardContent(
                title: "Press ⇧⌘V",
                body: "Everything you copied, along the bottom of the screen. Press A and "
                    + "the newest pastes where you were typing.",
                illustration: capsRow([("⇧⌘V", true), ("A", false)]))
        case .draft:
            return CardContent(
                title: "Hold right ⌘ and press period",
                body: "Click into any text field first. The draft opens where you can see it, "
                    + "and you will hear a soft note when it starts listening.\n\n"
                    + "The first time, macOS asks for the microphone. What you say is turned "
                    + "into text on this Mac, and no audio is kept.",
                illustration: capsRow([("lode", false), (".", true)]))
        case .land:
            return CardContent(
                title: "Talk, then press return",
                body: "Words arrive grey while they are heard, then settle. Type into the same "
                    + "draft to fix anything. Return puts it where your cursor was, and a second "
                    + "note says it arrived.",
                illustration: capsRow([("⏎", true)]))
        case .done:
            return CardContent(
                title: "\(chosenDoor.name) is ready",
                body: "Lodestar lives in the menu bar and starts with your Mac. Your right ⌘ is "
                    + "its key now: hold it whenever you want to see what it can reach.\n\n"
                    + "The other three stay out of the way. Lodestar brings up each one later, "
                    + "when it would help.",
                keys: [KeyRow("lode ⌫", "close this card",
                              action: { [weak self] in _ = self?.pass() })])
        }
    }

    /// The curriculum's cards: one gesture each, proved by the real
    /// gesture happening. One lesson as Lodestar speaking: what the lesson
    /// is for, in the voice, never naming a key; the keys it teaches as
    /// rows beneath, drawn as keys; the count quiet in the detail.
    struct LessonCard: Equatable {
        let sentence: String
        let detail: String
        let rows: [Row]
        struct Row: Equatable {
            let keys: [String]
            let label: String
        }
    }

    static func lessonCard(_ lesson: Curriculum.Lesson) -> LessonCard {
        let (position, total) = Curriculum.position(of: lesson)
        let count = "Lesson \(position) of \(total)"
        func row(_ keys: [String], _ label: String) -> LessonCard.Row { .init(keys: keys, label: label) }
        switch lesson {
        case .launcher:
            return LessonCard(sentence: "Any app, from one line",
                              detail: "A few letters of its name, and it opens filling the screen. \(count)",
                              rows: [row(["lode", "space"], "Launcher"), row(["⏎"], "Open")])
        case .editor:
            return LessonCard(sentence: "Spelling and grammar, checked as you type",
                              detail: "A thin line under what reads wrong, in every app, read on this Mac. \(count)",
                              rows: [row(["lode", "lode"], "Turn it on")])
        case .inside:
            return LessonCard(sentence: "Buttons and links can wear a letter",
                              detail: "Press the letter to click what wears it. \(count)",
                              rows: [row(["lode", ";"], "Letters on"), row(["esc"], "Letters off")])
        case .web:
            return LessonCard(sentence: "The web opens from one line",
                              detail: "A name, a domain, or a question. \(count)",
                              rows: [row(["lode", "⏎"], "Ask"), row(["⏎"], "Open")])
        case .draft:
            return LessonCard(sentence: "Dictation and Vim editing in one draft",
                              detail: "Speak or type, edit with Vim keys, and it lands where the cursor was. \(count)",
                              rows: [row(["lode", "."], "Draft with dictation"),
                                     row(["lode", "⇧."], "Draft without dictation"),
                                     row(["⏎"], "Place it")])
        case .select:
            return LessonCard(sentence: "Text on screen can be highlighted",
                              detail: "Type what you see, then mark where the selection starts and ends. \(count)",
                              rows: [row(["lode", "/"], "Select"), row(["⇧A"], "Mark an end"),
                                     row(["⌘C"], "Copy the selection")])
        case .commands:
            return LessonCard(sentence: "Run menu items from the keys",
                              detail: "Every item in this app's menus answers to a search, each wearing its own shortcut. \(count)",
                              rows: [row(["lode", "-"], "Commands"), row(["⏎"], "Run")])
        case .scroll:
            return LessonCard(sentence: "Scrolling without a mouse",
                              detail: "Hold to move, release to stop. \(count)",
                              rows: [row(["lode", "`"], "Scroll"), row(["J", "K"], "Down and up"),
                                     row(["D", "U"], "Half a page"), row(["/"], "Scroll where a word is")])
        case .clipboard:
            return LessonCard(sentence: "Everything copied is kept",
                              detail: "The newest clip pastes as plain text. The one gesture with no held key, because pasting happens mid-sentence. \(count)",
                              rows: [row(["⇧⌘V"], "Clipboard"), row(["A"], "Paste the newest")])
        case .sheet:
            return LessonCard(sentence: "Review any of the keymaps",
                              detail: "One sheet lists every key Lodestar answers to. Inside a mode or a bar it lists the keys of that place. \(count)",
                              rows: [row(["lode", "?"], "Show the keys"), row(["esc"], "Close")])
        }
    }

    /// The note a proven lesson leaves for a moment before it goes.
    static func provenNote(for lesson: Curriculum.Lesson) -> (sentence: String, detail: String) {
        let (position, total) = Curriculum.position(of: lesson)
        return ("That gesture is learned",
                position < total ? "The next lesson arrives in a few days" : "That was the last lesson")
    }

    /// A lesson on the companion's glass, in the voice.
    private func renderLesson(_ lesson: Curriculum.Lesson) {
        for view in cardRoot.subviews where view is NSStackView { view.removeFromSuperview() }
        let stack: NSStackView
        if lessonDone {
            let note = Self.provenNote(for: lesson)
            stack = VoiceCard.build(sentence: note.sentence, detail: note.detail, rows: [])
        } else {
            let card = Self.lessonCard(lesson)
            var rows = card.rows.enumerated().map { index, row in
                // The editor's one row is its answer, pressable as well.
                lesson == .editor && index == 0
                    ? GuideRow(keys: row.keys, label: row.label, action: { [weak self] in self?.assent() })
                    : GuideRow(keys: row.keys, label: row.label)
            }
            // Later on the same keys every ask answers to, pressable as
            // well: passing a lesson is the walk's one decision.
            rows.append(GuideRow(keys: ["lode", "⌫"], label: "Later", action: { [weak self] in _ = self?.pass() }))
            stack = VoiceCard.build(sentence: card.sentence, detail: card.detail, rows: rows)
        }
        cardRoot.addSubview(stack)
        let inset = ModePill.inset
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: cardRoot.topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: cardRoot.bottomAnchor, constant: -inset),
            stack.leadingAnchor.constraint(equalTo: cardRoot.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: cardRoot.trailingAnchor, constant: -inset),
        ])
        cardRoot.layoutSubtreeIfNeeded()
        let size = cardRoot.fittingSize
        Movable.place(card, size: size) {
            let visible = ActivePolicy.presentationFrame
            return NSPoint(x: visible.maxX - size.width - 20,
                           y: visible.maxY - size.height - 20)
        }
        card.orderFrontRegardless()
    }

    // MARK: - Companion drawing

    private func renderCard() {
        if let lesson {
            renderLesson(lesson)
            return
        }
        guard let walk else { return }
        let content = self.content(for: walk.step, door: walk.door)
        let progress = walk.progress
        let header: String? = walk.step == .done ? nil
            : "⌖ \(walk.door.name) · \(progress.position) of \(progress.total)"
        let footer: (title: String, action: Selector) = walk.step == .done
            ? ("done", #selector(donePressed))
            : ("skip this step", #selector(skipPressed))
        for view in cardRoot.subviews where view is NSStackView { view.removeFromSuperview() }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        if let header {
            stack.addArrangedSubview(label(header, size: BarTheme.Scale.meta,
                                           weight: .medium, color: BarTheme.secondaryColor))
        }
        stack.addArrangedSubview(label(content.title, size: BarTheme.Scale.title, weight: .semibold,
                                       color: .labelColor))
        stack.addArrangedSubview(wrapped(content.body, size: BarTheme.Scale.body,
                                         color: BarTheme.secondaryColor, alignment: .left,
                                         width: Self.cardText))
        if let illustration = content.illustration {
            stack.setCustomSpacing(14, after: stack.arrangedSubviews.last!)
            stack.addArrangedSubview(illustration)
            stack.setCustomSpacing(14, after: illustration)
        }
        for row in content.keys {
            stack.addArrangedSubview(keyMeaningRow(cap: row.cap, meaning: row.meaning,
                                                   action: row.action))
        }

        // The footer: skipping is per step and the walk cannot be
        // dismissed. The click target exists because lode ⌫ requires the
        // very key a first card may still be teaching. The finished card
        // trades it for a close, and is never on a clock.
        stack.setCustomSpacing(12, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(smallLink(footer.title, action: footer.action))

        cardRoot.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: cardRoot.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: cardRoot.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: cardRoot.trailingAnchor, constant: -20),
        ])

        cardRoot.layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.cardWidth,
                          height: stack.fittingSize.height + 18 + 16)
        // Top-right corner: the launcher owns the middle, the HUD, the
        // draft and the clipboard own the bottom, so this is the quiet
        // quarter.
        Movable.place(card, size: size) {
            let visible = ActivePolicy.presentationFrame
            return NSPoint(x: visible.maxX - size.width - 20,
                           y: visible.maxY - size.height - 20)
        }
        card.orderFrontRegardless()
    }

    // MARK: - Pieces

    private func heading(_ text: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        if let icon = NSApp.applicationIconImage {
            let image = NSImageView(image: icon)
            image.translatesAutoresizingMaskIntoConstraints = false
            image.widthAnchor.constraint(equalToConstant: 30).isActive = true
            image.heightAnchor.constraint(equalToConstant: 30).isActive = true
            row.addArrangedSubview(image)
        }
        row.addArrangedSubview(label(text, size: 22, weight: .semibold, color: .labelColor))
        return row
    }

    /// Lodestar's own sentence, in its voice.
    private func voice(_ text: String, width: CGFloat) -> NSTextField {
        let field = wrapped(text, size: BarTheme.Scale.body, color: BarTheme.secondaryColor,
                            alignment: .left, width: width)
        field.font = BarTheme.voiceFont
        return field
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight,
                       color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }

    private func wrapped(_ text: String, size: CGFloat, color: NSColor,
                         alignment: NSTextAlignment, width: CGFloat) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: .regular)
        field.textColor = color
        field.alignment = alignment
        field.isSelectable = false
        // Without this a wrapping label reports a one-line intrinsic size
        // and the fitting pass measures a card that does not exist.
        field.preferredMaxLayoutWidth = width
        field.widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true
        return field
    }

    private func bigButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.keyEquivalent = "\r"
        return button
    }

    private func smallLink(_ title: String, action: Selector) -> NSButton {
        let button = HandButton(title: title, target: self, action: action)
        button.isBordered = false
        button.font = BarTheme.secondaryFont
        button.contentTintColor = BarTheme.secondaryColor
        return button
    }

    private func keycap(_ text: String, lit: Bool = false, wide: Bool = false) -> NSView {
        let cap = NSTextField(labelWithString: text)
        cap.font = BarTheme.secondaryFont
        cap.textColor = lit ? BarTheme.accent : .labelColor
        cap.alignment = .center
        cap.translatesAutoresizingMaskIntoConstraints = false

        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = BarTheme.chipRadius
        box.layer?.backgroundColor = NSColor.labelColor
            .withAlphaComponent(lit ? 0.14 : 0.08).cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = (lit
            ? BarTheme.accent.withAlphaComponent(0.7)
            : NSColor.labelColor.withAlphaComponent(0.12)).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        // A cap is exactly as wide as its key. Without this the row stack
        // elects the lowest-hugging view to soak up its slack, and a letter
        // arrives on a keycap the width of the card.
        box.setContentHuggingPriority(.required, for: .horizontal)
        box.addSubview(cap)
        // Equality, not ≥: a plain NSView has no intrinsic size, so a
        // one-sided width lets the stack stretch the cap to the card.
        NSLayoutConstraint.activate([
            cap.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: wide ? 22 : 8),
            cap.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: wide ? -22 : -8),
            cap.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            box.heightAnchor.constraint(equalToConstant: 24),
        ])
        return box
    }

    private func capsRow(_ caps: [(String, Bool)]) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6
        row.setContentHuggingPriority(.required, for: .horizontal)
        for (text, lit) in caps { row.addArrangedSubview(keycap(text, lit: lit)) }
        return row
    }

    /// The bottom row of a keyboard, the right command key lit: "the lode
    /// key" is a name, and a location is what the hand needs.
    private func keyboardRow() -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 4
        row.addArrangedSubview(keycap("fn"))
        row.addArrangedSubview(keycap("⌃"))
        row.addArrangedSubview(keycap("⌥"))
        row.addArrangedSubview(keycap("⌘"))
        row.addArrangedSubview(keycap("space", lit: true, wide: true))
        row.addArrangedSubview(keycap("⌘", lit: true))
        row.addArrangedSubview(keycap("⌥"))
        column.addArrangedSubview(row)
        column.addArrangedSubview(label("the right ⌘ is lode", size: BarTheme.Scale.meta,
                                        weight: .regular, color: BarTheme.secondaryColor))
        return column
    }

    private func choiceList(_ options: [Walk.GraphChoice]) -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 5
        for option in options {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            row.setContentHuggingPriority(.required, for: .horizontal)
            for letter in option.path.split(separator: " ") {
                row.addArrangedSubview(keycap(String(letter).uppercased(), lit: true))
            }
            row.addArrangedSubview(label(option.label, size: BarTheme.Scale.body, weight: .regular,
                                         color: .labelColor))
            column.addArrangedSubview(row)
        }
        return column
    }

    private func proposalList(_ proposals: [StarterGraph.Proposal]) -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 5
        for proposal in proposals {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            row.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(keycap(proposal.letter.uppercased(), lit: true))
            row.addArrangedSubview(label(proposal.app, size: BarTheme.Scale.body, weight: .regular,
                                         color: .labelColor))
            column.addArrangedSubview(row)
        }
        return column
    }

    private func keyMeaningRow(cap: String, meaning: String,
                               action: (() -> Void)? = nil) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.setContentHuggingPriority(.required, for: .horizontal)
        let box = keycap(cap)
        if let action {
            // The walk's caps keep their own family — bordered, larger,
            // warmer than the chips' — so only the fill moves under the
            // pointer, through the same three states everything else uses.
            row.addArrangedSubview(Keycaps.CapGroup(content: box, paint: { state in
                box.layer?.backgroundColor = NSColor.labelColor
                    .withAlphaComponent(state == .resting ? 0.08 : state.fill).cgColor
            }, action: action))
        } else {
            row.addArrangedSubview(box)
        }
        row.addArrangedSubview(label(meaning, size: BarTheme.Scale.meta, weight: .regular,
                                     color: BarTheme.secondaryColor))
        return row
    }

    // MARK: - Staging

    #if DEBUG
    /// `lodestar __strip-preview N` puts every walk surface on screen
    /// without a fresh install: 20 the welcome, 21 a door chosen, 22 the
    /// permission, 23 the permission on an account that is not an
    /// administrator, 24 waiting at the edge; 25…28 a door's walk from its
    /// first step (`LODESTAR_WALK_DOOR`, Switch by default), 29 its close;
    /// 30 on the curriculum's cards in order, then a proven one.
    static func preview(_ index: Int, empty: Bool = false) -> WalkController {
        let controller = WalkController()
        var (config, _) = Config.load()
        if empty { config.graph = GraphNode() }
        controller.config = config
        controller.describeEngine = { AppDelegate.walkEngineAnswer($0) }
        let previewDoor = ProcessInfo.processInfo.environment["LODESTAR_WALK_DOOR"]
            .flatMap(Walk.Door.init(rawValue:)) ?? .switcher
        controller.grammarOffer = { "standard" }
        // After the run loop is up: a window ordered in before the app
        // finishes launching never reaches the window server.
        DispatchQueue.main.async {
            switch index {
            case 0:
                controller.renderDoor()
                controller.door.makeKeyAndOrderFront(nil)
            case 1:
                controller.chosen = previewDoor
                controller.renderDoor()
                controller.door.makeKeyAndOrderFront(nil)
            case 2, 3:
                controller.forceUntrusted = true
                controller.forceStandardAccount = index == 3
                controller.chosen = previewDoor
                controller.page = .permission
                controller.renderDoor()
                controller.door.makeKeyAndOrderFront(nil)
            case 4:
                controller.forceUntrusted = true
                controller.chosen = previewDoor
                controller.awaitingGrant = true
                controller.page = .waiting
                controller.renderDoor()
            case 5...9:
                controller.beginWalk(previewDoor, at: index - 5)
            default:
                let lessons = Curriculum.order.map(\.lesson)
                if index - 10 < lessons.count {
                    controller.showLesson(lessons[index - 10])
                } else {
                    controller.lesson = lessons[0]
                    controller.lessonDone = true
                    controller.renderCard()
                }
            }
        }
        return controller
    }
    #endif
}
