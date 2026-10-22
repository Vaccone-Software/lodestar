import AppKit
import LodestarCore

/// The app's tone: the system's choice, and nothing else. Liquid Glass
/// would rather adapt per panel to whatever sits behind it — that is how
/// the launcher and its ⌘K card once resolved to opposite tones a foot
/// apart, and how dark-mode text landed on light-adapted glass and
/// vanished. We keep the frost and take away the material's vote.
enum Tone {
    static var systemDark: Bool {
        // `shared`, not `NSApp`: a chip made before the application object
        // exists — the tests' world — must still have an answer.
        NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

extension Glass {
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

extension Glass {
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

/// A plain surface whose fill and edge follow the appearance: a card, a
/// rule, a dot, a caret. A layer's colour is a fixed value, so one set
/// once keeps the look it was set in; this repaints whenever the view's
/// appearance changes, so light and dark are always the ones on screen.
final class ToneView: NSView {
    /// Expressions, made again in the view's look at every paint: a colour
    /// with an alpha applied is fixed when made, so it cannot be stored.
    var fill: (() -> NSColor)? { didSet { repaint() } }
    var edge: (() -> NSColor)? { didSet { repaint() } }

    /// A lifted surface casts a small shadow in the light, where lighter is
    /// not higher; in the night it needs none.
    private let lifted: Bool

    init(fill: @autoclosure @escaping () -> NSColor? = nil, edge: @autoclosure @escaping () -> NSColor? = nil,
         edgeWidth: CGFloat = 0, radius: CGFloat = 0, lifted: Bool = false) {
        self.lifted = lifted
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
        layer?.backgroundColor = fill.map { make in Glass.resolved(make(), in: self) }
        layer?.borderColor = edge.map { make in Glass.resolved(make(), in: self) }
        guard lifted, let layer else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer.masksToBounds = false
        layer.shadowColor = BarTheme.shadow.cgColor
        layer.shadowOpacity = dark ? 0 : 0.06
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: -1)
    }
}

/// The system's accessibility settings, as the surfaces read them. Each
/// is a closure so a test can set the switch the way a person would.
enum Accessibility {
    static var reduceTransparency: () -> Bool = defaults.reduceTransparency
    static var increaseContrast: () -> Bool = defaults.increaseContrast
    static var reduceMotion: () -> Bool = defaults.reduceMotion

    /// The Mac's own settings, or under a test run all off: a test that
    /// "restored" the live value handed every later test in the process
    /// the machine's Reduce Motion, and a runner with it on turned CI red.
    private static let defaults: (reduceTransparency: () -> Bool, increaseContrast: () -> Bool,
                                  reduceMotion: () -> Bool) = TestRun.active
        ? ({ false }, { false }, { false })
        : ({ NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency },
           { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast },
           { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion })

    /// Back to the defaults, for a test that changed a setting.
    static func reset() {
        reduceTransparency = defaults.reduceTransparency
        increaseContrast = defaults.increaseContrast
        reduceMotion = defaults.reduceMotion
    }
}

/// Liquid Glass tinted toward the system's own ground, so text and glass
/// agree by construction. Text everywhere resolves from the system
/// appearance; the material would rather adapt its tone to whatever sits
/// behind it, and `tintColor` — "the color the glass effect view uses to
/// tint the background and glass effect toward" — removes that vote at
/// the source. It replaces the equalizer scrim, a veil painted over the
/// content view that sensed the material's adapted tone and corrected it
/// after the fact: the veil held the tone, not the weight.
///
/// Measured on macOS 27.0 at Liquid Glass's clearest, over both grounds
/// (tools/glass-sweep, 2026-09-14): the material alone drifted a dark bar
/// over paper to grey 147 with white text at 2.65 to 1; the scrim held it
/// at 100 and 4.79, and the pill at 124 and 3.50. Black at 0.85 fixed the
/// contrast and broke the colour — grey 6 over charcoal, where the design
/// draws 26 — so the tint aims at `BarTheme.glassTint` instead (2026-09-15).
/// Live, so a theme switch and Reduce Transparency both re-resolve on a
/// standing surface.
@available(macOS 26.0, *)
final class TonedGlass: NSGlassEffectView {
    var weight: Glass.Weight = .normal { didSet { retint() } }
    /// A veil in the ground's own colour inside the glass, at the weight's
    /// strength, opaque under Reduce Transparency. The tint sets the shade
    /// and cannot set the backdrop's share: every tint colour and alpha
    /// left the draft 25 over charcoal and about 60 over paper, and a big
    /// panel over a mixed desktop was patchy where a small bar over one
    /// thing was not. The veil takes the backdrop's vote: at 0.9 the bar,
    /// the draft and the pill read 25 over charcoal and 29, 29 and 31 over
    /// paper (2026-09-15) — 0.7 had left the draft at 37 and the pill,
    /// being small and mostly edge, a few levels lighter than a bar over
    /// the same ground, which was seen. It sits inside the glass so the
    /// rim and the shadow stay the material's.
    private let veil = NSView()
    var veilAlpha: CGFloat {
        (veil.layer?.backgroundColor).flatMap(NSColor.init(cgColor:))?.alphaComponent ?? 0
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        veil.wantsLayer = true
        veil.autoresizingMask = [.width, .height]
        contentView = veil
    }

    required init?(coder: NSCoder) { nil }

    private var themeObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        retint()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        retint()
        guard window != nil, themeObserver == nil else { return }
        // A standing surface — the pill, the strip — must hear a theme
        // switch and a Reduce Transparency flip at once, not at its next
        // opening.
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.retint() }
        }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.retint() }
    }

    deinit {
        if let themeObserver {
            DistributedNotificationCenter.default().removeObserver(themeObserver)
        }
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
    }

    /// The tint, re-read from the system's tone and the person's settings.
    /// It aims at `BarTheme.glassTint`, a grey chosen so the panel lands
    /// on its own ground; see the note there for why that grey is not the
    /// ground itself.
    func retint() {
        tintColor = BarTheme.glassTint.withAlphaComponent(weight.alpha)
        // On paper the text-dense panels stand nearly opaque: tinted glass
        // casts the desktop's colour over the page and reads muddy.
        let strength = Accessibility.reduceTransparency() ? Glass.opaque : weight.veil
        veil.layer?.cornerRadius = cornerRadius
        veil.layer?.backgroundColor = BarTheme.ground.withAlphaComponent(strength).cgColor
    }
}

/// Liquid Glass where the OS provides it (macOS 26+), vibrancy fallback
/// everywhere else. The backdrop is installed as a sibling pinned under the
/// content, so both paths behave identically.
///
/// One recipe for every panel, card, and chip. The clipboard's cards and
/// the hint chips once wore a second one — clear glass under a heavier
/// veil — and clear glass has no frost, so a card's opacity was entirely
/// the veil's. Regular glass, tinted, carries its own.
enum Glass {
    /// How far toward its ground the glass is tinted. The material is the
    /// same; this is state — a lit card, an empty slot — never a second
    /// style. Normal is the measured number; the others keep their order
    /// around it.
    enum Weight: Equatable {
        case normal, raised, faint
        var alpha: CGFloat {
            switch self {
            case .normal: return 0.92
            case .raised: return 0.96
            case .faint: return 0.82
            }
        }
        /// The veil's share of the panel: how much of the backdrop's vote
        /// is taken. Normal is the measured number; the others keep their
        /// order around it.
        var veil: CGFloat {
            switch self {
            case .normal: return 0.90
            case .raised: return 0.94
            case .faint: return 0.80
            }
        }
    }

    /// The veil when a person has asked for no transparency at all: the
    /// glass stays for its edge and its shadow, and the frost is gone.
    static let opaque: CGFloat = 0.95

    /// The weight a backdrop this made carries, for the tests.
    static func weight(in backdrop: NSView) -> Weight? {
        if #available(macOS 26.0, *), let glass = backdrop as? TonedGlass {
            return glass.weight
        }
        return nil
    }

    @discardableResult
    static func installBackdrop(in root: NSView, cornerRadius: CGFloat,
                                weight: Weight = .normal) -> NSView {
        let backdrop: NSView
        if #available(macOS 26.0, *) {
            // Regular glass, deliberately: the frost is the panel's beauty
            // AND half its contrast — clear glass let the world through
            // sharp and made everything worse.
            let glass = TonedGlass()
            glass.cornerRadius = cornerRadius
            glass.weight = weight
            backdrop = glass
        } else {
            // Before Liquid Glass: the system's own adaptive frost, and over
            // it the ground the glass above lands on, so a panel is clay by
            // day and night by night on every system Lodestar runs on. The
            // HUD material alone carried no ground of its own, so light
            // mode's ink sat on whatever tone the HUD chose.
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = cornerRadius
            effect.layer?.masksToBounds = true
            let veil = ToneView(fill: BarTheme.dynamicGround(alpha: weight.veil), radius: cornerRadius)
            veil.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(veil)
            NSLayoutConstraint.activate([
                veil.topAnchor.constraint(equalTo: effect.topAnchor),
                veil.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
                veil.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                veil.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            ])
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

    /// `takesKeys: false` is for a surface that only shows: a note, the
    /// pill, the overlays, the sheet. Its panel never becomes the key
    /// window, because a titled panel ordered in can take key status
    /// without its app coming forward, and every key typed while it stood
    /// then reached a window with nothing to take it and was answered with
    /// the alert: the launch note's two and a half seconds rang like that
    /// on every start. Lodestar's keys come through its tap, never here.
    static func makePanel(level: NSWindow.Level, takesKeys: Bool = true) -> NSPanel {
        // Titled + fullSizeContentView, exactly like the searcher's
        // KeyablePanel — and not for the shadow this time. Liquid Glass
        // senses its backdrop through the window: behind a raw borderless
        // panel it reads the wallpaper and adapts tone per panel, so the
        // ⌘K card could resolve white beside a charcoal launcher. Behind a
        // titled window it honors the window's appearance — the pinned
        // dark holds.
        let frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        let style: NSWindow.StyleMask = [.titled, .fullSizeContentView, .nonactivatingPanel]
        let panel: GlassPanel = takesKeys
            ? GlassPanel(contentRect: frame, styleMask: style, backing: .buffered, defer: true)
            : ShowingPanel(contentRect: frame, styleMask: style, backing: .buffered, defer: true)
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
/// A glass panel that only shows, and so is never the key window.
final class ShowingPanel: GlassPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

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
    /// How everything Lodestar draws moves: one curve, decelerating, so a
    /// thing arrives and settles the way an object set down does. A
    /// surface, a switch's knob and a line falling back all move alike;
    /// only the time differs, and nothing moves under Reduce Motion.
    static var motion: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1) }

    static let panelWidth: CGFloat = 640
    static let inputHeight: CGFloat = 60
    static let rowHeight: CGFloat = 48
    static let footerHeight: CGFloat = 24
    /// A bar's bottom edge when nothing stands beneath its rows. The bars
    /// carry no legend: their keys live on the sheet, behind lode ?.
    static let barFoot: CGFloat = 6
    /// The rounding, converged: one ladder from the pill's height, each
    /// rung the one above over φ². A surface (a panel, a card, the pill)
    /// rounds at the first rung, a control (a keycap, a chip, a well) at
    /// the second, a mark (a highlight on the page) at the third. A
    /// hairline rounds to its own half-width and is not on the ladder.
    static let phi: CGFloat = 1.618_033_988_75
    static let pillHeight: CGFloat = 44
    static let surfaceRadius: CGFloat = pillHeight / (phi * phi)
    static let controlRadius: CGFloat = surfaceRadius / (phi * phi)
    static let markRadius: CGFloat = controlRadius / (phi * phi)
    static let glassRadius: CGFloat = surfaceRadius
    static let rowRadius: CGFloat = surfaceRadius
    static let chipRadius: CGFloat = controlRadius
    /// One key-and-label row, shared by every surface that draws them: the
    /// chain guide, the cheat sheet, and the clipboard's actions menu. Left
    /// to themselves they drifted into three chip shapes, three keycap
    /// sizes and three icon sizes; this is the one set.
    static let chipMinWidth: CGFloat = 34
    static let chipHeight: CGFloat = 22
    static let chipPadX: CGFloat = 6
    static let rowGap: CGFloat = 9
    static let rowIcon: CGFloat = 17
    /// Clear water between the longest label and the key column, so the two
    /// never read as one run of text.
    static let rowKeyGap: CGFloat = 28

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
    /// A sentence's measure: wide enough for one thought, narrow enough
    /// to be read in a glance.
    static let voiceWidth: CGFloat = 380
    /// The dot that says "needs you" is a glyph used as a mark, not text
    /// that is read, so it may sit under the scale's floor.
    static let dotFont = NSFont.systemFont(ofSize: 8)
    /// Controls and marks on the ladder: a glass chip and a settings well
    /// are controls; a match's wash on the page is a mark. The hairline
    /// things (the draft's caret and its meter bars) round to half their
    /// width.
    static let glassChipRadius: CGFloat = controlRadius
    static let wellRadius: CGFloat = controlRadius
    static let highlightRadius: CGFloat = markRadius
    static let hairlineRadius: CGFloat = 1
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
    /// the pane of the palette in force, which the veil inside the glass
    /// lands every surface on, so the ground is a known tone rather than a
    /// query.
    static var ground: NSColor { palette.pane.color }

    /// The step a chosen thing stands on: the launcher's chosen row, a
    /// card being acted on. One step above the pane, which is the look's
    /// key step (the slab is a later contract), never a colour of its own:
    /// the lit keys say it is chosen, the step says it is lifted.
    static var raised: NSColor { palette.key.color }

    /// The open dot's distance from the name it belongs to.
    static let dotGap: CGFloat = 6

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

    /// A raised row's top edge catches the light, as every object in the
    /// pictures does: a flat line, never a gradient. By day it is the key
    /// step, the lightest thing the look draws; at night the ink, faintly.
    static var raisedRim: NSColor {
        Tone.systemDark ? palette.ink.color.withAlphaComponent(0.10)
                        : palette.key.color.withAlphaComponent(0.9)
    }

    /// The one key, resting: the look's key step, in the night a pale cap
    /// on the pane and in clay the lightest thing drawn.
    static var keyFill: NSColor { palette.key.color }
    /// In the light a key is drawn the way light keys are: a face, a
    /// hairline, a deeper side. In the night the side and the lit top do it.
    static var keyEdge: NSColor? {
        Tone.systemDark ? nil : palette.ink.color.withAlphaComponent(palette.hairlineAlpha)
    }
    /// A key laid over another app's window: the same cap, opaque, so
    /// nothing of the window beneath shows through it, and its letter in
    /// the ink, because a mark is read against someone else's content.
    static var markFill: NSColor { palette.key.color }
    static var markLetter: NSColor { palette.ink.color }
    /// A key's letter is the look's ink.
    static var keyLetter: NSColor { palette.ink.color }
    /// The key's top face catches the light; the side it stands on is the
    /// look's side step.
    static var keyTop: NSColor {
        Tone.systemDark ? palette.ink.color.withAlphaComponent(0.11)
                        : palette.key.color.withAlphaComponent(0.9)
    }
    static var keyLip: NSColor { palette.side.color }
    /// The neutral matter, two steps and no more. A well is what a field,
    /// a note box, a choice, a group's card, a chip read rather than
    /// pressed and a quiet key lie in; a hairline is an edge, a rule or a
    /// rim, the ink at the look's own share (a tenth by day, less at night
    /// where light lines read harder). Anything neutral that is not text is
    /// one of the two, and a thing under the pointer takes the next step
    /// up, the hairline's weight, rather than a weight of its own.
    static var well: NSColor { inkAt(0.05) }
    static var hairline: NSColor {
        NSColor(name: nil) { appearance in
            let look = steps(for: appearance)
            return look.ink.color.withAlphaComponent(look.hairlineAlpha)
        }
    }
    /// What a shadow is cast in: the night's ground, and by day the quiet
    /// ink, the palette's nearest step to the warm brown the day's shadows
    /// were. Opacity is the surface's; the colour is never black.
    static var shadow: NSColor { Tone.systemDark ? Palette.night.ground.color : Palette.clay.quietInk.color }
    /// A switch's knob: the lightest step the palette has, in both looks.
    static var knob: NSColor { Palette.clay.key.color }
    /// The lightest and the darkest step the palette owns, which a lit key
    /// is shaded toward: its top edge catches the key's face, its lip falls
    /// in the slab's side, the way the mark's faces are shaded.
    static var lightest: NSColor { Palette.clay.key.color }
    static var darkest: NSColor { Palette.clay.slabSide.color }
    /// A lit key is a small piece of the mark: the accent, its top edge the
    /// mark's brightest face and its lip the darkest.
    static var litKeyTop: NSColor { accent.blended(withFraction: 0.4, of: lightest) ?? accent }
    static var litKeyLip: NSColor { accent.blended(withFraction: 0.44, of: darkest) ?? accent }

    /// What the glass is tinted toward, so that it lands on `ground`: the
    /// look's pane, in the warm family, at the lightness the tint has always
    /// had (see `Palette.glassTint`). Not the ground itself: the material
    /// multiplies with its backdrop rather than blending, so a tint aimed at
    /// charcoal read grey 6 over charcoal, and black read the same.
    /// Measured 2026-09-15 with tools/glass-sweep at the normal weight:
    /// white 0.25 lands the bar at 25 over charcoal (the ground is 26);
    /// white 0.92 lands it at 237 over black (paper is 235). What lands over
    /// the *other* ground is the veil's to decide, not the tint's (see
    /// `TonedGlass.veil`). Glass material: replaced by the material
    /// contract.
    static var glassTint: NSColor {
        Palette.glassTint(of: palette, night: Tone.systemDark).color
    }

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
        // drawn shadow the gate opens the glass to the pointer and keeps
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
            panel.setGlassFrame(NSRect(origin: corner(), size: size), display: true)
            return
        }
        var frame = panel.glassFrame
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setGlassFrame(frame, display: true)
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

    /// A line written with its keys in brackets (`FlashLine`): words and
    /// key groups on one row, every key centred on the words' middle, in
    /// the footer's size and grey. A flash's way and the launcher's
    /// footer are drawn by it, so a key named in a sentence is a key.
    static func sentence(_ line: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5
        for part in FlashLine.parts(line) {
            switch part {
            case .words(let text):
                row.addArrangedSubview(word(text, color: BarTheme.secondaryColor))
            case .keys(let keys):
                let group = NSStackView(views: keys.map { cap($0) })
                group.orientation = .horizontal
                group.alignment = .centerY
                group.spacing = 3
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
        row.spacing = 4
        var previous: NSView?

        func add(_ view: NSView, spacingBefore: CGFloat? = nil) {
            if let spacingBefore, let previous { row.setCustomSpacing(spacingBefore, after: previous) }
            row.addArrangedSubview(view)
            previous = view
        }

        for (index, gesture) in gestures.enumerated() {
            if index > 0 {
                add(word("·", color: BarTheme.secondaryColor), spacingBefore: 10)
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
            add(verb, spacingBefore: 7)
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

/// A switch drawn in Lodestar's accent. macOS's own switch takes its tint
/// from the system accent and offers no way to say otherwise, so a
/// person who chose International Orange saw the settings' switches in
/// the Mac's colour. This one is the same gesture — click, space, the
/// screen reader's press — drawn by the theme. The knob slides; nothing
/// else moves.
/// A room's one-line field, drawn rather than the system's bezel: the
/// note box's material — a faint fill and a hairline, the theme's control
/// rounding — around a borderless field. The bezelled field is a system
/// control in costume, and its focus ring wears the Mac's accent.
final class RoomField: NSView {
    let field = NSTextField()

    init(placeholder: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = BarTheme.controlRadius
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.setRole(.body)
        field.textColor = BarTheme.ink
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setPlaceholder(placeholder)
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 32),
        ])
        tint()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        tint()
    }

    private func tint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Glass.resolved(BarTheme.well, in: self)
            layer?.borderColor = Glass.resolved(BarTheme.hairline, in: self)
        }
    }
}

/// A room's button, drawn rather than the system's bezel: the room field's
/// material, a word in the interface's face, brightening under the
/// pointer. The system's default button wears the Mac's accent; a room's
/// buttons wear Lodestar's material, and its primary actions are keys.
final class RoomButton: NSButton {
    /// Kept for its callers; what cannot be undone is told by its words.
    var destructive = false { didSet { restyle() } }
    /// The answer the surface exists for: lit as a key is lit, the
    /// accent's face with the mark's bright top edge and the letter in the
    /// ink that reads on it. One per surface.
    var primary = false { didSet { restyle() } }
    /// A word given as an answer (the editor's card): set in the body's
    /// face and size, on a taller key, because it is the person's text.
    var answer = false { didSet { restyle() } }
    private var hovering = false { didSet { restyle() } }
    private let light = EdgeLight()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = BarTheme.controlRadius
        layer?.borderWidth = 1
        layer?.masksToBounds = false
        if let layer { light.install(in: layer) }
        restyle()
    }

    override func layout() {
        super.layout()
        light.fit(bounds, radius: BarTheme.controlRadius, reach: BarTheme.controlRadius + 3, flipped: isFlipped)
    }

    required init?(coder: NSCoder) { nil }

    override var title: String {
        didSet { restyle() }
    }

    override var intrinsicContentSize: NSSize {
        let text = attributedTitle.size()
        return answer
            ? NSSize(width: (text.width + 22).rounded(.up), height: 30)
            : NSSize(width: (text.width + 20).rounded(.up), height: 24)
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        // A button that cannot be undone says so in its words, never in
        // an alarm colour: one light, no paint.
        let color: NSColor = primary ? BarTheme.onAccent : (isEnabled ? BarTheme.ink : BarTheme.secondaryColor)
        let words = super.title
        super.attributedTitle = NSAttributedString(
            string: words,
            attributes: BarTheme.attributes(.control, color: color, in: effectiveAppearance))
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if primary {
                let face = BarTheme.accent
                layer?.backgroundColor = (hovering ? face.blended(withFraction: 0.10, of: BarTheme.lightest) ?? face : face).cgColor
                layer?.borderColor = BarTheme.litKeyLip.cgColor
                light.color = BarTheme.litKeyTop
            } else {
                layer?.backgroundColor = Glass.resolved(hovering ? BarTheme.hairline : BarTheme.well, in: self)
                layer?.borderColor = Glass.resolved(BarTheme.hairline, in: self)
                light.color = nil
            }
        }
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
        let inset: CGFloat = 12
        dot.frame = NSRect(x: inset, y: ((bounds.height - BarTheme.dotDiameter) / 2).rounded(),
                           width: BarTheme.dotDiameter, height: BarTheme.dotDiameter)
        var x = inset + BarTheme.dotDiameter + 8
        if icon.image != nil {
            icon.frame = NSRect(x: x, y: ((bounds.height - 12) / 2).rounded(), width: 19, height: 12)
            x += 24
        }
        let natural = label.sizeThatFits(NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                height: CGFloat.greatestFiniteMagnitude)).height
        label.frame = NSRect(x: x, y: ((bounds.height - natural) / 2).rounded(),
                             width: max(0, bounds.width - x - inset), height: natural)
    }

    /// Lit by the menu's own highlight, which follows the pointer and the
    /// arrow keys alike.
    override func draw(_ dirtyRect: NSRect) {
        guard enclosingMenuItem?.isHighlighted == true, enclosingMenuItem?.isEnabled == true else { return }
        BarTheme.raised.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: BarTheme.controlRadius,
                     yRadius: BarTheme.controlRadius).fill()
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

final class AccentSwitch: NSControl {
    private let track = CALayer()
    private let knob = CALayer()
    static let size = NSSize(width: 30, height: 17)

    var state: NSControl.StateValue = .off {
        didSet { paint() }
    }
    /// How long the knob takes to cross, when motion is welcome.
    static let slide: TimeInterval = 0.18

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(origin: frameRect.origin, size: Self.size))
        wantsLayer = true
        layer?.masksToBounds = false
        track.cornerRadius = Self.size.height / 2
        knob.cornerRadius = (Self.size.height - 4) / 2
        knob.backgroundColor = BarTheme.knob.cgColor
        knob.shadowColor = BarTheme.shadow.withAlphaComponent(0.35).cgColor
        knob.shadowOpacity = 1
        knob.shadowRadius = 1.5
        knob.shadowOffset = CGSize(width: 0, height: -0.5)
        layer?.addSublayer(track)
        layer?.addSublayer(knob)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        paint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

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
        let tint = Glass.resolved(on ? BarTheme.accent : BarTheme.inkAt(0.22), in: self)
        let knobSize = Self.size.height - 4
        let knobFrame = NSRect(x: on ? bounds.width - knobSize - 2 : 2, y: 2, width: knobSize, height: knobSize)
        let fromPosition = knob.presentation()?.position ?? knob.position
        let fromTint = track.presentation()?.backgroundColor ?? track.backgroundColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
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
/// the glass is one family with the pill and nothing is retyped at
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

/// The one key Lodestar draws: a small object whose top face catches the
/// light and whose front lip falls in shadow. Lit, it is a piece of the
/// mark: the accent, with the mark's brightest face for its top edge and
/// its darkest for its lip, and the letter in whichever ink reads on it.
/// Resting, it is a quiet cap; in clay, the pictures' dark keycap.
final class KeyFace: NSView {
    let label = NSTextField(labelWithString: "")
    var lit = false { didSet { if lit != oldValue { refresh() } } }
    /// A key you could press but are not being asked to: the address the
    /// coach offers for later, a cheat sheet's unused gesture, an action
    /// not available yet. It lies flat. The light falls on raised things,
    /// so a key that is not raised loses its lit top edge and its lip and
    /// sits in a shallow well; resting keys stand, the lit key glows.
    /// Depth carries the importance, never a fade: a translucent key is
    /// not a thing a light falls on, and on clay it all but vanished.
    var quiet = false { didSet { if quiet != oldValue { refresh() } } }
    /// What a pointer is doing to a key that can be clicked: it brightens
    /// under the pointer and sinks onto its lip when pressed.
    private var pointer = Keycaps.CapState.resting
    private let top = EdgeLight()

    /// `padX` widens a key whose label is a word on a long cap, the walk's
    /// space bar; every other key takes the theme's.
    init(_ text: String, padX: CGFloat = BarTheme.chipPadX) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = BarTheme.chipRadius
        layer?.masksToBounds = false
        layer?.shadowOffset = CGSize(width: 0, height: -1.5)
        layer?.shadowRadius = 0
        layer?.shadowOpacity = 1
        if let layer { top.install(in: layer) }
        label.stringValue = text
        label.setRole(.key)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padX),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padX),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: BarTheme.chipHeight),
            widthAnchor.constraint(greaterThanOrEqualToConstant: BarTheme.chipMinWidth),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        top.fit(bounds, radius: BarTheme.chipRadius, reach: BarTheme.chipRadius + 3)
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let resting = lit ? BarTheme.accent : BarTheme.keyFill
        // Under the pointer the face catches a little more light; pressed,
        // it sinks onto its lip, which is the lip's whole height gone.
        // In the night, and lit, the face catches light (the ink, the
        // lightest step); in the light a key's face is already the lightest
        // step, so it can only darken, toward its side.
        let toward: NSColor = Tone.systemDark || lit ? (lit ? BarTheme.lightest : BarTheme.ink) : BarTheme.keyLip
        let face = pointer == .resting ? resting
            : resting.blended(withFraction: pointer == .pressed ? 0.06 : (Tone.systemDark || lit ? 0.12 : 0.05), of: toward) ?? resting
        if quiet, !lit {
            layer?.backgroundColor = Glass.resolved(BarTheme.well, in: self)
            layer?.borderWidth = 0
            layer?.borderColor = nil
            layer?.shadowOpacity = 0
            top.color = nil
            label.textColor = BarTheme.secondaryColor
            CATransaction.commit()
            return
        }
        layer?.shadowOpacity = 1
        layer?.backgroundColor = Glass.resolved(face, in: self)
        let edge = lit ? nil : BarTheme.keyEdge
        layer?.borderWidth = edge == nil ? 0 : 0.5
        layer?.borderColor = edge.map { Glass.resolved($0, in: self) }
        layer?.shadowOffset = CGSize(width: 0, height: pointer == .pressed ? -0.5 : -1.5)
        layer?.shadowColor = Glass.resolved(lit ? BarTheme.litKeyLip : BarTheme.keyLip, in: self)
        top.color = lit ? BarTheme.litKeyTop : BarTheme.keyTop
        label.textColor = lit ? BarTheme.onAccent : BarTheme.keyLetter
        CATransaction.commit()
    }
}

/// A row that rises when it is chosen: the raised step, its top edge
/// catching the light, and its keys lit by whoever subclasses it. The
/// bars' rows share it, so the launcher, Ask and the commands bar choose
/// a row the same way.
class RaisedRow: NSView {
    private let light = EdgeLight()
    private(set) var raised = false

    func setupRaised() {
        wantsLayer = true
        layer?.cornerRadius = BarTheme.rowRadius
        layer?.masksToBounds = false
        if let layer { light.install(in: layer) }
        // A soft, short shadow cast by the row's own rounded shape: no line
        // under it, nothing that stops where the corners begin.
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.shadowRadius = 3
        applyRaised(false)
    }

    override func layout() {
        super.layout()
        light.fit(bounds, radius: BarTheme.rowRadius, reach: BarTheme.rowRadius + 4)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: BarTheme.rowRadius,
                                   cornerHeight: BarTheme.rowRadius, transform: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyRaised(raised)
    }

    func applyRaised(_ on: Bool) {
        raised = on
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = on ? BarTheme.raised.cgColor : nil
        light.color = on ? BarTheme.raisedRim : nil
        layer?.shadowColor = BarTheme.shadow.cgColor
        layer?.shadowOpacity = on ? (Tone.systemDark ? 0.32 : 0.10) : 0
        CATransaction.commit()
    }
}

/// Light catching the top of a rounded object: a hairline along the
/// shape's own outline, brightest across the top, following the curve
/// into each corner and fading as the edge turns down, so it never starts
/// or stops abruptly. The chosen row and every key wear it.
final class EdgeLight {
    private let holder = CALayer()
    private let stroke = CAShapeLayer()
    private let fade = CAGradientLayer()

    init() {
        stroke.fillColor = nil
        stroke.lineWidth = 1
        holder.addSublayer(stroke)
        // A mask: only its alpha is read, so the colour is any step.
        let solid = BarTheme.lightest
        fade.colors = [solid.cgColor, solid.cgColor, solid.withAlphaComponent(0).cgColor]
        fade.locations = [0, 0.3, 1]
        holder.mask = fade
    }

    func install(in layer: CALayer) {
        holder.zPosition = 50
        layer.addSublayer(holder)
    }

    var color: NSColor? {
        didSet { stroke.strokeColor = color?.cgColor }
    }

    /// Lay the light on a shape of `radius` filling `bounds`, fading out
    /// `reach` points below the top edge. `flipped` for a view whose layer
    /// counts from the top, as a button's does.
    func fit(_ bounds: CGRect, radius: CGFloat, reach: CGFloat, flipped: Bool = false) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        holder.frame = bounds
        stroke.frame = holder.bounds
        fade.frame = holder.bounds
        let r = max(0, radius - 0.5)
        stroke.path = CGPath(roundedRect: holder.bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: r,
                             cornerHeight: r, transform: nil)
        // In an unflipped layer y = 1 is the top edge; in a flipped one, 0.
        let height = max(1, bounds.height)
        fade.startPoint = CGPoint(x: 0.5, y: flipped ? 0 : 1)
        fade.endPoint = CGPoint(x: 0.5, y: flipped ? min(1, reach / height) : max(0, 1 - reach / height))
        CATransaction.commit()
    }
}


/// A surface's own shadow, the way the clay objects in the pictures sit on
/// nothing: one long, soft, warm shadow beneath, a hairline contact shadow
/// under the edge, and a hairline edge in place of the window server's
/// outline. The system's window shadow cannot be shaped, so the panel
/// grows by `margin` on every side, the surface sits inset inside it, and
/// the host draws the shadow in that margin. Clicks in the margin land on
/// nothing.
enum SoftShadow {
    static let margin: CGFloat = 64

    /// The window's frame for a surface that should stand at `visible`.
    static func outset(_ visible: NSRect) -> NSRect { visible.insetBy(dx: -margin, dy: -margin) }
    /// The surface's frame inside a window hosted this way.
    static func inset(_ window: NSRect) -> NSRect { window.insetBy(dx: margin, dy: margin) }

    /// Host `content` as the panel's surface, with the shadow drawn here,
    /// and gate the pointer so only the glass takes it: the margin is
    /// window, and a click there belongs to whatever is beneath. Every
    /// hosted surface is gated by construction; the gate is returned for a
    /// surface that changes size under a still pointer and must re-read it.
    ///
    /// `takesPointer: false` is for a surface that only shows (a key
    /// guide, the ⌘K card): it never takes the mouse, glass or shadow.
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
    static func object(radius: CGFloat, lift: ObjectSurface.Lift) -> ObjectSurface {
        ObjectSurface(radius: radius, lift: lift)
    }
}

/// The drawn shadow, cast by one object rather than by a window: the long
/// soft shadow beneath, the hairline contact shadow under the edge, and
/// the hairline edge itself, in the same warm colours as a hosted
/// surface's. A floating object is lifted further than a resting one, so
/// what is passing stands over what is kept and what is older.
final class ObjectSurface: NSView {
    enum Lift { case float, rest }

    let radius: CGFloat
    var lift: Lift { didSet { if lift != oldValue { restyle(); place() } } }
    private let soft = CALayer()
    private let contact = CALayer()
    private let edge = CALayer()

    init(radius: CGFloat, lift: Lift) {
        self.radius = radius
        self.lift = lift
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        for shadow in [contact, soft] {
            shadow.shadowOffset = .zero
            shadow.shadowOpacity = 1
            layer?.insertSublayer(shadow, at: 0)
        }
        edge.borderWidth = 0.5
        edge.cornerRadius = radius
        edge.zPosition = 100
        layer?.addSublayer(edge)
        restyle()
    }

    required init?(coder: NSCoder) { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
    }

    private func place() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edge.frame = bounds
        let floating = lift == .float
        let softShape = bounds.insetBy(dx: floating ? 8 : 4, dy: floating ? 8 : 4)
            .offsetBy(dx: 0, dy: floating ? -12 : -4)
        if softShape.width > 0, softShape.height > 0 {
            soft.shadowPath = CGPath(roundedRect: softShape, cornerWidth: radius, cornerHeight: radius,
                                     transform: nil)
        }
        contact.shadowPath = CGPath(roundedRect: bounds.offsetBy(dx: 0, dy: -1), cornerWidth: radius,
                                    cornerHeight: radius, transform: nil)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        let dark = Tone.systemDark
        let floating = lift == .float
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        soft.shadowColor = BarTheme.shadow.cgColor
        soft.shadowOpacity = floating ? (dark ? 0.58 : 0.26) : (dark ? 0.42 : 0.16)
        soft.shadowRadius = floating ? 18 : 7
        contact.shadowColor = soft.shadowColor
        contact.shadowOpacity = dark ? 0.35 : 0.14
        contact.shadowRadius = 1
        edge.borderColor = Glass.resolved(BarTheme.hairline, in: self)
        CATransaction.commit()
    }
}

extension NSWindow {
    /// The glass's frame: the window's, less the drawn shadow's margin
    /// when the window hosts one. Surfaces place and read their glass by
    /// this, so moving onto the drawn shadow changes no arithmetic.
    var glassFrame: NSRect {
        contentView is ShadowHostView ? SoftShadow.inset(frame) : frame
    }

    func setGlassFrame(_ glass: NSRect, display: Bool) {
        setFrame(contentView is ShadowHostView ? SoftShadow.outset(glass) : glass, display: display)
    }
}

/// A soft-shadowed window is larger than its surface by the shadow's
/// margin, and a window that takes the mouse takes it everywhere it
/// stands, shadow included: a band of air around the glass that eats
/// clicks meant for the app beneath, the Dock's top edge among them. The
/// system's own shadow was never a target. A surface that stays open over
/// someone else's work therefore takes the mouse only while the pointer
/// is over its glass, and lets it through everywhere else.
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

    /// Read the pointer against the glass. Called on every move and
    /// whenever the glass changes size under a still pointer.
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
    private let soft = CALayer()
    private let contact = CALayer()
    private let edge = CALayer()

    init(content: NSView, cornerRadius: CGFloat) {
        self.content = content
        self.radius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        for shadow in [soft, contact] {
            shadow.shadowOffset = .zero
            shadow.shadowOpacity = 1
            layer?.addSublayer(shadow)
        }
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = []
        addSubview(content)
        content.wantsLayer = true
        content.layer?.addSublayer(edge)
        edge.borderWidth = 0.5
        edge.cornerRadius = cornerRadius
        edge.zPosition = 100
        restyle()
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
        edge.frame = content.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The soft shadow is cast by a slightly smaller shape held lower,
        // so it falls beneath the surface rather than around it.
        let softShape = surface.insetBy(dx: 16, dy: 16).offsetBy(dx: 0, dy: -26)
        soft.shadowPath = CGPath(roundedRect: softShape, cornerWidth: radius, cornerHeight: radius, transform: nil)
        contact.shadowPath = CGPath(roundedRect: surface.offsetBy(dx: 0, dy: -1), cornerWidth: radius,
                                    cornerHeight: radius, transform: nil)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        let dark = Tone.systemDark
        soft.shadowColor = BarTheme.shadow.cgColor
        soft.shadowOpacity = dark ? 0.62 : 0.30
        soft.shadowRadius = 30
        contact.shadowColor = soft.shadowColor
        contact.shadowOpacity = dark ? 0.35 : 0.14
        contact.shadowRadius = 1
        edge.borderColor = Glass.resolved(BarTheme.hairline, in: self)
    }

    /// Only the surface takes the pointer; the shadow is not a target.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard content.frame.contains(local) else { return nil }
        return super.hitTest(point)
    }
}

/// Marks laid over another app's window, drawn as the one key: the dark cap
/// with its lit top edge and its lip, standing on a short warm shadow so it
/// reads over any app, light or dark. A mark the hand has begun typing
/// stays the resting key and keeps its width: the letters already typed
/// dim in its label, and the ones still to press keep the mark's ink.
/// Built by hand, without layout, because a window of click hints can be
/// four hundred of them at once.
enum KeyMark {
    static let height: CGFloat = BarTheme.chipHeight
    /// The peek's numerals: the same key at a size read across the screen.
    static let peekHeight: CGFloat = 48
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
    /// hand has typed of the label so far; those letters dim.
    static func key(_ text: String, typed: String = "", peek: Bool = false) -> NSView {
        let height = peek ? peekHeight : height
        let radius = peek ? BarTheme.chipRadius * BarTheme.phi : BarTheme.chipRadius
        let label = NSTextField(labelWithAttributedString:
            letters(text, typed: typed, role: peek ? .largeFigure : .key))
        label.followLook()
        label.alignment = .center
        label.sizeToFit()
        let width = max(height, ceil(label.frame.width) + BarTheme.chipPadX * 2)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.wantsLayer = true
        guard let layer = view.layer else { return view }
        layer.masksToBounds = false
        layer.cornerRadius = radius
        layer.backgroundColor = BarTheme.markFill.cgColor
        // The lip: the key's own shadow, straight down and unblurred.
        layer.shadowColor = BarTheme.keyLip.cgColor
        layer.shadowOpacity = 1
        layer.shadowRadius = 0
        layer.shadowOffset = CGSize(width: 0, height: peek ? -3 : -1.5)
        layer.shadowPath = CGPath(roundedRect: view.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        // The top edge catching the light.
        let top = CALayer()
        top.frame = CGRect(x: radius * 0.8, y: height - 1, width: max(0, width - radius * 1.6), height: 1)
        top.backgroundColor = BarTheme.keyTop.cgColor
        top.cornerRadius = 0.5
        layer.addSublayer(top)
        label.frame = NSRect(x: 0, y: ((height - label.frame.height) / 2).rounded(), width: width,
                             height: label.frame.height)
        view.addSubview(label)
        return standing(view, radius: radius)
    }

    /// The editor lens's tag: the key and the fix in words, on a small
    /// surface of the palette in force, just above the word it fixes.
    static func tag(letter: String, word: String, typed: String = "") -> NSView {
        let pad: CGFloat = 3
        let radius = BarTheme.chipRadius + pad
        let key = KeyMark.key(letter, typed: typed)
        let label = NSTextField(labelWithString: word)
        label.setRole(.meta)
        label.textColor = BarTheme.ink
        label.sizeToFit()
        let height = key.frame.height + pad * 2
        let width = ceil(pad + key.frame.width + 6 + label.frame.width + 8)
        let tag = ToneView(fill: BarTheme.dynamicGround(), edge: BarTheme.hairline,
                           edgeWidth: 0.5, radius: radius)
        tag.frame = NSRect(x: 0, y: 0, width: width, height: height)
        key.frame.origin = NSPoint(x: pad, y: pad)
        tag.addSubview(key)
        label.frame.origin = NSPoint(x: key.frame.maxX + 6, y: ((height - label.frame.height) / 2).rounded())
        tag.addSubview(label)
        return standing(tag, radius: radius)
    }

    /// A short warm shadow under a mark, so it stands off whatever window
    /// it lies on. The mark keeps its own layer's shadow for its lip.
    private static func standing(_ content: NSView, radius: CGFloat) -> NSView {
        let holder = NSView(frame: content.frame)
        holder.wantsLayer = true
        guard let layer = holder.layer else { return content }
        layer.masksToBounds = false
        layer.shadowColor = BarTheme.shadow.withAlphaComponent(Tone.systemDark ? 0.3 : 0.2).cgColor
        layer.shadowOpacity = 1
        layer.shadowRadius = 7
        layer.shadowOffset = CGSize(width: 0, height: -4)
        layer.shadowPath = CGPath(roundedRect: holder.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        content.frame.origin = .zero
        holder.addSubview(content)
        return holder
    }

    /// An underline in the accent along the foot of `rect` (AppKit
    /// coordinates in the view it is added to).
    static func underline(under rect: NSRect, weight: CGFloat) -> NSView {
        let line = NSView(frame: NSRect(x: rect.minX + 1, y: rect.minY - weight + 1,
                                        width: max(2, rect.width - 2), height: weight))
        line.wantsLayer = true
        line.layer?.backgroundColor = BarTheme.accent.cgColor
        line.layer?.cornerRadius = weight / 2
        return line
    }
}
