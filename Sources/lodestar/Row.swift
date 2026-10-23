import AppKit
import LodestarCore

/// The row contract (design/13-row.md): every list line Lodestar draws is one
/// of four. A **row** (48, or 52 with a line beneath) leads with what it is,
/// an app's icon, and trails with its keys, the acting key last. A **setting**
/// (at least 48, growing with its detail) leads with its letter, a key. A
/// **line** (32) is a menu's: touching, 8 inside its menu, a dot column or a
/// symbol leading. A **legend** (24, a key's height) is the reverse of a row:
/// its keys first, then what they do, 8 apart. The heights and gaps are named
/// in Geometry.swift; the views the four are made of are here.
enum Row {
    /// Detail is meta in quiet ink, its parts joined by this; a path by `pathSeparator`.
    static let detailSeparator = " · "
    static let pathSeparator = " › "

    /// Detail's parts as one line, the empty ones left out.
    static func detail(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: detailSeparator)
    }

    /// A path of names as one line.
    static func path(_ names: [String]) -> String {
        names.filter { !$0.isEmpty }.joined(separator: pathSeparator)
    }
}

// MARK: - The dot

/// The one dot: drawn, 7 across, round. Ink where it marks the current choice
/// or your own setting, quiet where it marks a running app. Never a glyph
/// (a "●" set in a font is a different size in every font and look).
final class RowDot: NSView {
    enum Tone: Equatable {
        case ink, quiet
    }

    let tone: Tone

    init(_ tone: Tone) {
        self.tone = tone
        super.init(frame: NSRect(x: 0, y: 0, width: BarTheme.dotDiameter, height: BarTheme.dotDiameter))
        wantsLayer = true
        layer?.cornerRadius = BarTheme.dotRadius
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: BarTheme.dotDiameter, height: BarTheme.dotDiameter) }

    /// The colour as it is drawn now, for the tests.
    var fill: NSColor { tone == .ink ? BarTheme.ink : BarTheme.secondaryColor }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Ceramic.resolved(fill, in: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// A line's dot column: 16 wide, the dot centred in it when there is one, so
/// the words of a line stand in one column whether or not it has a dot.
final class DotColumn: NSView {
    private let dot: RowDot

    init(marked: Bool, tone: RowDot.Tone = .ink) {
        dot = RowDot(tone)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        dot.isHidden = !marked
        addSubview(dot)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: BarTheme.dotColumnWidth),
            heightAnchor.constraint(equalToConstant: BarTheme.dotDiameter),
            dot.centerXAnchor.constraint(equalTo: centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    var marked: Bool {
        get { !dot.isHidden }
        set { dot.isHidden = !newValue }
    }

    /// The dot inside, for the tests.
    var mark: RowDot { dot }
}

// MARK: - Words beside a key

/// Words standing on a key's line (design/13-row.md, rule 4). A key is 24
/// tall: 21 of face and 3 of side, and its letter is centred on the face. A
/// text field centred on the key's whole frame stands 1.5 points too low, and
/// one that is centred only by its line box shares no baseline with a lowercase
/// legend (an x-height centred on the face is a point above a cap height
/// centred on it). So words beside a key are set on the key's line by their
/// baseline:
/// - words at the legend's size (meta, 13) share the baseline of the legend
///   of the key they follow, whatever its band;
/// - larger words, and words beside no key, stand with their capital height
///   centred on the face, as a legend of capitals does.
/// The view is a key's height, aligned by its face as a key is, so a row that
/// centres it centres the face.
final class KeyWords: NSView {
    let label: NSTextField
    let role: BarTheme.Role
    /// The legend of the key these words follow, when there is one.
    let legend: String?
    private let size = KeySize.standard

    init(_ text: String, role: BarTheme.Role = .meta, color: NSColor = BarTheme.secondaryColor,
         following legend: String? = nil, truncates: Bool = true) {
        self.role = role
        self.legend = legend
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.setRole(role)
        label.textColor = color
        label.lineBreakMode = truncates ? .byTruncatingTail : .byClipping
        label.translatesAutoresizingMaskIntoConstraints = true
        addSubview(label)
        setContentHuggingPriority(.required, for: .horizontal)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    var stringValue: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    var textColor: NSColor? {
        get { label.textColor }
        set { label.textColor = newValue }
    }

    override var alignmentRectInsets: NSEdgeInsets { size.hang }
    override var intrinsicContentSize: NSSize {
        NSSize(width: label.intrinsicContentSize.width, height: size.faceHeight)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        place()
    }

    /// Where the words' baseline stands, from the bottom of this view: the
    /// legend's baseline when the words share it, else the capital height
    /// centred on the face.
    var baseline: CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        let night = BarTheme.isNight(effectiveAppearance)
        let face = CGRect(x: 0, y: size.side, width: 0, height: size.faceHeight)
        if role == .meta, let legend, !legend.isEmpty {
            return KeyLegend.place(legend, size: size, night: night, in: face, scale: scale).origin.y
        }
        let capital = (label.font ?? role.font).capHeight
        return ((face.midY - capital / 2) * scale).rounded() / scale
    }

    private func place() {
        let frame = label.frame(forAlignmentRect: NSRect(x: 0, y: 0, width: bounds.width, height: label.intrinsicContentSize.height))
        let scale = window?.backingScaleFactor ?? 2
        let y = ((baseline - label.baselineOffsetFromBottom) * scale).rounded() / scale
        label.frame = NSRect(x: frame.minX, y: y, width: frame.width, height: frame.height)
    }

    /// The baseline as drawn now, in this view's coordinates, for the tests.
    var drawnBaseline: CGFloat { label.frame.minY + label.baselineOffsetFromBottom }
}

// MARK: - A row

/// A row of a bar, a card or a list in a room: what it is leads, how to reach
/// it trails. Its parts, left to right:
/// - the **lead**, an app's icon (32 in a bar, 24 in a card) or nothing;
/// - the **title** and what follows it on its line (a dot, a quiet word),
///   12 from the lead; the **detail** (meta, quiet, one line cut at the tail)
///   2 under the title;
/// - the **trailing** parts, 8 apart, the acting key last.
/// Words and icons stand 12 inside the row's edge, and the lead, the title
/// and the trailing parts are centred on the title's first line, however many
/// lines of detail follow, so a key stands with its face on the title's line.
/// A row is 48 tall, or 52 with a line beneath, and is the slab when chosen
/// (design/11-slab.md): its content is the other look's.
class ListRow: SlabRow {
    /// The title, and what stands after it on its line.
    let titleLine = NSStackView()
    let title = NSTextField(labelWithString: "")
    /// Meta in quiet ink under the title; hidden while it is empty.
    let detail = NSTextField(labelWithString: "")
    /// The parts at the trailing edge, 8 apart, the acting key last. A hidden
    /// part takes no room.
    let trailing = NSStackView()
    private let block = NSStackView()
    private var leading: NSLayoutConstraint!
    private var leadLeading: NSLayoutConstraint?
    private var toTrailing: NSLayoutConstraint!
    private var toEdge: NSLayoutConstraint!
    private(set) var lead: NSView?

    /// `titleRole` is the title (18) in a bar and the label (16 medium) in a
    /// room or a card.
    init(height: CGFloat, titleRole: BarTheme.Role = .title) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setupSlab()
        heightAnchor.constraint(equalToConstant: height).isActive = true

        title.setRole(titleRole)
        title.textColor = BarTheme.ink
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setRole(.meta)
        detail.textColor = BarTheme.secondaryColor
        detail.lineBreakMode = .byTruncatingTail
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.isHidden = true

        titleLine.orientation = .horizontal
        titleLine.alignment = .centerY
        titleLine.spacing = Grid.close
        titleLine.addArrangedSubview(title)
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = BarTheme.detailGap
        block.translatesAutoresizingMaskIntoConstraints = false
        block.addArrangedSubview(titleLine)
        block.addArrangedSubview(detail)
        addSubview(block)

        trailing.orientation = .horizontal
        trailing.alignment = .centerY
        trailing.spacing = Grid.close
        trailing.translatesAutoresizingMaskIntoConstraints = false
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(trailing)

        leading = block.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Grid.part)
        toTrailing = block.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -Grid.part)
        toEdge = block.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Grid.part)
        NSLayoutConstraint.activate([
            leading,
            block.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Grid.part),
            trailing.centerYAnchor.constraint(equalTo: title.centerYAnchor),
        ])
        refreshTrailing()
    }

    required init?(coder: NSCoder) { nil }

    /// The lead: an icon, centred on the title's first line, 12 inside the row
    /// and 12 before the words.
    func setLead(_ view: NSView?) {
        lead?.removeFromSuperview()
        leadLeading = nil
        lead = view
        leading.isActive = false
        if let view {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            leadLeading = view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Grid.part)
            leading = block.leadingAnchor.constraint(equalTo: view.trailingAnchor, constant: Grid.part)
            NSLayoutConstraint.activate([leadLeading!, view.centerYAnchor.constraint(equalTo: title.centerYAnchor)])
        } else {
            leading = block.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Grid.part)
        }
        leading.isActive = true
    }

    /// The trailing parts, in the order they read: the acting key last.
    func setTrailing(_ views: [NSView]) {
        for view in trailing.arrangedSubviews { trailing.removeArrangedSubview(view); view.removeFromSuperview() }
        for view in views { trailing.addArrangedSubview(view) }
        refreshTrailing()
    }

    /// The title ends at the trailing parts when any is shown, and at the row's
    /// edge when none is: a column with nothing in it takes no room. Called
    /// when a part is shown or hidden.
    func refreshTrailing() {
        let shown = trailing.arrangedSubviews.contains { !$0.isHidden }
        toTrailing.isActive = shown
        toEdge.isActive = !shown
    }

    /// The detail line: empty hides it, and the row stands on its title alone.
    var detailText: String {
        get { detail.stringValue }
        set {
            if detail.stringValue != newValue { detail.stringValue = newValue }
            detail.isHidden = newValue.isEmpty
        }
    }
}

/// An app's icon as a row leads with it: 32 in a bar, 24 in a card.
enum RowIcon {
    static func view(_ image: NSImage?, size: CGFloat = BarTheme.appIconSize) -> NSImageView {
        let view = NSImageView(image: image ?? NSImage())
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: size),
            view.heightAnchor.constraint(equalToConstant: size),
        ])
        return view
    }

    /// A breath's apps: two icons of a card's size, the second over the first by 6.
    static func overlapped(_ images: [NSImage]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = -BarTheme.titleIconOverlap
        for image in images.prefix(2) { stack.addArrangedSubview(view(image, size: BarTheme.titleIconSize)) }
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }
}

// MARK: - A line

/// A line of a menu: 32 tall, touching the next, 8 inside its menu, so a
/// chosen line's slab rounds at 22 - 8 = 14. It leads with a dot column (16
/// wide, the dot centred in it when the line is the current choice) or a
/// symbol (16), 12 inside the line, then its words in the body, 12 after the
/// lead, cut at the tail; its parts at the trailing edge are 8 apart, a key
/// last. The line is laid by its parent's frame or constraints, never by a
/// height of its own.
class ListLine: SlabRow {
    let label = NSTextField(labelWithString: "")
    let trailing = NSStackView()
    /// How far words and icons stand inside the line: 12. A guide's lines
    /// are never chosen and stand on their card's own inset, so they take none.
    let padding: CGFloat
    private var lead: NSView?
    private var leading: NSLayoutConstraint!
    private var toTrailing: NSLayoutConstraint!
    private var toEdge: NSLayoutConstraint!

    init(frame: NSRect = .zero, padding: CGFloat = Grid.part) {
        self.padding = padding
        super.init(frame: frame)
        setupSlab()
        radius = BarTheme.lineRadius
        label.setRole(.body)
        label.textColor = BarTheme.ink
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        trailing.orientation = .horizontal
        trailing.alignment = .centerY
        trailing.spacing = Grid.close
        trailing.translatesAutoresizingMaskIntoConstraints = false
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(trailing)
        leading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding)
        toTrailing = label.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -Grid.part)
        toEdge = label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -padding)
        NSLayoutConstraint.activate([
            leading,
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refreshTrailing()
    }

    required init?(coder: NSCoder) { nil }

    /// The line's lead: a dot column or a symbol, 12 inside, the words 12 after.
    func setLead(_ view: NSView?) {
        lead?.removeFromSuperview()
        lead = view
        leading.isActive = false
        if let view {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            leading = label.leadingAnchor.constraint(equalTo: view.trailingAnchor, constant: Grid.part)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
                view.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        } else {
            leading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding)
        }
        leading.isActive = true
    }

    func setTrailing(_ views: [NSView]) {
        for view in trailing.arrangedSubviews { trailing.removeArrangedSubview(view); view.removeFromSuperview() }
        for view in views { trailing.addArrangedSubview(view) }
        refreshTrailing()
    }

    func refreshTrailing() {
        let shown = trailing.arrangedSubviews.contains { !$0.isHidden }
        toTrailing.isActive = shown
        toEdge.isActive = !shown
    }

    /// A symbol as a line leads with it: 16, in the ink.
    static func symbol(_ name: String, tint: NSColor = BarTheme.ink) -> NSImageView {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(BarTheme.symbol) ?? NSImage()
        let view = NSImageView(image: image)
        view.contentTintColor = tint
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: BarTheme.symbolSize),
            view.heightAnchor.constraint(equalToConstant: BarTheme.symbolSize),
        ])
        return view
    }
}
