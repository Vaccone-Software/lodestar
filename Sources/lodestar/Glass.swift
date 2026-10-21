import AppKit
import LodestarCore

/// The app's tone: the system's choice, and nothing else. The material
/// has no vote: a pane is opaque ceramic in the palette's own colours, so
/// the launcher and its ⌘K card cannot resolve to opposite tones a foot
/// apart, as the glass they once were did.
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
        var resolved = CGColor(gray: 0, alpha: 0)
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
        layer.shadowColor = CGColor(srgbRed: 0.35, green: 0.23, blue: 0.13, alpha: 1)
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

extension ToneView {
    /// A fact set in a small frame: a chip that is read and not pressed (a
    /// profile, a source). It is not a place and not a thing you press, so it
    /// is flat on whatever it lies on, the pane or the slab, with a hairline
    /// for its edge and no fill.
    static func flatChip() -> ToneView {
        ToneView(edge: BarTheme.hairline, edgeWidth: 0.5, radius: BarTheme.chipRadius)
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
        layer.shadowColor = CGColor(gray: 0, alpha: 1)
        layer.shadowOpacity = dark ? 0 : 0.06
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: -1)
    }
}

/// The system's accessibility settings, as the surfaces read them. Each
/// is a closure so a test can set the switch the way a person would.
/// Reduce Transparency is not read: no surface is transparent.
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

/// Matte ceramic: the one material every panel, card and chip is made of.
/// An opaque pane in the palette's own colour, with the surface's rounding,
/// a polished rim catching the one light along its top edge, and a
/// half-point hairline for its edge. No blur, no frost, no material and no
/// veil, on every system: glass contradicted honest matter, and its tone
/// drifted with whatever lay behind it, which is how a dark bar over paper
/// once measured 2.65 to 1 (tools/glass-sweep, 2026-09-14). Opaque, the
/// ground is a known colour rather than a reading, so the contrast floors
/// are held by the palette and not measured on the desktop.
///
/// The fill is resolved in the view's own appearance, the way `ToneView`
/// does, and repainted whenever the look changes, so a standing surface (the
/// pill, the strip) is clay by day and espresso by night without being
/// told.
final class CeramicPane: NSView {
    var weight: Glass.Weight { didSet { if weight != oldValue { repaint() } } }
    let radius: CGFloat
    /// The pane's edge, drawn above everything the surface holds: its
    /// hairline and the polished rim along its top. Content that fills a
    /// pane edge to edge (a picture, a tile) would cover an edge drawn in
    /// the pane's own layer, which stands under the content.
    let edge: PaneEdge
    /// The pane's own edge, unless the object it stands in draws one.
    var drawsEdge = true { didSet { if drawsEdge != oldValue { repaint() } } }

    static let rimHeight: CGFloat = PaneEdge.rimHeight
    static let edgeWidth: CGFloat = PaneEdge.edgeWidth

    init(radius: CGFloat, weight: Glass.Weight = .normal) {
        self.radius = radius
        self.weight = weight
        edge = PaneEdge(radius: radius)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = radius
        paint()
    }

    required init?(coder: NSCoder) { nil }

    // Painted in the layer pass, which AppKit runs with the view's own
    // appearance in force whenever the view is marked for display, and
    // marked whenever the look changes.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() { paint() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        repaint()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        edge.removeFromSuperview()
        guard let superview else { return }
        // Above whatever is there now, and by its depth above whatever is
        // added later, which a sibling's order alone would not hold.
        edge.translatesAutoresizingMaskIntoConstraints = false
        superview.addSubview(edge, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            edge.topAnchor.constraint(equalTo: topAnchor),
            edge.bottomAnchor.constraint(equalTo: bottomAnchor),
            edge.leadingAnchor.constraint(equalTo: leadingAnchor),
            edge.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        paint()
    }

    override func layout() {
        super.layout()
        place()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
    }

    private func place() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // A surface shorter than twice its rounding is a stadium.
        layer?.cornerRadius = min(radius, min(bounds.width, bounds.height) / 2)
        CATransaction.commit()
    }

    private func repaint() {
        paint()
        needsDisplay = true
    }

    private func paint() {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = Glass.resolved(weight.fill, in: self)
        CATransaction.commit()
        edge.paint(border: drawsEdge, rim: weight != .faint, in: self)
    }
}

/// The edge of a ceramic pane: a half-point hairline and the polished rim
/// catching the one light along the top, clipped to the pane's own corners
/// so it thins into the curve where the pane turns away from the light. It
/// is a view of its own, standing above the surface's content, and takes no
/// pointer.
final class PaneEdge: NSView {
    private let rim = CALayer()
    private let radius: CGFloat

    static let rimHeight: CGFloat = 1.5
    static let edgeWidth: CGFloat = 0.5

    init(radius: CGFloat) {
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = radius
        layer?.zPosition = 1000
        layer?.addSublayer(rim)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        place()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
    }

    /// The rim is a layer, the hairline the view's own border; what each is
    /// coloured is read in the pane's look, the look this edge stands in.
    var rimColor: CGColor? { rim.backgroundColor }
    var hairlineWidth: CGFloat { layer?.borderWidth ?? 0 }
    var hairlineColor: CGColor? { layer?.borderColor }
    var rimFrame: CGRect { rim.frame }

    private func place() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rim.frame = CGRect(x: 0, y: max(0, bounds.height - Self.rimHeight), width: bounds.width,
                           height: Self.rimHeight)
        layer?.cornerRadius = min(radius, min(bounds.width, bounds.height) / 2)
        CATransaction.commit()
    }

    func paint(border: Bool, rim shows: Bool, in pane: NSView) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.borderWidth = border ? Self.edgeWidth : 0
        layer?.borderColor = border ? Glass.resolved(BarTheme.hairline, in: pane) : nil
        // A place sunk in the surface catches no light on its rim.
        rim.backgroundColor = shows ? Glass.resolved(BarTheme.polishedRim, in: pane) : nil
        CATransaction.commit()
    }
}

/// Every panel, card and chip is one ceramic pane, installed as a sibling
/// pinned under the content, so the content and the material stay apart.
///
/// One recipe for every panel, card, and chip: the clipboard's cards and
/// the hint chips once wore a second glass under a heavier veil, and a
/// second recipe is how one material becomes several near-misses.
enum Glass {
    /// Which step of the palette the pane is. The material is the same;
    /// this is state — a lit card, an empty slot — never a second style.
    /// Normal is the pane, raised the step a key's face stands on, faint
    /// the ground a slot is sunk into, slab the other look's ground a chosen
    /// card is made of (it wears that look, so the colour is read as the
    /// other of its own).
    enum Weight: Equatable {
        case normal, raised, faint, slab

        /// The step's colour, a dynamic one that knows both looks.
        var fill: NSColor {
            switch self {
            case .normal: return BarTheme.dynamicStep(\.pane)
            case .raised: return BarTheme.dynamicStep(\.raised)
            case .faint: return BarTheme.dynamicStep(\.ground)
            case .slab: return BarTheme.slabFill
            }
        }
    }

    /// The weight a backdrop this made carries, for the tests.
    static func weight(in backdrop: NSView) -> Weight? {
        (backdrop as? CeramicPane)?.weight
    }

    @discardableResult
    static func installBackdrop(in root: NSView, cornerRadius: CGFloat,
                                weight: Weight = .normal) -> NSView {
        let pane = CeramicPane(radius: cornerRadius, weight: weight)
        // A card standing as an object already draws an edge of its own on
        // top of everything; two hairlines on one edge are a heavier line.
        if root is ObjectSurface { pane.drawsEdge = false }
        pane.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(pane, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            pane.topAnchor.constraint(equalTo: root.topAnchor),
            pane.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            pane.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        return pane
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
        // KeyablePanel: a titled panel keeps the key-window behaviour the
        // bars were built on, and a window honours its own appearance, so
        // every pane in it resolves in the one look.
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

/// A ceramic panel that only shows, and so is never the key window.
final class ShowingPanel: GlassPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A panel whose shadow, when it has the window server's, survives
/// reframing: the server derives a shadow from the window's opaque content
/// at order-in and does not ask again after a reframe, so it is derived
/// again after every reframe and every ordering.
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
    /// A row's height: a face of 48 and the slab's side beneath it, which
    /// the row holds whether or not it is chosen.
    static let rowHeight: CGFloat = 48 + RaisedRow.sideHeight
    static let footerHeight: CGFloat = 24
    /// A bar's bottom edge when nothing stands beneath its rows. The bars
    /// carry no legend: their keys live on the sheet, behind lode ?.
    static let barFoot: CGFloat = 6
    /// The rounding, converged: one ladder, each rung the one above over
    /// φ², from a surface at 22 to a control at 8.4 and a mark at 3.2. A
    /// surface (a panel, a card, the pill) rounds at the first rung, a
    /// control (a keycap, a chip, a well) at the second, a mark (a
    /// highlight on the page) at the third. The ladder starts from the
    /// surface and is no longer derived from the pill's height: the pill
    /// is a surface, and at 44 it is a stadium, which its rung happens to
    /// make. A hairline rounds to its own half-width and is not on the
    /// ladder.
    static let phi: CGFloat = 1.618_033_988_75
    static let pillHeight: CGFloat = 44
    static let surfaceRadius: CGFloat = 22
    static let controlRadius: CGFloat = surfaceRadius / (phi * phi)
    static let markRadius: CGFloat = controlRadius / (phi * phi)
    static let glassRadius: CGFloat = surfaceRadius

    /// A rounded thing inside another is concentric with it: it rounds at
    /// the outer radius less its inset, so the gap between the two curves
    /// stays one width all the way round, and never below its own rung, so
    /// a thing far from the edge is not squared off.
    static func nested(outer: CGFloat, inset: CGFloat, rung: CGFloat) -> CGFloat {
        max(outer - inset, rung)
    }

    /// How far a row stands from its bar's edge, left and right: the
    /// bars' rows are ten points in, so they round at twelve.
    static let rowInset: CGFloat = 10
    static let rowRadius: CGFloat = nested(outer: surfaceRadius, inset: rowInset, rung: controlRadius)
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

    /// The well a bar's field sinks into: the field is the one place in the
    /// bar something is put, so it is a receptacle (`BarTheme.well`, a
    /// hairline for its edge) and not a band of the pane. Installed under
    /// the field and its symbol, concentric with the pane the way a row is.
    @discardableResult
    static func installFieldWell(in root: NSView, bandHeight: CGFloat) -> ToneView {
        let well = ToneView(fill: BarTheme.well, edge: BarTheme.hairline, edgeWidth: 0.5, radius: rowRadius)
        well.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(well)
        NSLayoutConstraint.activate([
            well.topAnchor.constraint(equalTo: root.topAnchor, constant: fieldWellMargin),
            well.heightAnchor.constraint(equalToConstant: bandHeight - fieldWellMargin * 2),
            well.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: rowInset),
            well.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -rowInset),
        ])
        return well
    }
    static let fieldWellMargin: CGFloat = 8

    /// The type scale: three sizes for every word Lodestar draws, and one
    /// for the launcher's field. Nine sizes chosen one at a time, from 10
    /// to 23, had drifted in over a year, and the smallest sat below the
    /// floor a hand that lives at a screen should be asked to read. Meta
    /// is the caption, the key, the footer; body is what a row, a card,
    /// or the draft says — the size the eye rests on, which is the size a
    /// terminal is set to; title is a bar's name. The same scale on the
    /// settings window and the walk, since an eye is one eye.
    enum Scale {
        static let meta: CGFloat = 13
        static let body: CGFloat = 16
        static let title: CGFloat = 18
        static let input: CGFloat = 23
    }

    /// One family: the system's sans, for every word Lodestar draws and
    /// every word the person types into it. Lodestar no longer speaks in a
    /// serif, and a label, a fact and a field are never in a face of their
    /// own. The one other face is the hand's mono, which is only for the
    /// draft and the editor's lens, where Vim-style motions edit text a
    /// character at a time and the columns have to line up.
    static func handFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// The weight a face is set in: the weight asked for by day, and one
    /// step heavier at night, because light type on a dark ground blooms
    /// and thins to the eye at the weight that sits right on a light one.
    /// Only the weights the theme picks centrally go through here; a face
    /// built from the system directly keeps the one it was given.
    static func weight(_ day: NSFont.Weight, dark: Bool) -> NSFont.Weight {
        guard dark else { return day }
        let steps: [NSFont.Weight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]
        guard let index = steps.firstIndex(of: day), index + 1 < steps.count else { return day }
        return steps[index + 1]
    }

    /// The interface's face at a size and a day weight, in the look in
    /// force when it is asked for. The system's sans, whose own figures are
    /// the ones every number on the screen uses.
    static func face(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: Self.weight(weight, dark: Tone.systemDark))
    }

    static var inputFont: NSFont { face(Scale.input) }
    /// A placeholder is the interface asking, not the hand answering, so
    /// it wears the quiet tone at the field's size.
    static func placeholder(_ text: String, like font: NSFont?) -> NSAttributedString {
        let size = font?.pointSize ?? Scale.body
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .regular),
            .foregroundColor: secondaryColor,
        ])
    }
    static let inputSymbol = NSImage.SymbolConfiguration(pointSize: 19, weight: .medium)
    /// The one configuration a symbol beside text wears, and its larger
    /// cousin for the strip's own controls. Weight matched to the text.
    static let symbol = NSImage.SymbolConfiguration(pointSize: Scale.meta, weight: .medium)
    static let symbolBand = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
    /// What the person has typed or aimed, echoed in the pill: the same
    /// sans, a point above the body and medium, so it stands apart from the
    /// wings.
    static var typedFont: NSFont { NSFont.systemFont(ofSize: 17, weight: .medium) }
    /// Lodestar's voice: the sentences it says when it asks, teaches or
    /// reflects, and the note on a clip it has read, at the title size, the
    /// size Settings speaks in. It was set in New York until 20 October
    /// 2026; it is the interface's own sans now, and that it is Lodestar
    /// speaking is said by its place and its size, not by a second family.
    static var voiceFont: NSFont { face(Scale.title) }
    /// Lodestar's voice at the title size: a place's sentence in Settings,
    /// under its name.
    static var settingsSentenceFont: NSFont { face(Scale.title) }
    /// The mark at the centre of the settings overview.
    static let settingsMarkSize: CGFloat = 132
    /// The dot that says "yours" beside a value, and "needs you" beside a
    /// place's name: a mark on the page, round.
    static let dotDiameter: CGFloat = 7
    static let dotRadius: CGFloat = dotDiameter / 2
    /// A sentence's measure: wide enough for one thought, narrow enough
    /// to be read in a glance.
    static let voiceWidth: CGFloat = 380
    /// The strip's search field, the index badge, and the searcher's dot:
    /// sizes with one home each, so the drift guard can hold the line.
    static var stripInputFont: NSFont { face(19) }
    /// The meeting's stub, on the scale like everything read: its count at
    /// the title's size in digits that hold their width while they change,
    /// a word ("Now") at the body's, and the unit in small caps at meta.
    static let stubCountFont = NSFont.monospacedDigitSystemFont(ofSize: Scale.title, weight: .semibold)
    static let stubWordFont = NSFont.systemFont(ofSize: Scale.body, weight: .semibold)
    static let stubUnitFont = NSFont.systemFont(ofSize: Scale.meta, weight: .semibold)
    /// The meeting's name on its stub, in the voice at the body's size,
    /// and the line beneath it.
    static var stubTitleFont: NSFont { face(Scale.body) }
    /// Nothing read is set under the meta size: the coach's record and its
    /// way out, the stub's line, were 11.5 point in grey.
    static let stubDetailFont = NSFont.systemFont(ofSize: Scale.meta)
    /// The coach's sentence over its row: the voice at the body's size, so
    /// the card stays a line of type and a row.
    static var coachVoiceFont: NSFont { face(Scale.body) }
    static let dotFont = NSFont.systemFont(ofSize: 8)
    /// Controls and marks on the ladder: a chip and a settings well
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
    static var titleFont: NSFont { face(Scale.title) }
    /// A room's name at its head: the title size, set firm. Every room
    /// (Feedback, Uninstall, the calendar's question) wears this one.
    static var roomTitleFont: NSFont { face(Scale.title, .semibold) }
    /// The one look for secondary text — captions, legends, notes: meta
    /// size, regular weight, the secondary label colour. Weight is not a
    /// second style; a caption that needs emphasis is a caption too long.
    static let secondaryFont = NSFont.systemFont(ofSize: Scale.meta, weight: .regular)
    /// The one file a card shows is named in the caption's size, set firm:
    /// it is the card's subject, where the lines beside a stack of files
    /// are only a list.
    static let fileNameFont = NSFont.systemFont(ofSize: Scale.meta, weight: .medium)
    /// The ink: tinted, never pure black or pure white (the brightness
    /// ceiling), resolved in the look of the view that draws it. Text that
    /// takes this and not the system's label colour is the same ink in a
    /// selected row, whose own look is the other one's.
    static let ink = NSColor(name: "LodestarInk") { appearance in
        steps(for: appearance).ink.color
    }

    /// The one colour for secondary text — and the ink itself when a person
    /// has asked the system for more contrast. The palette's own quiet ink,
    /// measured against its pane and its keys' faces (4.5 to 1 and more) in
    /// both looks, where the system's secondary grey measured 3.9 to 1
    /// against clay.
    ///
    /// Resolved when it is drawn, not when it is handed out: a caption
    /// built in light mode and kept (an attributed title, a chip made once)
    /// otherwise stays clay's grey on a dark pane after the Mac turns dark
    /// at sunset.
    static let secondaryColor = NSColor(name: "LodestarSecondary") { appearance in
        let look = steps(for: appearance)
        return (Accessibility.increaseContrast() ? look.ink : look.secondary).color
    }

    /// A label, in the palette's ink unless told otherwise: the system's
    /// label colour is pure black and pure white, and the ink is never
    /// either. Every word Lodestar sets as a label is made here or sets its
    /// own colour from the theme.
    static func label(_ text: String, font: NSFont = secondaryFont, color: NSColor = ink,
                      truncates: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        if truncates { field.lineBreakMode = .byTruncatingTail }
        return field
    }

    /// The palette in force: espresso in dark mode, clay in light.
    static var palette: Palette.Steps {
        Tone.systemDark ? Palette.night : Palette.clay
    }

    /// The palette a given appearance asks for, for a colour that is
    /// resolved where it is drawn.
    static func steps(for appearance: NSAppearance) -> Palette.Steps {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? Palette.night : Palette.clay
    }

    /// The look the chosen row stands in: the other of the one around it,
    /// dark by day and light by night.
    static func slabLook(over appearance: NSAppearance) -> NSAppearance {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSAppearance(named: dark ? .aqua : .darkAqua) ?? appearance
    }

    /// One step of the palette as a colour that knows both looks, for a
    /// layer that must change with the look while it stands (`ToneView`
    /// and `Glass.resolved` resolve it in the view's own appearance).
    static func dynamicStep(_ step: KeyPath<Palette.Steps, Readability.RGB>, alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            steps(for: appearance)[keyPath: step].color.withAlphaComponent(alpha)
        }
    }

    /// The slab's face and its side, for a surface that wears the other look
    /// while it is chosen: read in that look, they are the ground of the look
    /// around it, which is the other of its own.
    static let slabFill = NSColor(name: "LodestarSlab") { appearance in
        steps(for: slabLook(over: appearance)).slab.color
    }
    static let slabSideFill = NSColor(name: "LodestarSlabSide") { appearance in
        steps(for: slabLook(over: appearance)).slabSide.color
    }

    /// The pane as a colour that knows both looks.
    static func dynamicGround(alpha: CGFloat = 1) -> NSColor { dynamicStep(\.pane, alpha: alpha) }

    /// The panes' ground, for anything that must be judged against it:
    /// the pane of the palette in force, which every surface is made of,
    /// so the ground is a known tone rather than a query.
    static var ground: NSColor { palette.pane.color }

    /// The step a chosen card stands on, and a key's face: one measured
    /// step lighter than the pane, never a colour of its own.
    static var raised: NSColor { palette.raised.color }

    /// The open dot's distance from the name it belongs to.
    static let dotGap: CGFloat = 6

    /// A bar's caret is the one light in its field: the accent, wherever
    /// the field editor would otherwise draw the system's own colour.
    static func lightCaret(of field: NSTextField) {
        (field.currentEditor() as? NSTextView)?.insertionPointColor = readableAccent
    }

    /// A pane's polished rim, and the top edge of whatever stands proud:
    /// the one light catching it, a flat line, never a gradient. White by
    /// day, and by night white at a tenth, which is what a glaze does to a
    /// dark ground.
    static var polishedRim: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 1, alpha: 1)
        }
    }

    /// The one key, resting: the look's raised step, which is a key's face,
    /// standing on its side. A key is the thing you press, so it is the
    /// thing that stands up; the pane around it is flat.
    static var keyFace: NSColor { dynamicStep(\.raised) }
    /// The side a resting key stands on, the look's own darker clay or
    /// espresso. It survives the night where a shadow does not, which is
    /// why depth is drawn as a side and not as a shadow.
    static var keySide: NSColor { dynamicStep(\.keySide) }
    /// A key laid over another app's window: the same ceramic, which is
    /// opaque already, so nothing of the window beneath shows through it,
    /// with the ink for its letter, because a mark is read against someone
    /// else's content.
    static var markFill: NSColor { keyFace }
    static var markLetter: NSColor { ink }
    static var keyLetter: NSColor { ink }
    /// The key's top face catches the light: the pane's polished rim.
    static var keyTop: NSColor { polishedRim }
    /// The neutral matter, two steps and no more. A well is where something
    /// is put — a field, a note box, a choice, a group's card, Keep's empty
    /// keepsake — and a quiet key lies beside, shallow and sunk; a
    /// hairline is an edge, a rule or a rim. Anything grey that is not
    /// text is one of the two, and a thing under the pointer takes the next
    /// step up, the hairline's weight, rather than a weight of its own.
    /// Eight inline opacities, from 0.03 to 0.2, had made one material read
    /// as several near-misses. The hairline is the look's ink at its own
    /// share (a tenth by day, less at night where light lines read harder).
    static var well: NSColor {
        NSColor(name: nil) { appearance in steps(for: appearance).ink.color.withAlphaComponent(0.05) }
    }
    static var hairline: NSColor {
        NSColor(name: nil) { appearance in
            let look = steps(for: appearance)
            return look.ink.color.withAlphaComponent(look.hairlineAlpha)
        }
    }
    /// A lit key is a small piece of the mark: the accent, its top edge the
    /// mark's brightest face and its side the darkest. Both are made in the
    /// appearance current where they are asked for (a blend is fixed when
    /// it is made), so a surface asks inside its own.
    static var litKeyTop: NSColor { accent.blended(withFraction: 0.4, of: .white) ?? accent }
    static var litKeySide: NSColor { accent.blended(withFraction: 0.44, of: .black) ?? accent }

    /// The accent, as a closure so a test can try the text rule and the
    /// floor against a colour of its own. In the app it is never anything
    /// but International Orange: there is no setting, and a person's own
    /// accent was retired with Ceramic (a second colour makes the same light
    /// two on one page, and one owned colour is the stronger brand).
    static var accentColor: () -> NSColor = { internationalOrange }

    /// The one accent every surface draws with: a row's highlight, a
    /// wash over a match, the walk's star, the settings' dots. The
    /// system's colour never reaches a surface directly — a test reads
    /// the sources for that — so the accent cannot drift.
    static var accent: NSColor { accentColor() }

    /// Text drawn over the accent as a fill — a selected row, a lit chip.
    /// White reads on a deep blue and fails on International Orange, so
    /// the choice is made by measure: whichever of white and near-black
    /// contrasts more with the fill, decided from the fill itself.
    static var onAccent: NSColor {
        guard let fill = accent.usingColorSpace(.sRGB) else { return .white }
        let ground = Readability.luminance(red: fill.redComponent, green: fill.greenComponent, blue: fill.blueComponent)
        let white = Readability.contrast(1, ground)
        let ink = Readability.contrast(Readability.luminance(red: 0.08, green: 0.08, blue: 0.08), ground)
        return white >= ink ? .white : NSColor(white: 0.08, alpha: 1)
    }

    /// International Orange as a colour that knows both looks: itself on
    /// espresso, where it clears the mark floor with room to spare, and on
    /// clay the same hue a step deeper (Readability measures both). It is
    /// resolved in the appearance of the view that draws it, so a lit key in
    /// a selected row, which wears the other look, wears the orange that
    /// stands on that row's ground.
    static let internationalOrange = NSColor(name: "LodestarOrange") { appearance in
        let pair = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? Readability.orangeOnCharcoal : Readability.orangeOnPaper
        return NSColor(srgbRed: pair.red, green: pair.green, blue: pair.blue, alpha: 1)
    }

    /// The accent for a mark the eye must find — the insert bar, a lit
    /// letter, the echoed query. International Orange clears the floor on
    /// both grounds, so this is the accent itself; a colour that sat nearly
    /// on the ground would fall back to the text's own colour, which is
    /// never lost.
    static var readableAccent: NSColor {
        let accent = accentColor()
        guard let a = accent.usingColorSpace(.sRGB), let g = ground.usingColorSpace(.sRGB) else { return accent }
        let ratio = Readability.contrast(
            Readability.luminance(red: a.redComponent, green: a.greenComponent, blue: a.blueComponent),
            Readability.luminance(red: g.redComponent, green: g.greenComponent, blue: g.blueComponent))
        return ratio >= Readability.markFloor ? accent : BarTheme.ink
    }
    /// What a key's row says it does — the reading size, not a caption.
    static var rowLabelFont: NSFont { face(Scale.body) }
    static var bodyFont: NSFont { face(Scale.body) }
    /// A key's letter: the interface's sans, set firm, as a key is the one
    /// place Lodestar shows a letter as an object.
    static let chipFont = NSFont.systemFont(ofSize: Scale.meta, weight: .semibold)
    static let footerFont = NSFont.systemFont(ofSize: Scale.meta, weight: .regular)
    /// The draft's face, which is also the editor lens's: the only mono
    /// Lodestar draws, because they are the only place text is edited a
    /// character at a time.
    static let readingMono = handFont(Scale.body)
    static let readingMonoAccent = handFont(Scale.body, weight: .semibold)
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
        // drawn shadow the gate opens the surface to the pointer and keeps
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
                add(word("·", color: .tertiaryLabelColor), spacingBefore: 10)
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
        field.font = BarTheme.secondaryFont
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
        field.font = BarTheme.rowLabelFont
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

/// A room's button, drawn rather than the system's bezel: a key. It is the
/// thing you press, so it stands on a visible side, three points and a bit
/// at its size, and pressed it collapses onto it at once. The answer a
/// surface exists for (`primary`) is the lit key: the accent's face with the
/// mark's bright top edge, its letters in whichever ink reads on it. One that
/// cannot be pressed now lies flat with a hairline and no side, like a quiet
/// key. Drawn by hand in `draw`, face and side and word together, because
/// the system's cell would draw the word under any layer standing behind it;
/// the title stays the button's own, an attributed title on a borderless
/// button.
final class RoomButton: NSButton {
    /// Kept for its callers; what cannot be undone is told by its words.
    var destructive = false { didSet { restyle() } }
    /// The answer the surface exists for: lit as a key is lit. One per
    /// surface.
    var primary = false { didSet { restyle() } }
    /// A word given as an answer (the editor's card): set in the body's
    /// face and size, on a taller key, because it is the person's text.
    var answer = false { didSet { restyle() } }
    private var hovering = false { didSet { restyle() } }
    private var pressing = false { didSet { restyle() } }

    static let height: CGFloat = 28
    static let answerHeight: CGFloat = 34

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        wantsLayer = true
        restyle()
    }

    required init?(coder: NSCoder) { nil }

    /// Drawn upright, so the side is at the foot whichever way the system's
    /// button counts.
    override var isFlipped: Bool { false }

    override var title: String {
        didSet { restyle() }
    }

    override var isEnabled: Bool {
        didSet { if isEnabled != oldValue { restyle() } }
    }

    override var intrinsicContentSize: NSSize {
        let text = attributedTitle.size()
        return answer
            ? NSSize(width: (text.width + 22).rounded(.up), height: Self.answerHeight)
            : NSSize(width: (text.width + 20).rounded(.up), height: Self.height)
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

    /// The key goes down while the button is held and comes up when it is
    /// let go, whether or not the pointer was still on it: the system's
    /// tracking decides whether that was a press.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressing = true
        super.mouseDown(with: event)
        pressing = false
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    /// For the tests: the key held down, as the pointer's press holds it.
    func holdForTesting(_ down: Bool) { pressing = down }

    /// What the key stands on, for the tests and the draw alike.
    var stance: KeyLayers.Stance { !isEnabled ? .flat : (pressing ? .pressed : .standing) }

    /// How much of the side shows now.
    var visibleSide: CGFloat {
        let full = KeyLayers.sideHeight(forHeight: bounds.height > 0 ? bounds.height : Self.height)
        switch stance {
        case .standing: return full
        case .pressed: return full / 3
        case .flat: return 0
        }
    }

    /// The face's and the side's colours in the button's own look, nil when
    /// there is none to draw (a flat key has no side and no fill).
    var faceColor: NSColor? { colours.face }
    var sideColor: NSColor? { colours.side }

    private var colours: (face: NSColor?, side: NSColor?, rim: NSColor?, word: NSColor) {
        var out: (face: NSColor?, side: NSColor?, rim: NSColor?, word: NSColor) = (nil, nil, nil, BarTheme.ink)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            guard stance != .flat else {
                out = (nil, nil, nil, BarTheme.secondaryColor)
                return
            }
            let resting = primary ? BarTheme.accent : BarTheme.keyFace
            // Under the pointer the face catches a little more light, as a
            // key's does.
            let toward: NSColor = dark || primary ? .white : BarTheme.ink
            let hover = dark || primary ? 0.12 : 0.05
            let face = hovering || pressing ? resting.blended(withFraction: hover, of: toward) ?? resting : resting
            // Fixed here, in the button's own look: a dynamic colour handed
            // out resolves in whichever look is current where it is read.
            func fixed(_ color: NSColor) -> NSColor { NSColor(cgColor: color.cgColor) ?? color }
            out = (fixed(face), fixed(primary ? BarTheme.litKeySide : BarTheme.keySide),
                   fixed(primary ? BarTheme.litKeyTop : BarTheme.keyTop),
                   primary ? BarTheme.onAccent : BarTheme.ink)
        }
        return out
    }

    private func restyle() {
        // A button that cannot be undone says so in its words, never in
        // an alarm colour: one light, no paint.
        let words = super.title
        super.attributedTitle = NSAttributedString(string: words, attributes: [
            .font: answer ? BarTheme.bodyFont : BarTheme.secondaryFont, .foregroundColor: colours.word])
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let colours = colours
        let full = KeyLayers.sideHeight(forHeight: bounds.height)
        let visible = visibleSide
        let faceHeight = max(0, bounds.height - full)
        // A flat key keeps the face where a standing one has it, so the
        // word does not move when the button is enabled.
        let face = NSRect(x: 0, y: stance == .flat ? full : visible, width: bounds.width, height: faceHeight)
        let round = min(BarTheme.controlRadius, faceHeight / 2)
        let facePath = NSBezierPath(roundedRect: face, xRadius: round, yRadius: round)
        if let side = colours.side {
            // The side's top is buried in the face, so only what is below it shows.
            side.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width, height: visible + faceHeight / 2),
                         xRadius: round, yRadius: round).fill()
        }
        if let fill = colours.face {
            fill.setFill()
            facePath.fill()
        } else {
            // Quiet: a hairline for its outline, nothing beneath it.
            BarTheme.hairline.setStroke()
            let outline = NSBezierPath(roundedRect: face.insetBy(dx: 0.25, dy: 0.25), xRadius: round, yRadius: round)
            outline.lineWidth = 0.5
            outline.stroke()
        }
        if let rim = colours.rim {
            // The top edge catching the light: a flat line, clipped to the
            // face's own corners so it thins into the curve.
            NSGraphicsContext.saveGraphicsState()
            facePath.addClip()
            rim.setFill()
            NSRect(x: face.minX, y: face.maxY - 1, width: face.width, height: 1).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        let text = attributedTitle
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                              y: (face.midY - size.height / 2).rounded()))
    }
}

/// A row in a room's choice menu, drawn by Lodestar: the system's menu
/// highlights in the Mac's accent, so each item wears this view, which
/// becomes the slab under the pointer or the arrow keys like the bars' rows
/// and marks the current choice with the accent's dot.
final class ChoiceMenuItemView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let dot = NSView()
    private weak var popup: NSPopUpButton?
    private let enabled: Bool
    private(set) var lit = false
    static let height: CGFloat = 22 + RaisedRow.sideHeight

    init(item: NSMenuItem, chosen: Bool, width: CGFloat, popup: NSPopUpButton) {
        self.popup = popup
        enabled = item.isEnabled
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        wantsLayer = true
        label.stringValue = item.title
        label.font = BarTheme.secondaryFont
        label.textColor = item.isEnabled ? BarTheme.ink : BarTheme.secondaryColor
        label.lineBreakMode = .byTruncatingTail
        icon.image = item.image
        dot.wantsLayer = true
        dot.layer?.cornerRadius = BarTheme.dotRadius
        dot.isHidden = !chosen
        [dot, icon, label].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(item.title)
        setAccessibilitySelected(chosen)
        paint(lit: false)
    }

    required init?(coder: NSCoder) { nil }

    /// The slab the row stands on while it is chosen: the face, and the
    /// side beneath it inside the row's own bounds.
    private var face: NSRect {
        NSRect(x: 5, y: RaisedRow.sideHeight, width: max(0, bounds.width - 10),
               height: max(0, bounds.height - RaisedRow.sideHeight))
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 12
        let face = face
        dot.frame = NSRect(x: inset, y: (face.minY + (face.height - BarTheme.dotDiameter) / 2).rounded(),
                           width: BarTheme.dotDiameter, height: BarTheme.dotDiameter)
        var x = inset + BarTheme.dotDiameter + 8
        if icon.image != nil {
            icon.frame = NSRect(x: x, y: (face.minY + (face.height - 12) / 2).rounded(), width: 19, height: 12)
            x += 24
        }
        let natural = label.sizeThatFits(NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                height: CGFloat.greatestFiniteMagnitude)).height
        label.frame = NSRect(x: x, y: (face.minY + (face.height - natural) / 2).rounded(),
                             width: max(0, bounds.width - x - inset), height: natural)
    }

    /// The menu's own highlight follows the pointer and the arrow keys
    /// alike, and says so only by drawing: what stands on the slab takes
    /// the other look's ink and orange before it is drawn.
    override func viewWillDraw() {
        super.viewWillDraw()
        let on = enclosingMenuItem?.isHighlighted == true && enabled
        if on != lit { paint(lit: on) }
    }

    /// The words and the dot in the look the row is standing in now: its
    /// own, or the slab's, which is the other.
    func paint(lit on: Bool) {
        lit = on
        let around = effectiveAppearance
        let look = on ? BarTheme.slabLook(over: around) : around
        let steps = BarTheme.steps(for: look)
        label.textColor = (enabled ? steps.ink : steps.secondary).color
        look.performAsCurrentDrawingAppearance {
            dot.layer?.backgroundColor = BarTheme.accent.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint(lit: lit)
    }

    /// The slab: the other look's ground on a four-point side.
    override func draw(_ dirtyRect: NSRect) {
        guard lit else { return }
        let steps = BarTheme.steps(for: effectiveAppearance)
        let face = face
        let round = min(BarTheme.controlRadius, face.height / 2)
        let side = NSRect(x: face.minX, y: 0, width: face.width, height: face.height / 2 + RaisedRow.sideHeight)
        steps.slabSide.color.setFill()
        NSBezierPath(roundedRect: side, xRadius: round, yRadius: round).fill()
        steps.slab.color.setFill()
        NSBezierPath(roundedRect: face, xRadius: round, yRadius: round).fill()
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
    /// The knob is a thing you press, so it stands up: a ceramic face on a
    /// side, as a key does, never a shadow.
    private let knob = CALayer()
    private let knobFace = CALayer()
    private let knobSide = CALayer()
    static let size = NSSize(width: 30, height: 17)
    /// How far the knob's side shows below its face.
    static let knobSideHeight: CGFloat = 1.5

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
        let diameter = Self.size.height - 4
        for part in [knobSide, knobFace] {
            part.cornerRadius = diameter / 2
            knob.addSublayer(part)
        }
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
        let tint = Glass.resolved(on ? BarTheme.accent : BarTheme.ink.withAlphaComponent(0.22), in: self)
        let knobSize = Self.size.height - 4
        let knobFaceColor = Glass.resolved(BarTheme.keyFace, in: self)
        let knobSideColor = Glass.resolved(BarTheme.keySide, in: self)
        let knobFrame = NSRect(x: on ? bounds.width - knobSize - 2 : 2, y: 2, width: knobSize, height: knobSize)
        let fromPosition = knob.presentation()?.position ?? knob.position
        let fromTint = track.presentation()?.backgroundColor ?? track.backgroundColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        track.backgroundColor = tint
        knob.frame = knobFrame
        knobFace.frame = knob.bounds
        knobSide.frame = knob.bounds.offsetBy(dx: 0, dy: -Self.knobSideHeight)
        knobFace.backgroundColor = knobFaceColor
        knobSide.backgroundColor = knobSideColor
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
/// the surface is one family with the pill and nothing is retyped at
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
    /// The one way a field takes a placeholder: in the interface's face.
    func setPlaceholder(_ text: String) {
        placeholderAttributedString = BarTheme.placeholder(text, like: font)
    }
}


extension Readability.RGB {
    var color: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
}

/// The layers a key is made of, shared by the key a hand presses (`KeyFace`)
/// and the mark laid over another app's window (`KeyMark`): a side the key
/// stands on, and the face above it with its polished top edge. A key is
/// the thing you press, so it is the thing that stands up, three points at
/// key size and in proportion at any other (never under a point and a half
/// or over five). Pressed, the side collapses to a third and the face
/// follows it down, at once; flat, which is a quiet key, there is no side.
final class KeyLayers {
    enum Stance { case standing, pressed, flat }

    let side = CALayer()
    let face = CALayer()
    /// The top edge catching the light, along the face's own outline.
    let rim = EdgeLight()
    let radius: CGFloat
    private(set) var stance = Stance.standing

    init(radius: CGFloat) {
        self.radius = radius
        rim.install(in: face)
    }

    /// Stand the key's layers in a view's own, under whatever the view
    /// adds above them.
    func install(in host: CALayer) {
        host.masksToBounds = false
        host.addSublayer(side)
        host.addSublayer(face)
    }

    /// The side's height for a key of this height: three at key size, in
    /// proportion above and below it.
    static func sideHeight(forHeight height: CGFloat) -> CGFloat {
        min(5, max(1.5, 3 * height / BarTheme.chipHeight))
    }

    /// How much of the side shows now, of a key `height` tall.
    func visibleSide(forHeight height: CGFloat) -> CGFloat {
        let full = Self.sideHeight(forHeight: height)
        switch stance {
        case .standing: return full
        case .pressed: return full / 3
        case .flat: return 0
        }
    }

    /// How far the face's middle stands above the key's own, which is where
    /// the letter belongs: up by what the side has put under the face.
    func labelLift(forHeight height: CGFloat) -> CGFloat {
        stance == .flat ? 0 : visibleSide(forHeight: height) - Self.sideHeight(forHeight: height) / 2
    }

    func place(_ stance: Stance, in bounds: CGRect) {
        self.stance = stance
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard stance != .flat else {
            side.isHidden = true
            face.frame = bounds
            face.cornerRadius = min(radius, bounds.height / 2)
            rim.fit(face.bounds, radius: face.cornerRadius, reach: radius + 3)
            return
        }
        let full = Self.sideHeight(forHeight: bounds.height)
        let visible = visibleSide(forHeight: bounds.height)
        let faceHeight = max(0, bounds.height - full)
        side.isHidden = false
        face.frame = CGRect(x: bounds.minX, y: bounds.minY + visible, width: bounds.width, height: faceHeight)
        // The side's top is buried in the face, so only what is below the
        // face shows and no fringe of it edges the face's own corners.
        side.frame = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: visible + faceHeight / 2)
        face.cornerRadius = min(radius, faceHeight / 2)
        side.cornerRadius = min(radius, faceHeight / 2)
        rim.fit(face.bounds, radius: face.cornerRadius, reach: radius + 3)
    }

    /// The colours, already resolved in the look of the view that draws the
    /// key. A nil face or side is clear.
    func paint(face faceColor: CGColor?, side sideColor: CGColor?, rim rimColor: NSColor?,
               outline: CGColor? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        face.backgroundColor = faceColor
        side.backgroundColor = sideColor
        face.borderWidth = outline == nil ? 0 : 0.5
        face.borderColor = outline
        rim.color = rimColor
        CATransaction.commit()
    }
}

/// The one key Lodestar draws: a small object standing on a visible side,
/// whose top edge catches the light. Lit, it is a piece of the mark: the
/// accent, with the mark's brightest face for its top edge and its darkest
/// for its side, and the letter in whichever ink reads on it. Resting, it
/// is a cap of the look's raised ceramic.
final class KeyFace: NSView {
    let label = NSTextField(labelWithString: "")
    var lit = false { didSet { if lit != oldValue { refresh() } } }
    /// A key you could press but are not being asked to: the address the
    /// coach offers for later, a cheat sheet's unused gesture, an action
    /// not available yet. It lies flat, with no side and no well: it is not
    /// a place, and the light falls on raised things, so a key that is not
    /// raised loses its lit top edge and its side, keeps a hairline outline
    /// and sets its letter in the quiet ink. Resting keys stand, the lit
    /// key glows. Depth carries the importance, never a fade: a
    /// translucent key is not a thing a light falls on.
    var quiet = false { didSet { if quiet != oldValue { refresh() } } }
    /// What a pointer is doing to a key that can be clicked: it brightens
    /// under the pointer and sinks onto its side when pressed.
    private var pointer = Keycaps.CapState.resting
    private let layers: KeyLayers
    private var labelLift: NSLayoutConstraint?

    /// What the key is drawn with, for the tests: the face's and the side's
    /// colours, and how much of the side shows.
    var faceColor: CGColor? { layers.face.backgroundColor }
    var sideColor: CGColor? { layers.side.backgroundColor }
    var visibleSide: CGFloat { layers.visibleSide(forHeight: bounds.height > 0 ? bounds.height : BarTheme.chipHeight) }
    var stance: KeyLayers.Stance { layers.stance }
    var rimColor: NSColor? { layers.rim.color }

    /// `padX` widens a key whose label is a word on a long cap, the walk's
    /// space bar; every other key takes the theme's.
    init(_ text: String, padX: CGFloat = BarTheme.chipPadX) {
        layers = KeyLayers(radius: BarTheme.chipRadius)
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        if let layer { layers.install(in: layer) }
        label.stringValue = text
        label.font = BarTheme.chipFont
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        let lift = label.centerYAnchor.constraint(equalTo: centerYAnchor)
        labelLift = lift
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padX),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padX),
            lift,
            heightAnchor.constraint(equalToConstant: BarTheme.chipHeight),
            widthAnchor.constraint(greaterThanOrEqualToConstant: BarTheme.chipMinWidth),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        layers.place(layers.stance, in: bounds)
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
        let stance: KeyLayers.Stance = quiet && !lit ? .flat : (pointer == .pressed ? .pressed : .standing)
        layers.place(stance, in: bounds.isEmpty ? NSRect(x: 0, y: 0, width: 0, height: BarTheme.chipHeight) : bounds)
        labelLift?.constant = layers.labelLift(forHeight: bounds.height > 0 ? bounds.height : BarTheme.chipHeight)
        // Every colour is made in this key's own look: a blend, like an
        // alpha, is fixed in whatever look is current when it is made.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if stance == .flat {
                layers.paint(face: nil, side: nil, rim: nil, outline: Glass.resolved(BarTheme.hairline, in: self))
                label.textColor = BarTheme.secondaryColor
                return
            }
            let resting = lit ? BarTheme.accent : BarTheme.keyFace
            // Under the pointer the face catches a little more light:
            // brighter in the night and on the accent, and in the light,
            // where a key's face is already near the top, a little less.
            let toward: NSColor = Tone.systemDark || lit ? .white : BarTheme.ink
            let hover = pointer == .resting ? 0 : (Tone.systemDark || lit ? 0.12 : 0.05)
            let face = pointer == .resting ? resting : resting.blended(withFraction: hover, of: toward) ?? resting
            let side = lit ? BarTheme.litKeySide : BarTheme.keySide
            let rim = lit ? BarTheme.litKeyTop : BarTheme.keyTop
            layers.paint(face: Glass.resolved(face, in: self), side: Glass.resolved(side, in: self),
                         rim: NSColor(cgColor: Glass.resolved(rim, in: self)))
            label.textColor = lit ? BarTheme.onAccent : BarTheme.keyLetter
        }
    }
}

/// A row that becomes the slab when it is chosen (DESIGN, "Ceramic"): the
/// opposite look's ground with a four-point side in its darker shade, an
/// espresso slab with clay ink by day and a clay slab with espresso ink by
/// night. Each look is the other's selection.
///
/// The row takes the other look's appearance, so everything inside it that
/// follows the look follows it: the labels and their quiet ink, the keys,
/// the accent. A lit key on the slab is the accent that stands on that
/// ground, with no second colour stored for it. The bars' rows share it, so
/// the launcher, Ask and the commands bar choose a row the same way.
class RaisedRow: NSView {
    private let light = EdgeLight()
    private let slabFace = CALayer()
    private let slabSide = CALayer()
    private(set) var raised = false
    private var lookObserver: NSKeyValueObservation?

    /// What stands on the slab, when it is not the row itself: a step drawn
    /// behind a row's own content (Settings' chosen entry and result), whose
    /// words are siblings of the step and so take the other look from here.
    weak var carries: NSView?
    /// The view whose look the row is the other of, when that is not the
    /// row's own superview (it is not, for a step inside the content it
    /// makes the other look).
    weak var surroundings: NSView?

    /// The slab's side, at the foot of the row and inside its bounds: a
    /// side hung below the row was clipped by a scroll view or covered by
    /// the next sibling. The face is the row less this, and what is in the
    /// row is centred on the face, so a row reserves the side whether it is
    /// chosen or not and nothing in it moves when it is.
    static let sideHeight: CGFloat = 4

    /// The face as a layout guide, for a row whose content is laid out by
    /// constraints: pin to it and the content is centred on the face.
    let faceGuide = NSLayoutGuide()

    /// The face in the row's own coordinates, for a row laid out by hand.
    var faceBounds: CGRect {
        CGRect(x: 0, y: Self.sideHeight, width: bounds.width, height: max(0, bounds.height - Self.sideHeight))
    }

    /// How far the row stands from the edge of the surface it is in, which
    /// decides its rounding: concentric with that surface, so a row six
    /// points in rounds a little more than one ten points in.
    var inset: CGFloat = BarTheme.rowInset {
        didSet { if inset != oldValue { layer?.cornerRadius = radius; needsLayout = true } }
    }
    var radius: CGFloat { BarTheme.nested(outer: BarTheme.surfaceRadius, inset: inset, rung: BarTheme.controlRadius) }

    /// The slab as drawn, for the tests: its face and side colours.
    var slabColors: (face: CGColor?, side: CGColor?) { (slabFace.backgroundColor, slabSide.backgroundColor) }

    func setupRaised() {
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.masksToBounds = false
        // Face and side under everything the row adds, so its labels and
        // keys draw on the slab and not beneath it.
        layer?.insertSublayer(slabSide, at: 0)
        layer?.insertSublayer(slabFace, at: 1)
        light.install(in: slabFace)
        addLayoutGuide(faceGuide)
        NSLayoutConstraint.activate([
            faceGuide.topAnchor.constraint(equalTo: topAnchor),
            faceGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
            faceGuide.trailingAnchor.constraint(equalTo: trailingAnchor),
            faceGuide.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.sideHeight),
        ])
        // A row is the other look's only while it is chosen, and the look it
        // is the other of is the one around it, which a Mac that turns dark
        // at sunset changes without telling the row.
        lookObserver = NSApplication.shared.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyRaised(self?.raised ?? false) }
        }
        applyRaised(false)
    }

    override func layout() {
        super.layout()
        // A face shorter than twice its rounding is a stadium, not a
        // rectangle with corners that overlap.
        let face = faceBounds
        let round = min(radius, face.height / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        slabFace.frame = face
        slabFace.cornerRadius = round
        // The side's top is buried in the face, so only what is below the
        // face shows.
        slabSide.frame = CGRect(x: 0, y: 0, width: bounds.width, height: face.height / 2 + Self.sideHeight)
        slabSide.cornerRadius = round
        CATransaction.commit()
        light.fit(slabFace.bounds, radius: round, reach: round + 4)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview != nil { applyRaised(raised) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyRaised(raised)
    }

    /// The look the row is standing in, which is its surroundings' and never
    /// its own once it has taken the other.
    private var surroundingLook: NSAppearance {
        (surroundings ?? superview)?.effectiveAppearance ?? window?.effectiveAppearance
            ?? NSApplication.shared.effectiveAppearance
    }

    func applyRaised(_ on: Bool) {
        raised = on
        let surrounding = surroundingLook
        let slab = BarTheme.steps(for: surrounding)
        let wanted: NSAppearance? = on ? BarTheme.slabLook(over: surrounding) : nil
        let wearer = carries ?? self
        if wearer.appearance?.name != wanted?.name { wearer.appearance = wanted }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        slabFace.backgroundColor = on ? slab.slab.color.cgColor : nil
        slabSide.backgroundColor = on ? slab.slabSide.color.cgColor : nil
        slabSide.isHidden = !on
        CATransaction.commit()
        // The rim is the pane's, in the slab's own look: a tenth of white
        // on the dark slab, white on the clay one.
        light.color = on ? NSColor(cgColor: Glass.resolved(BarTheme.polishedRim, in: self)) : nil
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
        fade.colors = [NSColor.white.cgColor, NSColor.white.cgColor, NSColor.white.withAlphaComponent(0).cgColor]
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
/// nothing: one long, soft, warm shadow beneath and a hairline contact
/// shadow under the edge; the hairline edge in place of the window server's
/// outline is the ceramic pane's own. The system's window shadow cannot be
/// shaped, so the panel grows by `margin` on every side, the surface sits
/// inset inside it, and the host draws the shadow in that margin. Clicks in
/// the margin land on nothing.
enum SoftShadow {
    static let margin: CGFloat = 64

    /// The window's frame for a surface that should stand at `visible`.
    static func outset(_ visible: NSRect) -> NSRect { visible.insetBy(dx: -margin, dy: -margin) }
    /// The surface's frame inside a window hosted this way.
    static func inset(_ window: NSRect) -> NSRect { window.insetBy(dx: margin, dy: margin) }

    /// Host `content` as the panel's surface, with the shadow drawn here,
    /// and gate the pointer so only the surface takes it: the margin is
    /// window, and a click there belongs to whatever is beneath. Every
    /// hosted surface is gated by construction; the gate is returned for a
    /// surface that changes size under a still pointer and must re-read it.
    ///
    /// `takesPointer: false` is for a surface that only shows (a key
    /// guide, the ⌘K card): it never takes the mouse, surface or shadow.
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
/// the hairline edge itself, in the theme's hairline (a pane standing in
/// it leaves the edge to this, so it is drawn once). A floating object is lifted further than a resting one, so
/// what is passing stands over what is kept and what is older.
final class ObjectSurface: NSView {
    enum Lift { case float, rest }

    /// What the object is to the hand. A pane over the work casts the drawn
    /// shadow (`shadow`); something you press stands on a visible side, in
    /// the key's own colour (`key`) or the slab's when it is the chosen one
    /// (`slab`, which wears the other look); a place you put something
    /// is sunk and casts nothing (`well`).
    enum Stance { case shadow, key, slab, well }

    let radius: CGFloat
    var lift: Lift { didSet { if lift != oldValue { restyle(); place() } } }
    var stance: Stance = .shadow { didSet { if stance != oldValue { restyle(); place() } } }
    private let soft = CALayer()
    private let contact = CALayer()
    private let edge = CALayer()
    /// The side a key or a slab stands on, below the face and inside the
    /// card's own layer; the strip's window is the whole screen, so it hangs
    /// there unclipped.
    private let side = CALayer()

    /// How far the side hangs below the card's frame, for the tests.
    var sideHeight: CGFloat { stance == .key || stance == .slab ? KeyLayers.sideHeight(forHeight: bounds.height) : 0 }
    var sideColor: CGColor? { side.isHidden ? nil : side.backgroundColor }
    var hasEdge: Bool { edge.borderWidth > 0 }

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
        layer?.insertSublayer(side, at: 0)
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
        let sideHeight = sideHeight
        side.isHidden = sideHeight == 0
        // The side's top is buried in the face, so only what hangs below shows.
        side.frame = CGRect(x: 0, y: -sideHeight, width: bounds.width, height: bounds.height / 2 + sideHeight)
        side.cornerRadius = radius
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
        soft.shadowColor = (dark ? NSColor(srgbRed: 0.055, green: 0.027, blue: 0.008, alpha: 1)
                                 : NSColor(srgbRed: 0.35, green: 0.23, blue: 0.13, alpha: 1)).cgColor
        let casts = stance == .shadow
        soft.shadowOpacity = casts ? (floating ? (dark ? 0.58 : 0.26) : (dark ? 0.42 : 0.16)) : 0
        soft.shadowRadius = floating ? 18 : 7
        contact.shadowColor = soft.shadowColor
        contact.shadowOpacity = casts ? (dark ? 0.35 : 0.14) : 0
        contact.shadowRadius = 1
        // The slab is a ground of its own and wants no outline round it.
        edge.borderWidth = stance == .slab ? 0 : 0.5
        edge.borderColor = Glass.resolved(BarTheme.hairline, in: self)
        side.backgroundColor = Glass.resolved(stance == .slab ? BarTheme.slabSideFill : BarTheme.keySide, in: self)
        CATransaction.commit()
    }
}

extension NSWindow {
    /// The surface's frame: the window's, less the drawn shadow's margin
    /// when the window hosts one. Surfaces place and read their pane by
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
/// stands, shadow included: a band of air around the surface that eats
/// clicks meant for the app beneath, the Dock's top edge among them. The
/// system's own shadow was never a target. A surface that stays open over
/// someone else's work therefore takes the mouse only while the pointer
/// is over its surface, and lets it through everywhere else.
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

    /// Read the pointer against the surface. Called on every move and
    /// whenever the surface changes size under a still pointer.
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The soft shadow is cast by a slightly smaller shape held lower,
        // so it falls beneath the surface rather than around it.
        let softShape = surface.insetBy(dx: 16, dy: 16).offsetBy(dx: 0, dy: -26)
        // The rounding is held to what the shape can carry: a surface
        // shorter than twice its radius is a stadium.
        func rounding(_ shape: CGRect) -> CGFloat { min(radius, min(shape.width, shape.height) / 2) }
        soft.shadowPath = CGPath(roundedRect: softShape, cornerWidth: rounding(softShape),
                                 cornerHeight: rounding(softShape), transform: nil)
        contact.shadowPath = CGPath(roundedRect: surface.offsetBy(dx: 0, dy: -1), cornerWidth: rounding(surface),
                                    cornerHeight: rounding(surface), transform: nil)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        let dark = Tone.systemDark
        soft.shadowColor = (dark ? NSColor(srgbRed: 0.055, green: 0.027, blue: 0.008, alpha: 1)
                                 : NSColor(srgbRed: 0.35, green: 0.23, blue: 0.13, alpha: 1)).cgColor
        soft.shadowOpacity = dark ? 0.62 : 0.30
        soft.shadowRadius = 30
        contact.shadowColor = soft.shadowColor
        contact.shadowOpacity = dark ? 0.35 : 0.14
        contact.shadowRadius = 1
    }

    /// Only the surface takes the pointer; the shadow is not a target.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard content.frame.contains(local) else { return nil }
        return super.hitTest(point)
    }
}

/// A key drawn without layout, for `KeyMark`: the one key's layers in a plain
/// view, so a window of four hundred of them costs nothing to build.
final class KeyBody: NSView {
    let layers: KeyLayers

    init(frame: NSRect, radius: CGFloat) {
        layers = KeyLayers(radius: radius)
        super.init(frame: frame)
        wantsLayer = true
        if let layer { layers.install(in: layer) }
        layers.place(.standing, in: bounds)
    }

    required init?(coder: NSCoder) { nil }

    /// The face's and the side's colours, for the tests.
    var faceColor: CGColor? { layers.face.backgroundColor }
    var sideColor: CGColor? { layers.side.backgroundColor }
}

/// Marks laid over another app's window, drawn as the one key: the raised
/// ceramic cap standing on its side with its lit top edge, on a short warm
/// shadow so it reads over any app, light or dark. A mark the hand has
/// begun typing stays the resting key and keeps its width: the letters
/// already typed dim in its label, and the ones still to press keep the
/// mark's ink. Built by hand, without layout, because a window of click
/// hints can be four hundred of them at once.
enum KeyMark {
    static let height: CGFloat = BarTheme.chipHeight
    /// The peek's numerals: the same key at a size read across the screen.
    static let peekHeight: CGFloat = 48
    static let peekFont = NSFont.monospacedDigitSystemFont(ofSize: 24, weight: .semibold)
    /// The neutral hairline from a displaced tag to its word.
    static var connector: NSColor { BarTheme.ink.withAlphaComponent(Tone.systemDark ? 0.38 : 0.35) }
    /// The underline's weight: the editor's line, select's matches, a held span.
    static let underline: CGFloat = 2.5
    /// The anchor's and the held span's heavier line.
    static let heavyUnderline: CGFloat = 3.5

    /// A label with its first `typed` letters dimmed, in the caption grey,
    /// and the rest in the mark's ink. The label compares to what was
    /// typed without case, since it is drawn in capitals; a label the typed
    /// letters do not begin is drawn whole.
    static func letters(_ text: String, typed: String, font: NSFont) -> NSAttributedString {
        let drawn = text.uppercased()
        let done = !typed.isEmpty && text.lowercased().hasPrefix(typed.lowercased()) ? typed.count : 0
        let label = NSMutableAttributedString(string: drawn, attributes: [
            .font: font, .foregroundColor: BarTheme.markLetter])
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
            letters(text, typed: typed, font: peek ? peekFont : BarTheme.chipFont))
        label.alignment = .center
        label.sizeToFit()
        let width = max(height, ceil(label.frame.width) + BarTheme.chipPadX * 2)
        let view = KeyBody(frame: NSRect(x: 0, y: 0, width: width, height: height), radius: radius)
        // The mark is built outside any window, so its look is the one the
        // Mac shows now, and it is made again when the hints are.
        view.layers.paint(face: Glass.resolved(BarTheme.markFill), side: Glass.resolved(BarTheme.keySide),
                          rim: NSColor(cgColor: Glass.resolved(BarTheme.keyTop)))
        // The letter sits on the face's middle, which the side has raised.
        let lift = view.layers.labelLift(forHeight: height)
        label.frame = NSRect(x: 0, y: ((height - label.frame.height) / 2 + lift).rounded(), width: width,
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
        label.font = BarTheme.secondaryFont
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
        layer.shadowColor = (Tone.systemDark
            ? NSColor(srgbRed: 0.03, green: 0.016, blue: 0.004, alpha: 0.3)
            : NSColor(srgbRed: 0.37, green: 0.24, blue: 0.14, alpha: 0.2)).cgColor
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
