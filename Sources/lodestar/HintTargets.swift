import AppKit
import LodestarCore

/// What survived the hints controller: the harvest and the press. The
/// `;` door is select's machine now — one sensor, one grammar, the verb
/// declared at the door — and what it borrows from the old tree-only
/// hints is exactly this file: which roles press, how to find them
/// without stalling on a wedged app, and how to fire one with the app's
/// own action before falling back to a synthetic click.
enum HintTargets {
    struct Target {
        let element: AXUIElement
        let frame: CGRect
        let isTextInput: Bool
    }

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

    /// Press a target: the element's own action when it has one, honest
    /// synthetics otherwise. A text input focuses instead — firing one
    /// means "put my typing here".
    static func fire(_ target: Target, rightClick: Bool) {
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

    /// Bounded walk of the focused window's element tree, off the main
    /// thread. Electron apps need AXManualAccessibility flipped before
    /// their tree exists; setting it is harmless everywhere else. The
    /// completion lands on main with whatever the deadline allowed.
    static func harvest(window: WindowModel.Window, capacity: Int,
                        completion: @escaping ([Target]) -> Void) {
        let windowElement = window.element
        let windowFrame = window.frame
        let pid = window.pid
        let began = Date()

        DispatchQueue.global(qos: .userInitiated).async {
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

            DispatchQueue.main.async {
                Log.info("hints", ["targets": found.count, "visited": visited,
                                   "ms": elapsed])
                completion(found)
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
