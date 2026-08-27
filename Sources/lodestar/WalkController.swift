import AppKit
import LodestarCore

/// The walk's two surfaces. Neither decides anything — `Walk` (LodestarCore)
/// owns the sequence; these draw it and translate clicks.
///
/// **The door** (act one) is a small centered card, mouse-first and keyable,
/// because before the Accessibility grant there is no event tap and AppKit
/// is all there is. It asks for exactly one permission, and while the user
/// is inside System Settings it parks at the screen edge and *stays
/// visible* — the old full-screen deck had to hide itself for the grant,
/// which left the user alone in the settings pane with the instructions
/// gone. That single difference is most of why the door is a card.
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
    var markCompleted: (() -> Void)?

    private var walk: Walk?

    // MARK: - Windows

    /// The door: keyable on purpose, exactly like the deck's panel was —
    /// pre-grant, AppKit key handling is the only keyboard there is.
    private let door = KeyablePanel(
        contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let doorRoot = NSView()

    /// The companion: a floating glass card that can never become key.
    private let card = Glass.makePanel(level: .floating)
    private let cardRoot = NSView()

    private static let doorWidth: CGFloat = 460
    private static let cardWidth: CGFloat = 330
    private static let inset: CGFloat = 26
    /// What the wrapping labels wrap at — the card width minus its insets,
    /// so the measured height is the height of the card that ships.
    private static let doorText: CGFloat = doorWidth - inset * 2
    private static let cardText: CGFloat = cardWidth - 40

    // MARK: - Grant flow (ported from the deck, card-sized)

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

    #if DEBUG
    /// The door's untrusted copy, on a machine that granted long ago — the
    /// one state a preview cannot reach by looking.
    private var forceUntrusted = false
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

    /// From the boot trigger or the menu. `resumeAt` is the persisted step
    /// of an unfinished walk; nil means start from the greeting.
    func show(resumeAt: Int? = nil) {
        guard !isUp else {
            // Asked for again while the grant is pending: bring the door
            // back rather than decline, or the walk is unreachable until
            // the grant lands.
            if awaitingGrant { stopWaiting(granted: false) }
            return
        }
        #if DEBUG
        if let jump = ProcessInfo.processInfo.environment["LODESTAR_WALK_STEP"],
           let step = Int(jump) {
            beginWalk(at: step)
            return
        }
        #endif
        if !trusted {
            showDoor()
        } else if let step = resumeAt, step > 0 {
            // Mid-walk: straight back to the step they left. The greeting
            // is for arrivals, not returns.
            beginWalk(at: step)
        } else {
            showDoor()
        }
    }

    private func hideAll() {
        trustPoll?.invalidate(); trustPoll = nil
        awaitingGrant = false
        settingsIsOurs = false
        door.orderOut(nil)
        card.orderOut(nil)
    }

    // MARK: - Signals (the companion's only sense)

    func notice(_ signal: Walk.Signal) {
        guard cardVisible, walk != nil, walk?.isDone != true else { return }
        let effects = walk!.handle(signal)
        guard !effects.isEmpty else { return }
        for effect in effects {
            switch effect {
            case .acceptProposals(let proposals):
                if let problem = acceptGraph(proposals) {
                    Log.error("walk", ["graph": problem])
                }
            case .stepChanged:
                persistStep?(walk!.stepIndex)
            case .completed:
                // The closing card is not on a clock. It stays until the
                // user closes it, and a restart clears it, because the
                // walk is complete and never auto shows again.
                markCompleted?()
                Log.info("walk", ["completed": Lodestar.version])
            }
        }
        renderCard()
    }

    // MARK: - The walk itself

    private func beginWalk(at index: Int) {
        door.orderOut(nil)
        // The offer appears while the graph is still thin, fewer than four
        // bound apps, and proposes only from unbound running apps. A built
        // graph is a person who knows how to add letters, and the offer
        // would be noise on top of knowledge.
        let leaves = config.graph.leaves()
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
        let proposals = leaves.count < 4
            ? StarterGraph.propose(running: running, existing: config.graph,
                                   reserved: Config.reservedTopLevel)
            : []
        // A few of their own addresses for the graph card, shortest first.
        // The card offers and never prescribes: "press A" once told
        // somebody to open an app they had no wish to open.
        let existing = leaves
            .sorted { ($0.chain.count, $0.target.label) < ($1.chain.count, $1.target.label) }
            .prefix(4)
            .map { Walk.GraphChoice(path: $0.chain.joined(separator: " "),
                                    label: $0.target.label) }
        walk = Walk(proposals: proposals, existing: Array(existing), resumeAt: index)
        persistStep?(walk!.stepIndex)
        renderCard()
    }

    /// Lode ⌫, routed here by the app while the walk is up: the coach's
    /// "not this one", meaning skip the current step. Never a dismissal.
    /// The card persists until the walk is done, by decision. On the
    /// finished card the same gesture is the close.
    func pass() -> Bool {
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

    /// Lode-lode, routed here while the walk is up. Only the offer answers.
    func assent() {
        notice(.assent)
    }

    // MARK: - Door state machine

    private func doorKey(_ key: String) -> Bool {
        guard doorVisible else { return false }
        // Nothing is swallowed while the keyboard is somebody else's: the
        // user followed the grant into System Settings, and a card that
        // keeps eating keys then is a locked keyboard in another app.
        // The deck learned this from its first outside user.
        guard door.isKeyWindow else { return false }
        switch key {
        case "escape":
            if awaitingGrant { stopWaiting(granted: false) } else { notNow() }
            return true
        case "return":
            if trusted { begin() } else { grantAccess() }
            return true
        case "space" where !trusted:
            grantAccess()
            return true
        default:
            return true
        }
    }

    private func showDoor() {
        renderDoor(waiting: false)
        door.makeKeyAndOrderFront(nil)
        pollTrust()
    }

    @objc private func grantPressed() { grantAccess() }
    @objc private func beginPressed() { begin() }
    @objc private func notNowPressed() { notNow() }
    @objc private func skipPressed() { _ = pass() }

    private func begin() {
        beginWalk(at: 0)
    }

    /// "Not now" leaves the walk unfinished on purpose: nothing is marked,
    /// so the next boot offers the door again, and the menu always can.
    private func notNow() {
        hideAll()
    }

    /// Ask, without leaving. The prompt comes first because a permission
    /// you can grant from where you are standing is the point of asking;
    /// macOS spends that prompt once per app, so from the second press
    /// this opens the pane instead. Either way the door parks at the
    /// screen's edge and waits where the instructions stay readable.
    private func grantAccess() {
        guard !trusted else { return }
        awaitingGrant = true
        settingsIsOurs = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.settingsBundleID).isEmpty
        if !prompted {
            prompted = true
            _ = Permissions.requestIfNeeded()
        } else if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        renderDoor(waiting: true)
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
        renderDoor(waiting: false)
        door.makeKeyAndOrderFront(nil)
        if granted { Log.info("walk", ["accessibility": "granted"]) }
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
                self.stopWaiting(granted: true)
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

    // MARK: - Door drawing

    private func renderDoor(waiting: Bool) {
        for view in doorRoot.subviews where view is NSStackView { view.removeFromSuperview() }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let star = label("✦", size: 22, weight: .medium, color: .controlAccentColor)
        stack.addArrangedSubview(star)
        stack.addArrangedSubview(label("Lodestar", size: 26, weight: .semibold, color: .labelColor))
        stack.addArrangedSubview(wrapped(
            "Every app you use gets a permanent key.\nPress it and you are there.",
            size: 15, color: .labelColor, alignment: .center, width: Self.doorText))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        if waiting {
            stack.addArrangedSubview(wrapped(
                "In System Settings: Privacy & Security → Accessibility → "
                + "switch Lodestar on.",
                size: 13, color: .secondaryLabelColor, alignment: .center, width: Self.doorText))
            stack.addArrangedSubview(wrapped(
                "This card waits with you. It notices the moment the grant lands.",
                size: 12, color: .tertiaryLabelColor, alignment: .center, width: Self.doorText))
            stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)
            stack.addArrangedSubview(smallLink("cancel", action: #selector(notNowPressed)))
        } else if trusted {
            stack.addArrangedSubview(wrapped(
                "Accessibility is granted. The walk takes about a minute, "
                + "on your own apps. A few small steps, each one a gesture "
                + "your hand keeps.",
                size: 13, color: .secondaryLabelColor, alignment: .center, width: Self.doorText))
            stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)
            stack.addArrangedSubview(bigButton("Begin", action: #selector(beginPressed)))
            stack.addArrangedSubview(smallLink("not now", action: #selector(notNowPressed)))
        } else {
            stack.addArrangedSubview(wrapped(
                "To see your windows and move them, macOS needs you to allow "
                + "Accessibility. Nothing leaves your Mac.\n\nOne more "
                + "permission exists. Screen Recording, for selecting text "
                + "you can see. Lodestar asks the first time you use that "
                + "feature, never before.",
                size: 13, color: .secondaryLabelColor, alignment: .center, width: Self.doorText))
            stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)
            stack.addArrangedSubview(bigButton(prompted ? "Open System Settings" : "Grant Access",
                                               action: #selector(grantPressed)))
            stack.addArrangedSubview(smallLink("not now", action: #selector(notNowPressed)))
        }

        doorRoot.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doorRoot.topAnchor, constant: Self.inset + 6),
            stack.leadingAnchor.constraint(equalTo: doorRoot.leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(equalTo: doorRoot.trailingAnchor, constant: -Self.inset),
        ])
        doorRoot.layoutSubtreeIfNeeded()
        presentDoor(waiting: waiting,
                    height: stack.fittingSize.height + Self.inset * 2 + 6)
    }

    /// Centered to be read; parked at the trailing edge to wait, so System
    /// Settings has the middle of the screen and the instructions stay on it.
    private func presentDoor(waiting: Bool, height: CGFloat) {
        let size = NSSize(width: Self.doorWidth, height: height)
        let visible = ActivePolicy.presentationFrame
        let origin = waiting
            ? NSPoint(x: visible.maxX - size.width - 20, y: visible.midY - size.height / 2)
            : NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2 + 40)
        door.setFrame(NSRect(origin: origin, size: size), display: true)
        door.orderFrontRegardless()
    }

    // MARK: - Companion copy

    private struct CardContent {
        var title: String
        var body: String
        var illustration: NSView?
        /// The gesture that answers this card, shown as caps + meaning
        /// rows. A row carrying an action is pressable as well as typable —
        /// which matters most on the first card, where the gesture being
        /// taught is the only way out and has not been learned yet.
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

    private func content(for step: Walk.Step) -> CardContent {
        switch step {
        case .lodeKey:
            return CardContent(
                title: "The lode key",
                body: "Lodestar lives on one key, your right command key. "
                    + "Hold it and the keyboard speaks to Lodestar. Release "
                    + "it and the keyboard is yours again.\n\nHold it now, "
                    + "until the map appears.",
                illustration: keyboardRow())
        case .launcher:
            return CardContent(
                title: "The launcher",
                body: "That map was your graph. More on it in a moment.\n\n"
                    + "Hold lode and tap space. Type a few letters of any "
                    + "app, then return. The app arrives maximized, "
                    + "launching first if needed.",
                illustration: capsRow([("lode", false), ("space", true)]))
        case .graphOffer(let proposals):
            return CardContent(
                title: "Your letters",
                body: "Search works. Letters are faster. Each is a permanent "
                    + "address your hand learns. These were drafted from the "
                    + "apps you have open.",
                illustration: proposalList(proposals),
                keys: [KeyRow("lode lode", "tap lode twice to take these letters",
                              action: { [weak self] in self?.assent() }),
                       KeyRow("lode ⌫", "pass",
                              action: { [weak self] in _ = self?.pass() })])
        case .graphGo(let options):
            return CardContent(
                title: "The graph",
                body: "Some of your letters. Hold lode and press one. No "
                    + "list, no search. You are simply there.\n\nThis is "
                    + "the core of Lodestar. The letters become muscle "
                    + "memory, and navigation disappears.",
                illustration: choiceList(options))
        case .inside:
            return CardContent(
                title: "Inside the app",
                body: "Lodestar also works inside the window. Hold lode and "
                    + "press ; and every button and link wears a letter. "
                    + "Press a letter to click it, or press escape to put "
                    + "the letters away. Try it now.",
                illustration: capsRow([("lode", false), (";", true)]),
                keys: [KeyRow("lode .", "search the menus of the app you are in"),
                       KeyRow("lode `", "scroll from the keyboard")])
        case .web:
            return CardContent(
                title: "The web",
                body: "Hold lode and press return to open Ask. Type a name, "
                    + "a domain, or a question. Destinations open in the "
                    + "right browser profile. Everything else searches. "
                    + "Open it now.\n\nLodestar can also stand as your "
                    + "default browser. Links clicked in any app then "
                    + "follow the same rules.",
                illustration: capsRow([("lode", false), ("⏎", true)]))
        case .clipboard:
            return CardContent(
                title: "The clipboard",
                body: "Lodestar keeps a history of what you copy. Press "
                    + "⇧⌘V and the history appears along the bottom of the "
                    + "screen, the newest clip under A. A letter pastes it "
                    + "as plain text. Open it now.\n\nThis is the one "
                    + "gesture outside lode, because pasting happens in the "
                    + "middle of typing.",
                illustration: capsRow([("⇧⌘V", true)]))
        case .sheet:
            return CardContent(
                title: "Everything else",
                body: "More gestures exist. Saved window layouts, moving "
                    + "windows between displays, text selection by eye. You "
                    + "do not need them today.\n\nHold lode and press ? "
                    + "once. The sheet holds everything, whenever you need "
                    + "it.",
                illustration: capsRow([("lode", false), ("?", true)]))
        case .done:
            return CardContent(
                title: "You are ready",
                body: "The launcher when you need to search. Letters when "
                    + "you do not. Lodestar offers the rest one suggestion "
                    + "at a time, as it learns how you work.\n\nPress "
                    + "lode ? whenever you need a reminder.",
                keys: [KeyRow("lode ⌫", "close this card",
                              action: { [weak self] in _ = self?.pass() })])
        }
    }

    // MARK: - Companion drawing

    private func renderCard() {
        guard let walk else { return }
        for view in cardRoot.subviews where view is NSStackView { view.removeFromSuperview() }
        let content = content(for: walk.step)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        if walk.step != .done {
            let progress = walk.progress
            stack.addArrangedSubview(label(
                "⌖ the walk · \(progress.position) of \(progress.total)", size: 11,
                weight: .medium, color: .tertiaryLabelColor))
        }
        stack.addArrangedSubview(label(content.title, size: 17, weight: .semibold,
                                       color: .labelColor))
        stack.addArrangedSubview(wrapped(content.body, size: 12.5,
                                         color: .secondaryLabelColor, alignment: .left,
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
        // very key the first card is still teaching. The finished card
        // trades it for a close, and is never on a clock.
        stack.setCustomSpacing(12, after: stack.arrangedSubviews.last!)
        let link = walk.step == .done
            ? smallLink("done", action: #selector(donePressed))
            : smallLink("skip this step", action: #selector(skipPressed))
        stack.addArrangedSubview(link)

        cardRoot.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: cardRoot.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: cardRoot.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: cardRoot.trailingAnchor, constant: -20),
        ])

        cardRoot.layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.cardWidth,
                          height: stack.fittingSize.height + 18 + 16)
        // Top-right corner: the launcher owns the middle, the HUD and the
        // clipboard own the bottom, so this is the quiet quarter.
        Movable.place(card, size: size) {
            let visible = ActivePolicy.presentationFrame
            return NSPoint(x: visible.maxX - size.width - 20,
                           y: visible.maxY - size.height - 20)
        }
        card.orderFrontRegardless()
    }

    // MARK: - Pieces

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
        button.font = .systemFont(ofSize: 11.5, weight: .regular)
        button.contentTintColor = .tertiaryLabelColor
        return button
    }

    private func keycap(_ text: String, lit: Bool = false, wide: Bool = false) -> NSView {
        let cap = NSTextField(labelWithString: text)
        cap.font = .systemFont(ofSize: 12, weight: .medium)
        cap.textColor = lit ? .controlAccentColor : .labelColor
        cap.alignment = .center
        cap.translatesAutoresizingMaskIntoConstraints = false

        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 5
        box.layer?.backgroundColor = NSColor.labelColor
            .withAlphaComponent(lit ? 0.14 : 0.08).cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = (lit
            ? NSColor.controlAccentColor.withAlphaComponent(0.7)
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

    /// The bottom row of a keyboard, the right command key lit: the one
    /// illustration the first card cannot do without, because "the lode
    /// key" is a name and a location is what the hand needs.
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
        row.addArrangedSubview(keycap("space", wide: true))
        row.addArrangedSubview(keycap("⌘", lit: true))
        row.addArrangedSubview(keycap("⌥"))
        column.addArrangedSubview(row)
        column.addArrangedSubview(label("the right ⌘ is lode", size: 11,
                                        weight: .regular, color: .tertiaryLabelColor))
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
            row.addArrangedSubview(label(option.label, size: 12.5, weight: .regular,
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
            row.addArrangedSubview(label(proposal.app, size: 12.5, weight: .regular,
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
        row.addArrangedSubview(label(meaning, size: 11.5, weight: .regular,
                                     color: .secondaryLabelColor))
        return row
    }

    // MARK: - Staging

    #if DEBUG
    /// `lodestar __strip-preview N` puts every walk surface on screen
    /// without a fresh install: 20 the door asking, 21 waiting at the edge,
    /// 22 granted, 23…30 the companion's eight steps, 31 the closing card,
    /// 40…51 the same with no graph.
    static func preview(_ index: Int, empty: Bool = false) -> WalkController {
        let controller = WalkController()
        var (config, _) = Config.load()
        if empty { config.graph = GraphNode() }
        controller.config = config
        // After the run loop is up: a window ordered in before the app
        // finishes launching never reaches the window server.
        DispatchQueue.main.async {
            switch index {
            case 0:
                controller.forceUntrusted = true
                controller.renderDoor(waiting: false)
                controller.door.makeKeyAndOrderFront(nil)
            case 1:
                controller.forceUntrusted = true
                controller.awaitingGrant = true
                controller.renderDoor(waiting: true)
            case 2:
                controller.renderDoor(waiting: false)
                controller.door.makeKeyAndOrderFront(nil)
            default:
                controller.beginWalk(at: index - 3)
            }
        }
        return controller
    }
    #endif
}
