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
/// band in italic: the symbol and the icon never move, and the fold is
/// the only change. No motion anywhere, because a mode indicator that
/// arrives late is late.
///
/// Every dimension is the height over a power of φ, so one number sets
/// the object. Floating at the guide's home, where the eye already is.
final class ModePill {
    enum Mode: Equatable {
        case scroll, click, select

        var symbol: String {
            switch self {
            case .scroll: return "arrow.up.and.down"
            case .click: return "cursorarrow.click.2"
            case .select: return "character.cursor.ibeam"
            }
        }

        var word: String {
            switch self {
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

        static func == (lhs: State, rhs: State) -> Bool {
            lhs.mode == rhs.mode && lhs.app == rhs.app && lhs.listening == rhs.listening
                && lhs.text == rhs.text && lhs.icon === rhs.icon
        }
    }

    /// What the pill draws, pure, so a stage can read the composition
    /// instead of pixels.
    enum Piece: Equatable {
        case symbol(String), modeWord(String), caret, text(String), appWord(String), appIcon
    }

    static func layout(for state: State) -> [Piece] {
        if let text = state.text {
            return [.symbol(state.mode.symbol), .text(text), state.icon == nil ? .appWord(state.app) : .appIcon]
        }
        var pieces: [Piece] = [.symbol(state.mode.symbol), .modeWord(state.mode.word)]
        if state.listening { pieces.append(.caret) }
        pieces.append(.appWord(state.app))
        if state.icon != nil { pieces.append(.appIcon) }
        return pieces
    }

    // MARK: - Proportion

    static let phi: CGFloat = 1.618_033_988_75
    static let height: CGFloat = 44
    static var radius: CGFloat { height / (phi * phi) }
    static var inset: CGFloat { height / phi }
    static var wingGap: CGFloat { height / phi }
    static var wordGap: CGFloat { height / (phi * phi * phi) }
    /// The band's home: the guide's, a little above the bottom edge.
    static let rise: CGFloat = 96
    /// Room reserved for the hand's words, so the outline never changes
    /// with a keystroke. Wide enough for the queries uniqueness commits
    /// on; a longer one grows the slot, which is rare by construction.
    static let textSlot: CGFloat = 140
    static let iconSize: CGFloat = 16

    static var textFont: NSFont {
        NSFontManager.shared.convert(NSFont.systemFont(ofSize: 17, weight: .medium),
                                     toHaveTrait: .italicFontMask)
    }

    // MARK: - Surface

    private let panel: NSPanel
    private let root = NSView()
    private var content: NSStackView?
    private(set) var state: State?
    var isVisible: Bool { panel.isVisible }

    init() {
        panel = Glass.makePanel(level: .statusBar)
        panel.ignoresMouseEvents = true
        panel.contentView = root
        _ = Glass.installBackdrop(in: root, cornerRadius: Self.radius)
    }

    func show(_ state: State) {
        if state == self.state, panel.isVisible { return }
        self.state = state
        build(state)
        present()
    }

    func hide() {
        state = nil
        panel.orderOut(nil)
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
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.inset),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        content = stack
    }

    /// A glyph sits close to its own word; wings stand apart from the
    /// center and from each other by the wing gap.
    private static func gapBefore(_ piece: Piece, after previous: Piece) -> CGFloat {
        switch (previous, piece) {
        case (.symbol, .modeWord), (.appWord, .appIcon): return wordGap
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
            let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            let image = NSImage(systemSymbolName: name, accessibilityDescription: state.mode.word)?
                .withSymbolConfiguration(configuration)
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
        case .text(let text):
            let label = Self.label(text, font: Self.textFont, color: .labelColor)
            let slot = NSStackView(views: [label, Self.caret(alpha: 1)])
            slot.orientation = .horizontal
            slot.alignment = .centerY
            slot.spacing = 3
            slot.translatesAutoresizingMaskIntoConstraints = false
            slot.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.textSlot).isActive = true
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
        root.layoutSubtreeIfNeeded()
        var size = root.fittingSize
        size.height = Self.height
        size.width = min(max(size.width, 160), 900)
        let visible = ActivePolicy.presentationFrame
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.minY + Self.rise,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }
}
