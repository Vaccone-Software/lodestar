import AppKit
import LodestarCore

/// What survived the hints controller: the harvest and the click. The
/// `;` door is select's machine now — one sensor, one grammar, the verb
/// declared at the door — and what it borrows from the old tree-only
/// hints is exactly this file: which roles press, how to find them
/// without stalling on a wedged app, and where to click for one.
enum HintTargets {
    struct Target {
        let element: AXUIElement
        let frame: CGRect
        let isTextInput: Bool
        /// Found by its press action rather than by its role: a div, an
        /// image, a generic container the page made clickable. The tree
        /// has no name for it and the screen paints no word on it, which
        /// is exactly why it is the one kind of target worth a chip on a
        /// dense window.
        let viaAction: Bool
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

    /// The largest share of a window an action-found target may cover.
    /// Measured with `probe pressables` against live windows: on a
    /// Chromium page the pressables outside the role list are a nest of
    /// clickable cards wrapping clickable rows wrapping the control the
    /// eye actually sees, and in Brave, Slack, Asana and Claude alike
    /// every leaf-most one of them came in under 5% of its window. What
    /// sits above that line is a card, and a chip on a card puts a letter
    /// over a whole region.
    private static let actionShareCap = 0.05

    /// The target that owns a point: the smallest one enclosing it, and
    /// at a tie the one the tree named by role over one found by action.
    /// The first in tree order was taken before, and in Asana that was
    /// the wrapper the page marks pressable around the Share button: its
    /// press reported success and did nothing, while the button's own
    /// press opens the dialog (probe press, 2026-09-15). The harvest is
    /// leaf-most by doctrine; the commit has to be too.
    static func owner(of point: CGPoint, among targets: [Target]) -> Target? {
        targets
            .filter { $0.frame.contains(point) }
            .min { a, b in
                let areaA = a.frame.width * a.frame.height
                let areaB = b.frame.width * b.frame.height
                if areaA != areaB { return areaA < areaB }
                return !a.viaAction && b.viaAction
            }
    }

    /// A pick is a click. The letter does what the hand would have done at
    /// that point, in every app alike: a text input takes focus and the
    /// caret where you looked, a button presses, ⌃ opens the menu a
    /// right-click opens. The element's own action was tried first for a
    /// year and retired 2026-09-15: `AXPress` answers success whether or
    /// not anything happened — in Asana the page-sized group around the
    /// Share button said yes every time and did nothing — and a press that
    /// cannot be told from a no-op cannot be backed up without waiting,
    /// and a wrong wait fires twice. A click either lands or plainly does
    /// not, and the cursor going where the hand would have sent it is not
    /// a cost the doctrine minds.
    static func fire(_ target: Target, rightClick: Bool) {
        let point = CGPoint(x: target.frame.midX, y: target.frame.midY)
        Pointer.post(SyntheticPointer.click(at: point, right: rightClick))
        Log.info("hint", ["action": rightClick ? "right-click" : "click", "text": target.isTextInput])
    }

    /// The tabs of a window, off the main thread: every `AXTabButton`
    /// under an `AXTabGroup`, except the one already selected. Measured
    /// with `probe tabs` (2026-09-15): Brave's tab strip and Ghostty's tab
    /// bar expose the identical shape — a group of radio buttons whose
    /// value is 1 on the current tab — so one rule reads both, and the
    /// press is the button's own action. Chromium builds no tree until an
    /// assistive client announces itself, the same flag the click door
    /// flips. Replaced by the tests, whose world has no tabs to read.
    static var harvestTabs: (WindowModel.Window, @escaping ([Target]) -> Void) -> Void = { window, completion in
        let windowElement = window.element
        let pid = window.pid
        DispatchQueue.global(qos: .userInitiated).async {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            AXUIElementSetMessagingTimeout(app, 0.5)
            var found: [Target] = []
            var visited = 0
            let deadline = Date().addingTimeInterval(0.8)
            func walk(_ element: AXUIElement, depth: Int, inGroup: Bool) {
                visited += 1
                guard depth < 16, visited < 4000, Date() < deadline else { return }
                let role = AX.string(element, kAXRoleAttribute) ?? ""
                let group = inGroup || role == "AXTabGroup"
                if group, AX.string(element, kAXSubroleAttribute) == "AXTabButton" {
                    if AX.int(element, kAXValueAttribute) != 1,
                       let origin = AX.point(element, kAXPositionAttribute),
                       let size = AX.size(element, kAXSizeAttribute) {
                        found.append(Target(element: element, frame: CGRect(origin: origin, size: size),
                                            isTextInput: false, viaAction: true))
                    }
                    return
                }
                for child in AX.elements(element, kAXChildrenAttribute) ?? [] {
                    walk(child, depth: depth + 1, inGroup: group)
                }
            }
            walk(windowElement, depth: 0, inGroup: false)
            Log.info("tabs", ["harvested": found.count, "visited": visited])
            DispatchQueue.main.async { completion(found) }
        }
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
            var byAction = 0
            // Two answers from one walk. The first lands the moment the
            // chips are full, so the door is usable as fast as it ever
            // was; the walk then goes on to the deadline collecting
            // role-named pressables only — owners for a typed pick, never
            // chips, so nothing on the glass changes under the hand — and
            // answers once more. Asana's Share button was pressable
            // number 1,115 in its tree; a walk that stopped at 200
            // targets never reached it, and a wrapper it had reached
            // took the point (probe owners, 2026-09-15).
            var announced = false
            let windowArea = max(windowFrame.width * windowFrame.height, 1)
            let deadline = Date().addingTimeInterval(1.2)
            let batch = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute,
                         kAXChildrenAttribute] as CFArray

            func add(_ element: AXUIElement, frame: CGRect, isTextInput: Bool,
                     viaAction: Bool) -> Bool {
                // Past the chips' capacity only owners join, and an owner
                // is a target the tree named by role.
                if found.count >= capacity, viaAction || isTextInput { return false }
                let key = "\(Int(frame.minX)):\(Int(frame.minY)):\(Int(frame.width))"
                guard !seenFrames.contains(key) else { return false }
                seenFrames.insert(key)
                found.append(Target(element: element, frame: frame,
                                    isTextInput: isTextInput, viaAction: viaAction))
                if viaAction { byAction += 1 }
                if !announced, found.count >= capacity {
                    announced = true
                    let chipsFull = found
                    DispatchQueue.main.async { completion(chipsFull) }
                }
                return true
            }

            /// Answers whether this subtree yielded a target, which is
            /// what makes an action-found candidate wait: the tree presses
            /// all the way up, so the only honest chip is the leaf-most
            /// one — the innermost thing that presses under the point.
            @discardableResult
            func walk(_ element: AXUIElement, depth: Int) -> Bool {
                guard depth < 28, visited < 9000, Date() < deadline else { return false }
                visited += 1

                var values: CFArray?
                guard AXUIElementCopyMultipleAttributeValues(
                    element, batch, AXCopyMultipleAttributeOptions(rawValue: 0),
                    &values) == .success,
                    let array = values as? [CFTypeRef], array.count == 4 else { return false }

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
                    return false
                }

                var yielded = false
                var pending: (element: AXUIElement, frame: CGRect)?
                if let role = array[0] as? String, let frame,
                   frame.width >= 5, frame.height >= 5, frame.intersects(windowFrame) {
                    let pressable = Self.pressableRoles.contains(role)
                    let textInput = Self.textRoles.contains(role)
                    if pressable || textInput {
                        // A role the tree can name goes in where it stands,
                        // ahead of its own children, which is reading order.
                        yielded = add(element, frame: frame,
                                      isTextInput: textInput && !pressable, viaAction: false)
                    } else if frame.width * frame.height <= windowArea * Self.actionShareCap {
                        // Everything else is asked the only question that
                        // matters — does it press? — and held until its
                        // children have answered for themselves.
                        var actions: CFArray?
                        AXUIElementCopyActionNames(element, &actions)
                        if (actions as? [String] ?? []).contains(kAXPressAction as String) {
                            pending = (element, frame)
                        }
                    }
                }

                let mark = found.count
                if CFGetTypeID(array[3]) == CFArrayGetTypeID(),
                   let children = array[3] as? [AXUIElement] {
                    for child in children {
                        walk(child, depth: depth + 1)
                    }
                }
                // Nothing deeper pressed, so this is the leaf-most press
                // under the point. `found` has not grown, so appending now
                // lands exactly where appending before the children would
                // have — reading order survives the wait.
                if let pending, found.count == mark, found.count < capacity {
                    yielded = add(pending.element, frame: pending.frame,
                                  isTextInput: false, viaAction: true) || yielded
                }
                return yielded || found.count > mark
            }

            walk(windowElement, depth: 0)
            let elapsed = Int(Date().timeIntervalSince(began) * 1000)

            DispatchQueue.main.async {
                Log.info("hints", ["targets": found.count, "byAction": byAction,
                                   "visited": visited, "ms": elapsed, "batched": true,
                                   "owners": found.count > capacity])
                // The second answer, only when the walk found owners past
                // the chips; a walk that never filled them answers once.
                if !announced || found.count > capacity { completion(found) }
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
    /// Replaced by the scenario harness, whose world never moves a pointer.
    static var post: ([SyntheticPointer.Step]) -> Void = postToSystem

    static let postToSystem: ([SyntheticPointer.Step]) -> Void = { steps in
        for step in steps {
            let right = step.type == .rightMouseDown || step.type == .rightMouseUp
                || step.type == .rightMouseDragged
            guard let event = CGEvent(mouseEventSource: nil, mouseType: step.type,
                                      mouseCursorPosition: step.point,
                                      mouseButton: right ? .right : .left) else { continue }
            event.setIntegerValueField(.eventSourceUserData, value: SelectController.ownMark)
            if step.type == .leftMouseDown || step.type == .leftMouseUp
                || step.type == .rightMouseDown || step.type == .rightMouseUp {
                event.setIntegerValueField(.mouseEventClickState, value: 1)
            }
            event.post(tap: .cghidEventTap)
            // The walk must land before the press. Posted back to back, the
            // press reached apps before the cursor had moved, so it landed
            // where the pointer last rested and the release at the target:
            // a drag, and a highlight, from wherever the hand had left it.
            // A warp puts the cursor there now; the pause lets the app hear
            // the move before the button. Runs off the tap, so the wait is
            // nobody's keystroke.
            if step.type == .mouseMoved {
                CGWarpMouseCursorPosition(step.point)
                usleep(40_000)
            } else if step.type == .leftMouseDown || step.type == .rightMouseDown {
                usleep(30_000)
            }
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

    /// `lit` is how many leading letters the hand has already typed of
    /// this label: they wear the accent, so a narrowing pick can be seen
    /// on the chip it narrows.
    static func make(_ text: String, lit: Int = 0) -> (chip: NSView, label: NSTextField) {
        let dark = Tone.systemDark
        // Explicit, not labelColor: the label sits inside the material's
        // contentView, where the glass stamps its backdrop-adapted
        // appearance — labelColor there can resolve against the system's
        // tone, which is the invisible-text bug in one line.
        let ink = dark ? NSColor.white : NSColor(white: 0.12, alpha: 1)
        let caps = text.uppercased()
        let string = NSMutableAttributedString(string: caps, attributes: [.font: font, .foregroundColor: ink])
        let litCount = min(max(0, lit), caps.count)
        if litCount > 0 {
            string.addAttribute(.foregroundColor, value: BarTheme.readableAccent,
                                range: NSRange(location: 0, length: litCount))
        }
        let label = NSTextField(labelWithAttributedString: string)
        label.alignment = .center
        label.sizeToFit()

        // The label rides on the chip above the material, never inside
        // it, for the reason the cards give.
        let chip = NSView()
        Glass.installBackdrop(in: chip, cornerRadius: BarTheme.glassChipRadius)
        chip.addSubview(label)
        lift(chip)
        return (chip, label)
    }

    /// The shadow, once the chip knows its size. Without a path, Core
    /// Animation derives the shadow from the layer's alpha channel on
    /// every composite — it must rasterize the glass underneath to learn
    /// its shape. A rounded rectangle is a shape we already know, and
    /// four hundred chips is four hundred rasterizations not done.
    static func settleShadow(_ view: NSView, cornerRadius: CGFloat = BarTheme.glassChipRadius) {
        view.layer?.shadowPath = CGPath(roundedRect: view.bounds,
                                        cornerWidth: cornerRadius,
                                        cornerHeight: cornerRadius, transform: nil)
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
