import AppKit
import LodestarCore

/// The pill: one object that says which lens is up, over which app, and
/// what the hand has said inside it. Every lens wears it — scroll, click,
/// select, and scroll's aim band — so the eye learns one shape.
///
/// Two wings and a center. The leading wing is the mode, symbol then
/// word; the trailing wing is the app, word then icon; the center holds
/// the hand's words. When the hand has said nothing the center is empty,
/// or a still hairline caret when the lens is listening, so the band says
/// whether typing would land without carrying an instruction. The moment
/// there is text, both wings fold to their glyphs and the text takes the
/// band: the symbol and the icon never move, and the fold is
/// the only change. No motion anywhere, because a mode indicator that
/// arrives late is late.
///
/// Every dimension is the height over a power of φ, so one number sets
/// the object. Floating at the guide's home, where the eye already is.
final class ModePill {
    enum Mode: Equatable {
        case scroll, click, select
        /// A launch that is taking time: stands while the window is awaited.
        case opening

        var symbol: String {
            switch self {
            case .opening: return "arrow.up.forward.app"
            case .scroll: return "arrow.up.and.down"
            case .click: return "cursorarrow.click.2"
            case .select: return "character.cursor.ibeam"
            }
        }

        var word: String {
            switch self {
            case .opening: return "Opening"
            case .scroll: return "Scroll"
            case .click: return "Click"
            case .select: return "Select"
            }
        }
    }

    struct State: Equatable {
        var mode: Mode
        var app: String
        var icon: NSImage?
        /// Typing would land here: a still caret stands in the center.
        var listening: Bool
        /// What the hand has said. Any text at all folds the wings.
        var text: String?
        /// A word the hand has already taken — select's start anchor —
        /// shown ahead of the text while the far end is chosen. It folds
        /// the wings the way text does.
        var anchored: String? = nil

        static func == (lhs: State, rhs: State) -> Bool {
            lhs.mode == rhs.mode && lhs.app == rhs.app && lhs.listening == rhs.listening
                && lhs.text == rhs.text && lhs.anchored == rhs.anchored && lhs.icon === rhs.icon
        }
    }

    /// What the pill draws, pure, so a stage can read the composition
    /// instead of pixels.
    enum Piece: Equatable {
        case symbol(String), modeWord(String), caret, text(String), anchored(String), appWord(String), appIcon
    }

    static func layout(for state: State) -> [Piece] {
        let tail: Piece = state.icon == nil ? .appWord(state.app) : .appIcon
        if state.text != nil || state.anchored != nil {
            var center: [Piece] = []
            if let anchored = state.anchored { center.append(.anchored(anchored)) }
            if let text = state.text {
                center.append(.text(text))
            } else if state.listening {
                // The far end is still to be typed: the caret waits after
                // the word the hand already has.
                center.append(.caret)
            }
            return [.symbol(state.mode.symbol)] + center + [tail]
        }
        var pieces: [Piece] = [.symbol(state.mode.symbol), .modeWord(state.mode.word)]
        if state.listening { pieces.append(.caret) }
        pieces.append(.appWord(state.app))
        if state.icon != nil { pieces.append(.appIcon) }
        return pieces
    }

    // MARK: - Proportion

    static let phi: CGFloat = BarTheme.phi
    static let height: CGFloat = BarTheme.pillHeight
    static var radius: CGFloat { BarTheme.surfaceRadius }
    static var inset: CGFloat { height / phi }
    static var wingGap: CGFloat { height / phi }
    static var wordGap: CGFloat { height / (phi * phi * phi) }
    /// The band's home: the guide's, a little above the bottom edge.
    static let rise: CGFloat = 96
    static let iconSize: CGFloat = 16

    /// The hand's words, upright: the italic was tried and did not look
    /// right on the glass. Size and weight set them apart from the wings.
    static var textFont: NSFont { BarTheme.typedFont }

    // MARK: - Surface

    private let panel: NSPanel
    private let root = NSView()
    private var content: NSStackView?
    private(set) var state: State?
    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }
    /// Where the hand put the pill, as a displacement from its home, so
    /// a dragged pill comes back where it was left for the rest of the
    /// session. Zero until dragged; the home is the guide's.
    private(set) var offset = NSPoint.zero
    private var moveObserver: Any?
    private var placing = false

    init() {
        panel = Glass.makePanel(level: .statusBar)
        panel.contentView = root
        _ = Glass.installBackdrop(in: root, cornerRadius: Self.radius)
        // Draggable by its glass, the way the coach's chip is: one home by
        // default, and a remembered displacement once the hand moves it.
        Movable.enable(panel)
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in self?.noteMoved() }
    }

    deinit {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
    }

    /// The hand dragged the pill: keep where it went as a displacement
    /// from home. Our own placement moves the window too, and is not a
    /// drag.
    private func noteMoved() {
        guard !placing, panel.isVisible else { return }
        remember(origin: panel.frame.origin)
    }

    func remember(origin: NSPoint) {
        let home = Self.home(for: panel.frame.size)
        offset = NSPoint(x: origin.x - home.x, y: origin.y - home.y)
    }

    static func home(for size: NSSize) -> NSPoint {
        let visible = ActivePolicy.presentationFrame
        return NSPoint(x: visible.midX - size.width / 2, y: visible.minY + rise)
    }

    func show(_ state: State) {
        if state == self.state, panel.isVisible { return }
        self.state = state
        build(state)
        present()
    }

    func hide() {
        state = nil
        keys?.removeFromSuperview()
        keys = nil
        keyEdges = []
        panel.orderOut(nil)
    }

    // MARK: - The keys

    /// The lens's keys, above the row, in the pill's own glass. The row
    /// never moves: the glass grows around it, upward and outward, and
    /// the keys fade in above.
    private var keys: NSView?
    /// The edges that ask the glass to be big enough for the keys. Taken
    /// off before the glass shrinks, or the departing keys would still
    /// hold it wide while they fade.
    private var keyEdges: [NSLayoutConstraint] = []
    var keysShown: Bool { keys != nil }

    func toggleKeys(_ sections: [CheatSheet.Section]) {
        if keysShown { hideKeys() } else { showKeys(sections) }
    }

    func showKeys(_ sections: [CheatSheet.Section]) {
        guard panel.isVisible, let content else { return }
        keys?.removeFromSuperview()
        let columns = CheatSheet.columns(sections)
        columns.alphaValue = 0
        root.addSubview(columns)
        // Laid out once at their own width, centred on the row and standing
        // on it, so the glass reveals them as it grows and nothing inside
        // it moves or reflows. The edges that ask the glass to be big
        // enough sit below the window-size threshold: above it AppKit
        // would size the window to them at once, ahead of the motion, and
        // the row would sit off centre until the glass caught up. They
        // still decide the fitting size the motion grows toward.
        let width = columns.fittingSize.width
        let edges = [
            columns.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.inset),
            columns.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: Self.inset),
            columns.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -Self.inset),
        ]
        for edge in edges { edge.priority = .init(NSLayoutConstraint.Priority.windowSizeStayPut.rawValue - 1) }
        keyEdges = edges
        NSLayoutConstraint.activate(edges + [
            columns.widthAnchor.constraint(equalToConstant: width),
            columns.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            columns.bottomAnchor.constraint(equalTo: content.topAnchor, constant: -Self.wingGap),
        ])
        keys = columns
        // The glass moves while it grows; that is placement, not a drag.
        placing = true
        KeysMotion.grow(panel, to: frameForContent(), revealing: columns) { [weak self] in self?.placing = false }
    }

    func hideKeys() {
        guard let going = keys else { return }
        keys = nil
        NSLayoutConstraint.deactivate(keyEdges)
        keyEdges = []
        placing = true
        KeysMotion.shrink(panel, to: frameForContent(), hiding: going) { [weak self] in self?.placing = false }
    }

    // MARK: - Construction

    private func build(_ state: State) {
        content?.removeFromSuperview()
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        let pieces = Self.layout(for: state)
        for (index, piece) in pieces.enumerated() {
            if index > 0 { stack.addArrangedSubview(Self.gap(Self.gapBefore(piece, after: pieces[index - 1]))) }
            stack.addArrangedSubview(view(for: piece, state: state))
        }

        root.addSubview(stack)
        // The row is the foot of the glass and its centre line: the same
        // pill when nothing stands above it, and the unmoved last line
        // of the card when its keys do.
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -Self.inset),
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.height / 2),
        ])
        content = stack
    }

    /// A glyph sits close to its own word; wings stand apart from the
    /// center and from each other by the wing gap.
    private static func gapBefore(_ piece: Piece, after previous: Piece) -> CGFloat {
        switch (previous, piece) {
        case (.symbol, .modeWord), (.appWord, .appIcon), (.anchored, .text), (.anchored, .caret): return wordGap
        default: return wingGap
        }
    }

    private static func gap(_ width: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        return view
    }

    private func view(for piece: Piece, state: State) -> NSView {
        switch piece {
        case .symbol(let name):
            let image = NSImage(systemSymbolName: name, accessibilityDescription: state.mode.word)?
                .withSymbolConfiguration(BarTheme.symbol)
            let view = NSImageView(image: image ?? NSImage())
            view.contentTintColor = .labelColor
            view.setContentHuggingPriority(.required, for: .horizontal)
            return view
        case .modeWord(let word):
            return Self.label(word, font: BarTheme.bodyFont, color: .labelColor)
        case .appWord(let word):
            return Self.label(word, font: BarTheme.bodyFont, color: BarTheme.secondaryColor)
        case .appIcon:
            let view = NSImageView(image: state.icon ?? NSImage())
            view.imageScaling = .scaleProportionallyUpOrDown
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.widthAnchor.constraint(equalToConstant: Self.iconSize),
                view.heightAnchor.constraint(equalToConstant: Self.iconSize),
            ])
            return view
        case .caret:
            return Self.caret(alpha: 0.55)
        case .anchored(let word):
            // The word already taken, then a quiet dot before whatever
            // comes next: the far end's letters, or the caret waiting.
            let label = Self.label(word, font: Self.textFont, color: .labelColor)
            let dot = Self.label("·", font: BarTheme.bodyFont, color: BarTheme.secondaryColor)
            let pair = NSStackView(views: [label, dot])
            pair.orientation = .horizontal
            pair.alignment = .centerY
            pair.spacing = Self.wordGap
            pair.translatesAutoresizingMaskIntoConstraints = false
            return pair
        case .text(let text):
            // The letters and their caret, and no more: a slot reserved
            // ahead of the typing left a gap before the icon that read as
            // something missing. The pill fits what has been said.
            let label = Self.label(text, font: Self.textFont, color: .labelColor)
            let slot = NSStackView(views: [label, Self.caret(alpha: 1)])
            slot.orientation = .horizontal
            slot.alignment = .centerY
            slot.spacing = 3
            slot.translatesAutoresizingMaskIntoConstraints = false
            return slot
        }
    }

    private static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        return field
    }

    /// A hairline, still. It never blinks: a blinking caret would make
    /// the band a text field, and the band must never look like a thing
    /// to click into.
    private static func caret(alpha: CGFloat) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 1.5),
            view.heightAnchor.constraint(equalToConstant: 18),
        ])
        return view
    }

    private func present() {
        placing = true
        panel.setFrame(frameForContent(), display: true)
        placing = false
        panel.orderFrontRegardless()
    }

    /// The glass for what it holds: the row's width and height alone, or
    /// the keys' above them. Its centre and its foot stay where the pill
    /// is, so growing never moves the row.
    func frameForContent() -> NSRect {
        root.layoutSubtreeIfNeeded()
        var size = root.fittingSize
        if keys == nil { size.height = Self.height }
        size.width = min(max(size.width, 160), 1100)
        let rowSize = NSSize(width: size.width, height: Self.height)
        let home = Self.home(for: rowSize)
        // Home plus the hand's displacement, kept on the screen: a pill
        // dragged to an edge on one display must not vanish on a smaller
        // one.
        let visible = ActivePolicy.presentationFrame
        var origin = NSPoint(x: home.x + offset.x, y: home.y + offset.y)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return NSRect(origin: origin, size: size)
    }
}
