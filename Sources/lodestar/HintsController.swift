import AppKit
import LodestarCore

/// Click hints (`lode ;` / sticky `lode ⇧;`): label every pressable
/// element of the focused window, type a label to press it — the mouse's
/// last territory annexed. Harvest is async and bounded (a heavy Chromium
/// page must never stall the overlay), labels come from the user's own
/// alphabet, and ⇧label right-clicks.
final class HintsController {
    struct Target {
        let element: AXUIElement
        let frame: CGRect
        let isTextInput: Bool
    }

    private let model: WindowModel
    private let overlay = HintOverlay()

    /// Refreshed from config at boot and reload.
    var letters = "asdfghjkl"
    var rescanDelay: TimeInterval = 0.4

    private var targets: [Target] = []
    private var labels: [String] = []
    private var typed = ""
    private var generation = 0
    private var sticky = false
    private var windowFrame: CGRect = .zero
    private var appName = ""

    /// Roles that press. Rows and cells are deliberately absent — they
    /// explode label counts and rarely beat scrolling.
    private static let pressableRoles: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXMenuButton", "AXComboBox", "AXDisclosureTriangle", "AXMenuItem",
        "AXSegment", "AXSwitch", "AXToggle",
    ]
    private static let textRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXSearchField",
    ]

    init(model: WindowModel) {
        self.model = model
    }

    // MARK: - Lifecycle

    func enter(sticky: Bool) -> Bool {
        guard let window = model.focusedWindow, window.isAlive else { return false }
        self.sticky = sticky
        typed = ""
        targets = []
        labels = []
        windowFrame = window.frame
        appName = window.appName
        generation += 1
        overlay.showScanning(over: window.frame, appName: window.appName, sticky: sticky)
        harvest(window: window, generation: generation)
        return true
    }

    func exit() {
        generation += 1
        typed = ""
        overlay.hide()
    }

    /// Sticky mode, after a fire: the app may have changed — give it a
    /// beat, then relabel whatever the window looks like now.
    func rescan() {
        typed = ""
        generation += 1
        let expected = generation
        overlay.clearTyped()
        DispatchQueue.main.asyncAfter(deadline: .now() + rescanDelay) { [weak self] in
            guard let self, self.generation == expected else { return }
            guard let window = self.model.focusedWindow, window.isAlive else {
                self.exit()
                return
            }
            self.windowFrame = window.frame
            self.appName = window.appName
            self.overlay.showScanning(over: window.frame, appName: window.appName, sticky: true)
            self.harvest(window: window, generation: expected)
        }
    }

    func backspace() {
        guard !typed.isEmpty else { return }
        typed.removeLast()
        overlay.filter(typed: typed)
    }

    func type(_ letter: String, shift: Bool) -> HintStep {
        let candidate = typed + letter
        switch HintLabels.match(typed: candidate, labels: labels) {
        case .exact(let index):
            // The match above is pure, so the verdict is already settled;
            // pressing is a call into another app from inside the event tap,
            // and a wedged one would hold every key on the machine for the
            // full accessibility timeout.
            //
            // What follows a fire is `exitHints` or a delayed `hintRescan`,
            // and both only take down an overlay that already ignores mouse
            // events, so a press or a right-click lands the same either way.
            // The one case carrying an ordering question is a text input,
            // where firing means focusing and what you type next belongs in
            // it: against an app slow enough for this to matter, a character
            // typed blind could reach the old focus first. That is one
            // interaction with an app that is already wedged, weighed
            // against stalling the keyboard for every app on the machine —
            // so it goes off the tap. Bounding these calls with a
            // per-element messaging timeout is the answer that would give us
            // both, and it wants measurement first: Electron trees are
            // legitimately slow, and a guessed ceiling would break them.
            let target = targets[index]
            OffTap.run { [weak self] in self?.fire(target, rightClick: shift) }
            typed = ""
            return .fired
        case .partial:
            typed = candidate
            overlay.filter(typed: typed)
            return .pending
        case .none:
            return .ignored
        }
    }

    // MARK: - Acting

    private func fire(_ target: Target, rightClick: Bool) {
        if rightClick {
            // The element's own context-menu action when it has one; a
            // synthetic right-click at its center otherwise.
            if AXUIElementPerformAction(target.element, "AXShowMenu" as CFString) == .success {
                Log.info("hint", ["action": "show-menu"])
                return
            }
            let point = CGPoint(x: target.frame.midX, y: target.frame.midY)
            if let down = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown,
                                  mouseCursorPosition: point, mouseButton: .right),
               let up = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp,
                                mouseCursorPosition: point, mouseButton: .right) {
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
            Log.info("hint", ["action": "right-click"])
            return
        }
        if target.isTextInput {
            AX.set(target.element, kAXFocusedAttribute, to: true)
            Log.info("hint", ["action": "focus-text"])
            return
        }
        let pressed = AXUIElementPerformAction(target.element, kAXPressAction as CFString) == .success
        Log.info("hint", ["action": "press", "ok": pressed])
    }

    // MARK: - Harvest

    /// Bounded walk of the focused window's element tree, off the main
    /// thread. Electron apps need AXManualAccessibility flipped before
    /// their tree exists; setting it is harmless everywhere else.
    private func harvest(window: WindowModel.Window, generation expected: Int) {
        let windowElement = window.element
        let windowFrame = window.frame
        let pid = window.pid
        let capacity = HintLabels.capacity(alphabet: letters)
        let began = Date()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)

            var found: [Target] = []
            var seenFrames = Set<String>()
            var visited = 0
            let deadline = Date().addingTimeInterval(1.2)

            func frame(of element: AXUIElement) -> CGRect? {
                guard let position = AX.point(element, kAXPositionAttribute),
                      let size = AX.size(element, kAXSizeAttribute) else { return nil }
                return CGRect(origin: position, size: size)
            }

            func walk(_ element: AXUIElement, depth: Int) {
                guard depth < 28, visited < 2800, found.count < capacity,
                      Date() < deadline else { return }
                visited += 1

                if let role = AX.string(element, kAXRoleAttribute) {
                    let pressable = Self.pressableRoles.contains(role)
                    let textInput = Self.textRoles.contains(role)
                    if pressable || textInput,
                       let elementFrame = frame(of: element),
                       elementFrame.width >= 5, elementFrame.height >= 5,
                       elementFrame.intersects(windowFrame) {
                        let key = "\(Int(elementFrame.minX)):\(Int(elementFrame.minY)):\(Int(elementFrame.width))"
                        if !seenFrames.contains(key) {
                            seenFrames.insert(key)
                            found.append(Target(element: element, frame: elementFrame,
                                                isTextInput: textInput && !pressable))
                        }
                    }
                }
                guard let children = AX.elements(element, kAXChildrenAttribute) else { return }
                for child in children {
                    walk(child, depth: depth + 1)
                }
            }

            walk(windowElement, depth: 0)
            let elapsed = Int(Date().timeIntervalSince(began) * 1000)

            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == expected else { return }
                self.targets = found
                self.labels = HintLabels.labels(count: found.count, alphabet: self.letters)
                Log.info("hints", ["targets": found.count, "visited": visited,
                                   "ms": elapsed, "app": self.appName])
                self.overlay.show(labels: zip(self.labels, found.map(\.frame)).map { ($0, $1) },
                                  over: self.windowFrame, appName: self.appName,
                                  sticky: self.sticky)
            }
        }
    }
}


/// The one chip design, shared by every overlay that labels the screen —
/// hints and select draw literally the same object, so the styles cannot
/// drift. Clear liquid glass over a quiet scrim, 12pt bold mono caps with
/// an opposite-color halo, lifted by a soft shadow. (See the readability
/// saga in the project memory before changing any of this.)
enum GlassChip {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    static let height: CGFloat = 18

    static func make(_ text: String) -> (chip: NSView, label: NSTextField) {
        let dark = Tone.systemDark
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = font
        // Explicit, not labelColor: the label sits inside the material's
        // contentView, where the glass stamps its backdrop-adapted
        // appearance — labelColor there can resolve against the system's
        // tone, which is the invisible-text bug in one line.
        label.textColor = dark ? .white : NSColor(white: 0.12, alpha: 1)
        label.alignment = .center
        let halo = NSShadow()
        halo.shadowColor = dark
            ? NSColor.black.withAlphaComponent(0.7)
            : NSColor.white.withAlphaComponent(0.85)
        halo.shadowBlurRadius = 2
        halo.shadowOffset = .zero
        label.shadow = halo
        label.sizeToFit()

        let chip: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 4.5
            glass.style = .clear
            let scrim = EqualizerScrim()
            scrim.darkBase = 0.45
            scrim.lightBase = 0.55
            scrim.wantsLayer = true
            scrim.layer?.cornerRadius = 4.5
            scrim.autoresizingMask = [.width, .height]
            scrim.addSubview(label)
            glass.contentView = scrim
            chip = glass
        } else {
            let fallback = NSView()
            Glass.installBackdrop(in: fallback, cornerRadius: 4.5)
            fallback.addSubview(label)
            chip = fallback
        }
        lift(chip)
        return (chip, label)
    }

    static func lift(_ view: NSView) {
        view.wantsLayer = true
        view.layer?.masksToBounds = false
        view.layer?.shadowColor = NSColor.black.withAlphaComponent(0.4).cgColor
        view.layer?.shadowOpacity = 1
        view.layer?.shadowRadius = 3.5
        view.layer?.shadowOffset = CGSize(width: 0, height: -1)
    }
}

/// One transparent panel over the focused window, chips at every target.
/// High-contrast solid chips — glass would vanish on busy pages.
final class HintOverlay {
    private let panel: NSPanel
    private let root = NSView()
    private let chipHost = NSView()
    private var chips: [(view: NSView, label: NSTextField, text: String)] = []
    private let status = NSTextField(labelWithString: "")
    private let statusChip = NSView()
    /// Held, because the band's clearance depends on which display the
    /// overlay landed on and whether the Dock is along its bottom.
    private var statusBottom: NSLayoutConstraint!

    private static let chipFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    /// Grown with the label: at 16 a 12pt chip hugs its text hard enough to
    /// read as clipped.
    private static let chipHeight: CGFloat = 18
    /// Clear water between the band and the bottom of the usable screen.
    private static let bandGap: CGFloat = 10

    init() {
        panel = Glass.makePanel(level: .statusBar)
        panel.ignoresMouseEvents = true
        panel.contentView = root

        // Chips live inside a glass-effect container: similar glass views
        // render as a batch instead of one compositor pass each.
        if #available(macOS 26.0, *) {
            let container = NSGlassEffectContainerView()
            container.contentView = chipHost
            container.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(container)
            NSLayoutConstraint.activate([
                container.topAnchor.constraint(equalTo: root.topAnchor),
                container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ])
        } else {
            chipHost.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(chipHost)
            NSLayoutConstraint.activate([
                chipHost.topAnchor.constraint(equalTo: root.topAnchor),
                chipHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                chipHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                chipHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ])
        }

        // The status line is a miniature guide panel — same glass as
        // everything else in the system.
        statusChip.translatesAutoresizingMaskIntoConstraints = false
        Glass.installBackdrop(in: statusChip, cornerRadius: 10)
        Self.lift(statusChip)
        status.font = .systemFont(ofSize: 11.5, weight: .medium)
        status.textColor = .labelColor
        status.translatesAutoresizingMaskIntoConstraints = false
        statusChip.addSubview(status)
        root.addSubview(statusChip)
        statusBottom = statusChip.bottomAnchor.constraint(equalTo: root.bottomAnchor,
                                                          constant: -Self.bandGap)
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: statusChip.leadingAnchor, constant: 9),
            status.trailingAnchor.constraint(equalTo: statusChip.trailingAnchor, constant: -9),
            status.topAnchor.constraint(equalTo: statusChip.topAnchor, constant: 4),
            status.bottomAnchor.constraint(equalTo: statusChip.bottomAnchor, constant: -4),
            statusChip.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            statusBottom,
        ])
    }

    /// A soft drop shadow lifts a glass chip off busy content — the depth
    /// carries the contrast that a material alone can't guarantee.
    private static func lift(_ view: NSView) {
        view.wantsLayer = true
        view.layer?.masksToBounds = false
        view.layer?.shadowColor = NSColor.black.withAlphaComponent(0.4).cgColor
        view.layer?.shadowOpacity = 1
        view.layer?.shadowRadius = 3.5
        view.layer?.shadowOffset = CGSize(width: 0, height: -1)
    }


    func showScanning(over windowFrame: CGRect, appName: String, sticky: Bool) {
        clearChips()
        present(over: windowFrame)
        status.stringValue = "⌖ hints · \(appName) · scanning…\(sticky ? " · sticky" : "")"
    }

    func show(labels: [(String, CGRect)], over windowFrame: CGRect, appName: String, sticky: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        defer {
            NSAnimationContext.endGrouping()
            CATransaction.commit()
        }
        clearChips()
        present(over: windowFrame)
        guard let primary = NSScreen.screens.first else { return }
        let primaryHeight = primary.frame.maxY

        for (text, frame) in labels {
            let (chip, label) = GlassChip.make(text)

            let width = label.frame.width + 7
            let height = Self.chipHeight
            // Quartz → AppKit, positioned at the element's top-left corner,
            // then clamped inside the overlay.
            let x = min(max(frame.minX - panel.frame.minX - 2, 0), panel.frame.width - width)
            let appKitY = primaryHeight - frame.minY - panel.frame.minY
            let y = min(max(appKitY - height + 4, 0), panel.frame.height - height)
            chip.frame = NSRect(x: x, y: y, width: width, height: height)
            label.frame = NSRect(x: 0, y: (height - label.frame.height) / 2,
                                 width: width, height: label.frame.height)
            chipHost.addSubview(chip)
            chips.append((chip, label, text))
        }
        status.stringValue = labels.isEmpty
            ? "⌖ hints · \(appName) · nothing pressable · esc"
            : "⌖ hints · \(appName) · \(labels.count) · type label · ⇧ right-click · esc\(sticky ? " · sticky" : "")"
    }

    /// Typing narrows: matching chips stay with the typed prefix in the
    /// accent color, the rest vanish.
    func filter(typed: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for (chip, label, text) in chips {
            if typed.isEmpty || text.hasPrefix(typed) {
                chip.isHidden = false
                let attributed = NSMutableAttributedString(
                    string: text.uppercased(),
                    attributes: [.font: Self.chipFont,
                                 .foregroundColor: NSColor.labelColor])
                attributed.addAttribute(.foregroundColor,
                                        value: NSColor.controlAccentColor,
                                        range: NSRange(location: 0, length: typed.count))
                label.attributedStringValue = attributed
            } else {
                chip.isHidden = true
            }
        }
    }

    func clearTyped() {
        filter(typed: "")
    }

    func hide() {
        clearChips()
        panel.orderOut(nil)
    }

    private func clearChips() {
        for (chip, _, _) in chips { chip.removeFromSuperview() }
        chips.removeAll()
    }

    private func present(over windowFrame: CGRect) {
        guard let primary = NSScreen.screens.first else { return }
        let primaryHeight = primary.frame.maxY
        let appKit = NSRect(x: windowFrame.minX,
                            y: primaryHeight - windowFrame.maxY,
                            width: windowFrame.width, height: windowFrame.height)
        panel.setFrame(appKit, display: true)
        panel.orderFrontRegardless()
        // A window that runs to the bottom of its display puts the band
        // over the Dock; step up by exactly what the Dock takes.
        statusBottom.constant = -(Self.bandGap + Glass.bottomInset(for: appKit))
    }
}
