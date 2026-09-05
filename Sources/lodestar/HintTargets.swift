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
            Pointer.post(SyntheticPointer.click(at: point, right: true))
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
    ///
    /// Two lessons carried over from select's harvest, where the browser
    /// taught them. **Batched reads**: role, position, size, and children
    /// come back in one round trip instead of four, so a heavy page spends
    /// its deadline on nodes rather than on messaging. **Viewport
    /// pruning**: a container whose frame is real and lies off the window
    /// is skipped with its whole subtree — a Chromium page keeps its
    /// scrolled-away content in the tree, and walking it found chips for
    /// nothing anyone could see while the visit budget ran out on it.
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
            let batch = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute,
                         kAXChildrenAttribute] as CFArray

            func walk(_ element: AXUIElement, depth: Int) {
                guard depth < 28, visited < 2800, found.count < capacity,
                      Date() < deadline else { return }
                visited += 1

                var values: CFArray?
                guard AXUIElementCopyMultipleAttributeValues(
                    element, batch, AXCopyMultipleAttributeOptions(rawValue: 0),
                    &values) == .success,
                    let array = values as? [CFTypeRef], array.count == 4 else { return }

                var frame: CGRect?
                if CFGetTypeID(array[1]) == AXValueGetTypeID(),
                   CFGetTypeID(array[2]) == AXValueGetTypeID() {
                    var point = CGPoint.zero
                    var size = CGSize.zero
                    if AXValueGetValue(array[1] as! AXValue, .cgPoint, &point),
                       AXValueGetValue(array[2] as! AXValue, .cgSize, &size) {
                        frame = CGRect(origin: point, size: size)
                    }
                }
                // The pruning that makes the budget go to what is visible.
                if let frame, frame.width > 1, frame.height > 1,
                   !frame.intersects(windowFrame.insetBy(dx: -8, dy: -8)) {
                    return
                }

                if let role = array[0] as? String {
                    let pressable = Self.pressableRoles.contains(role)
                    let textInput = Self.textRoles.contains(role)
                    if pressable || textInput, let frame,
                       frame.width >= 5, frame.height >= 5,
                       frame.intersects(windowFrame) {
                        let key = "\(Int(frame.minX)):\(Int(frame.minY)):\(Int(frame.width))"
                        if !seenFrames.contains(key) {
                            seenFrames.insert(key)
                            found.append(Target(element: element, frame: frame,
                                                isTextInput: textInput && !pressable))
                        }
                    }
                }
                guard CFGetTypeID(array[3]) == CFArrayGetTypeID(),
                      let children = array[3] as? [AXUIElement] else { return }
                for child in children {
                    walk(child, depth: depth + 1)
                }
            }

            walk(windowElement, depth: 0)
            let elapsed = Int(Date().timeIntervalSince(began) * 1000)

            DispatchQueue.main.async {
                Log.info("hints", ["targets": found.count, "visited": visited,
                                   "ms": elapsed, "batched": true])
                completion(found)
            }
        }
    }
}

/// The one place a synthetic pointer script leaves the process. Every
/// event is stamped as Lodestar's own — the tap passes it to the app
/// untouched, and the held highlight's click monitor lets it by — and the
/// scripts themselves are `SyntheticPointer`'s, so the walk-before-press
/// rule is decided once, in code a test can read.
enum Pointer {
    static func post(_ steps: [SyntheticPointer.Step]) {
        for step in steps {
            let right = step.type == .rightMouseDown || step.type == .rightMouseUp
                || step.type == .rightMouseDragged
            guard let event = CGEvent(mouseEventSource: nil, mouseType: step.type,
                                      mouseCursorPosition: step.point,
                                      mouseButton: right ? .right : .left) else { continue }
            event.setIntegerValueField(.eventSourceUserData, value: SelectController.ownMark)
            event.post(tap: .cghidEventTap)
        }
    }

    /// Where the pointer rests now, in Quartz coordinates.
    static func location() -> CGPoint {
        let mouse = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: mouse.x, y: primaryHeight - mouse.y)
    }
}


/// The one chip design, shared by every overlay that labels the screen —
/// hints and select draw literally the same object, so the styles cannot
/// drift. The launcher's glass, small: the one backdrop recipe, bold mono
/// caps on top of it, lifted by a soft shadow because a chip sits on
/// someone else's content with no edge of its own to meet. It once wore
/// clear glass with a halo around the letters to survive what showed
/// through; frost is what makes the halo unnecessary.
enum GlassChip {
    static let font = NSFont.monospacedSystemFont(ofSize: BarTheme.Scale.meta, weight: .bold)
    static let height: CGFloat = 20

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
        label.sizeToFit()

        // The label rides on the chip above the material, never inside
        // it, for the reason the cards give.
        let chip = NSView()
        Glass.installBackdrop(in: chip, cornerRadius: 4.5)
        chip.addSubview(label)
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
