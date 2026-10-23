import AppKit
import LodestarCore

/// The app's tone: the system's choice, and nothing else. The material has
/// no vote: a pane is opaque ceramic in the palette's own colours, so the
/// launcher and its ⌘K card cannot resolve to opposite tones a foot apart,
/// as the glass they once were did.
enum Tone {
    static var systemDark: Bool {
        // `shared`, not `NSApp`: a chip made before the application object
        // exists — the tests' world — must still have an answer.
        NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

extension Ceramic {
    /// A colour as a layer needs it, resolved in the appearance of the view
    /// it is drawn in. `NSColor.cgColor` resolves a dynamic colour in the
    /// appearance current at the call, which off a draw pass is not the
    /// view's: a light surface drew dark mode's colours.
    ///
    /// The colour is an expression, evaluated inside the view's appearance:
    /// `labelColor.withAlphaComponent(…)` is not dynamic but fixed the moment
    /// it is made, in whatever look is current then, so it has to be made in
    /// the right one.
    static func resolved(_ color: @autoclosure () -> NSColor, in view: NSView? = nil) -> CGColor {
        var resolved = NSColor.clear.cgColor
        (view?.effectiveAppearance ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
            resolved = color().cgColor
        }
        return resolved
    }
}

extension Ceramic {
    /// The appearance a colour resolves in when it is turned into a layer's
    /// colour outside a draw pass, kept with the system's. Left alone it is
    /// whatever was current when the app started, so a Lodestar launched at
    /// night went on drawing night's colours after the Mac turned light.
    /// A net under every such conversion; `resolved(_:in:)` is the rule.
    static func followSystemAppearance() {
        NSAppearance.current = NSApp.effectiveAppearance
    }
}

/// The clay pictures, one per look. They were rendered pale for night,
/// and pale clay on clay's pale page loses its edges, so each has a twin
/// rendered in sand, a warmer, deeper clay, for the light look
/// (tools/doors, `CLAY=sand`). One image that draws whichever twin the look
/// in force calls for, so a picture already on screen changes with the look.
enum TonedPicture {

    static func make(night: NSImage, day: NSImage?) -> NSImage {
        guard let day else { return night }
        return NSImage(size: night.size, flipped: false) { rect in
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if dark {
                night.draw(in: rect)
                return true
            }
            day.draw(in: rect)
            return true
        }
    }
}

/// A root view that says when the look changes, for a surface that bakes
/// its colours into what it renders and so must render again.
final class AppearanceRoot: NSView {
    var onAppearance: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        DispatchQueue.main.async { [weak self] in self?.onAppearance?() }
    }
}

/// A clay picture on the page. In the light an object stands off the page
/// by its shadow, the way the night lets a pale object stand off by its
/// tone: a soft warm shadow cast from the object's own outline, in the
/// layer, so nothing frames it. `away` is the way the shadow falls, a unit
/// vector with y up; on the Settings overview the mark at the centre is the
/// light and every place's shadow falls away from it. Nil falls straight
/// down. The night casts none.
final class PictureView: NSImageView {
    var away: CGVector? { didSet { restyle() } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restyle()
    }

    override func layout() {
        super.layout()
        restyle()
    }

    private func restyle() {
        wantsLayer = true
        guard let layer else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer.masksToBounds = false
        layer.shadowColor = BarTheme.shadow.cgColor
        let width = max(bounds.width, 1)
        let direction = away ?? CGVector(dx: 0, dy: -1)
        // Cast from the mark the shadow is long and plain enough to read
        // as direction at a glance; a lone picture's sits close beneath it.
        layer.shadowOpacity = dark ? 0 : (away == nil ? 0.32 : 0.64)
        let reach = width * (away == nil ? 0.03 : 0.096)
        layer.shadowRadius = width * (away == nil ? 0.04 : 0.07)
        layer.shadowOffset = CGSize(width: direction.dx * reach, height: direction.dy * reach)
    }
}

/// A flat surface whose fill and edge follow the appearance: a group, a
/// rule, a dot, a caret. It casts nothing and stands on nothing. A layer's colour is a fixed value, so one set
/// once keeps the look it was set in; this repaints whenever the view's
/// appearance changes, so light and dark are always the ones on screen.
final class ToneView: NSView {
    /// Expressions, made again in the view's look at every paint: a colour
    /// with an alpha applied is fixed when made, so it cannot be stored.
    var fill: (() -> NSColor)? { didSet { repaint() } }
    var edge: (() -> NSColor)? { didSet { repaint() } }

    init(fill: @autoclosure @escaping () -> NSColor? = nil, edge: @autoclosure @escaping () -> NSColor? = nil,
         edgeWidth: CGFloat = 0, radius: CGFloat = 0) {
        self.fill = fill() == nil ? nil : { fill()! }
        self.edge = edge() == nil ? nil : { edge()! }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = edgeWidth
        layer?.cornerRadius = radius
        repaint()
    }

    required init?(coder: NSCoder) { nil }

    // Painted in the layer pass, which AppKit runs with the view's own
    // appearance in force whenever the view is marked for display, and
    // marked whenever the look changes. Painting from the change callback
    // alone left a view that draws nothing else in the look it was born in.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        paint()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        paint()
    }

    private func repaint() {
        paint()
        needsDisplay = true
    }

    private func paint() {
        layer?.backgroundColor = fill.map { make in Ceramic.resolved(make(), in: self) }
        layer?.borderColor = edge.map { make in Ceramic.resolved(make(), in: self) }
    }
}

/// The system's accessibility settings, as the surfaces read them. Each
/// is a closure so a test can set the switch the way a person would.
enum Accessibility {
    static var increaseContrast: () -> Bool = defaults.increaseContrast
    static var reduceMotion: () -> Bool = defaults.reduceMotion

    /// The Mac's own settings, or under a test run all off: a test that
    /// "restored" the live value handed every later test in the process
    /// the machine's Reduce Motion, and a runner with it on turned CI red.
    private static let defaults: (increaseContrast: () -> Bool, reduceMotion: () -> Bool) = TestRun.active
        ? ({ false }, { false })
        : ({ NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast },
           { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion })

    /// Back to the defaults, for a test that changed a setting.
    static func reset() {
        increaseContrast = defaults.increaseContrast
        reduceMotion = defaults.reduceMotion
    }
}

/// The ceramic's namespace: the one place the app's panels are made and
/// the look is followed (design/04-material.md has the material itself).
/// One recipe for every panel, card and chip: an opaque pane in the look's
/// own step, with a rim, an edge and, where it floats, one shadow.
enum Ceramic {
    /// `takesKeys: false` is for a surface that only shows: a note, the
    /// pill, the overlays, the sheet. Its panel never becomes the key
    /// window, because a titled panel ordered in can take key status
    /// without its app coming forward, and every key typed while it stood
    /// then reached a window with nothing to take it and was answered with
    /// the alert: the launch note's two and a half seconds rang like that
    /// on every start. Lodestar's keys come through its tap, never here.
    static func makePanel(level: NSWindow.Level, takesKeys: Bool = true) -> NSPanel {
        // Titled + fullSizeContentView, exactly like the searcher's
        // KeyablePanel: a key window that is not titled gets a hairline
        // etched round its raw rectangle by the window server.
        let frame = BarTheme.unplaced
        let style: NSWindow.StyleMask = [.titled, .fullSizeContentView, .nonactivatingPanel]
        let panel: CeramicPanel = takesKeys
            ? CeramicPanel(contentRect: frame, styleMask: style, backing: .buffered, defer: true)
            : ShowingPanel(contentRect: frame, styleMask: style, backing: .buffered, defer: true)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovable = false
        panel.level = level
        // The window is clear only where the pane's own shadow falls and
        // its corners curve; the pane itself is opaque and nothing lets the
        // desktop through it.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
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

/// A panel that only shows, and so is never the key window.
final class ShowingPanel: CeramicPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

class CeramicPanel: NSPanel {
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
}

/// One visual system for every bar. The searcher, web bar, and menu
/// search must feel like a single instrument — same width, rhythm, and
/// type — so the tokens live here, where drift can't hide in literals.
enum BarTheme {
    /// How everything Lodestar draws moves: one curve, decelerating, so a
    /// thing arrives and settles the way an object set down does. A
    /// surface, a switch's knob and a line falling back all move alike;
    /// only the time differs, and nothing moves under Reduce Motion.
    static var motion: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1) }

    static let footerHeight: CGFloat = Grid.section
    /// One key-and-label row, shared by every surface that draws them: the
    /// chain guide, the cheat sheet, and the clipboard's actions menu. Left
    /// to themselves they drifted into three chip shapes, three keycap
    /// sizes and three icon sizes; this is the one set. (A key's width and
    /// parts are the key contract's, later.)
    static let chipMinWidth: CGFloat = 34

    /// The type scale: three sizes for every word Lodestar draws, and one
    /// for what is typed into a bar. Nine sizes chosen one at a time, from
    /// 10 to 23, had drifted in over a year, and the smallest sat below the
    /// floor a hand that lives at a screen should be asked to read. Meta
    /// is the caption, the key, the footer; body is what a row, a card,
    /// or the draft says — the size the eye rests on; title is a bar's
    /// name. The same scale on the settings window and the walk, since an
    /// eye is one eye. Only `Role` (Type.swift) turns a size into a font.
    enum Scale {
        static let meta: CGFloat = 13
        static let body: CGFloat = 16
        static let title: CGFloat = 18
        static let input: CGFloat = 23
    }

    /// One family, the system's sans, in the roles of `Type.swift`
    /// (design/02-type.md): a surface names the role a piece of text plays
    /// and never builds a font. There is no serif and no mono, and the
    /// hand's words are set like the interface's own.
    ///
    /// A placeholder is the interface asking, not the hand answering, so it
    /// wears the field's role in the quiet tone.
    static func placeholder(_ text: String, role: Role) -> NSAttributedString {
        NSAttributedString(string: text, attributes: attributes(role, color: secondaryColor))
    }
    static let inputSymbol = NSImage.SymbolConfiguration(pointSize: 19, weight: .medium)
    /// The one configuration a symbol beside text wears, and its larger
    /// cousin for the strip's own controls. Weight matched to the text.
    static let symbol = NSImage.SymbolConfiguration(pointSize: Scale.meta, weight: .medium)
    static let symbolBand = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
    /// The mark at the centre of the settings overview.
    static let settingsMarkSize: CGFloat = 132
    /// The dot that says "yours" beside a value, and "needs you" beside a
    /// place's name: a mark on the page, round.
    static let dotDiameter: CGFloat = 7
    static let dotRadius: CGFloat = dotDiameter / 2
    /// The dot that says "needs you" is a glyph used as a mark, not text
    /// that is read, so it may sit under the scale's floor.
    static let dotFont = NSFont.systemFont(ofSize: 8)
    /// The pin inside a chip whose profile was chosen, and its gap to the name.
    /// A symbol leading a bar's row, a size above the text's.
    static let symbolRow = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
    /// The breath's mark: air moving. A breath is taken and released,
    /// not filed, so it wears wind rather than a window.
    static let breathSymbol = "wind"
    /// The palette of the look an appearance is: espresso in dark, clay in
    /// light. Every colour below resolves through this, in the look of the
    /// view that draws it.
    static func steps(for appearance: NSAppearance) -> Palette.Steps {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? Palette.night : Palette.clay
    }

    /// The ink: tinted, never pure black or pure white (the ceiling),
    /// resolved in the look of the view that draws it. Text that takes this
    /// and not the system's label colour is the same ink in every look.
    static let ink = NSColor(name: "LodestarInk") { appearance in
        steps(for: appearance).ink.color
    }

    /// The ink at a share, a colour that follows the look: a fixed alpha on
    /// a dynamic colour is fixed when it is made, so the share is applied
    /// inside the resolution.
    static func inkAt(_ alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in steps(for: appearance).ink.color.withAlphaComponent(alpha) }
    }

    /// The one colour for secondary text — captions, legends, what is said
    /// about a thing — and the ink itself when a person has asked the
    /// system for more contrast. The palette's own quiet ink, measured on
    /// the pane and on a key's face in both looks (5.7 to 1 and more).
    ///
    /// Resolved when it is drawn, not when it is handed out: a caption
    /// built in one look and kept (an attributed title, a chip made once)
    /// otherwise stays that look's grey after the Mac turns to the other.
    static let secondaryColor = NSColor(name: "LodestarSecondary") { appearance in
        let look = steps(for: appearance)
        return (Accessibility.increaseContrast() ? look.ink : look.quietInk).color
    }

    /// A label, in the ink unless told otherwise: the system's label colour
    /// is pure black and pure white, and the ink is never either. Every word
    /// Lodestar sets as a label is made here or sets its own colour from
    /// the theme.
    static func label(_ text: String, role: Role = .meta, tabular: Bool = false, color: NSColor = ink,
                      truncates: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.setRole(role, tabular: tabular)
        field.textColor = color
        if truncates { field.lineBreakMode = .byTruncatingTail }
        return field
    }

    /// The palette in force: the night in dark mode, clay in light.
    static var palette: Palette.Steps {
        Tone.systemDark ? Palette.night : Palette.clay
    }

    /// The pane as a colour that knows both looks, for a layer that must
    /// change with the look while it stands (`ToneView` resolves it).
    static func dynamicGround(alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in steps(for: appearance).pane.color.withAlphaComponent(alpha) }
    }

    /// The panels' ground, for anything that must be judged against it:
    /// the pane of the palette in force, which every surface is made of.
    static var ground: NSColor { palette.pane.color }

    /// The step a chosen thing stands on: the launcher's chosen row, a
    /// card being acted on. One step above the pane, which is the look's
    /// key step (the slab is a later contract), never a colour of its own:
    /// the lit keys say it is chosen, the step says it is lifted.
    static var raised: NSColor { palette.key.color }

    /// A bar's caret is the one light in its field: the accent, wherever
    /// the field editor would otherwise draw the system's own colour. The
    /// editor draws its selection in the system's too (the Mac's accent, and
    /// white letters); here it is the ink at a share and the letters stay
    /// the ink.
    static func lightCaret(of field: NSTextField) {
        guard let editor = field.currentEditor() as? NSTextView else { return }
        editor.insertionPointColor = readableAccent
        editor.textColor = ink
        editor.selectedTextAttributes = [.backgroundColor: inkAt(0.3)]
    }

    /// The one key, resting: the look's key step, in the night a pale cap
    /// on the pane and in clay the lightest thing drawn.
    static var keyFill: NSColor { palette.key.color }
    /// A key laid over another app's window: the same cap, opaque, so
    /// nothing of the window beneath shows through it, and its letter in
    /// the ink, because a mark is read against someone else's content.
    static var markFill: NSColor { palette.key.color }
    static var markLetter: NSColor { palette.ink.color }
    /// A key's letter is the look's ink.
    static var keyLetter: NSColor { palette.ink.color }
    /// The neutral matter, two steps and no more (design/04-material.md): a
    /// well, the pane one step down, for a place you put something; and a
    /// hairline, the ink at the look's own share (a tenth by day, less at
    /// night where light lines read harder), for an edge or a rule. A well is
    /// opaque and never below the ground.
    static var well: NSColor { wellFill }
    static var hairline: NSColor {
        NSColor(name: nil) { appearance in
            let look = steps(for: appearance)
            return look.ink.color.withAlphaComponent(look.hairlineAlpha)
        }
    }
    /// What a content picture's shadow is cast in (a picture is content, not
    /// chrome): the night's ground, and by day the quiet ink. A pane casts
    /// `shadowInk`, the same two, at the contract's share.
    static var shadow: NSColor { Tone.systemDark ? Palette.night.ground.color : Palette.clay.quietInk.color }
    /// A switch's knob: the lightest step the palette has, in both looks.
    static var knob: NSColor { Palette.clay.key.color }
    /// The lightest and the darkest step the palette owns, which a lit key
    /// is shaded toward: its rim catches the key's face, its side falls in
    /// the slab's side, the way the mark's faces are shaded.
    static var lightest: NSColor { Palette.clay.key.color }
    static var darkest: NSColor { Palette.clay.slabSide.color }

    /// The accent, as a closure so a test can try the text rule and the
    /// floor against a colour of its own. In the app it is never anything
    /// but International Orange: there is no setting, because a second
    /// colour makes the same light two on one page and the one owned colour
    /// is the stronger brand (design/01-colour.md).
    static var accentColor: () -> NSColor = { internationalOrange }

    /// The one accent every surface draws with: a row's highlight, a
    /// wash over a match, the walk's star, the settings' dots. The
    /// system's colour never reaches a surface directly — a test reads
    /// the sources for that — so the accent cannot drift.
    static var accent: NSColor { accentColor() }

    /// Text drawn over the accent as a fill — a selected row, a lit chip.
    /// The letter on the orange is whichever of clay's key face and clay's
    /// ink measures higher on the fill, never pure white or pure black
    /// (white on the night's orange is 3.3 to 1), decided from the fill
    /// itself.
    static var onAccent: NSColor {
        guard let fill = accent.usingColorSpace(.sRGB) else { return Palette.clay.ink.color }
        return Palette.letter(on: Readability.RGB(red: fill.redComponent, green: fill.greenComponent,
                                                  blue: fill.blueComponent)).color
    }

    /// International Orange as the look in force wants it: #FA5617 at night,
    /// #C83500 on clay, one value per look (Palette).
    static var internationalOrange: NSColor { palette.orange.color }

    /// A palette step as the mark's own colour type, for the surfaces that
    /// draw the star from `Mark`.
    static func mark(_ color: Readability.RGB) -> Mark.RGB {
        Mark.RGB(red: color.red, green: color.green, blue: color.blue)
    }

    /// The accent as the mark's colour, for the star on a surface.
    static var accentMark: Mark.RGB {
        guard let c = accent.usingColorSpace(.sRGB) else { return mark(palette.orange) }
        return Mark.RGB(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent))
    }

    /// The accent for a mark the eye must find — the insert bar, a lit
    /// letter, the echoed query. International Orange clears the floor on
    /// both grounds, so this is the accent itself; a colour that sat nearly
    /// on the ground (a test tries one) falls back to the text's own
    /// colour, which is never lost.
    static var readableAccent: NSColor {
        let accent = accentColor()
        guard let a = accent.usingColorSpace(.sRGB), let g = ground.usingColorSpace(.sRGB) else { return accent }
        let ratio = Readability.contrast(
            Readability.luminance(red: a.redComponent, green: a.greenComponent, blue: a.blueComponent),
            Readability.luminance(red: g.redComponent, green: g.greenComponent, blue: g.blueComponent))
        return ratio >= Readability.markFloor ? accent : ink
    }
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
        // A chip that cannot be clicked cannot be dragged either. On the
        // drawn shadow the gate opens the pane to the pointer and keeps
        // the shadow closed; anywhere else the whole window takes it.
        if !(panel.contentView is ShadowHostView) { panel.ignoresMouseEvents = false }
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
            panel.setPaneFrame(NSRect(origin: corner(), size: size), display: true)
            return
        }
        var frame = panel.paneFrame
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setPaneFrame(frame, display: true)
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
    /// A link is a pointer target like any other: never under 24 high.
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        if size.height > 0 { size.height = max(size.height, BarTheme.minTarget) }
        return size
    }

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
        /// A room's own verb: its keys lit, as the launcher lights the keys
        /// of the row the hand is about to take.
        var lit = false
        /// Not available now (Continue before a choice, Send while
        /// sending): drawn receded, and not clickable.
        var quiet = false

        init(_ keys: [String], _ verb: String, action: (() -> Void)? = nil, lit: Bool = false,
             quiet: Bool = false) {
            self.keys = keys
            self.verb = verb
            self.action = action
            self.lit = lit
            self.quiet = quiet
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

    /// A cap is the one key: `KeyFace`, which a pointer can refill.
    typealias CapView = KeyFace

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
            row.spacing = Grid.tight
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

    /// A line written with its keys in brackets (`FlashLine`): words and
    /// key groups on one row, every key centred on the words' middle, in
    /// the footer's size and grey. A flash's way and the launcher's
    /// footer are drawn by it, so a key named in a sentence is a key.
    static func sentence(_ line: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Grid.tight
        for part in FlashLine.parts(line) {
            switch part {
            case .words(let text):
                row.addArrangedSubview(word(text, color: BarTheme.secondaryColor))
            case .keys(let keys):
                let group = NSStackView(views: keys.map { cap($0) })
                group.orientation = .horizontal
                group.alignment = .centerY
                group.spacing = Grid.hair
                row.addArrangedSubview(group)
            }
        }
        row.setAccessibilityLabel(FlashLine.plain(line))
        return row
    }

    /// A single cap: the one key, the launcher's, so a key never looks
    /// like two different things on two surfaces.
    static func cap(_ text: String) -> CapView {
        let cap = KeyFace(text)
        cap.setContentHuggingPriority(.required, for: .horizontal)
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
        row.spacing = Grid.tight
        var previous: NSView?

        func add(_ view: NSView, spacingBefore: CGFloat? = nil) {
            if let spacingBefore, let previous { row.setCustomSpacing(spacingBefore, after: previous) }
            row.addArrangedSubview(view)
            previous = view
        }

        for (index, gesture) in gestures.enumerated() {
            if index > 0 {
                add(word("·", color: BarTheme.secondaryColor), spacingBefore: Grid.close)
            }
            let caps = gesture.keys.map { cap($0) }
            for capView in caps {
                capView.lit = gesture.lit && !gesture.quiet
                capView.quiet = gesture.quiet
            }
            if let action = gesture.action, !gesture.quiet {
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
            // A label is a name, capitalized wherever it is written from:
            // "esc Back", never "esc back".
            let verb = word(gesture.verb.prefix(1).uppercased() + gesture.verb.dropFirst(),
                            color: gesture.lit && !gesture.quiet ? BarTheme.ink : BarTheme.secondaryColor)
            add(verb, spacingBefore: Grid.close)
        }
        return row
    }

    private static func word(_ text: String, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.setRole(.meta)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }
}

/// A room's one-line field, drawn rather than the system's bezel: a well,
/// the theme's control rounding, around a borderless field. The bezelled field is a system
/// control in costume, and its focus ring wears the Mac's accent.
final class RoomField: WellView {
    let field = NSTextField()

    init(placeholder: String) {
        super.init(cornerRadius: BarTheme.controlRadius)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.setRole(.body)
        field.textColor = BarTheme.ink
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setPlaceholder(placeholder)
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: BarTheme.wordPadding),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -BarTheme.wordPadding),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: BarTheme.fieldHeight),
        ])
    }

    required init?(coder: NSCoder) { nil }
}

/// A room's button, drawn rather than the system's bezel: a key, a face on
/// a side, with a word in the interface's face, brightening under the
/// pointer and standing down onto its side when pressed. The system's
/// default button wears the Mac's accent; a room's buttons wear Lodestar's
/// material, and its primary actions are lit as keys are.
final class RoomButton: NSButton, CeramicDepth {
    /// Kept for its callers; what cannot be undone is told by its words.
    var destructive = false { didSet { restyle() } }
    /// The answer the surface exists for: lit as a key is lit, the
    /// accent's face with the mark's bright rim and the letter in the
    /// ink that reads on it. One per surface.
    var primary = false { didSet { restyle() } }
    /// A word given as an answer (the editor's card): set in the body's
    /// face and size, on a taller key, because it is the person's text.
    var answer = false { didSet { restyle() } }
    private var hovering = false { didSet { restyle() } }
    private var pressing = false { didSet { restyle() } }
    private let standing = Standing(rest: Ceramic.Side.control, drawsBody: true)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        wantsLayer = true
        layer?.masksToBounds = false
        if let layer { standing.install(in: layer) }
        restyle()
    }

    override func layout() {
        super.layout()
        standing.fit(bounds, radius: BarTheme.controlRadius, flipped: isFlipped)
    }

    required init?(coder: NSCoder) { nil }

    override var title: String {
        didSet { restyle() }
    }

    var depth: Ceramic.Depth { .standsUp(side: standing.side) }
    var drawnSide: CGFloat { standing.visibleSide }

    override var intrinsicContentSize: NSSize {
        let text = attributedTitle.size()
        return answer
            ? NSSize(width: (text.width + BarTheme.wordPadding * 2).rounded(.up), height: BarTheme.fieldHeight)
            : NSSize(width: (text.width + BarTheme.wordPadding * 2).rounded(.up), height: BarTheme.minTarget)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways],
                                       owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// Pressed while the pointer holds it: the side gives up what it can
    /// and the face, with its word, follows it down.
    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        pressing = flag
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    /// The word is drawn on the face, wherever the face stands.
    override func draw(_ dirtyRect: NSRect) {
        standing.drawBody()
        let lift = standing.lift
        NSGraphicsContext.current?.cgContext.saveGState()
        NSGraphicsContext.current?.cgContext.translateBy(x: 0, y: isFlipped ? -lift : lift)
        super.draw(dirtyRect)
        NSGraphicsContext.current?.cgContext.restoreGState()
    }

    private func restyle() {
        // A button that cannot be undone says so in its words, never in
        // an alarm colour: one light, no paint.
        let color: NSColor = primary ? BarTheme.onAccent : (isEnabled ? BarTheme.ink : BarTheme.secondaryColor)
        let words = super.title
        super.attributedTitle = NSAttributedString(
            string: words,
            attributes: BarTheme.attributes(.control, color: color, in: effectiveAppearance))
        standing.pressed = pressing
        let state: Keycaps.CapState = pressing ? .pressed : (hovering ? .hovered : .resting)
        standing.paint(in: self, face: BarTheme.face(lit: primary, state: state),
                       side: primary ? BarTheme.litSideFill : BarTheme.sideFill,
                       rim: primary ? BarTheme.litRimFill : BarTheme.rimFill,
                       edge: primary ? nil : BarTheme.faceEdge)
        needsDisplay = true
        invalidateIntrinsicContentSize()
    }
}

/// A row in a room's choice menu, drawn by Lodestar: the system's menu
/// highlights in the Mac's accent, so each item wears this view, which
/// rises under the pointer or the arrow keys like the bars' rows and marks
/// the current choice with the accent's dot.
final class ChoiceMenuItemView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let dot = NSView()
    private weak var popup: NSPopUpButton?
    static let height: CGFloat = 26

    /// The width a menu of these labels needs: the dot's room, the icon's if
    /// any, the longest label, and a part to each side.
    static func width(forLabel widest: CGFloat, withIcon icon: Bool) -> CGFloat {
        (Grid.part + BarTheme.dotDiameter + Grid.close + (icon ? Grid.section : 0) + widest + Grid.part).rounded(.up)
    }

    init(item: NSMenuItem, chosen: Bool, width: CGFloat, popup: NSPopUpButton) {
        self.popup = popup
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        wantsLayer = true
        label.stringValue = item.title
        label.setRole(.control)
        label.textColor = item.isEnabled ? BarTheme.ink : BarTheme.secondaryColor
        label.lineBreakMode = .byTruncatingTail
        icon.image = item.image
        dot.wantsLayer = true
        dot.layer?.cornerRadius = BarTheme.dotRadius
        dot.layer?.backgroundColor = BarTheme.accent.cgColor
        dot.isHidden = !chosen
        [dot, icon, label].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(item.title)
        setAccessibilitySelected(chosen)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let inset = Grid.part
        // Centred on the face, which stands a side's half-height above the middle.
        let lift = Ceramic.Side.control / 2
        dot.frame = NSRect(x: inset, y: ((bounds.height - BarTheme.dotDiameter) / 2 + lift).rounded(),
                           width: BarTheme.dotDiameter, height: BarTheme.dotDiameter)
        var x = inset + BarTheme.dotDiameter + Grid.close
        if icon.image != nil {
            icon.frame = NSRect(x: x, y: ((bounds.height - Grid.part) / 2 + lift).rounded(), width: Grid.section - Grid.tight, height: Grid.part)
            x += Grid.section
        }
        let natural = label.sizeThatFits(NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                height: CGFloat.greatestFiniteMagnitude)).height
        label.frame = NSRect(x: x, y: ((bounds.height - natural) / 2 + lift).rounded(),
                             width: max(0, bounds.width - x - inset), height: natural)
    }

    /// Lit by the menu's own highlight, which follows the pointer and the
    /// arrow keys alike: the chosen row stands up on its side.
    override func draw(_ dirtyRect: NSRect) {
        guard enclosingMenuItem?.isHighlighted == true, enclosingMenuItem?.isEnabled == true else { return }
        let rect = bounds.insetBy(dx: Grid.tight, dy: Grid.hair)
        Ceramic.drawStanding(in: rect, radius: BarTheme.radius(BarTheme.paneRowRadius, height: rect.height),
                             side: Ceramic.Side.control)
    }

    /// A view in a menu takes the click itself: choose, close, and send
    /// the popup's action as the system's item would.
    override func mouseUp(with event: NSEvent) {
        guard let item = enclosingMenuItem, item.isEnabled, let menu = item.menu else { return }
        menu.cancelTracking()
        let index = menu.index(of: item)
        popup?.selectItem(at: index)
        if let action = popup?.action { NSApp.sendAction(action, to: popup?.target, from: popup) }
    }
}

/// A switch drawn in Lodestar's accent. macOS's own switch takes its tint
/// from the system accent and offers no way to say otherwise, so a
/// person who chose International Orange saw the settings' switches in
/// the Mac's colour. This one is the same gesture — click, space, the
/// screen reader's press — drawn by the theme. The knob slides; nothing
/// else moves.
final class AccentSwitch: NSControl, CeramicDepth {
    private let track = CALayer()
    /// The knob is a thing you press, so it stands up: a face on a side, as
    /// a key does, and casts no shadow. It stands inside its own frame.
    private let knob = CALayer()
    private let knobStanding = Standing(rest: Ceramic.Side.control)
    static let size = NSSize(width: BarTheme.switchWidth, height: BarTheme.minTarget)
    /// The track is a hairline pill the knob sits in; the control around
    /// it is the pointer's target, never under 24 high.
    private static let trackHeight = BarTheme.switchTrackHeight

    var state: NSControl.StateValue = .off {
        didSet { paint() }
    }
    /// How long the knob takes to cross, when motion is welcome.
    static let slide: TimeInterval = 0.18

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(origin: frameRect.origin, size: Self.size))
        wantsLayer = true
        layer?.masksToBounds = false
        track.cornerRadius = BarTheme.hairlineRadius(width: Self.trackHeight)
        let knobSize = Self.trackHeight - Grid.tight
        knobStanding.install(in: knob)
        knobStanding.fit(CGRect(x: 0, y: 0, width: knobSize, height: knobSize),
                         radius: BarTheme.hairlineRadius(width: knobSize))
        layer?.addSublayer(track)
        layer?.addSublayer(knob)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        paint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var depth: Ceramic.Depth { .standsUp(side: knobStanding.side) }
    var drawnSide: CGFloat { knobStanding.visibleSide }

    override var intrinsicContentSize: NSSize { Self.size }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func layout() {
        super.layout()
        paint()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    /// The knob slides and the track's colour crosses with it, unless a
    /// person has asked the system for less motion, in which case both
    /// simply arrive. A layout pass never animates: the switch drawn
    /// into place must not slide into it.
    private func paint(animated: Bool = false) {
        let on = state == .on
        let tint = Ceramic.resolved(on ? BarTheme.accent : BarTheme.inkAt(0.22), in: self)
        knobStanding.paint(in: self, face: BarTheme.knob, side: BarTheme.sideFill, rim: nil, edge: nil)
        let knobSize = Self.trackHeight - Grid.tight
        let trackFrame = NSRect(x: 0, y: ((bounds.height - Self.trackHeight) / 2).rounded(),
                                width: bounds.width, height: Self.trackHeight)
        let knobFrame = NSRect(x: on ? bounds.width - knobSize - Grid.hair : Grid.hair,
                               y: trackFrame.minY + Grid.hair, width: knobSize, height: knobSize)
        let fromPosition = knob.presentation()?.position ?? knob.position
        let fromTint = track.presentation()?.backgroundColor ?? track.backgroundColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = trackFrame
        track.backgroundColor = tint
        knob.frame = knobFrame
        layer?.opacity = isEnabled ? 1 : 0.45
        CATransaction.commit()
        // A layout pass leaves a running slide alone; only a new slide
        // replaces one.
        if animated, !Accessibility.reduceMotion() {
            knob.removeAnimation(forKey: "slide")
            track.removeAnimation(forKey: "tint")
            let slide = CABasicAnimation(keyPath: "position")
            slide.fromValue = NSValue(point: fromPosition)
            slide.toValue = NSValue(point: knob.position)
            slide.duration = Self.slide
            slide.timingFunction = BarTheme.motion
            knob.add(slide, forKey: "slide")
            let cross = CABasicAnimation(keyPath: "backgroundColor")
            cross.fromValue = fromTint
            cross.toValue = tint
            cross.duration = Self.slide
            track.add(cross, forKey: "tint")
        }
        setAccessibilityValue(on ? 1 : 0)
    }

    override var isEnabled: Bool { didSet { paint() } }

    private func flip() {
        guard isEnabled else { return }
        set(state == .on ? .off : .on, animated: true)
        sendAction(action, to: target)
    }

    /// A state arriving from outside — the config re-read after a write
    /// — that differs from what is shown slides the same way a press does.
    func set(_ next: NSControl.StateValue, animated: Bool) {
        guard next != state else { return }
        state = next
        if animated { paint(animated: true) }
    }

    override func mouseDown(with event: NSEvent) { flip() }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { flip() } else { super.keyDown(with: event) }
    }

    override func accessibilityPerformPress() -> Bool {
        flip()
        return true
    }

    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
}

/// The flash's mark, read from the glyph every flash has opened with
/// since the first one: ✕ refused, ⚠ needs you, ◎ a breath, ⌂ the
/// clipboard, … opening, ✓ ⌖ done, and the layout family's arrows. The
/// glyph was the kind; the kind now draws as a symbol in the pill's
/// configuration and the line opens with a capital, so every flash on
/// the pane is one family with the pill and nothing is retyped at
/// sixty sites.
enum FlashMark {
    static let symbols: [Character: String] = [
        "✕": "xmark",
        "⚠": "exclamationmark.triangle",
        "◎": BarTheme.breathSymbol,
        "⌂": "doc.on.clipboard",
        "✓": "checkmark",
        "⌖": "checkmark",
        "↺": "rectangle.3.group",
        "⟲": "rectangle.3.group",
        "⤺": "rectangle.3.group",
        "☰": "line.3.horizontal",
    ]

    /// The symbol the line's glyph names, and the line without it, its
    /// first letter raised. A line with no glyph keeps its words and
    /// takes no symbol.
    static func parse(_ text: String) -> (symbol: String?, text: String) {
        guard let first = text.first, let symbol = symbols[first] else { return (nil, text) }
        let rest = text.dropFirst().trimmingCharacters(in: .whitespaces)
        return (symbol, Coach.sentenceCase(rest))
    }
}


extension NSTextField {
    /// The one way a field takes a placeholder: in the field's own role,
    /// quiet, and resolved again with the look.
    func setPlaceholder(_ text: String) {
        placeholderAttributedString = BarTheme.placeholder(text, role: typeStyle?.role ?? .body)
        followLook()
    }
}


extension Readability.RGB {
    var color: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
}

/// The one key Lodestar draws: a face on a visible side. Lit, it is a piece
/// of the mark: the accent, with the mark's brightest face for its rim and
/// its darkest for its side, and the letter in whichever ink reads on it.
/// Resting, it is a quiet cap; in clay, the pictures' pale keycap. Pressed,
/// its side falls to a point and the face follows it down, at once.
final class KeyFace: NSView, CeramicDepth {
    let label = NSTextField(labelWithString: "")
    var lit = false { didSet { if lit != oldValue { refresh() } } }
    /// A key you could press but are not being asked to: the address the
    /// coach offers for later, a cheat sheet's unused gesture, an action
    /// not available yet. It lies flat: no side and no fill, a hairline and
    /// the quiet ink for its letter. Depth carries the importance, never a
    /// fade: a translucent key is not a thing a light falls on, and on clay
    /// it all but vanished.
    var quiet = false { didSet { if quiet != oldValue { refresh() } } }
    /// What a pointer is doing to a key that can be clicked: it brightens
    /// under the pointer and stands down onto its side when pressed.
    private var pointer = Keycaps.CapState.resting
    let standing = Standing(rest: Ceramic.Side.control)
    private var labelCentre: NSLayoutConstraint?

    /// `padX` widens a key whose label is a word on a long cap, the walk's
    /// space bar; every other key takes the theme's.
    init(_ text: String, padX: CGFloat = Grid.half) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.masksToBounds = false
        if let layer { standing.install(in: layer) }
        label.stringValue = text
        label.setRole(.key)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        let centre = label.centerYAnchor.constraint(equalTo: centerYAnchor)
        labelCentre = centre
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padX),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padX),
            centre,
            heightAnchor.constraint(equalToConstant: BarTheme.keyHeight),
            widthAnchor.constraint(greaterThanOrEqualToConstant: BarTheme.chipMinWidth),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    var depth: Ceramic.Depth { standing.flat ? .flat : .standsUp(side: standing.side) }
    var drawnSide: CGFloat { standing.visibleSide }

    override func layout() {
        super.layout()
        standing.fit(bounds, radius: BarTheme.controlRadius)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    /// Refill for the pointer, as `Keycaps.CapGroup` does for its caps.
    func fill(_ state: Keycaps.CapState) {
        guard state != pointer else { return }
        pointer = state
        refresh()
    }

    func refresh() {
        let flat = quiet && !lit
        standing.flat = flat
        standing.pressed = pointer == .pressed
        if flat {
            standing.paint(in: self, face: nil, side: nil, rim: nil, edge: BarTheme.hairline)
            label.textColor = BarTheme.secondaryColor
        } else {
            standing.paint(in: self, face: BarTheme.face(lit: lit, state: pointer),
                           side: lit ? BarTheme.litSideFill : BarTheme.sideFill,
                           rim: lit ? BarTheme.litRimFill : BarTheme.rimFill,
                           edge: lit ? nil : BarTheme.faceEdge)
            label.textColor = lit ? BarTheme.onAccent : BarTheme.keyLetter
        }
        // The letter stays on the face, wherever the face stands.
        // (An anchor's constant counts the other way from the view's own y.)
        labelCentre?.constant = -standing.lift
    }
}

/// A chip that only says something lies flat: a hairline outline with no
/// fill and no side, set again whenever the appearance changes, since a
/// layer keeps the colour it was given.
final class FlatChip: NSView, CeramicDepth {
    var depth: Ceramic.Depth { .flat }
    var drawnSide: CGFloat { 0 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = BarTheme.controlRadius
        tint()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tint()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        tint()
    }

    private func tint() {
        layer?.borderWidth = Ceramic.Edge.line
        layer?.borderColor = Ceramic.resolved(BarTheme.hairline, in: self)
    }
}

/// A row that stands up when it is chosen: its face on a side in the key
/// step, its rim catching the light, and its keys lit by whoever subclasses
/// it. The bars' rows share it, so the launcher, Ask and the commands bar
/// choose a row the same way. The row's frame holds the side, and its
/// content is centred on the face, half a side above the frame's middle.
class RaisedRow: NSView, CeramicDepth {
    /// The side a chosen row stands on, which its content is lifted half of.
    static let side = Ceramic.Side.row
    private let standing = Standing(rest: Ceramic.Side.row)
    private(set) var raised = false
    /// Where the row's corners are, before a row too short for it becomes
    /// a stadium. A row stands one pane-inset inside its pane, so it
    /// rounds at the pane's radius less that inset and its corners keep an
    /// even gap from the pane's; a row set deeper says its own.
    var radius = BarTheme.paneRowRadius {
        didSet { if radius != oldValue { needsLayout = true } }
    }

    func setupRaised() {
        wantsLayer = true
        layer?.cornerRadius = BarTheme.paneRowRadius
        layer?.masksToBounds = false
        // The content stands on the face, not on the face and its side: the
        // row's layers rise by half the side, and the face and side are laid
        // lower by the same, so they stay where the frame says.
        layer?.sublayerTransform = CATransform3DMakeTranslation(0, Self.side / 2, 0)
        if let layer { standing.install(in: layer) }
        applyRaised(false)
    }

    var depth: Ceramic.Depth { raised ? .standsUp(side: standing.side) : .flat }
    var drawnSide: CGFloat { raised ? standing.visibleSide : 0 }

    override func layout() {
        super.layout()
        let corner = BarTheme.radius(radius, height: bounds.height)
        layer?.cornerRadius = corner
        standing.fit(bounds.offsetBy(dx: 0, dy: -Self.side / 2), radius: corner)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyRaised(raised)
    }

    func applyRaised(_ on: Bool) {
        raised = on
        standing.hidden = !on
        standing.paint(in: self, face: BarTheme.faceFill, side: BarTheme.sideFill, rim: BarTheme.rimFill, edge: nil)
    }
}

/// A surface's own shadow: the one shadow a floating pane casts, following
/// its outline. The system's window shadow cannot be shaped, so the panel
/// grows by `margin` on every side, the surface sits inset inside it, and
/// the host casts the shadow in that margin. Clicks in the margin land on
/// nothing.
enum SoftShadow {
    static let margin = Grid.column + Grid.group

    /// The window's frame for a surface that should stand at `visible`.
    static func outset(_ visible: NSRect) -> NSRect { visible.insetBy(dx: -margin, dy: -margin) }
    /// The surface's frame inside a window hosted this way.
    static func inset(_ window: NSRect) -> NSRect { window.insetBy(dx: margin, dy: margin) }

    /// Host `content` as the panel's surface, with the shadow cast here,
    /// and gate the pointer so only the pane takes it: the margin is
    /// window, and a click there belongs to whatever is beneath. Every
    /// hosted surface is gated by construction; the gate is returned for a
    /// surface that changes size under a still pointer and must re-read it.
    ///
    /// `takesPointer: false` is for a surface that only shows (a key
    /// guide, the ⌘K card): it never takes the mouse, pane or shadow.
    @discardableResult
    static func host(_ content: NSView, in panel: NSPanel, cornerRadius: CGFloat,
                     takesPointer: Bool = true) -> PointerGate {
        panel.hasShadow = false
        let host = ShadowHostView(content: content, cornerRadius: cornerRadius)
        panel.contentView = host
        let gate = PointerGate(panel: panel)
        gate.enabled = takesPointer
        host.gate = gate
        return gate
    }
}

extension SoftShadow {
    /// One object among several in a window that hosts no single surface:
    /// Keep's cards, each casting its own shadow onto whatever is beneath.
    static func object(radius: CGFloat) -> ObjectSurface {
        ObjectSurface(radius: radius)
    }
}

/// The pane's shadow, cast by one object rather than by a window: the same
/// shadow a hosted surface casts, from the object's own outline.
final class ObjectSurface: NSView {
    let radius: CGFloat
    private let casting = PaneShadow()

    init(radius: CGFloat) {
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.insertSublayer(casting.layer, at: 0)
        casting.paint(in: self)
    }

    required init?(coder: NSCoder) { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
    }

    private func place() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        casting.cast(outline: bounds, radius: BarTheme.radius(radius, height: bounds.height))
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        casting.paint(in: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        casting.paint(in: self)
    }
}

extension NSWindow {
    /// The pane's frame: the window's, less the shadow's margin when the
    /// window hosts one. Surfaces place and read their pane by this, so
    /// the margin changes no arithmetic.
    var paneFrame: NSRect {
        contentView is ShadowHostView ? SoftShadow.inset(frame) : frame
    }

    func setPaneFrame(_ pane: NSRect, display: Bool) {
        setFrame(contentView is ShadowHostView ? SoftShadow.outset(pane) : pane, display: display)
    }
}

/// A soft-shadowed window is larger than its surface by the shadow's
/// margin, and a window that takes the mouse takes it everywhere it
/// stands, shadow included: a band of air around the pane that eats
/// clicks meant for the app beneath, the Dock's top edge among them. The
/// system's own shadow was never a target. A surface that stays open over
/// someone else's work therefore takes the mouse only while the pointer
/// is over its pane, and lets it through everywhere else.
final class PointerGate {
    private weak var panel: NSPanel?
    private var monitors: [Any] = []
    private var visibility: NSObjectProtocol?

    init(panel: NSPanel) {
        self.panel = panel
        panel.ignoresMouseEvents = true
        // Watching only while the window is on screen, whoever shows or
        // hides it: a bar that closes on losing key never says so here.
        visibility = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main
        ) { [weak self] _ in self?.followVisibility() }
    }

    deinit {
        monitors.forEach(NSEvent.removeMonitor)
        if let visibility { NotificationCenter.default.removeObserver(visibility) }
    }

    private func followVisibility() {
        guard let panel else { return }
        if panel.isVisible { start() } else { stop() }
    }

    func start() {
        if monitors.isEmpty {
            let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
            if let global = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
                self?.update()
            }) { monitors.append(global) }
            if let local = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
                self?.update()
                return event
            }) { monitors.append(local) }
        }
        update()
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panel?.ignoresMouseEvents = true
    }

    /// Whether the window takes the mouse right now, for the tests.
    var open: Bool { panel.map { !$0.ignoresMouseEvents } ?? false }

    /// Off, the surface takes no mouse anywhere: one that only shows, or
    /// one that takes it only while it offers something (the flash).
    var enabled = true {
        didSet { if enabled != oldValue { update() } }
    }

    /// Read the pointer against the pane. Called on every move and
    /// whenever the pane changes size under a still pointer.
    func update(pointer: NSPoint = NSEvent.mouseLocation) {
        guard let panel else { return }
        let over = enabled && panel.isVisible && SoftShadow.inset(panel.frame).contains(pointer)
        if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
    }
}

final class ShadowHostView: NSView {
    /// The surface's pointer gate, held for the window's life.
    var gate: PointerGate?
    private let content: NSView
    private let radius: CGFloat
    private let casting = PaneShadow()

    init(content: NSView, cornerRadius: CGFloat) {
        self.content = content
        self.radius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(casting.layer)
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = []
        addSubview(content)
        content.wantsLayer = true
        casting.paint(in: self)
    }

    required init?(coder: NSCoder) { nil }

    /// Placed on every change of size, not only in a layout pass: a plain
    /// resize of a view without constraints does not always lay out.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
    }

    override func layout() {
        super.layout()
        place()
    }

    private func place() {
        let surface = bounds.insetBy(dx: SoftShadow.margin, dy: SoftShadow.margin)
        // A window smaller than its own margins (a panel before its first
        // placement) has no surface yet; a null frame would be handed to
        // the content's constraints.
        guard !surface.isNull, surface.width > 0, surface.height > 0 else { return }
        if content.frame != surface { content.frame = surface }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        casting.cast(outline: surface, radius: radius)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        casting.paint(in: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        casting.paint(in: self)
    }

    /// Only the surface takes the pointer; the shadow is not a target.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard content.frame.contains(local) else { return nil }
        return super.hitTest(point)
    }
}

/// A mark's key: the one key laid over another app's window, built by hand
/// without layout, so it stands on its side in its own layer.
final class MarkKey: NSView, CeramicDepth {
    let standing: Standing

    init(frame: NSRect, rest: CGFloat) {
        standing = Standing(rest: rest)
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        if let layer { standing.install(in: layer) }
        paint()
    }

    required init?(coder: NSCoder) { nil }

    var depth: Ceramic.Depth { .standsUp(side: standing.side) }
    var drawnSide: CGFloat { standing.visibleSide }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        standing.paint(in: self, face: BarTheme.markFill, side: BarTheme.sideFill, rim: BarTheme.rimFill,
                       edge: BarTheme.hairline)
    }
}

/// Marks laid over another app's window, drawn as the one key: the pale cap
/// on its side, with a hairline so it reads over any app, light or dark. A mark the hand has begun typing
/// stays the resting key and keeps its width: the letters already typed
/// dim in its label, and the ones still to press keep the mark's ink.
/// Built by hand, without layout, because a window of click hints can be
/// four hundred of them at once.
enum KeyMark {
    static let height: CGFloat = BarTheme.keyHeight
    /// The peek's numerals: the same key at a size read across the screen.
    static let peekHeight: CGFloat = BarTheme.rowHeight
    /// The neutral hairline from a displaced tag to its word.
    static var connector: NSColor { BarTheme.inkAt(Tone.systemDark ? 0.38 : 0.35) }
    /// The underline's weight: the editor's line, select's matches, a held span.
    static let underline: CGFloat = 2.5
    /// The anchor's and the held span's heavier line.
    static let heavyUnderline: CGFloat = 3.5

    /// A label with its first `typed` letters dimmed, in the caption grey,
    /// and the rest in the mark's ink. The label compares to what was
    /// typed without case, since it is drawn in capitals; a label the typed
    /// letters do not begin is drawn whole.
    static func letters(_ text: String, typed: String, role: BarTheme.Role) -> NSAttributedString {
        let drawn = text.uppercased()
        let done = !typed.isEmpty && text.lowercased().hasPrefix(typed.lowercased()) ? typed.count : 0
        let label = NSMutableAttributedString(string: drawn, attributes: BarTheme.attributes(
            role, color: BarTheme.markLetter))
        label.addAttribute(.foregroundColor, value: BarTheme.secondaryColor,
                           range: NSRange(location: 0, length: min(done, label.length)))
        return label
    }

    /// One key, origin at zero, sized to its letters. `typed` is what the
    /// hand has typed of the label so far; those letters dim. It stands on
    /// a side inside its frame, three points at a key's size and five at the
    /// peek's, and wears a hairline so it reads over any app.
    static func key(_ text: String, typed: String = "", peek: Bool = false) -> NSView {
        let height = peek ? peekHeight : height
        let side = peek ? Ceramic.Side.large : Ceramic.Side.control
        let radius = BarTheme.controlRadius
        let label = NSTextField(labelWithAttributedString:
            letters(text, typed: typed, role: peek ? .largeFigure : .key))
        label.followLook()
        label.alignment = .center
        label.sizeToFit()
        let width = max(height, ceil(label.frame.width) + Grid.half * 2)
        let view = MarkKey(frame: NSRect(x: 0, y: 0, width: width, height: height), rest: side)
        view.standing.fit(view.bounds, radius: radius)
        // The letter stands on the face: the frame less the side.
        label.frame = NSRect(x: 0, y: (side + (height - side - label.frame.height) / 2).rounded(), width: width,
                             height: label.frame.height)
        view.addSubview(label)
        return view
    }

    /// The editor lens's tag: the key and the fix in words, on a small
    /// pane of the palette in force, just above the word it fixes. It
    /// floats over another app's text, so it casts the pane's shadow.
    static func tag(letter: String, word: String, typed: String = "") -> NSView {
        let pad = Grid.tight
        let radius = BarTheme.controlRadius + pad
        let key = KeyMark.key(letter, typed: typed)
        let label = NSTextField(labelWithString: word)
        label.setRole(.meta)
        label.textColor = BarTheme.ink
        label.sizeToFit()
        let height = key.frame.height + pad * 2
        let width = ceil(pad + key.frame.width + Grid.half + label.frame.width + Grid.close)
        let tag = ObjectSurface(radius: radius)
        tag.frame = NSRect(x: 0, y: 0, width: width, height: height)
        Ceramic.installPane(in: tag, cornerRadius: radius)
        key.frame.origin = NSPoint(x: pad, y: pad)
        tag.addSubview(key)
        label.frame.origin = NSPoint(x: key.frame.maxX + Grid.half, y: ((height - label.frame.height) / 2).rounded())
        tag.addSubview(label)
        return tag
    }

    /// An underline in the accent along the foot of `rect` (AppKit
    /// coordinates in the view it is added to).
    static func underline(under rect: NSRect, weight: CGFloat) -> NSView {
        let line = NSView(frame: NSRect(x: rect.minX + 1, y: rect.minY - weight + 1,
                                        width: max(Grid.hair, rect.width - Grid.hair), height: weight))
        line.wantsLayer = true
        line.layer?.backgroundColor = BarTheme.accent.cgColor
        line.layer?.cornerRadius = weight / 2
        return line
    }
}
