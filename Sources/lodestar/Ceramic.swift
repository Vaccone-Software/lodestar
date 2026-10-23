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
    /// Held inside a slab: a picture is content, drawn as it is, so it takes
    /// the look around the slab and not the one inside it.
    var heldInSlab = false { didSet { pin.active = heldInSlab } }
    private lazy var pin = Slab.Flip(self)

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        pin.settle()
    }

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
    static let footerHeight: CGFloat = Grid.section

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
    /// light, at the Eye comfort level in force (design/06-eye-comfort.md).
    /// Every colour below resolves through this, in the look of the view that
    /// draws it, and nothing else in the app reads a palette: the level lives
    /// here and nowhere else, so a surface is dimmed, calmed and receded
    /// without a line of its own. The look is the Mac's, and only the Mac's.
    static func steps(for appearance: NSAppearance) -> Palette.Steps {
        EyeComfortState.shared.steps(dark: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    /// The ink: tinted, never pure black or pure white (the ceiling),
    /// resolved in the look of the view that draws it. Text that takes this
    /// and not the system's label colour is the same ink in every look.
    static let ink = NSColor(name: "LodestarInk") { appearance in
        steps(for: appearance).ink.color
    }

    /// The one selection: ink at 30%, behind the words, in every well and in
    /// Keep's naming (design/12-well.md).
    static let washShare: CGFloat = 0.3
    static var wash: NSColor { inkAt(washShare) }

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

    /// The palette in force: the night in dark mode, clay in light, at the
    /// Eye comfort level.
    static var palette: Palette.Steps {
        EyeComfortState.shared.steps(dark: Tone.systemDark)
    }

    /// The pane as a colour that knows both looks, for a layer that must
    /// change with the look while it stands (`ToneView` resolves it).
    static func dynamicGround(alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in steps(for: appearance).pane.color.withAlphaComponent(alpha) }
    }

    /// The panels' ground, for anything that must be judged against it:
    /// the pane of the palette in force, which every surface is made of.
    static var ground: NSColor { palette.pane.color }

    /// What a file's sheet lies in on a card: the look's key step, as a page
    /// is paler than the table it lies on. It is content, drawn as it is.
    /// Never what marks a chosen thing: that is the slab (design/11-slab.md).
    static var sheet: NSColor { palette.key.color }

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
    static var shadow: NSColor { palette.isDark ? palette.ground.color : palette.quietInk.color }
    /// The light look as the level has it: clay's own steps, which the dark
    /// look borrows for its lightest and darkest things.
    private static var clayInForce: Palette.Steps { EyeComfortState.shared.steps(dark: false) }
    /// A switch's knob: the lightest step the palette has, in both looks.
    /// By day it is the key step as dimmed with the pane it stands on; by
    /// night it is clay's key as it is, because night's bright things are
    /// the ink, the quiet ink and the slab, and the knob is none of them.
    static var knob: NSColor { lightest }
    /// The lightest and the darkest step the palette owns, which a lit key
    /// is shaded toward: its rim catches the key's face, its side falls in
    /// the slab's side, the way the mark's faces are shaded.
    static var lightest: NSColor { (palette.isDark ? Palette.clay : palette).key.color }
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

    /// Text drawn over the accent as a fill — a lit key's letter. The letter
    /// on the orange is whichever of clay's key face and clay's ink measures
    /// higher on the fill, never pure white or pure black (white on the
    /// night's orange is 3.3 to 1), decided from the fill itself, in the look
    /// the letter is drawn in: a lit key on a slab is the slab's look's.
    static var onAccent: NSColor {
        NSColor(name: "LodestarOnAccent") { appearance in
            let light = clayInForce
            var fill: NSColor?
            appearance.performAsCurrentDrawingAppearance { fill = accent.usingColorSpace(.sRGB) }
            guard let fill else { return light.ink.color }
            return Palette.letter(on: Readability.RGB(red: fill.redComponent, green: fill.greenComponent,
                                                      blue: fill.blueComponent), face: light.key, ink: light.ink).color
        }
    }

    /// International Orange exactly as Palette holds it for the look in
    /// force, at full level: for what is drawn as it is at every hour (the
    /// app's icon), never calmed for the evening.
    static var brandOrange: NSColor { (Tone.systemDark ? Palette.night : Palette.clay).orange.color }

    /// International Orange as the look in force wants it: #FA5617 at night,
    /// #C83500 on clay, one value per look (Palette). Resolved in the look
    /// of the view that draws it, so a lit key on a slab, which stands in the
    /// other look, is that look's orange.
    static var internationalOrange: NSColor {
        NSColor(name: "LodestarOrange") { appearance in steps(for: appearance).orange.color }
    }

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
class HandButton: NSButton {
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
        /// The keystrokes, one key each, as typed: `e`, `p`, `⌘K`, `esc`.
        let keys: [String]
        /// The last key tapped twice: one key and `×2`, never two keys.
        var double = false
        let verb: String
        let action: (() -> Void)?
        /// A room's own verb: its keys lit, as the launcher lights the keys
        /// of the row the hand is about to take.
        var lit = false
        /// Not available now (Continue before a choice, Send while
        /// sending): drawn receded, and not clickable.
        var quiet = false

        init(_ keys: [String], _ verb: String, double: Bool = false, action: (() -> Void)? = nil,
             lit: Bool = false, quiet: Bool = false) {
            self.keys = keys
            self.double = double
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
        private let content: NSView
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
            self.content = content
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

        /// The common case: the keys of one gesture, lit together.
        convenience init(strokes: KeyStrokes, action: @escaping () -> Void) {
            let caps = strokes.caps
            self.init(content: strokes,
                      paint: { state in for cap in caps { cap.fill(state) } },
                      action: action)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not from a nib") }

        /// As aligned as what it holds: by the keys' faces, with their sides
        /// inside the group's own frame, where the click lands.
        override var alignmentRectInsets: NSEdgeInsets { content.alignmentRectInsets }

        /// As wide as its keys, said, so a row that holds it hugs it: a view
        /// with no width of its own is the one a stack hands the slack to.
        override var intrinsicContentSize: NSSize {
            NSSize(width: content.intrinsicContentSize.width, height: NSView.noIntrinsicMetric)
        }

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
        // A legend is as wide as its keys and words: a column that holds it
        // must not stretch it (a tie with the column's own pull at 250).
        row.setContentHuggingPriority(.required, for: .horizontal)
        let parts = FlashLine.parts(line)
        // Words stand on the baseline of the key they follow, or of the one
        // they lead into when no key comes before them.
        func legend(of part: FlashLine.Part?, last: Bool) -> String? {
            guard case .keys(let keys)? = part else { return nil }
            return last ? keys.last : keys.first
        }
        for (index, part) in parts.enumerated() {
            switch part {
            case .words(let text):
                let before = index > 0 ? legend(of: parts[index - 1], last: true) : nil
                let after = index + 1 < parts.count ? legend(of: parts[index + 1], last: false) : nil
                row.addArrangedSubview(KeyWords(text, following: before ?? after))
            case .keys(let keys):
                // One key per keystroke, 4 apart, as typed.
                row.addArrangedSubview(strokes(keys))
            }
        }
        row.setAccessibilityLabel(FlashLine.plain(line))
        return row
    }

    /// The keystrokes a written group of keys is: a key by name or a chord
    /// is one (`esc`, `⌘K`, `⇧F`, `a…z`), and a run of letters and symbols
    /// is one each (`zo` is `z` then `o`).
    static func keystrokes(of written: String) -> [String] {
        let modifiers = Set("⇧⌘⌥⌃")
        if written.count == 1 || written.contains("…") || written.first.map({ modifiers.contains($0) }) == true {
            return [written]
        }
        let named: Set<String> = ["esc", "tab", "space", "lode", "fn", "return", "delete"]
        if named.contains(written) { return [written] }
        return written.map(String.init)
    }

    /// A single key: the one key, so a key never looks like two different
    /// things on two surfaces.
    static func cap(_ legend: String, size: KeySize = .standard) -> Key {
        Key(legend, size: size)
    }

    /// The keys of one gesture: a key per keystroke, 4 apart; a double tap
    /// is one key and `×2`.
    static func strokes(_ legends: [String], double: Bool = false, lit: Bool = false,
                        quiet: Bool = false) -> KeyStrokes {
        KeyStrokes(legends, double: double, lit: lit, quiet: quiet)
    }

    /// A chip's gesture line: keys and the words that say what they do, with
    /// a middot between gestures. Keys within a gesture stand 4 apart, a
    /// double tap is one key and `×2`, and separate gestures 8 apart.
    static func line(_ gestures: [Gesture]) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Grid.tight
        row.setContentHuggingPriority(.required, for: .horizontal)
        var previous: NSView?
        // The legend of the key the words that come next follow: words beside
        // a key stand on its baseline (design/13-row.md, rule 4).
        var previousLegend: String?

        func add(_ view: NSView, spacingBefore: CGFloat? = nil) {
            if let spacingBefore, let previous { row.setCustomSpacing(spacingBefore, after: previous) }
            row.addArrangedSubview(view)
            previous = view
        }

        for (index, gesture) in gestures.enumerated() {
            if index > 0 {
                add(KeyWords("·", following: previousLegend), spacingBefore: Grid.close)
            }
            let keys = strokes(gesture.keys, double: gesture.double, lit: gesture.lit && !gesture.quiet,
                               quiet: gesture.quiet)
            if let action = gesture.action, !gesture.quiet {
                // One view for the whole gesture, so hover lights its keys
                // at once: `lode ⌫` is one press of two keys, not two
                // things that happen to sit together.
                add(CapGroup(strokes: keys, action: action), spacingBefore: index > 0 ? Grid.close : nil)
            } else {
                add(keys, spacingBefore: index > 0 ? Grid.close : nil)
            }
            // A label is a name, capitalized wherever it is written from:
            // "esc Back", never "esc back".
            previousLegend = gesture.keys.last
            let verb = KeyWords(gesture.verb.prefix(1).uppercased() + gesture.verb.dropFirst(),
                                color: gesture.lit && !gesture.quiet ? BarTheme.ink : BarTheme.secondaryColor,
                                following: previousLegend)
            add(verb, spacingBefore: Grid.close)
        }
        return row
    }
}

/// A room's one-line field, drawn rather than the system's bezel: a well,
/// the theme's control rounding, around a borderless field. The bezelled field is a system
/// control in costume, and its focus ring wears the Mac's accent.
final class RoomField: WellView {
    let field = InputField()

    init(placeholder: String) {
        super.init(cornerRadius: BarTheme.controlRadius)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.setRole(.body)
        field.textColor = BarTheme.ink
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setPlaceholder(placeholder)
        addSubview(field)
        hold(field)
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

/// A line in a room's choice menu, drawn by Lodestar: the system's menu
/// highlights in the Mac's accent, so each item wears this view. A line of the
/// row contract (`ListLine`): 32 tall, touching the next, 8 inside the menu,
/// a dot column leading (the dot marks the choice in use), a symbol after it
/// if the item has one, then the words, cut at the tail. The line the menu has
/// chosen, by the pointer or the arrow keys alike, is the slab, as the bars'
/// chosen row is, rounded at the menu's radius less its inset. A choice that
/// cannot be taken keeps its words in the quiet ink and never becomes the slab.
final class ChoiceMenuItemView: NSView {
    /// The line inside the item's frame: the slab when chosen, holding the
    /// dot, the icon and the words.
    private final class Row: ListLine {}
    private let step = Row()
    private weak var popup: NSPopUpButton?
    private let hasIcon: Bool
    static let height = BarTheme.lineHeight
    /// A test's say on whether the row is the chosen one; the menu's own
    /// highlight says it otherwise.
    var highlighted: Bool? { didSet { sync() } }

    /// The width a menu of these labels needs: a line's inset, the dot's
    /// column, the symbol's if any, the longest label, each 12 apart and 12
    /// from the line's edges, and the inset again.
    static func width(forLabel widest: CGFloat, withIcon icon: Bool) -> CGFloat {
        (BarTheme.lineInset * 2 + Grid.part + BarTheme.dotColumnWidth + Grid.part
            + (icon ? BarTheme.symbolSize + Grid.part : 0) + widest + Grid.part).rounded(.up)
    }

    init(item: NSMenuItem, current: Bool, width: CGFloat, popup: NSPopUpButton) {
        self.popup = popup
        hasIcon = item.image != nil
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        wantsLayer = true
        step.label.stringValue = item.title
        step.label.setRole(.control)
        step.label.textColor = item.isEnabled ? BarTheme.ink : BarTheme.secondaryColor
        let lead = NSStackView()
        lead.orientation = .horizontal
        lead.alignment = .centerY
        lead.spacing = Grid.part
        lead.addArrangedSubview(DotColumn(marked: current))
        if let image = item.image {
            let icon = NSImageView(image: image)
            icon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: BarTheme.symbolSize),
                icon.heightAnchor.constraint(equalToConstant: BarTheme.symbolSize),
            ])
            lead.addArrangedSubview(icon)
        }
        step.setLead(lead)
        addSubview(step)
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(item.title)
        setAccessibilitySelected(current)
    }

    required init?(coder: NSCoder) { nil }

    /// Whether this row is the chosen one now.
    var isChosen: Bool { step.chosen }

    /// The slab's frame and side, for the tests.
    var slab: SlabRow { step }

    /// The line's words, for the tests.
    var label: NSTextField { step.label }

    override func layout() {
        super.layout()
        step.frame = bounds.insetBy(dx: BarTheme.lineInset, dy: 0)
    }

    /// Choose the row, or let it go, as the menu's highlight moves.
    func choose(_ on: Bool) {
        step.choose(on && (enclosingMenuItem?.isEnabled ?? true))
    }

    private func sync() {
        choose(highlighted ?? enclosingMenuItem?.isHighlighted ?? false)
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        sync()
    }

    /// A view in a menu takes the click itself: choose, close, and send
    /// the popup's action as the system's item would.
    override func mouseDown(with event: NSEvent) {
        step.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        step.mouseUp(with: event)
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
/// screen reader's press — drawn by the theme. The knob slides, over
/// `Motion.knobSlide`; nothing else moves, and the track's colour
/// changes at once.
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

    /// The switch is painted in its end state, the knob and the track's
    /// colour at once. A flip then draws the knob's slide on top, over
    /// `Motion.knobSlide` on the one curve, unless a person has asked the
    /// system for less motion, in which case the knob simply arrives. A
    /// layout pass never animates: the switch drawn into place must not
    /// slide into it.
    private func paint(animated: Bool = false) {
        let on = state == .on
        // A switch that cannot be turned keeps its value, drawn quiet and
        // opaque: an on track is the quiet ink and not the accent.
        let tint = Ceramic.resolved(on ? (isEnabled ? BarTheme.accent : BarTheme.secondaryColor) : BarTheme.inkAt(0.22),
                                    in: self)
        knobStanding.paint(in: self, face: BarTheme.knob, side: BarTheme.sideFill, rim: nil, edge: nil)
        let knobSize = Self.trackHeight - Grid.tight
        let trackFrame = NSRect(x: 0, y: ((bounds.height - Self.trackHeight) / 2).rounded(),
                                width: bounds.width, height: Self.trackHeight)
        let knobFrame = NSRect(x: on ? bounds.width - knobSize - Grid.hair : Grid.hair,
                               y: trackFrame.minY + Grid.hair, width: knobSize, height: knobSize)
        let fromPosition = knob.presentation()?.position ?? knob.position
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = trackFrame
        track.backgroundColor = tint
        knob.frame = knobFrame
        CATransaction.commit()
        // A layout pass leaves a running slide alone; only a new slide
        // replaces one.
        if animated, !Motion.reduced {
            knob.removeAnimation(forKey: "slide")
            let slide = CABasicAnimation(keyPath: "position")
            slide.fromValue = NSValue(point: fromPosition)
            slide.toValue = NSValue(point: knob.position)
            slide.duration = Motion.knobSlide
            slide.timingFunction = Motion.curve
            knob.add(slide, forKey: "slide")
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
///
/// An object that is chosen is the slab (design/11-slab.md), whole: it takes
/// the look inside a slab, so its face, its words, its keys and its rim and
/// edge are the other look's, while the shadow it casts is the look around it:
/// the desktop beneath is that look's, not the slab's.
final class ObjectSurface: NSView, SlabSurface {
    let radius: CGFloat
    private let casting = PaneShadow()
    private lazy var flip = Slab.Flip(self)
    /// Whether the object is the slab.
    var chosen = false {
        didSet {
            guard chosen != oldValue else { return }
            flip.active = chosen
            if !chosen { press(false) }
            paintShadow()
        }
    }
    var isSlab: Bool { chosen }
    private(set) var pressed = false

    init(radius: CGFloat) {
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.insertSublayer(casting.layer, at: 0)
        paintShadow()
    }

    /// The pane inside, whose face this object's side belongs to.
    var pane: CeramicPane? { subviews.compactMap { $0 as? CeramicPane }.first }

    /// Pressed: the slab's side falls to a point and the face, and everything
    /// on it, lies lower by what the side gave up. At once.
    func press(_ down: Bool) {
        guard down != pressed, let pane, pane.rest > 0 else { return }
        pressed = down
        pane.pressed = down
        let drop = pane.rest - Ceramic.Side.pressed
        for content in subviews where !(content is CeramicPane) && !(content is PaneEdge) {
            content.frame.origin.y += down ? -drop : drop
        }
    }

    /// The shadow in the look around the object, and under a slab its caster
    /// in the slab's own side.
    private func paintShadow() {
        if chosen, let host = superview ?? window?.contentView {
            casting.paint(in: host, under: Ceramic.resolved(BarTheme.slabSideFill, in: self))
        } else {
            casting.paint(in: self)
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        flip.settle()
        paintShadow()
        if chosen { remeasureWords(padding: Grid.group) }
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
        paintShadow()
        if chosen { remeasureWords(padding: Grid.group) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        flip.settle()
        paintShadow()
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
