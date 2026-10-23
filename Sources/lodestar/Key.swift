import AppKit
import CoreText

/// The key contract (design/10-key.md): the one thing only Lodestar has. A
/// key is drawn wherever Lodestar asks the hand to press something: a face
/// on a side, its legend the key as typed, as wide as what it says. Every
/// surface draws a `Key`; none draws a key of its own.

// MARK: - Sizes and states

/// The two sizes a key comes in, each a face on a side.
enum KeySize: Equatable {
    /// Every key in a row, a footer, a guide, a card: 24 tall, 21 of face on 3 of side.
    case standard
    /// The peek's numerals, the meeting's countdown: 36 tall, 31 on 5.
    case large

    var height: CGFloat { self == .standard ? Ceramic.Side.control + faceHeight : Ceramic.Side.large + faceHeight }
    var side: CGFloat { self == .standard ? Ceramic.Side.control : Ceramic.Side.large }
    var faceHeight: CGFloat { self == .standard ? 21 : 31 }
    /// The legend's role: a key's letter, or a figure read across the screen.
    var role: BarTheme.Role { self == .standard ? .key : .largeFigure }
}

/// What a key is for the hand right now. Instant: nothing animates.
enum KeyState: Equatable {
    /// A key you can press.
    case resting
    /// The one key to press next: the orange.
    case lit
    /// While it is down: the side gives up the rest and the face follows.
    case pressed
    /// Shown but not pressable now, or disabled: no face, a hairline.
    case quiet
}

// MARK: - The legend

/// Where a legend sits on a key's face, and how wide it makes the key. All
/// of it comes from the font's own metrics and the legend's ink, never from
/// a text field's line box.
enum KeyLegend {
    /// What a legend is centred on, vertically.
    enum Band: Equatable {
        /// No capitals, digits or symbols: the x-height band.
        case xHeight
        /// Anything else: the cap-height band.
        case capHeight
        /// Punctuation alone: its own ink, because at the letters' size it is a speck.
        case ink
    }

    /// Punctuation alone on a key (`'`, `` ` ``, `;`, `/`, `.`): ASCII, no
    /// letter, no digit.
    static func isPunctuation(_ legend: String) -> Bool {
        !legend.isEmpty && legend.allSatisfy { $0.isASCII && !$0.isLetter && !$0.isNumber && !$0.isWhitespace }
    }

    static func band(of legend: String) -> Band {
        if isPunctuation(legend) { return .ink }
        return !legend.isEmpty && legend.allSatisfy({ $0.isLetter && $0.isLowercase }) ? .xHeight : .capHeight
    }

    private static func line(_ legend: String, font: NSFont) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: legend, attributes: [.font: font]))
    }

    private static func ink(_ line: CTLine) -> CGRect { CTLineGetImageBounds(line, nil) }

    /// The font a legend is drawn in: the key's role in the look, and for a
    /// punctuation legend the size on the type scale whose ink comes
    /// nearest the role's cap height, so a tick or a dot is seen.
    static func font(for legend: String, size: KeySize, night: Bool) -> NSFont {
        measure(legend, size: size, night: night).font
    }

    struct Measure {
        let font: NSFont
        /// The legend's ink, relative to the point it is drawn from.
        let ink: CGRect
    }

    private static var cache: [String: Measure] = [:]
    private static let lock = NSLock()

    static func measure(_ legend: String, size: KeySize, night: Bool) -> Measure {
        let id = "\(legend)|\(size == .standard ? "s" : "l")|\(night ? "n" : "d")"
        lock.lock()
        if let hit = cache[id] { lock.unlock(); return hit }
        lock.unlock()
        let base = size.role.font(night: night)
        var font = base
        if isPunctuation(legend) {
            let weight = size.role.weight(night: night)
            let candidates = [BarTheme.Scale.meta, BarTheme.Scale.body, BarTheme.Scale.title, BarTheme.Scale.input]
                .filter { $0 >= base.pointSize }
            let target = base.capHeight
            var best = (distance: CGFloat.greatestFiniteMagnitude, font: base)
            for points in candidates {
                let candidate = points == base.pointSize ? base : NSFont.systemFont(ofSize: points, weight: weight)
                let distance = abs(ink(line(legend, font: candidate)).height - target)
                if distance < best.distance { best = (distance, candidate) }
            }
            font = best.font
        }
        let made = Measure(font: font, ink: ink(line(legend, font: font)))
        lock.lock()
        cache[id] = made
        lock.unlock()
        return made
    }

    /// A key's width: its legend's ink and a grid step at each side, never
    /// narrower than the key is tall, rounded up to a whole point.
    static func width(of legend: String, size: KeySize, night: Bool) -> CGFloat {
        let inkWidth = measure(legend, size: size, night: night).ink.width
        return max(size.height, ceil(inkWidth) + Grid.close * 2)
    }

    /// Where a legend is drawn on a face.
    struct Placement {
        let font: NSFont
        let line: CTLine
        /// The point CoreText draws from: the legend's baseline origin.
        let origin: CGPoint
        /// The band the legend is centred on, bottom to top, where it is drawn.
        let band: ClosedRange<CGFloat>
        /// The legend's ink, where it is drawn.
        let ink: CGRect
    }

    /// Centred on `face` across by its ink, and up and down by its band:
    /// the x-height or cap-height band from the font's metrics, or the
    /// ink itself for punctuation. Descenders never move it, so a row of
    /// keys shares a baseline. `scale` is the pixels to a point, so the
    /// baseline stands on a pixel and the letters stay crisp.
    static func place(_ legend: String, size: KeySize, night: Bool, in face: CGRect,
                      scale: CGFloat = 2) -> Placement {
        let font = measure(legend, size: size, night: night).font
        let line = line(legend, font: font)
        let ink = ink(line)
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let x = snap(face.midX - ink.midX)
        let y: CGFloat
        let range: ClosedRange<CGFloat>
        let kind = band(of: legend)
        switch kind {
        case .ink:
            y = snap(face.midY - ink.midY)
            range = (y + ink.minY)...(y + ink.maxY)
        case .xHeight, .capHeight:
            let height = kind == .xHeight ? font.xHeight : font.capHeight
            y = snap(face.midY - height / 2)
            range = y...(y + height)
        }
        return Placement(font: font, line: line, origin: CGPoint(x: x, y: y), band: range,
                         ink: ink.offsetBy(dx: x, dy: y))
    }

    /// What VoiceOver says for a legend.
    static func spoken(_ legend: String) -> String {
        let names: [Character: String] = [
            "⏎": "return", "↵": "return", "⌫": "delete", "⇧": "shift", "⌘": "command", "⌥": "option",
            "⌃": "control", "⇥": "tab", "↑": "up arrow", "↓": "down arrow", "←": "left arrow", "→": "right arrow",
        ]
        guard legend.count > 1 || legend.first.map({ names[$0] != nil }) == true else { return legend }
        var out: [String] = []
        var rest = Substring(legend)
        while let first = rest.first, let name = names[first] {
            out.append(name)
            rest = rest.dropFirst()
        }
        if !rest.isEmpty { out.append(String(rest)) }
        return out.joined(separator: " ")
    }
}

// MARK: - The key

/// A face on a visible side, with its legend on the face. Lit, it is a
/// piece of the mark: the accent, with the mark's brightest face for its
/// rim and its darkest for its side, and the letter in whichever ink reads
/// on it. Resting, a quiet cap; in clay, the pictures' pale keycap.
/// Pressed, its side falls to a point and the face follows it down, at
/// once. Quiet, it lies flat: no side and no fill, a hairline and the quiet
/// ink. Depth carries the importance, never a fade.
final class Key: NSView, CeramicDepth {
    let size: KeySize
    /// What the key says, as typed: `e`, `⌘K`, `esc`, `⏎`.
    var legend: String {
        didSet {
            guard legend != oldValue else { return }
            legendView.legend = legend
            setAccessibilityLabel(KeyLegend.spoken(legend))
            invalidateIntrinsicContentSize()
        }
    }
    /// A key laid over another app's window: opaque, hairlined, so it reads
    /// over any content. A hint is one.
    let overContent: Bool
    var state: KeyState { didSet { if state != oldValue { refresh() } } }
    /// What a pointer is doing to a key that can be clicked: it brightens
    /// under the pointer and stands down onto its side when pressed.
    private var pointer = Keycaps.CapState.resting
    let standing: Standing
    private let legendView: KeyLegendView

    init(_ legend: String, size: KeySize = .standard, state: KeyState = .resting, overContent: Bool = false) {
        self.size = size
        self.legend = legend
        self.state = state
        self.overContent = overContent
        standing = Standing(rest: size.side)
        legendView = KeyLegendView(legend: legend, size: size)
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: size.height))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.masksToBounds = false
        if let layer { standing.install(in: layer) }
        addSubview(legendView)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(KeyLegend.spoken(legend))
        frame.size.width = intrinsicContentSize.width
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    var lit: Bool {
        get { state == .lit }
        set { if newValue { state = .lit } else if state == .lit { state = .resting } }
    }

    var quiet: Bool {
        get { state == .quiet }
        set { if newValue { if state != .lit { state = .quiet } } else if state == .quiet { state = .resting } }
    }

    var depth: Ceramic.Depth { state == .quiet ? .flat : .standsUp(side: standing.side) }
    var drawnSide: CGFloat { standing.visibleSide }

    /// A key's width for a legend, in the look the Mac is in.
    static func width(of legend: String, size: KeySize = .standard) -> CGFloat {
        KeyLegend.width(of: legend, size: size, night: Tone.systemDark)
    }

    /// The key's width in the look it is drawn in.
    var width: CGFloat {
        KeyLegend.width(of: legend, size: size, night: BarTheme.isNight(effectiveAppearance))
    }

    override var intrinsicContentSize: NSSize { NSSize(width: width, height: size.height) }

    /// Where the legend is drawn, on the key's own coordinates, for the tests.
    var placement: KeyLegend.Placement {
        let face = standing.faceFrame
        return KeyLegend.place(legend, size: size, night: BarTheme.isNight(effectiveAppearance), in: face,
                               scale: window?.backingScaleFactor ?? 2)
    }

    /// The legend's font as it is drawn now.
    var legendFont: NSFont { placement.font }

    /// The face as it is drawn now: the whole of a standing key's, and a
    /// quiet key's hairline outline.
    var face: CGRect { standing.faceFrame }

    /// The legend's colour as it is drawn now.
    var legendColor: NSColor { legendView.color }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fit()
    }

    override func layout() {
        super.layout()
        fit()
    }

    private func fit() {
        standing.fit(bounds, radius: BarTheme.controlRadius)
        legendView.frame = standing.faceFrame
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidateIntrinsicContentSize()
        refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        legendView.needsDisplay = true
    }

    /// Refill for the pointer, as `Keycaps.CapGroup` does for its caps.
    func fill(_ next: Keycaps.CapState) {
        guard next != pointer else { return }
        pointer = next
        refresh()
    }

    func refresh() {
        let flat = state == .quiet
        standing.flat = flat
        standing.pressed = state == .pressed || pointer == .pressed
        if flat {
            // Shown, not pressable: no side, no face; the pane shows. Over
            // another app's window the pane's own step stands behind it, or
            // the content would run through the letter.
            standing.paint(in: self, face: overContent ? BarTheme.paneFill : nil, side: nil, rim: nil,
                           edge: BarTheme.hairline)
            legendView.color = BarTheme.secondaryColor
        } else {
            let lit = state == .lit
            standing.paint(in: self, face: BarTheme.face(lit: lit, state: pointer),
                           side: lit ? BarTheme.litSideFill : BarTheme.sideFill,
                           rim: lit ? BarTheme.litRimFill : BarTheme.rimFill,
                           edge: lit ? nil : (overContent ? BarTheme.hairline : BarTheme.faceEdge))
            legendView.color = lit ? BarTheme.onAccent : BarTheme.ink
        }
        // The legend stays on the face, wherever the face stands.
        legendView.frame = standing.faceFrame
        legendView.needsDisplay = true
    }
}

/// The legend, drawn on the face by CoreText from the font's metrics.
private final class KeyLegendView: NSView {
    var legend: String { didSet { needsDisplay = true } }
    let size: KeySize
    var color: NSColor = BarTheme.ink { didSet { needsDisplay = true } }

    init(legend: String, size: KeySize) {
        self.legend = legend
        self.size = size
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, !legend.isEmpty else { return }
        let placement = KeyLegend.place(legend, size: size, night: BarTheme.isNight(effectiveAppearance), in: bounds,
                                        scale: window?.backingScaleFactor ?? 2)
        context.saveGState()
        context.textMatrix = .identity
        context.setFillColor(color.cgColor)
        context.textPosition = placement.origin
        CTLineDraw(placement.line, context)
        context.restoreGState()
    }
}

// MARK: - Strokes: a sequence, a double tap

/// The keys of one gesture: one key per keystroke, 4 apart; a double tap is
/// one key and, 4 after it, `×2` in quiet ink at the meta size. Never a
/// chip reading "e p", and never two identical keys where one tapped twice
/// is meant. Keys that are not one sequence (alternatives, `h` `j` `k` `l`)
/// stand 8 apart, each a group of its own.
final class KeyStrokes: NSStackView {
    private(set) var caps: [Key] = []

    /// One sequence.
    convenience init(_ legends: [String], double: Bool = false, lit: Bool = false, quiet: Bool = false,
                     size: KeySize = .standard, overContent: Bool = false) {
        self.init(groups: [legends], double: double, lit: lit, quiet: quiet, size: size, overContent: overContent)
    }

    /// Sequences, 8 apart from each other; `double` taps the last key twice.
    init(groups: [[String]], double: Bool = false, lit: Bool = false, quiet: Bool = false,
         size: KeySize = .standard, overContent: Bool = false) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = Grid.tight
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        for group in groups {
            for legend in group {
                let key = Key(legend, size: size, state: quiet ? .quiet : (lit ? .lit : .resting),
                              overContent: overContent)
                caps.append(key)
                addArrangedSubview(key)
            }
            if let last = arrangedSubviews.last { setCustomSpacing(Grid.close, after: last) }
        }
        if let last = arrangedSubviews.last { setCustomSpacing(Grid.tight, after: last) }
        if double {
            let times = NSTextField(labelWithString: "×2")
            times.setRole(.meta)
            times.textColor = BarTheme.secondaryColor
            times.setContentHuggingPriority(.required, for: .horizontal)
            addArrangedSubview(times)
        }
        setAccessibilityLabel(groups.map { $0.map(KeyLegend.spoken).joined(separator: " ") }
            .joined(separator: " or ") + (double ? " twice" : ""))
    }

    required init?(coder: NSCoder) { nil }

    var lit: Bool {
        get { caps.allSatisfy { $0.state == .lit } }
        set { for cap in caps { cap.lit = newValue } }
    }

    var quiet: Bool {
        get { caps.allSatisfy { $0.state == .quiet } }
        set { for cap in caps { cap.quiet = newValue } }
    }
}

// MARK: - Hints and marks: keys over another app's window

/// Marks laid over another app's window, drawn as the one key: the pale cap
/// on its side, with a hairline so it reads over any app, light or dark. A
/// hint is a sequence, one key per keystroke, 4 apart; letters the hand has
/// already typed take the quiet state, and the ones still to press keep the
/// key's own. Built by hand, without layout, because a window of click
/// hints can be four hundred of them at once.
enum KeyMark {
    static let height: CGFloat = KeySize.standard.height
    /// The peek's numerals: the same key at a size read across the screen.
    static let peekHeight: CGFloat = KeySize.large.height
    /// The neutral hairline from a displaced tag to its word.
    static var connector: NSColor { BarTheme.inkAt(Tone.systemDark ? 0.38 : 0.35) }
    /// The underline's weight: the editor's line, select's matches, a held span.
    static let underline: CGFloat = 2.5
    /// The anchor's and the held span's heavier line.
    static let heavyUnderline: CGFloat = 3.5

    /// How many of `text`'s letters the hand has typed: the label compares
    /// to what was typed without case; a label the typed letters do not
    /// begin has none done.
    static func done(_ text: String, typed: String) -> Int {
        !typed.isEmpty && text.lowercased().hasPrefix(typed.lowercased()) ? typed.count : 0
    }

    /// A hint: one key per letter of `text`, 4 apart, origin at zero, the
    /// letters typed so far quiet. A view of plain frames, no layout.
    static func key(_ text: String, typed: String = "") -> NSView {
        let done = done(text, typed: typed)
        let keys = text.enumerated().map { offset, letter in
            Key(String(letter), state: offset < done ? .quiet : .resting, overContent: true)
        }
        return run(keys)
    }

    /// The peek's figure: one large key, centred.
    static func peek(_ text: String) -> NSView {
        run([Key(text, size: .large, overContent: true)])
    }

    /// Keys laid in a row, 4 apart, at their own widths.
    private static func run(_ keys: [Key]) -> NSView {
        let height = keys.map(\.size.height).max() ?? 0
        let group = NSView(frame: .zero)
        var x: CGFloat = 0
        for key in keys {
            key.translatesAutoresizingMaskIntoConstraints = true
            key.frame = NSRect(x: x, y: 0, width: key.width, height: key.size.height)
            group.addSubview(key)
            x += key.frame.width + Grid.tight
        }
        group.frame = NSRect(x: 0, y: 0, width: max(0, x - Grid.tight), height: height)
        return group
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
        let width = ceil(pad + key.frame.width + Grid.close + label.frame.width + Grid.close)
        let tag = ObjectSurface(radius: radius)
        tag.frame = NSRect(x: 0, y: 0, width: width, height: height)
        Ceramic.installPane(in: tag, cornerRadius: radius)
        key.frame.origin = NSPoint(x: pad, y: pad)
        tag.addSubview(key)
        label.frame.origin = NSPoint(x: key.frame.maxX + Grid.close, y: ((height - label.frame.height) / 2).rounded())
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
