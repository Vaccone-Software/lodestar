import AppKit

/// The app's tone: the system's choice, and nothing else. Liquid Glass
/// would rather adapt per panel to whatever sits behind it — that is how
/// the launcher and its ⌘K card once resolved to opposite tones a foot
/// apart, and how dark-mode text landed on light-adapted glass and
/// vanished. We keep the frost and take away the material's vote.
enum Tone {
    static var systemDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

/// The quiet layer between glass and text that guarantees the two agree.
/// Text everywhere resolves from the system appearance; the material
/// adapts to its backdrop and stamps that choice onto its contentView's
/// appearance — this view's. The scrim uses the stamp as a sensor and
/// equalizes toward the system's tone: a light veil when the material
/// already agrees (the frost stays the star), a heavy one when the
/// backdrop pulled it the other way. Live, so theme switches and
/// backdrop changes both re-resolve.
final class EqualizerScrim: NSView {
    /// Veil strength when the material agrees with the system tone.
    /// Callers tune these; the opposed-material weights are fixed.
    var darkBase: CGFloat = 0.32
    var lightBase: CGFloat = 0.42

    private var themeObserver: NSObjectProtocol?

    override var wantsUpdateLayer: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, themeObserver == nil else { return }
        // The material's stamp does not change when the user switches
        // themes (it tracks the backdrop), so a long-lived scrim would
        // never hear about the new target without listening for it.
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.needsDisplay = true }
        }
    }

    deinit {
        if let themeObserver {
            DistributedNotificationCenter.default().removeObserver(themeObserver)
        }
    }

    override func updateLayer() {
        let materialDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if Tone.systemDark {
            layer?.backgroundColor = NSColor.black
                .withAlphaComponent(materialDark ? darkBase : max(darkBase, 0.72)).cgColor
        } else {
            layer?.backgroundColor = NSColor.white
                .withAlphaComponent(materialDark ? max(lightBase, 0.80) : lightBase).cgColor
        }
    }
}

/// Liquid Glass where the OS provides it (macOS 26+), vibrancy fallback
/// everywhere else. The backdrop is installed as a sibling pinned under the
/// content, so both paths behave identically.
enum Glass {
    @discardableResult
    static func installBackdrop(in root: NSView, cornerRadius: CGFloat) -> NSView {
        let backdrop: NSView
        if #available(macOS 26.0, *) {
            // Regular glass, deliberately: the frost is the panel's beauty
            // AND half its contrast — clear glass let the world through
            // sharp and made everything worse. The scrim rides inside it.
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            let scrim = EqualizerScrim()
            scrim.wantsLayer = true
            scrim.layer?.cornerRadius = cornerRadius
            scrim.autoresizingMask = [.width, .height]
            glass.contentView = scrim
            backdrop = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = cornerRadius
            effect.layer?.masksToBounds = true
            backdrop = effect
        }
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(backdrop, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: root.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        return backdrop
    }

    static func makePanel(level: NSWindow.Level) -> NSPanel {
        // Titled + fullSizeContentView, exactly like the searcher's
        // KeyablePanel — and not for the shadow this time. Liquid Glass
        // senses its backdrop through the window: behind a raw borderless
        // panel it reads the wallpaper and adapts tone per panel, so the
        // ⌘K card could resolve white beside a charcoal launcher. Behind a
        // titled window it honors the window's appearance — the pinned
        // dark holds.
        let panel = GlassPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovable = false
        panel.level = level
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        return panel
    }

    /// How far a panel's bottom edge sits below the usable part of the
    /// screen it covers — the Dock's strip, for an overlay handed a whole
    /// display. Furniture pinned to the panel's bottom adds this so it
    /// stands above the Dock instead of on top of it.
    static func bottomInset(for frame: NSRect) -> CGFloat {
        func overlap(_ screen: NSScreen) -> CGFloat {
            let shared = screen.frame.intersection(frame)
            return shared.isNull || shared.isEmpty ? 0 : shared.width * shared.height
        }
        guard let screen = NSScreen.screens.max(by: { overlap($0) < overlap($1) }) else { return 0 }
        return max(0, screen.visibleFrame.minY - frame.minY)
    }
}

/// A borderless glass panel whose shadow survives reframing. The window
/// server derives a window's shadow from its opaque content, but glass
/// composites out-of-process: the shape it sees at order-in is empty, and
/// it never asks again. Without the shadow the pane sits flush on the
/// wallpaper and its rim reads as a drawn rectangle instead of an edge.
/// Re-deriving after every reframe and every ordering keeps it lifted.
class GlassPanel: NSPanel {
    /// A titled window is screen-constrained: AppKit slides it down until
    /// its title bar clears the menu bar, and never gives the height back.
    /// Select and hints hand their panel a whole display on purpose — the
    /// constraint pushed the overlay a menu bar's worth below the screen
    /// and took the query band off the bottom edge with it. Every panel
    /// here already places itself inside `visibleFrame`, so the constraint
    /// only ever had wrong answers to give.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        invalidateShadow()
    }

    override func orderFront(_ sender: Any?) {
        super.orderFront(sender)
        invalidateShadow()
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        invalidateShadow()
    }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        invalidateShadow()
    }
}

/// One visual system for every bar. The searcher, web bar, and menu
/// search must feel like a single instrument — same width, rhythm, and
/// type — so the tokens live here, where drift can't hide in literals.
enum BarTheme {
    static let panelWidth: CGFloat = 640
    static let inputHeight: CGFloat = 60
    static let rowHeight: CGFloat = 48
    static let footerHeight: CGFloat = 24
    static let glassRadius: CGFloat = 18
    static let rowRadius: CGFloat = 18
    static let chipRadius: CGFloat = 5
    /// One key-and-label row, shared by every surface that draws them: the
    /// chain guide, the cheat sheet, and the clipboard's actions menu. Left
    /// to themselves they drifted into three chip shapes, three keycap
    /// sizes and three icon sizes; this is the one set.
    static let chipMinWidth: CGFloat = 30
    static let chipHeight: CGFloat = 20
    static let chipPadX: CGFloat = 6
    static let rowGap: CGFloat = 9
    static let rowIcon: CGFloat = 17
    /// Clear water between the longest label and the key column, so the two
    /// never read as one run of text.
    static let rowKeyGap: CGFloat = 28

    static let inputFont = NSFont.systemFont(ofSize: 23, weight: .regular)
    static let inputSymbol = NSImage.SymbolConfiguration(pointSize: 19, weight: .medium)
    static let titleFont = NSFont.systemFont(ofSize: 16, weight: .regular)
    static let secondaryFont = NSFont.systemFont(ofSize: 11.5, weight: .regular)
    /// What a key's row says it does — the reading size, not a caption.
    static let rowLabelFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let chipFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold)
    static let footerFont = NSFont.systemFont(ofSize: 11, weight: .regular)
}

/// Chips you can move, and put back by ignoring.
///
/// A chip stands in one corner because that corner is usually empty. When
/// it is not — the thing you need to read is under it — the answer people
/// reach for is to move the chip, and until now there was nothing to grab.
///
/// The position is deliberately not remembered. A chip always returns to
/// its corner on its next showing, because a drag answers *this* chip in
/// front of *this* window, and a position learned from one bad overlap
/// would then be carried to every future chip that had no such problem.
/// Nothing to reset, nothing to persist, nothing to migrate.
enum Movable {
    /// Let this panel be dragged by its background. Controls inside it
    /// still take their own clicks, because a view that handles mouseDown
    /// is not background.
    static func enable(_ panel: NSPanel) {
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        // A chip that cannot be clicked cannot be dragged either.
        panel.ignoresMouseEvents = false
        // Lodestar is an accessory app and almost never the active one, so
        // the pointer is usually somebody else's. Tracking has to be asked
        // for explicitly or the hover state and the cursor never arrive.
        panel.acceptsMouseMovedEvents = true
    }

    /// Where a chip goes when it is drawn.
    ///
    /// On the way up it takes its corner. While it is already standing it
    /// keeps the place it was put — a chip that is retitled or regrown
    /// must not jump back out from under the pointer that just moved it —
    /// and grows downward from its own top edge, since that is the edge a
    /// person aimed when they dropped it.
    static func place(_ panel: NSPanel, size: NSSize, corner: () -> NSPoint) {
        guard panel.isVisible else {
            panel.setFrame(NSRect(origin: corner(), size: size), display: true)
            return
        }
        var frame = panel.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
    }
}

/// A button that admits it is one.
///
/// AppKit leaves the arrow cursor over `NSButton`, which is right inside a
/// document window and wrong on a floating card that a person is deciding
/// whether they are allowed to touch. Same tracking-area route as the caps
/// use, rather than `resetCursorRects`, because cursor rects want a key
/// window and these panels are deliberately never key.
final class HandButton: NSButton {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.cursorUpdate, .activeAlways],
                                       owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
}

/// Keys, drawn as keys. One cap is one press.
///
/// That rule cannot be inferred from a key string, which is why this exists
/// as a type the caller fills in rather than something that splits text on
/// spaces. The guide's own rows prove why: `G G` means press G twice, and
/// `J K` means press either one. Same delimiter, opposite meanings — a
/// splitter would render half the guide as a lie.
///
/// So the surfaces that describe a *specific* gesture say what it is here,
/// and the chain guide keeps its one-cap-per-row string for the rows where
/// the keys are alternatives rather than a sequence.
enum Keycaps {
    /// One gesture: the keys pressed, what pressing them does, and — when
    /// the surface can be reached by mouse as well as by hand — the same
    /// thing the keys would have done.
    struct Gesture {
        let keys: [String]
        let verb: String
        let action: (() -> Void)?

        init(_ keys: [String], _ verb: String, action: (() -> Void)? = nil) {
            self.keys = keys
            self.verb = verb
            self.action = action
        }
    }

    /// How a cap is filled, by what the pointer is doing to it. A cap with
    /// no action never leaves `.resting`, so a guide row looks exactly as
    /// it always did.
    enum CapState {
        case resting, hovered, pressed

        var fill: CGFloat {
            switch self {
            case .resting: return 0.09
            case .hovered: return 0.18
            case .pressed: return 0.26
            }
        }
    }

    /// A cap that can be refilled — the shape and its one variable.
    final class CapView: NSView {
        func fill(_ state: CapState) {
            layer?.backgroundColor = NSColor.labelColor
                .withAlphaComponent(state.fill).cgColor
        }
    }

    /// The caps of one gesture, made pressable.
    ///
    /// The caps are the button. That is the whole idea: the thing you press
    /// with a finger and the thing you press with the mouse are drawn as
    /// one object, so the surface teaches the key while accepting the
    /// click. It lights on hover, sinks on press, and wears the pointing
    /// hand — three signals, because a flat rectangle that happens to be
    /// clickable is not discoverable by looking at it.
    ///
    /// Only the caps take the click, never the words beside them: the verb
    /// says what the keys do, and a label that is also a button makes the
    /// sentence ambiguous about where to aim.
    final class CapGroup: NSView {
        private let paint: (CapState) -> Void
        private let action: () -> Void
        private var hovering = false { didSet { restyle() } }
        private var pressing = false { didSet { restyle() } }

        /// The general form: any view, and a closure that knows how that
        /// view looks under a pointer. The walk draws its own caps —
        /// bordered, larger, a different family on purpose — and must not
        /// be dragged into this file's shape just to become pressable.
        init(content: NSView, paint: @escaping (CapState) -> Void,
             action: @escaping () -> Void) {
            self.paint = paint
            self.action = action
            super.init(frame: .zero)
            // The caps hug their letters; this has to hug them back. A view
            // with nothing to say about its width is the one a horizontal
            // stack elects to absorb the slack, and the group would arrive
            // stretched to the width of the chip with its caps adrift in it.
            setContentHuggingPriority(.required, for: .horizontal)
            setContentCompressionResistancePriority(.required, for: .horizontal)
            content.translatesAutoresizingMaskIntoConstraints = false
            addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: topAnchor),
                content.bottomAnchor.constraint(equalTo: bottomAnchor),
                content.leadingAnchor.constraint(equalTo: leadingAnchor),
                content.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }

        /// The common case: the shared caps, lit together.
        convenience init(caps: [CapView], action: @escaping () -> Void) {
            let row = NSStackView(views: caps)
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 4
            self.init(content: row,
                      paint: { state in for cap in caps { cap.fill(state) } },
                      action: action)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not from a nib") }

        private func restyle() {
            paint(pressing ? .pressed : (hovering ? .hovered : .resting))
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways],
                owner: self))
        }

        override func mouseEntered(with event: NSEvent) { hovering = true }

        override func mouseExited(with event: NSEvent) {
            hovering = false
            pressing = false
        }

        /// The pointer says "pressable" before anything is clicked, which is
        /// the only one of the three signals that arrives without the person
        /// having already guessed.
        override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

        /// Taking the press here is also what keeps a click on a cap from
        /// dragging the panel: the window only moves by its background, and
        /// this view is not background.
        override func mouseDown(with event: NSEvent) { pressing = true }

        override func mouseUp(with event: NSEvent) {
            let inside = bounds.contains(convert(event.locationInWindow, from: nil))
            pressing = false
            // Released off the caps is a cancelled press, the way every
            // button on this platform behaves.
            if inside { action() }
        }
    }

    /// A single cap — the one shape, shared with the chain guide's rows so
    /// a key never looks like two different things on two surfaces.
    static func cap(_ text: String) -> CapView {
        let letter = NSTextField(labelWithString: text)
        letter.font = BarTheme.chipFont
        letter.textColor = .secondaryLabelColor
        letter.alignment = .center
        letter.translatesAutoresizingMaskIntoConstraints = false

        let cap = CapView()
        cap.wantsLayer = true
        cap.fill(.resting)
        cap.layer?.cornerRadius = BarTheme.chipRadius
        cap.translatesAutoresizingMaskIntoConstraints = false
        cap.setContentHuggingPriority(.required, for: .horizontal)
        cap.addSubview(letter)
        NSLayoutConstraint.activate([
            letter.leadingAnchor.constraint(equalTo: cap.leadingAnchor,
                                            constant: BarTheme.chipPadX),
            letter.trailingAnchor.constraint(equalTo: cap.trailingAnchor,
                                             constant: -BarTheme.chipPadX),
            letter.centerYAnchor.constraint(equalTo: cap.centerYAnchor),
            cap.heightAnchor.constraint(equalToConstant: BarTheme.chipHeight),
            cap.widthAnchor.constraint(greaterThanOrEqualToConstant: BarTheme.chipMinWidth),
        ])
        return cap
    }

    /// A chip's gesture line: caps and the words that say what they do,
    /// with a middot between gestures. Tight inside a gesture and open
    /// between them, so `lode lode` reads as one thing done twice rather
    /// than two things.
    static func line(_ gestures: [Gesture]) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4
        var previous: NSView?

        func add(_ view: NSView, spacingBefore: CGFloat? = nil) {
            if let spacingBefore, let previous { row.setCustomSpacing(spacingBefore, after: previous) }
            row.addArrangedSubview(view)
            previous = view
        }

        for (index, gesture) in gestures.enumerated() {
            if index > 0 {
                add(word("·", color: .tertiaryLabelColor), spacingBefore: 10)
            }
            let caps = gesture.keys.map { cap($0) }
            if let action = gesture.action {
                // One view for the whole gesture, so hover lights both caps
                // at once: `lode ⌫` is one press of two keys, not two
                // things that happen to sit together.
                add(CapGroup(caps: caps, action: action),
                    spacingBefore: index > 0 ? 10 : nil)
            } else {
                for (position, capView) in caps.enumerated() {
                    add(capView, spacingBefore: index > 0 && position == 0 ? 10 : nil)
                }
            }
            add(word(gesture.verb, color: .tertiaryLabelColor), spacingBefore: 7)
        }
        return row
    }

    private static func word(_ text: String, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 10.5, weight: .regular)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }
}
