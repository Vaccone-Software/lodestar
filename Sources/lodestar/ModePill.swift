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
        case scroll, click, select, editor
        /// A launch that is taking time: stands while the window is awaited.
        case opening

        var symbol: String {
            switch self {
            case .opening: return "arrow.up.forward.app"
            case .scroll: return "arrow.up.and.down"
            case .click: return "cursorarrow.click.2"
            case .select: return "character.cursor.ibeam"
            case .editor: return "text.badge.checkmark"
            }
        }

        var word: String {
            switch self {
            case .opening: return "Opening"
            case .scroll: return "Scroll"
            case .click: return "Click"
            case .select: return "Select"
            case .editor: return "Editor"
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
        /// A key the lens answers to, said beside it: the editor's ⏎ lit
        /// over every fix it shows ("Fix all 3"), and ⌫ quiet once they
        /// have landed ("Undo").
        var offer: Offer? = nil

        static func == (lhs: State, rhs: State) -> Bool {
            lhs.mode == rhs.mode && lhs.app == rhs.app && lhs.listening == rhs.listening
                && lhs.text == rhs.text && lhs.anchored == rhs.anchored && lhs.icon === rhs.icon
                && lhs.offer == rhs.offer
        }
    }

    struct Offer: Equatable {
        var key: String
        var words: String
        var lit: Bool
    }

    /// What the pill draws, pure, so a stage can read the composition
    /// instead of pixels.
    enum Piece: Equatable {
        case symbol(String), modeWord(String), caret, text(String), anchored(String), appWord(String), appIcon
        case offer(Offer)
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
        if let offer = state.offer { pieces.append(.offer(offer)) }
        pieces.append(.appWord(state.app))
        if state.icon != nil { pieces.append(.appIcon) }
        return pieces
    }

    // MARK: - Proportion

    /// The pill is 44 tall and fully round: its ends are the surface
    /// radius, 22. Wings stand a section apart; a glyph stands a part from
    /// its own word.
    static let height: CGFloat = BarTheme.pillHeight
    static let inset = Grid.section
    static let wingGap = Grid.section
    static let wordGap = Grid.part
    /// The band's home: the guide's, a little above the bottom edge.
    static let rise: CGFloat = 96
    static let iconSize = BarTheme.symbolSize
    /// The glass is never narrower than this, nor wider than that.
    static let leastWidth: CGFloat = 160
    static let mostWidth: CGFloat = 1100

    /// The hand's words, upright: the italic was tried and did not look
    /// right on the glass. Size and weight set them apart from the wings.
    static let textRole = BarTheme.Role.typed

    // MARK: - Surface

    private let panel: NSPanel
    private let root = AppearanceRoot()
    /// The pill recedes when left alone (design/06-eye-comfort.md): its ink
    /// to 5.5 to 1 and its quiet ink to 4.5 to 1 after twenty seconds without
    /// attention, back at once on the pointer, a key or a change of state.
    let recess = Recess()
    private var hover: RecessHover?
    private var content: NSStackView?
    private(set) var state: State?
    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.paneFrame }
    #if DEBUG
    /// What the pill is drawn in, for the tests that hold its receding.
    var drawnRoot: NSView { root }
    #endif
    /// Where the hand put the pill, as a displacement from its home, so
    /// a dragged pill comes back where it was left for the rest of the
    /// session. Zero until dragged; the home is the guide's.
    private(set) var offset = NSPoint.zero
    private var moveObserver: Any?
    private var placing = false

    init() {
        panel = Ceramic.makePanel(level: .statusBar, takesKeys: false)
        SoftShadow.host(root, in: panel, cornerRadius: BarTheme.surfaceRadius)
        _ = Ceramic.installPane(in: root, cornerRadius: BarTheme.surfaceRadius)
        // Draggable by its glass, the way the coach's chip is: one home by
        // default, and a remembered displacement once the hand moves it.
        Movable.enable(panel)
        recess.onChange = { [weak self] in self?.root.redrawAll() }
        hover = RecessHover(root, recess: recess)
        // A change of look changes every word's weight, and the words' width
        // with it: the glass is fitted to them again.
        root.onAppearance = { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.present()
        }
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
        remember(origin: panel.paneFrame.origin)
    }

    func remember(origin: NSPoint) {
        let home = Self.home(for: panel.paneFrame.size)
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
        recess.touch()
    }

    func hide() {
        recess.stop()
        state = nil
        keys?.removeFromSuperview()
        keys = nil
        keyEdges = []
        panel.orderOut(nil)
    }

    // MARK: - The keys

    /// The lens's keys, above the row, in the pill's own glass. The row
    /// never moves: the glass takes room for the keys at once, upward and
    /// outward, and the keys are there with it.
    private var keys: NSView?
    /// The edges that ask the glass to be big enough for the keys. Taken
    /// off before the glass shrinks, or the departing keys would still
    /// hold it wide.
    private var keyEdges: [NSLayoutConstraint] = []
    var keysShown: Bool { keys != nil }

    func toggleKeys(_ sections: [CheatSheet.Section]) {
        if keysShown { hideKeys() } else { showKeys(sections) }
    }

    func showKeys(_ sections: [CheatSheet.Section]) {
        guard panel.isVisible, let content else { return }
        recess.touch()
        keys?.removeFromSuperview()
        let columns = CheatSheet.columns(sections)
        root.addSubview(columns)
        // Laid out once at their own width, centred on the row and standing
        // on it, so nothing inside the glass moves or reflows when it
        // takes its new size. The edges that ask the glass to be big
        // enough sit below the window-size threshold: above it AppKit
        // would size the window to them itself, ahead of the placement,
        // and the row would sit off centre. They still decide the
        // fitting size the placement takes.
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
        // The glass moves to its end frame; that is placement, not a drag.
        placing = true
        KeysSheet.open(panel, to: SoftShadow.outset(frameForContent())) { [weak self] in self?.placing = false }
    }

    func hideKeys() {
        guard let going = keys else { return }
        recess.touch()
        keys = nil
        NSLayoutConstraint.deactivate(keyEdges)
        keyEdges = []
        placing = true
        KeysSheet.close(panel, to: SoftShadow.outset(frameForContent()), removing: going) { [weak self] in self?.placing = false }
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
            view.contentTintColor = recess.ink
            view.setContentHuggingPriority(.required, for: .horizontal)
            return view
        case .modeWord(let word):
            return Self.label(word, role: .body, color: recess.ink)
        case .offer(let offer):
            // The pill's one light, when the offer is ⏎: the key, lit.
            return Keycaps.line([.init([offer.key], offer.words, lit: offer.lit, quiet: !offer.lit)])
        case .appWord(let word):
            return Self.label(word, role: .body, color: recess.quietInk)
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
            let label = Self.label(word, role: Self.textRole, color: recess.ink)
            let dot = Self.label("·", role: .body, color: recess.quietInk)
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
            let label = Self.label(text, role: Self.textRole, color: recess.ink)
            let slot = NSStackView(views: [label, Self.caret(alpha: 1)])
            slot.orientation = .horizontal
            slot.alignment = .centerY
            slot.spacing = Grid.tight
            slot.translatesAutoresizingMaskIntoConstraints = false
            return slot
        }
    }

    private static func label(_ text: String, role: BarTheme.Role, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.setRole(role)
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
        let view = ToneView(fill: BarTheme.inkAt(alpha))
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: BarTheme.caretWidth),
            view.heightAnchor.constraint(equalToConstant: BarTheme.bodyCaretHeight),
        ])
        return view
    }

    private func present() {
        placing = true
        panel.setPaneFrame(frameForContent(), display: true)
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
        // Whole points: the window lands on them anyway, and a width of
        // words in the sans is rarely one, so a pill sized to its text that
        // did not round up would cut the last letter by a fraction.
        size.width = min(max(size.width.rounded(.up), Self.leastWidth), Self.mostWidth)
        size.height = size.height.rounded(.up)
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
