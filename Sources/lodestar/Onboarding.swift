import AppKit
import LodestarCore

/// The walkthrough: one card per tool, in the order the tools build on each
/// other, and the real panel every time somebody presses a key.
///
/// Lodestar changes nothing until it is summoned, which is exactly why a new
/// user can keep it and exactly why they might never find it. So this hands
/// over the vocabulary and then stops, because after that the app teaches
/// itself through guides, chips and the cheat sheet.
///
/// Two decisions shape it. Each card is **named for its tool** rather than for
/// a problem: somebody who knows what the graph is can work out when to reach
/// for it, while somebody told only about outcomes has to be taught each one.
/// And a lesson is **the real panel**: on the practice key the walkthrough steps
/// out of the way, the actual searcher or clipboard or hint overlay runs over
/// the user's own windows, and the card returns when the screen is quiet again.
/// Nothing here is a drawing of a panel that can drift out of date, and the hint
/// overlay finally has something real to label.
final class OnboardingController: NSObject {
    var onFinished: (() -> Void)?
    /// Accept the drafted graph. An error string, or nil on success.
    var acceptGraph: ([StarterGraph.Proposal]) -> String? = { _ in "the graph is unavailable" }
    /// Save what to call the user.
    var saveName: (String) -> Void = { _ in }
    /// Take the browser role, deferred until the walkthrough is down.
    var routeClickedLinks: () -> Void = {}
    /// True when no panel, chain or strip is up: how a card knows its lesson has
    /// finished without any panel having to report to it.
    var screenIsQuiet: () -> Bool = { true }
    var config = Config()

    enum Card: Int, CaseIterable {
        case permission, searcher, graph, breaths, inside, actions, clipboard, web, note
    }

    private var card: Card = .permission
    private var performed: Set<Card> = []
    private var proposals: [StarterGraph.Proposal] = []
    private var nameDraft = ""
    private var wantsBrowserRole = false
    /// Set while the real panel has the screen: every key goes to the engine and
    /// none to this, which is the whole point of stepping aside.
    private var steppedAside = false
    private var watch: Timer?

    /// A floor, not a fixed size. Sized purely to its own content the panel grew
    /// and shrank on every keystroke, which reads as unfinished; equalised to the
    /// tallest card it left the short ones two thirds empty. A floor holds every
    /// ordinary card at one height and lets the closing note be the only card
    /// that is taller.
    private static let minimumHeight: CGFloat = 296
    private static let cardWidth: CGFloat = 560
    private static let textWidth: CGFloat = 470

    private var backdrops: [NSWindow] = []
    private let panel = Glass.makePanel(level: .modalPanel)
    private let root = NSView()
    private var trustPoll: Timer?

    override init() {
        super.init()
        panel.ignoresMouseEvents = true
        panel.contentView = root
        _ = Glass.installBackdrop(in: root, cornerRadius: BarTheme.glassRadius)
    }

    // MARK: - Presentation

    var isVisible: Bool { !backdrops.isEmpty }

    func show() {
        guard backdrops.isEmpty else { return }
        card = .permission
        performed = []
        nameDraft = config.yourName
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.level = .modalPanel
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.contentView = Backdrop(frame: NSRect(origin: .zero, size: screen.frame.size))
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            backdrops.append(window)
        }
        prepare()
        render()
        pollTrust()
    }

    func finish() {
        trustPoll?.invalidate(); trustPoll = nil
        watch?.invalidate(); watch = nil
        let wanted = wantsBrowserRole
        wantsBrowserRole = false
        steppedAside = false
        saveNameIfChanged()
        panel.orderOut(nil)
        for window in backdrops { window.orderOut(nil) }
        backdrops = []
        onFinished?()
        // After the walkthrough is down, so the panel macOS raises to confirm a
        // browser change is not competing with a modal still on screen.
        if wanted { routeClickedLinks() }
    }

    // MARK: - Keys

    /// Every key while the walkthrough owns the screen. Returning false hands the
    /// key to the engine, which is what makes stepping aside work and what
    /// leaves ⌘Q alone.
    func handle(key: String, held: Bool, shift: Bool) -> Bool {
        guard isVisible, !steppedAside else { return false }

        if key == "escape" {
            finish()
            return true
        }
        if key == "return", !held {
            advance()
            return true
        }
        if key == "delete" {
            // Backspace is back, except where there is something to unsay.
            if card == .permission, !nameDraft.isEmpty {
                nameDraft.removeLast()
            } else if card == .graph, !proposals.isEmpty {
                proposals.removeLast()
            } else {
                back()
                return true
            }
            render()
            return true
        }
        if card == .permission, key == "space" {
            Permissions.requestIfNeeded()
            return true
        }
        if card == .permission, !held, key.count == 1, let scalar = key.first,
           scalar.isLetter || scalar.isNumber || scalar == "-" {
            nameDraft += shift ? key.uppercased() : key
            render()
            return true
        }
        if card == .web, !held, key == "b" {
            wantsBrowserRole = true
            render()
            return true
        }
        // The practice gesture: hand it to the engine and get out of the way.
        if let lesson = Card.lesson(for: card),
           lesson.matches(key: key, held: held, shift: shift) {
            stepAside()
            return false
        }
        // Everything else is swallowed, so a card cannot leak keystrokes into
        // whatever is behind it.
        return !held
    }

    /// Hide, let the real panel have the screen, and come back once the screen is
    /// quiet. The delay before watching is not politeness: on the keystroke that
    /// opens a panel the panel is not open yet, so an immediate quiet check would
    /// pass and snap the card straight back.
    private func stepAside() {
        steppedAside = true
        performed.insert(card)
        panel.orderOut(nil)
        for window in backdrops { window.orderOut(nil) }
        watch?.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.steppedAside else { return }
            self.watch = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
                guard let self else { return timer.invalidate() }
                guard self.screenIsQuiet() else { return }
                timer.invalidate()
                self.watch = nil
                self.steppedAside = false
                for window in self.backdrops { window.orderFrontRegardless() }
                self.render()
            }
        }
    }

    private func back() {
        guard let previous = Card(rawValue: card.rawValue - 1) else { return }
        card = previous
        prepare()
        render()
    }

    private func advance() {
        if card == .permission { saveNameIfChanged() }
        if card == .graph, !proposals.isEmpty {
            if let problem = acceptGraph(proposals) { Log.error("onboarding", ["graph": problem]) }
            proposals = []
        }
        guard let next = Card(rawValue: card.rawValue + 1) else {
            finish()
            return
        }
        card = next
        prepare()
        render()
    }

    private func prepare() {
        guard card == .graph else { return }
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
        proposals = config.graph.children.isEmpty
            ? StarterGraph.propose(running: running, existing: config.graph,
                                   reserved: Config.reservedTopLevel)
            : []
    }

    private func saveNameIfChanged() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespaces)
        guard trimmed != config.yourName else { return }
        config.yourName = trimmed
        saveName(trimmed)
    }

    private func pollTrust() {
        guard !Permissions.isTrusted else { return }
        trustPoll?.invalidate()
        trustPoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self, Permissions.isTrusted else { return }
            self.trustPoll?.invalidate(); self.trustPoll = nil
            if self.card == .permission { self.render() }
        }
    }

    // MARK: - Copy

    private struct Content {
        var title: String
        var body: String
        var keys: [String] = []
        var lines: [String] = []
        var state: String?
        var stateIsGood = false
        var footer: String
    }

    /// Interim, and Rocco's to replace: the voice has to be his. The detail worth
    /// keeping whatever else changes is why the name was already waiting.
    private static let letter = """
    Lodestar was the code name of a company I tried to build. The company did \
    not happen; the name stayed in my notes until I gave it to the thing I \
    could not stop working on, which was getting around my own computer without \
    thinking about it.

    Most tools for this ask you to change how you work first and pay you back \
    later. This one asks for nothing until you go through it.

    Every address you make is a decision you never make again.
    """

    private func content() -> Content {
        let did = performed.contains(card)
        switch card {
        case .permission:
            let granted = Permissions.isTrusted
            return Content(
                title: "Accessibility",
                body: "Lodestar moves windows and reads their titles. macOS requires permission for that, and it is the only permission it asks for.",
                lines: ["Lodestar uses your name sparingly, and never sends it anywhere."],
                state: granted ? "Granted." : "Not granted yet.",
                stateIsGood: granted,
                footer: granted ? "↵ continue" : "space opens System Settings    ↵ continue")
        case .searcher:
            return Content(
                title: "Searcher",
                body: "Lodestar keeps one app in front of you, or the few you asked for. The searcher is how they open: lode space, type, ↵. ⇧↵ opens one beside what you already have.",
                keys: ["lode", "space"],
                state: did ? "Tried." : "Press it. The real searcher opens.",
                stateIsGood: did,
                footer: "↵ continue    ⌫ back")
        case .graph:
            var lines: [String] = []
            if !proposals.isEmpty {
                lines.append("Drafted from what you have open:")
                lines.append(proposals.map { "\($0.letter.uppercased())   \($0.app)" }
                    .joined(separator: "      "))
            } else {
                let bound = config.graph.leaves()
                    .sorted { $0.chain.joined() < $1.chain.joined() }
                    .prefix(6)
                    .map { "\($0.chain.map { $0.uppercased() }.joined(separator: " "))   \($0.target.label)" }
                if !bound.isEmpty {
                    lines.append("Yours so far:")
                    lines.append(bound.joined(separator: "      "))
                }
            }
            return Content(
                title: "Graph",
                body: "A destination you keep returning to earns a letter instead of a search. ⌘K on a searcher row binds one, and lode G goes straight there.",
                lines: lines,
                footer: proposals.isEmpty
                    ? "↵ continue    ⌫ back"
                    : "↵ take these    ⌫ drop the last one")
        case .breaths:
            return Content(
                title: "Breaths",
                body: "A breath is a snapshot of the arrangement in front of you. lode ' saves one under a letter and returns to it later, which is also where an app you do not want in the graph can live.",
                lines: ["lode 1 through 9 moves between the windows on screen, left to right."],
                footer: "↵ continue    ⌫ back")
        case .inside:
            return Content(
                title: "Inside a window",
                body: "lode ; labels every clickable element with a letter. Type one to press it. lode , scrolls with j and k, half pages with d and u.",
                keys: ["lode", ";"],
                state: did ? "Tried." : "Press it. The labels land on your own window.",
                stateIsGood: did,
                footer: "↵ continue    ⌫ back")
        case .actions:
            return Content(
                title: "Action menu",
                body: "lode . searches the menu bar of the app in front of you and runs what you choose. Every menu command, without opening a menu.",
                keys: ["lode", "."],
                state: did ? "Tried." : "Press it. This app's menus become searchable.",
                stateIsGood: did,
                footer: "↵ continue    ⌫ back")
        case .clipboard:
            return Content(
                title: "Clipboard",
                body: "⇧⌘V shows what you have copied, each labelled by a home row letter. Pins climb the left edge and stay there.",
                keys: ["⇧⌘V"],
                lines: ["The order changes only when you copy, so a letter keeps meaning the same clip."],
                state: did ? "Tried." : "Press it. Your history appears.",
                stateIsGood: did,
                footer: "↵ continue    ⌫ back")
        case .web:
            let profile = config.browserProfiles.keys.sorted().first
            return Content(
                title: "Web bar",
                body: "lode ⏎ is the same grammar for the web: a named link, a bare domain, or a search. Each opens in the browser profile your rules name\(profile.map { ", such as \($0)" } ?? "").",
                keys: ["lode", "⏎"],
                lines: [wantsBrowserRole
                    ? "Clicked links: on. macOS will ask you to confirm once you finish here."
                    : "Lodestar can take links clicked in other apps and route them the same way. Press b to set that up."],
                state: did ? "Tried." : "Press it. The real bar opens.",
                stateIsGood: did,
                footer: "↵ continue    b route clicked links    ⌫ back")
        case .note:
            return Content(
                title: "Why this exists",
                body: Self.letter,
                lines: ["lode ? holds every gesture, and this walkthrough is in the menu bar whenever you want it again."],
                footer: "↵ done    ⌫ back")
        }
    }

    // MARK: - Drawing

    private func render() {
        for view in root.subviews where view is NSStackView { view.removeFromSuperview() }
        let stack = buildStack(content())
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            // Centred, not pinned to the top: with a height floor the slack has
            // to go somewhere, and split above and below it reads as composed
            // rather than as a card that ran out of things to say.
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: root.topAnchor, constant: 28),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 34),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -34),
        ])
        // Lay out at the final width first, or the measurement is of text that
        // has not wrapped yet.
        panel.setFrame(NSRect(x: 0, y: 0, width: Self.cardWidth, height: Self.minimumHeight),
                       display: false)
        root.layoutSubtreeIfNeeded()
        let height = max(Self.minimumHeight, stack.fittingSize.height + 56)
        let visible = ActivePolicy.presentationFrame
        panel.setFrame(NSRect(x: visible.midX - Self.cardWidth / 2,
                              y: visible.midY - height / 2 + 30,
                              width: Self.cardWidth, height: height), display: true)
        panel.orderFrontRegardless()
    }

    private func buildStack(_ content: Content) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = label(content.title, size: 25, weight: .semibold, color: .labelColor)
        stack.addArrangedSubview(title)
        let body = wrapped(content.body, size: 14.5, color: .secondaryLabelColor)
        stack.addArrangedSubview(body)
        stack.setCustomSpacing(5, after: title)
        stack.setCustomSpacing(17, after: body)

        if !content.keys.isEmpty {
            let keys = NSStackView()
            keys.orientation = .horizontal
            keys.spacing = 6
            for key in content.keys { keys.addArrangedSubview(keycap(key)) }
            stack.addArrangedSubview(keys)
            stack.setCustomSpacing(15, after: keys)
        }

        if let state = content.state, card == .permission {
            stack.addArrangedSubview(label(state, size: 12.5, weight: .medium,
                                           color: content.stateIsGood
                                               ? .controlAccentColor : .tertiaryLabelColor))
            stack.addArrangedSubview(nameField())
        }

        for line in content.lines {
            stack.addArrangedSubview(wrapped(line, size: 12.5, color: .tertiaryLabelColor))
        }

        if let state = content.state, card != .permission {
            stack.addArrangedSubview(label(state, size: 12.5, weight: .medium,
                                           color: content.stateIsGood
                                               ? .controlAccentColor : .tertiaryLabelColor))
        }
        if let last = stack.arrangedSubviews.last {
            stack.setCustomSpacing(20, after: last)
        }

        let progress = dots()
        stack.addArrangedSubview(progress)
        stack.setCustomSpacing(9, after: progress)
        stack.addArrangedSubview(label(content.footer, size: 11.5, weight: .regular,
                                       color: .tertiaryLabelColor))

        return stack
    }

    /// A field, drawn as one. Written as a grey sentence it read as another
    /// caption and nobody would think to type into it.
    private func nameField() -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 7
        box.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.45).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false

        let caption = label("Name", size: 11.5, weight: .regular, color: .tertiaryLabelColor)
        let value = label(nameDraft.isEmpty ? "" : nameDraft, size: 14,
                          weight: .regular, color: .labelColor)
        let caret = NSView()
        caret.wantsLayer = true
        caret.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        caret.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [caption, value, caret])
        row.orientation = .horizontal
        row.spacing = 9
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false

        box.addSubview(row)
        NSLayoutConstraint.activate([
            caret.widthAnchor.constraint(equalToConstant: 1.5),
            caret.heightAnchor.constraint(equalToConstant: 15),
            row.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 11),
            row.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            box.heightAnchor.constraint(equalToConstant: 34),
            box.widthAnchor.constraint(equalToConstant: 250),
        ])
        return box
    }

    private func dots() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 7
        for candidate in Card.allCases {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.layer?.backgroundColor = candidate == card
                ? NSColor.controlAccentColor.cgColor
                : NSColor.labelColor.withAlphaComponent(
                    candidate.rawValue < card.rawValue ? 0.45 : 0.15).cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 6),
                dot.heightAnchor.constraint(equalToConstant: 6),
            ])
            row.addArrangedSubview(dot)
        }
        return row
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight,
                       color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private func wrapped(_ text: String, size: CGFloat, color: NSColor) -> NSTextField {
        let field = label(text, size: size, weight: .regular, color: color)
        field.preferredMaxLayoutWidth = Self.textWidth
        field.lineBreakMode = .byWordWrapping
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        return field
    }

    private func keycap(_ text: String) -> NSView {
        let cap = NSTextField(labelWithString: text)
        cap.font = .systemFont(ofSize: 12.5, weight: .medium)
        cap.textColor = .labelColor
        cap.alignment = .center
        cap.translatesAutoresizingMaskIntoConstraints = false

        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 5
        box.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.11).cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(cap)
        NSLayoutConstraint.activate([
            cap.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 9),
            cap.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -9),
            cap.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            box.heightAnchor.constraint(equalToConstant: 24),
        ])
        return box
    }
}

/// The gesture a card teaches, declared beside the card so the two cannot drift.
extension OnboardingController.Card {
    struct Lesson {
        let key: String
        var held = true
        var shift = false

        func matches(key pressed: String, held pressedHeld: Bool, shift pressedShift: Bool) -> Bool {
            pressed == key && pressedHeld == held && (!shift || pressedShift)
        }
    }

    static func lesson(for card: OnboardingController.Card) -> Lesson? {
        switch card {
        case .searcher: return Lesson(key: "space")
        case .inside: return Lesson(key: ";")
        case .actions: return Lesson(key: ".")
        case .clipboard: return Lesson(key: "v", held: false, shift: true)
        case .web: return Lesson(key: "return")
        default: return nil
        }
    }
}

/// What sits behind the walkthrough: the desktop blurred past reading, a wash of
/// dark over it, and a sky. An earlier version drew one large mark instead and it
/// read as a decal pasted onto the desktop.
private final class Backdrop: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let blur = NSVisualEffectView(frame: bounds)
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        addSubview(blur)
        let sky = Sky(frame: bounds)
        sky.autoresizingMask = [.width, .height]
        addSubview(sky)
    }

    required init?(coder: NSCoder) { nil }
}

private final class Sky: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.64).setFill()
        bounds.fill()

        // The one place colour belongs: a wash in the user's own accent behind
        // where the reading happens, so this is not another grey sheet.
        let center = NSPoint(x: bounds.midX, y: bounds.midY + 30)
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        if let gradient = NSGradient(colors: [accent.withAlphaComponent(0.11),
                                              accent.withAlphaComponent(0.0)]) {
            gradient.draw(fromCenter: center, radius: 0,
                          toCenter: center, radius: bounds.width * 0.42, options: [])
        }

        var seed: UInt64 = 0x5EED_1ADE_5748
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((seed >> 33) % 100_000) / 100_000
        }

        for index in 0..<240 {
            let x = next() * bounds.width
            let y = next() * bounds.height
            let roll = next()
            // Thinned where the card sits: stars behind text are noise.
            if hypot(x - center.x, y - center.y) < 400, roll > 0.2 { continue }
            let size = roll > 0.95 ? 2.4 : (roll > 0.74 ? 1.7 : 1.1)
            let alpha = roll > 0.95 ? 0.32 : (roll > 0.74 ? 0.19 : 0.10)
            NSColor.white.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: size, height: size)).fill()
            if index.isMultiple(of: 41) {
                let reach = 6.0 + roll * 5
                NSColor.white.withAlphaComponent(0.13).setStroke()
                let spikes = NSBezierPath()
                spikes.lineWidth = 0.7
                spikes.move(to: NSPoint(x: x - reach, y: y))
                spikes.line(to: NSPoint(x: x + reach, y: y))
                spikes.move(to: NSPoint(x: x, y: y - reach))
                spikes.line(to: NSPoint(x: x, y: y + reach))
                spikes.stroke()
            }
        }
    }
}

#if DEBUG
/// Visual harness: every card, without a whole app or a state file that says the
/// walkthrough has not been seen.
extension OnboardingController {
    static func preview(_ index: Int, performed done: Bool = false) -> OnboardingController {
        let controller = OnboardingController()
        var (config, _) = Config.load()
        config.yourName = ""
        controller.config = config
        controller.show()
        controller.jump(to: index, performed: done)
        return controller
    }

    func jump(to index: Int, performed done: Bool) {
        guard let target = Card(rawValue: index) else { return }
        card = target
        prepare()
        if done { performed.insert(target) }
        render()
    }
}
#endif
