import AppKit
import LodestarCore

/// The walkthrough. Lodestar changes nothing until it is summoned, which is
/// exactly why a new user can keep it and exactly why they might never find
/// it: nothing about the app announces itself. So this exists to hand over the
/// first gesture, and then to get out of the way and let the app teach itself
/// the way it already does, through guides, chips and the cheat sheet.
///
/// Two decisions shape everything here. It is **modal**, with its own backdrop,
/// so there is nothing behind it to read and nothing to be distracted by. And
/// the practice happens **inside** it: pressing `lode space` shows the searcher
/// in the lesson rather than the real one over the top of it, which means the
/// engine has to hand its keys over while this is up. What is drawn is built
/// from the same tokens as the real panels, so what the hand learns here
/// transfers without translation.
final class OnboardingController: NSObject {
    /// Written when the walkthrough is finished or skipped.
    var onFinished: (() -> Void)?
    /// Accept the drafted graph. Returns an error string, or nil on success.
    var acceptGraph: ([StarterGraph.Proposal]) -> String? = { _ in "the graph is unavailable" }
    /// Take the browser role, the same flow the menu bar item runs.
    var routeClickedLinks: () -> Void = {}
    var config = Config()
    var appIndex: AppIndex?

    private enum Step: Int, CaseIterable {
        case welcome, permission, destinations, inside, clipboard, web, close
    }

    /// A step is done when its lesson has been performed, and only then does ↵
    /// move on. Reading about a gesture is not learning it.
    private var step: Step = .welcome
    private var performed: Set<Step> = []
    private var proposals: [StarterGraph.Proposal] = []
    private var copied: [String] = []
    private var pasted = false
    private var searcherQuery = ""
    private var webQuery = ""
    private var hintTarget = "a"
    private var pastedText: String?
    private var wantsBrowserRole = false
    static let samples = ["lodestar.vaccone.software", "destination over process"]

    private var windows: [NSWindow] = []
    private let card = NSView()
    private var trustPoll: Timer?

    // MARK: - Presentation

    var isVisible: Bool { !windows.isEmpty }

    func show(startingAt trusted: Bool) {
        guard windows.isEmpty else { return }
        step = .welcome
        if trusted { performed.insert(.permission) }
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
            windows.append(window)
        }
        // The card lives on the display the pointer is on, which is the same
        // rule every other surface in the app follows.
        if let host = windows.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? windows.first {
            host.contentView?.addSubview(card)
        }
        render()
        pollTrustIfNeeded()
    }

    #if DEBUG
    /// Preview only: park the walkthrough on one screen in one state.
    func jump(to index: Int, performed done: Bool) {
        guard let target = Step(rawValue: index) else { return }
        step = target
        prepare(target)
        if done {
            performed.insert(target)
            if target == .clipboard { copied = ["lodestar.vaccone.software", "destination over process"] }
        }
        render()
    }
    #endif

    func finish() {
        trustPoll?.invalidate()
        trustPoll = nil
        let wanted = wantsBrowserRole
        wantsBrowserRole = false
        for window in windows { window.orderOut(nil) }
        windows = []
        card.removeFromSuperview()
        onFinished?()
        // After the windows are down, so the confirmation panel macOS raises is
        // not competing with a modal that is still on screen.
        if wanted { routeClickedLinks() }
    }

    // MARK: - Keys

    /// Every key while the walkthrough is up, handed over by the engine.
    /// Returning false lets something through, which is why ⌘Q still quits.
    func handle(key: String, held: Bool, shift: Bool) -> Bool {
        guard isVisible else { return false }
        switch key {
        case "escape":
            finish()
            return true
        case "return":
            advance()
            return true
        case "left":
            back()
            return true
        default:
            break
        }
        if practice(key: key, held: held, shift: shift) {
            render()
            return true
        }
        // Typing into a lesson that has a field: the searcher and the web bar.
        let typed = key
        if !held, typed.count == 1, let scalar = typed.first,
           scalar.isLetter || scalar.isNumber || scalar == "." {
            switch step {
            case .destinations where performed.contains(.destinations):
                searcherQuery += typed
                render()
                return true
            case .web where performed.contains(.web):
                webQuery += typed
                render()
                return true
            default:
                return true
            }
        }
        if key == "delete" {
            if step == .destinations, !searcherQuery.isEmpty { searcherQuery.removeLast() }
            if step == .web, !webQuery.isEmpty { webQuery.removeLast() }
            render()
            return true
        }
        // Swallow anything else so a lesson cannot leak keystrokes into the
        // apps behind it, except modified chords that are not ours.
        return !held
    }

    /// The gesture each step is teaching. True when it was just performed.
    private func practice(key: String, held: Bool, shift: Bool) -> Bool {
        switch step {
        case .destinations where held && key == "space":
            performed.insert(.destinations)
            return true
        case .inside where held && key == ";":
            performed.insert(.inside)
            return true
        case .inside where performed.contains(.inside) && key == hintTarget:
            advance()
            return true
        case .inside where performed.contains(.inside) && key == "s":
            finish()
            return true
        case .inside where performed.contains(.inside) && key == "d":
            back()
            return true
        case .permission where key == "space":
            // The instruction said space opens System Settings and nothing was
            // listening, so the one step that cannot be skipped did nothing.
            openAccessibility()
            return true
        case .clipboard where !performed.contains(.clipboard) && (key == "1" || key == "2"):
            // Static text in a window that ignores the mouse cannot be copied,
            // so a key does it. The real pasteboard, so the real history sees it.
            let index = key == "1" ? 0 : 1
            let sample = Self.samples[index]
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(sample, forType: .string)
            if !copied.contains(sample) { copied.insert(sample, at: 0) }
            return true
        case .clipboard where !held && shift && key == "v":
            performed.insert(.clipboard)
            return true
        case .clipboard where performed.contains(.clipboard) && (key == "a" || key == "s"):
            let rows = copied.isEmpty ? Self.samples : copied
            pasted = true
            pastedText = key == "a" ? rows.first : rows.dropFirst().first ?? rows.first
            return true
        case .web where held && key == "return":
            performed.insert(.web)
            return true
        case .web where performed.contains(.web) && key == "b":
            // Deferred to the end. Run here it opens System Settings behind the
            // walkthrough, which is a strange thing to have happen mid lesson.
            wantsBrowserRole = true
            return true
        case .destinations where key == "delete" && !proposals.isEmpty && !performed.contains(.destinations):
            proposals.removeLast()
            return true
        default:
            return false
        }
    }

    /// Back one step, keeping what was already performed so a step you have
    /// done does not ask you to do it again.
    private func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous == .permission && Permissions.isTrusted
            ? (Step(rawValue: previous.rawValue - 1) ?? .welcome)
            : previous
        prepare(step)
        render()
    }

    private func advance() {
        // The graph offer is taken on the way out of the step that showed it.
        if step == .destinations, !proposals.isEmpty, performed.contains(.destinations) {
            if let problem = acceptGraph(proposals) {
                Log.error("onboarding", ["graph": problem])
            }
            proposals = []
        }
        guard let next = Step(rawValue: step.rawValue + 1) else {
            markDone()
            return
        }
        if next == .permission, Permissions.isTrusted {
            performed.insert(.permission)
            step = .destinations
        } else {
            step = next
        }
        prepare(step)
        render()
    }

    private func markDone() {
        finish()
    }

    private func prepare(_ step: Step) {
        switch step {
        case .destinations:
            let running = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap(\.localizedName)
            proposals = config.graph.children.isEmpty
                ? StarterGraph.propose(running: running, existing: config.graph,
                                       reserved: Config.reservedTopLevel)
                : []
        case .clipboard:
            copied = []
            pasted = false
        default:
            break
        }
    }

    /// The permission step advances itself the moment the grant lands, which is
    /// the one place in this flow where waiting is the user's job and not ours.
    private func pollTrustIfNeeded() {
        guard step == .permission || step == .welcome, !Permissions.isTrusted else { return }
        trustPoll?.invalidate()
        trustPoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self, Permissions.isTrusted else { return }
            self.trustPoll?.invalidate()
            self.trustPoll = nil
            if self.step == .permission {
                self.performed.insert(.permission)
                self.render()
            }
        }
    }

    @objc private func openAccessibility() {
        Permissions.requestIfNeeded()
    }

    // MARK: - Copy

    private var salutation: String {
        config.yourName.isEmpty ? "" : ", \(config.yourName)"
    }

    /// Interim, and Rocco's to replace: the voice has to be his. The one detail
    /// worth keeping whatever else changes is why the name was already sitting
    /// there waiting for something to be called Lodestar.
    private var letter: String {
        """
        Lodestar was the code name of a company I tried to build. The company \
        did not happen. The name kept turning up in my notes, so I gave it to \
        the thing I actually could not stop working on: getting around my own \
        computer without thinking about it.

        Most tools for this ask you to change how you work first and pay off \
        later. I wanted the opposite. Nothing here moves your windows, remaps \
        your keys, or has an opinion about your setup until you ask it to. It \
        only helps you get somewhere when you go through it.

        That is the whole idea. Every address you make is one decision you \
        never have to make again.
        """
    }

    private struct Screen {
        var title: String
        var body: String
        var keys: [String] = []
        var state: String?
        var done: Bool = false
        var footer: String
        var lines: [String] = []
    }

    private func screen() -> Screen {
        switch step {
        case .welcome:
            return Screen(
                title: "Lodestar\(salutation)",
                body: "One instrument for getting where you are going. It stays out of the way until you ask for it.",
                state: nil,
                done: true,
                footer: "↵ continue    esc skip the walkthrough",
                lines: [
                    "Your windows stay exactly where they are.",
                    "None of your keyboard shortcuts change.",
                    "Nothing happens unless you ask for it.",
                ])
        case .permission:
            let granted = Permissions.isTrusted
            return Screen(
                title: "One permission",
                body: "Lodestar moves windows and reads their titles, and macOS asks you to allow that. It is the only thing it needs.",
                state: granted ? "granted, thank you" : "waiting. Open Privacy and Security, then Accessibility, and switch lodestar on.",
                done: granted,
                footer: granted ? "↵ continue    ← back" : "space opens System Settings    ↵ continue    esc skip")
        case .destinations:
            let did = performed.contains(.destinations)
            var lines: [String] = []
            if did, !proposals.isEmpty {
                lines.append("We drafted a graph from what you have open:")
                lines.append(proposals.map { "\($0.letter.uppercased()) → \($0.app)" }
                    .joined(separator: "     "))
                lines.append("Then lode G goes straight there, with no searching at all.")
            } else if did {
                lines.append("Reach the same app twice and it has earned an address: lode G, with no searching at all. Lodestar will offer you some once it has watched you work for a few days.")
            }
            return Screen(
                title: "Where do you want to be?",
                body: did
                    ? "That is the searcher. Type a few letters, ↵ takes you there full screen, ⇧↵ opens it beside what you have."
                    : "Hold the lode key and press space. Lode is right ⌘.",
                keys: ["lode", "space"],
                state: did ? nil : "go ahead",
                done: did,
                footer: did
                    ? (proposals.isEmpty ? "↵ continue    ← back" : "↵ take the graph    ⌫ drop the last one    ← back")
                    : "↵ continue    ← back    esc skip",
                lines: lines)
        case .inside:
            let did = performed.contains(.inside)
            return Screen(
                title: "And once you are there?",
                body: did
                    ? "Every button, link and field gets a letter, including on this panel. Type one to press it. lode , scrolls the same way, with j and k."
                    : "Hold lode and press ; — labels appear on everything pressable.",
                keys: ["lode", ";"],
                state: did ? nil : "go ahead",
                done: did,
                footer: did ? "↵ continue    ← back" : "↵ continue    ← back    esc skip")
        case .clipboard:
            let did = performed.contains(.clipboard)
            return Screen(
                title: "What did you copy?",
                body: did
                    ? "Your recent copies, labelled by the home row. Press A or S to paste one back."
                    : "Press 1 or 2 to copy one of these, then press ⇧⌘V.",
                keys: ["⇧", "⌘", "V"],
                state: pastedText.map { "pasted: \($0)" }
                    ?? (did ? "press A or S"
                        : (copied.isEmpty ? "go ahead" : "copied. now ⇧⌘V")),
                done: pasted || did,
                footer: did ? "↵ continue    ← back" : "↵ continue    ← back    esc skip",
                lines: copied.isEmpty
                    ? ["lodestar.vaccone.software", "destination over process"]
                    : copied)
        case .web:
            let did = performed.contains(.web)
            let profile = config.browserProfiles.keys.sorted().first
            return Screen(
                title: "Where on the web?",
                body: did
                    ? "Anything with a dot is a destination, anything else is a search, and a name you save becomes an address like any other."
                    : "Hold lode and press return.",
                keys: ["lode", "⏎"],
                state: did ? nil : "go ahead",
                done: did,
                footer: did ? "↵ continue    b route my clicked links too    ← back" : "↵ continue    ← back    esc skip",
                lines: did
                    ? [profile == nil
                        ? "Add browser profiles and every row learns which one it opens in."
                        : "Each row shows the profile it will open in, like \(profile!).",
                       wantsBrowserRole
                        ? "Right. When you finish here, macOS will ask you to confirm the change."
                        : "Lodestar can also catch links you click in other apps and send them to the profile your rules name. Press b to set that up when you finish."]
                    : [])
        case .close:
            return Screen(
                title: "Why this exists",
                body: letter,
                keys: ["lode", "?"],
                state: nil,
                done: true,
                footer: "↵ done    ← back",
                lines: ["Everything else lives behind lode ?, and this walkthrough is in the menu bar whenever you want it again."])
        }
    }

    // MARK: - Drawing

    private func render() {
        card.subviews.forEach { $0.removeFromSuperview() }
        let screen = self.screen()

        // The same glass every other surface in this app is made of, at the same
        // radius. A bespoke card would be the one screen that looked like a
        // different program, and it is the first screen anybody sees.
        let panel = NSView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        _ = Glass.installBackdrop(in: panel, cornerRadius: BarTheme.glassRadius)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = label(screen.title, size: 26, weight: .semibold, color: .labelColor)
        stack.addArrangedSubview(title)
        let body = label(screen.body, size: 15, weight: .regular, color: .secondaryLabelColor)
        body.preferredMaxLayoutWidth = 520
        body.lineBreakMode = .byWordWrapping
        stack.addArrangedSubview(body)
        // Title and body are one thought; everything after is a step away from
        // it. Uniform gaps read as a template rather than a page.
        stack.setCustomSpacing(6, after: title)
        stack.setCustomSpacing(18, after: body)

        if !screen.keys.isEmpty, !screen.done {
            let keys = NSStackView()
            keys.orientation = .horizontal
            keys.spacing = 6
            for key in screen.keys { keys.addArrangedSubview(keycap(key)) }
            stack.addArrangedSubview(keys)
        }

        for line in screen.lines {
            let view = label(line, size: 13, weight: .regular, color: .tertiaryLabelColor)
            view.preferredMaxLayoutWidth = 520
            view.lineBreakMode = .byWordWrapping
            stack.addArrangedSubview(view)
        }

        if let lesson = lessonView() {
            stack.addArrangedSubview(lesson)
        }



        if let state = screen.state {
            stack.addArrangedSubview(label(state, size: 13, weight: .medium,
                                           color: screen.done ? .systemGreen : .tertiaryLabelColor))
        }

        let progress = dots()
        stack.addArrangedSubview(progress)
        if let previous = stack.arrangedSubviews.dropLast().last {
            stack.setCustomSpacing(22, after: previous)
        }
        stack.setCustomSpacing(9, after: progress)
        stack.addArrangedSubview(footerRow(screen.footer))

        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 34),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -28),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 38),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -38),
            panel.widthAnchor.constraint(equalToConstant: 640),
        ])

        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: card.topAnchor),
            panel.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        if let host = card.superview {
            NSLayoutConstraint.activate([
                card.centerXAnchor.constraint(equalTo: host.centerXAnchor),
                card.centerYAnchor.constraint(equalTo: host.centerYAnchor, constant: 40),
            ])
        }
    }

    /// The lesson, drawn as the panel it is teaching. Not a screenshot: the
    /// searcher here filters the real app index, and the clipboard rows are the
    /// real pasteboard, so what is practised is the thing itself with its
    /// consequences withheld.
    private func lessonView() -> NSView? {
        switch step {
        case .destinations where performed.contains(.destinations):
            let entries = (appIndex?.query(searcherQuery).prefix(3)) ?? []
            return mockPanel(prompt: searcherQuery.isEmpty ? "Where to?" : searcherQuery,
                             symbol: "magnifyingglass",
                             rows: entries.map { entry in
                                 (entry.name,
                                  config.graph.chains(toAppNamed: entry.name).first?
                                      .map { $0.uppercased() }.joined(separator: " "),
                                  NSWorkspace.shared.icon(forFile: entry.url.path))
                             },
                             footer: "↵ open    ⇧↵ beside    esc close")
        case .clipboard where performed.contains(.clipboard):
            let rows: [String] = copied.isEmpty ? Self.samples : copied
            return mockPanel(prompt: "clipboard", symbol: "doc.on.clipboard",
                             rows: zip(["A", "S"], rows).map { ($0.1, $0.0, NSImage?.none) },
                             footer: pasted ? "pasted" : "a letter pastes it back")
        case .web where performed.contains(.web):
            let profile = config.browserProfiles.keys.sorted().first ?? "no profile yet"
            let typed = webQuery.isEmpty ? "youtube.com" : webQuery
            return mockPanel(prompt: typed, symbol: "globe",
                             rows: [(typed, profile, nil), ("Search “\(typed)”", profile, nil)],
                             footer: "↵ open    ⌘K link · route")
        default:
            return nil
        }
    }

    private func mockPanel(prompt: String, symbol: String,
                           rows: [(String, String?, NSImage?)], footer: String) -> NSView {
        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.cornerRadius = BarTheme.glassRadius
        panel.layer?.cornerCurve = .continuous
        panel.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        panel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let head = NSStackView()
        head.orientation = .horizontal
        head.spacing = 10
        let glyph = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? NSImage())
        glyph.contentTintColor = .secondaryLabelColor
        head.addArrangedSubview(glyph)
        head.addArrangedSubview(label(prompt, size: 17, weight: .regular, color: .labelColor))
        stack.addArrangedSubview(head)

        for (index, row) in rows.enumerated() {
            let line = NSStackView()
            line.orientation = .horizontal
            line.spacing = 11
            line.alignment = .centerY
            line.translatesAutoresizingMaskIntoConstraints = false
            if let icon = row.2 {
                let view = NSImageView(image: icon)
                view.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    view.widthAnchor.constraint(equalToConstant: 26),
                    view.heightAnchor.constraint(equalToConstant: 26),
                ])
                line.addArrangedSubview(view)
            }
            let name = label(row.0, size: 14, weight: index == 0 ? .medium : .regular,
                             color: index == 0 ? .labelColor : .secondaryLabelColor)
            line.addArrangedSubview(name)
            if let chip = row.1 { line.addArrangedSubview(keycap(chip, quiet: true)) }
            stack.addArrangedSubview(line)
        }
        stack.addArrangedSubview(label(footer, size: 11, weight: .regular, color: .tertiaryLabelColor))

        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            panel.widthAnchor.constraint(equalToConstant: 520),
        ])
        return panel
    }

    /// The footer, and during the hints lesson the footer *is* the lesson: a
    /// yellow label sits on each action, exactly as the real overlay puts one on
    /// everything pressable. Showing the labels on a separate row would have
    /// taught the idea while demonstrating nothing.
    private func footerRow(_ text: String) -> NSView {
        guard step == .inside, performed.contains(.inside) else {
            return label(text, size: 12, weight: .regular, color: .tertiaryLabelColor)
        }
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 14
        for (letter, what) in [(hintTarget, "↵ continue"), ("s", "esc skip"), ("d", "← back")] {
            let pair = NSStackView()
            pair.orientation = .horizontal
            pair.spacing = 6
            pair.addArrangedSubview(hintChip(letter))
            pair.addArrangedSubview(label(what, size: 12, weight: .regular,
                                          color: .tertiaryLabelColor))
            row.addArrangedSubview(pair)
        }
        return row
    }

    private func dots() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 7
        for candidate in Step.allCases where candidate != .permission {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            let reached = candidate.rawValue <= step.rawValue
            dot.layer?.backgroundColor = (reached ? NSColor.labelColor.withAlphaComponent(0.7)
                : NSColor.labelColor.withAlphaComponent(0.18)).cgColor
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

    /// The hint label, as the real overlay draws it: a small filled square with
    /// a letter in it, so the lesson and the thing it teaches look alike.
    private func hintChip(_ letter: String) -> NSView {
        let cap = NSTextField(labelWithString: letter.uppercased())
        cap.font = .systemFont(ofSize: 12, weight: .bold)
        cap.textColor = .black
        cap.alignment = .center
        cap.translatesAutoresizingMaskIntoConstraints = false

        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 3
        box.layer?.backgroundColor = NSColor.systemYellow.cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(cap)
        NSLayoutConstraint.activate([
            cap.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            cap.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            box.widthAnchor.constraint(equalToConstant: 20),
            box.heightAnchor.constraint(equalToConstant: 18),
        ])
        return box
    }

    private func keycap(_ text: String, quiet: Bool = false) -> NSView {
        let cap = NSTextField(labelWithString: text)
        cap.font = .systemFont(ofSize: quiet ? 11 : 13, weight: .medium)
        cap.textColor = quiet ? .tertiaryLabelColor : .labelColor
        cap.alignment = .center
        cap.translatesAutoresizingMaskIntoConstraints = false

        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 5
        box.layer?.backgroundColor = NSColor.white.withAlphaComponent(quiet ? 0.07 : 0.13).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(cap)
        NSLayoutConstraint.activate([
            cap.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
            cap.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            cap.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            box.heightAnchor.constraint(equalToConstant: quiet ? 18 : 24),
        ])
        return box
    }
}

/// What sits behind the walkthrough: the desktop made unreadable, a faint glow
/// where the reading happens, and the lodestar mark drawn large and almost
/// invisible. Not a grey sheet. The app is named for a star you steer by, and
/// this is the one screen with room to say so.
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
        // Above the blur, not below it. Drawn underneath, the scrim and the
        // mark were invisible and all that showed was a dimmed desktop.
        let sky = Starfield(frame: bounds)
        sky.autoresizingMask = [.width, .height]
        addSubview(sky)
    }

    required init?(coder: NSCoder) { nil }
}

/// The dark, and stars.
///
/// The first version put one large eight pointed mark behind the card and it
/// read as a decal pasted onto the desktop. This is the same idea done as
/// scenery: the desktop blurred past recognition, a wash of dark over it, and a
/// scattering of small stars with a few brighter ones. Positions come from a
/// fixed seed rather than a random one, so the sky is the same every time it
/// draws instead of twinkling on every relayout.
private final class Starfield: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.66).setFill()
        bounds.fill()

        var seed: UInt64 = 0x5EED_1ADE_5748
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((seed >> 33) % 100_000) / 100_000
        }

        // A quiet glow where the reading happens, so the card has ground.
        let center = NSPoint(x: bounds.midX, y: bounds.midY + 40)
        if let gradient = NSGradient(colors: [
            NSColor.white.withAlphaComponent(0.055),
            NSColor.white.withAlphaComponent(0.0),
        ]) {
            gradient.draw(fromCenter: center, radius: 0,
                          toCenter: center, radius: bounds.width * 0.45, options: [])
        }

        for index in 0..<220 {
            let x = next() * bounds.width
            let y = next() * bounds.height
            let roll = next()
            // Thin the field where the card sits: stars behind text are noise.
            let distance = hypot(x - center.x, y - center.y)
            if distance < 380, roll > 0.25 { continue }

            let size = roll > 0.94 ? 2.6 : (roll > 0.72 ? 1.8 : 1.1)
            let alpha = roll > 0.94 ? 0.34 : (roll > 0.72 ? 0.20 : 0.11)
            NSColor.white.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: size, height: size)).fill()

            // Every so often, one with points on it.
            if index.isMultiple(of: 37) {
                let reach = 7.0 + roll * 5
                NSColor.white.withAlphaComponent(0.16).setStroke()
                let spikes = NSBezierPath()
                spikes.lineWidth = 0.8
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
/// Visual harness for the walkthrough, which otherwise needs a whole app and a
/// state file that says it has not been seen. Every screen, in both the state
/// before its lesson and the state after, because those are two designs and
/// only one of them was ever being looked at.
extension OnboardingController {
    static func preview(_ index: Int, performed done: Bool = false) -> OnboardingController {
        let controller = OnboardingController()
        controller.appIndex = { let index = AppIndex(); index.refresh(); return index }()
        var (config, _) = Config.load()
        config.yourName = ""
        controller.config = config
        controller.show(startingAt: true)
        controller.jump(to: index, performed: done)
        return controller
    }
}
#endif
