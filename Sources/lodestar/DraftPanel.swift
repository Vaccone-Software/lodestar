import AppKit
import LodestarCore

/// What the draft panel draws in one frame.
struct DraftView {
    let buffer: Draft.Buffer
    let mode: Draft.Mode
    /// The editor's own mode: visual and its line form draw a selection
    /// and say so on the register line.
    var editor: Vim.Mode = .normal
    var selection: Range<Int>? = nil
    /// The letters a pending find could land on, lit while the hand
    /// decides which one to name; the lights go out the moment it acts.
    var findTargets: [Int] = []
    /// The editor's marks, as UTF-16 ranges of the settled text: a thin
    /// line in the accent under each, drawn only with no ghost standing.
    var editorMarks: [NSRange] = []
    /// A command is half typed (an operator, a count, a find).
    var pending = false
    /// The recognizer's state while the speak door is open; nil when the
    /// mic was never asked for.
    let speech: SpeechState?
    /// The input device's name and its level, while listening.
    var input: String? = nil
    var level: Float = 0
    /// Every input the machine has, the one the system calls default, and
    /// the one chosen in the config (nil follows the system).
    var inputs: [String] = []
    var systemInput: String? = nil
    var chosenInput: String? = nil
    /// The mic is wanted: it writes, or would as soon as insert mode returns.
    var micOn = false
    /// Listening, and nothing but zeros has arrived for as long as a
    /// hand waits: the register line says so, because the meter's
    /// stillness is not a message.
    var silent = false
    /// Where ⏎ lands right now: the frontmost app, or the clipboard.
    let destination: (name: String, icon: NSImage?)?
    /// The origin field's text was pulled in, so ⏎ replaces it there.
    let replacing: Bool
    /// The clip door: the card being edited stands on the register line
    /// where the destination would, and there is no microphone.
    struct Card {
        let name: String
        let icon: NSImage?
        let detail: String
    }
    var card: Card? = nil
    /// The panel's width, chosen once at open from the text; nil is the
    /// draft's own.
    var width: CGFloat? = nil
    /// What the panel stands above — the strip's row of recents, while a
    /// card is open over it.
    var standsAbove: CGFloat = 0
    /// The whole text, or its last four lines: `zo` and `zc`, decided by
    /// the controller, never guessed here.
    var expanded = false
    /// Ink still drying: words the second ear or the intent pass may yet
    /// change, grey like the ghost until they are done.
    var wet: Range<Int>? = nil
    /// Words a pass rewrote, underlined quietly until the hand's next key.
    var revised: [Range<Int>] = []
}

/// The voice light: the panel's own top edge, lit in the accent while the
/// draft listens, spreading out from the middle as the voice gets louder
/// and curving down into the corners at its fullest. One flat stroke
/// along the glass's outline, no glow and no fade, so the level reads as
/// a length that can be seen from across the room.
///
/// It is the microphone's whole status, in three states: out while the
/// mic is turned off, a grey floor while it is wanted but not hearing
/// (opening, or failed, with the reason in the foot), the accent while
/// it hears (speak). Each asks something different of the hand, so each
/// looks different.
final class VoiceLight: NSView {
    enum State: Equatable {
        case off
        case waiting
        case listening(Float)
    }

    private let stroke = CAShapeLayer()
    /// What a silent room still shows, so a listening draft is never
    /// mistaken for a closed one.
    static let floor: CGFloat = 0.22
    /// How long a falling level takes to come down. A rising one arrives
    /// on the next frame: the voice leads, the light follows.
    static let release: CFTimeInterval = 0.35
    static let lineWidth: CGFloat = 2
    private(set) var length: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        stroke.fillColor = nil
        stroke.lineWidth = Self.lineWidth
        stroke.lineCap = .round
        stroke.strokeStart = 0.5
        stroke.strokeEnd = 0.5
        layer?.addSublayer(stroke)
        // The glyph it replaced was the one place VoiceOver could learn
        // the microphone's state; the light says it in words too. Never
        // announced: a screen reader speaking aloud would be dictated.
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel("Microphone")
        setAccessibilityValue("off")
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The light is drawn over everything and takes nothing: the mic
    /// toggle and the input menu sit under its view.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        stroke.frame = bounds
        stroke.path = Self.edge(in: bounds)
    }

    /// The top of the outline, from partway down the left corner, across,
    /// and down into the right one: symmetric, so the middle of the path
    /// is the middle of the edge and a length grows from there both ways.
    static func edge(in bounds: NSRect) -> CGPath {
        let inset = lineWidth / 2
        let r = BarTheme.glassRadius - inset
        let left = bounds.minX + inset, right = bounds.maxX - inset, top = bounds.maxY - inset
        let path = CGMutablePath()
        path.move(to: CGPoint(x: left, y: top - r))
        path.addArc(center: CGPoint(x: left + r, y: top - r), radius: r,
                    startAngle: .pi, endAngle: .pi / 2, clockwise: true)
        path.addLine(to: CGPoint(x: right - r, y: top))
        path.addArc(center: CGPoint(x: right - r, y: top - r), radius: r,
                    startAngle: .pi / 2, endAngle: 0, clockwise: true)
        return path
    }

    private(set) var state: State = .off

    /// Light the edge for a level from 0 to 1, or put it out with nil.
    func show(level: Float?) {
        show(level.map(State.listening) ?? .off)
    }

    /// A colour changes at once: grey becoming the accent is the
    /// moment to speak, and a cross-fade would blur the moment.
    private func paint(_ color: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stroke.strokeColor = color.cgColor
        CATransaction.commit()
    }

    func show(_ state: State) {
        self.state = state
        let target: CGFloat
        switch state {
        case .off:
            target = 0
            setAccessibilityValue("off")
        case .waiting:
            // The floor, in the quiet grey: wanted, not hearing.
            paint(BarTheme.secondaryColor)
            target = Self.floor
            setAccessibilityValue("not listening")
        case .listening(let level):
            paint(BarTheme.readableAccent)
            // Reduce Motion holds the light still at its whole length:
            // it still says listening, and nothing moves.
            target = Accessibility.reduceMotion()
                ? 1 : Self.floor + (1 - Self.floor) * CGFloat(max(0, min(1, level)))
            setAccessibilityValue("listening")
        }
        guard target != length else { return }
        let falling = target < length
        length = target
        CATransaction.begin()
        if falling, target > 0, !Accessibility.reduceMotion() {
            CATransaction.setAnimationDuration(Self.release)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        stroke.strokeStart = 0.5 - target / 2
        stroke.strokeEnd = 0.5 + target / 2
        CATransaction.commit()
    }
}

/// The draft's glass: bottom center, fixed in place, growing upward with
/// the text. Never key — the app under it keeps its cursor the whole
/// time — but it takes the mouse for two things on its register line:
/// the microphone, which toggles, and the input, which is a menu.
final class DraftPanel {
    let panel: NSPanel
    private let root = NSView()
    private let gate: PointerGate
    /// Where the glass is going: the surface's frame as last laid out,
    /// which a quick fold reaches a tenth of a second later.
    private var target: NSRect?
    /// A fold in motion, by generation, so a render that lands mid-way
    /// carries the motion on rather than fighting it.
    private var foldMotion = 0
    private var restaging = false
    /// How long the glass takes to fold or open: fast enough to read as
    /// sudden, long enough that the eye sees where the text went.
    static let foldSeconds: TimeInterval = 0.1
    private var backdrop: NSView?

    // The foot: made once, placed on every render, so a menu that is
    // open survives the next volatile word. It says where the words land
    // and which microphone hears them; whether it is hearing is the
    // light's to say.
    private let registerIcon = NSImageView()
    private let registerName = NSTextField(labelWithString: "")
    private let registerNote = NSTextField(labelWithString: "")
    private let inputButton = InputButton(frame: .zero)
    private let inputMenu = InputMenu()
    private var inputChoices: [InputMenu.Choice] = []
    private var inputChosen = 0
    /// The level, as the top edge's light.
    private let voiceLight = VoiceLight(frame: .zero)

    /// Whether the draft shows all of its text or the last four lines,
    /// as the view says: four lines from every door so the work behind
    /// stays in view, `zo` to open it whole, `zc` or the voice to fold
    /// it again.
    private(set) var expanded = false

    /// Internal so the tests can read the storage the screen reads: the
    /// find lights once shipped as background washes that vibrancy ate,
    /// and only a test against the rendered attributes catches that class
    /// of nothing-appears bug.
    let textView = NSTextView()
    private let scroll = NSScrollView()
    private let caret = NSView()
    /// The keys, when they are asked for. The draft carries no legend:
    /// every key it owns lives behind `lode ?`, like every other
    /// surface's, and the glass grows to hold them.
    private var keysView: NSView?
    private(set) var keysShown = false

    /// An input was chosen from the menu; nil is the system default.
    var onChooseInput: ((String?) -> Void)?

    private static let width: CGFloat = 720
    private static let margin: CGFloat = 22
    private static let padX: CGFloat = 22
    /// The foot, under the text: where the words land, and the mic.
    private static let footHeight: CGFloat = 40
    /// The air over the text, under the light.
    private static let padTop: CGFloat = 18
    /// Air between the text and the keys: the pill's own inset, so a
    /// draft holding its keys is spaced like a bar holding its keys. The
    /// foot's own air is the air under them.
    private static let keysAbove: CGFloat = ModePill.inset
    private static let minTextHeight: CGFloat = 58
    /// The lines a speaking draft holds.
    static let compactLines = 4
    /// The system's mono face: a block cursor in a proportional face is
    /// a fresh width on every character, `j` and `k` walk columns that
    /// lie, and a lit letter's semibold reflows the line. Mono makes all
    /// three constant — the advance survives the weight by design.
    private static let font = BarTheme.readingMono
    /// The find lights' weight: heavier than the text so a lit letter
    /// reads at a glance, and in the mono face the same width, so
    /// nothing reflows.
    private static let accentFont = BarTheme.readingMonoAccent
    /// The panel's ground, for the glyph a block cursor inverts: the
    /// equalizer scrim keeps every panel charcoal, whatever the material
    /// decided, so the ground is a known dark rather than a query.
    static var ground: NSColor { BarTheme.ground }
    /// Wet ink is the ghost's grey: grey can still change, ink is final.
    /// A third tone between them was tried and could not be told from
    /// settled text at a glance; which pass might still change a word is
    /// not the hand's question, only whether it is done.
    static var wetInk: NSColor { BarTheme.secondaryColor }

    var isVisible: Bool { panel.isVisible }

    init() {
        panel = Glass.makePanel(level: .statusBar)
        // A click on the foot must not make the draft key: ⏎'s paste goes
        // to the app that has the keyboard, which has to stay that app.
        panel.becomesKeyOnlyIfNeeded = true
        // The bars' edge and soft shadow, drawn by the window around the
        // glass rather than by the system.
        // The mouse reaches the foot's input menu, and only over the
        // glass. The panel never becomes key, so the app underneath
        // keeps its cursor.
        gate = SoftShadow.host(root, in: panel, cornerRadius: BarTheme.glassRadius)
        backdrop = Glass.installBackdrop(in: root, cornerRadius: BarTheme.glassRadius)

        registerName.font = BarTheme.rowLabelFont
        registerName.textColor = .labelColor
        registerName.lineBreakMode = .byTruncatingTail
        registerNote.font = BarTheme.secondaryFont
        registerNote.textColor = BarTheme.secondaryColor
        registerNote.lineBreakMode = .byTruncatingTail

        inputButton.onClick = { [weak self] in self?.toggleInputMenu() }
        inputMenu.owner = panel
        inputMenu.onChoose = { [weak self] device in self?.onChooseInput?(device) }


        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.font = Self.font
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder
        // AppKit pads a scroll view's top on its own, which offsets every
        // scroll by that much: the folded window cut a line at each end.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        // Every view here is placed by frame on each render; nothing may
        // opt into Auto Layout, or the first layout pass zeroes it.

        caret.wantsLayer = true
        caret.layer?.cornerRadius = BarTheme.hairlineRadius

        // The caret sits under the text: a block cursor is a solid plate
        // with the glyph inverted over it, the way every terminal draws
        // one, and the plate has to be behind the glyph for that.
        for view in [registerIcon, registerName, registerNote, inputButton,
                     caret, scroll, voiceLight] {
            root.addSubview(view)
        }
        // The panel's frame animates when the keys arrive, and the draft
        // places every view by hand rather than by constraint. These
        // masks are what carries the layout through an animation that no
        // render runs inside: the foot and the keys hold the bottom edge,
        // the text takes the room that opens, the light rides the top.
        root.autoresizesSubviews = true
        backdrop?.autoresizingMask = [.width, .height]
        for view in [registerIcon, registerName, registerNote, inputButton] {
            view.autoresizingMask = [.maxYMargin]
        }
        scroll.autoresizingMask = [.width, .height]
        voiceLight.autoresizingMask = [.width, .height]
    }

    /// The name was clicked: open the card beside the draft, or close it.
    func toggleInputMenu() {
        if inputMenu.isVisible {
            inputMenu.hide()
        } else {
            inputMenu.present(inputChoices, chosen: inputChosen, beside: frame)
        }
    }

    /// The keys go with the panel.
    ///
    /// Every other keyed surface drops its keys in `hide()`; this one did
    /// not, so a draft closed with its keys up came back with them up —
    /// `lode ?` is a question asked of a surface, and the answer should
    /// not outlive the asking. The last frame goes too, rather than
    /// holding a destination's icon until the next opening.
    func hide() {
        keysView?.removeFromSuperview()
        keysView = nil
        keysShown = false
        lastView = nil
        expanded = false
        inputMenu.hide()
        target = nil
        foldMotion = 0
        voiceLight.show(level: nil)
        gate.stop()
        panel.orderOut(nil)
    }

    /// Where the panel stands and what its lines say, for the tests.
    /// The glass's frame — where it stands, or where a fold in motion
    /// is taking it — without the shadow's margin.
    var frame: NSRect { target ?? SoftShadow.inset(panel.frame) }
    /// Whether the window takes the mouse right now, for the tests.
    var takesPointer: Bool { gate.open }
    func gatePointer(at point: NSPoint) { gate.update(pointer: point) }
    var caretFrame: NSRect { caret.frame }
    var caretColor: NSColor? { caret.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)) }
    /// Every view on the register line, named, for a layout probe.
    var registerViews: [(String, NSView)] {
        [("icon", registerIcon), ("name", registerName),
         ("note", registerNote), ("input", inputButton)]
    }
    var registerText: String { registerName.stringValue }
    var registerDetail: String { registerNote.stringValue }
    /// What the keys say, when they are up — the legend's replacement,
    /// for the tests that used to read the footer.
    var keysText: String {
        guard let keysView else { return "" }
        var out: [String] = []
        func walk(_ view: NSView) {
            if let field = view as? NSTextField { out.append(field.stringValue) }
            view.subviews.forEach(walk)
        }
        walk(keysView)
        return out.joined(separator: " ")
    }
    /// Whether the foot names the microphone right now.
    var inputNamed: Bool { !inputButton.isHidden }
    /// The name the foot shows, and the menu it opens, for the tests.
    var inputTitle: String { inputButton.title }
    var inputMenuForTests: InputMenu { inputMenu }
    /// How much of the top edge is lit, 0 when the light is out.
    var lightLength: CGFloat { voiceLight.length }
    var lightState: VoiceLight.State { voiceLight.state }
    /// The two bands a keys toggle moves, for the tests that hold them
    /// apart.
    var textFrame: NSRect { scroll.frame }
    var keysFrame: NSRect { keysView?.frame ?? .zero }
    /// Whether the text has more than fits and must be scrolled.
    var textOverflows: Bool { scroll.hasVerticalScroller }
    /// Where the visible window onto the text begins, so a test can see
    /// the cursor did not fall out of it.
    var textScrollOrigin: CGFloat { scroll.contentView.bounds.origin.y }

    /// The width a text asks for: its longest line in the panel's face,
    /// between the draft's own width and the screen. Prose stays at
    /// reading width, code gets its columns. Measured once, at open, so
    /// typing never resizes the panel.
    func width(for text: String) -> CGFloat {
        let screen = ActivePolicy.presentationFrame
        var longest: CGFloat = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let measured = (String(line) as NSString).size(withAttributes: [.font: Self.font]).width
            longest = max(longest, measured)
        }
        let asked = (longest + Self.padX * 2 + 8).rounded(.up)
        return min(max(Self.width, asked), screen.width - Self.margin * 2)
    }

    /// Where one visual line up or down from character `index` lands, by
    /// the same layout the screen shows — the eye's lines, not the
    /// file's. nil at the layout's edges, and while a ghost stands (its
    /// inserted text shifts every position after the cursor).
    func visualMove(from index: Int, down: Bool, in buffer: Draft.Buffer) -> Int? {
        guard buffer.ghost.isEmpty,
              let layout = textView.layoutManager, let container = textView.textContainer,
              let storage = textView.textStorage, storage.length > 0 else { return nil }
        let text = storage.string as NSString
        let utf16 = (String(buffer.characters[..<min(index, buffer.count)]) as NSString).length
        let glyph = layout.glyphIndexForCharacter(at: min(utf16, max(0, text.length - 1)))
        var fragmentRange = NSRange()
        _ = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &fragmentRange)
        let x = layout.location(forGlyphAt: glyph).x
        let neighborGlyph = down ? NSMaxRange(fragmentRange) : fragmentRange.location - 1
        guard neighborGlyph >= 0, neighborGlyph < layout.numberOfGlyphs else { return nil }
        var neighborRange = NSRange()
        let neighbor = layout.lineFragmentRect(forGlyphAt: neighborGlyph, effectiveRange: &neighborRange)
        let landingGlyph = layout.glyphIndex(for: NSPoint(x: x, y: neighbor.midY), in: container)
        let landingUTF16 = layout.characterIndexForGlyph(at: landingGlyph)
        // Back from UTF-16 to character space.
        return text.substring(to: min(landingUTF16, text.length)).count
    }

    /// Where UTF-16 ranges of the settled text are drawn, in quartz screen
    /// coordinates (top-left origin), as the editor's lens places chips.
    /// Nil for a range the panel is not showing.
    func screenRects(for ranges: [NSRange]) -> [CGRect?] {
        guard panel.isVisible, let layout = textView.layoutManager, let container = textView.textContainer,
              let storage = textView.textStorage, let primary = NSScreen.screens.first else {
            return ranges.map { _ in nil }
        }
        return ranges.map { range in
            guard range.location + range.length <= storage.length, range.length > 0 else { return nil }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            let inWindow = textView.convert(rect, to: nil)
            let onScreen = panel.convertToScreen(inWindow)
            return CGRect(x: onScreen.minX, y: primary.frame.maxY - onScreen.maxY,
                          width: onScreen.width, height: onScreen.height)
        }
    }

    /// The panel's frame in quartz screen coordinates.
    var quartzFrame: CGRect? {
        guard panel.isVisible, let primary = NSScreen.screens.first else { return nil }
        let frame = SoftShadow.inset(panel.frame)
        return CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
    }

    /// The last frame rendered, so the keys can re-render the panel once
    /// the glass has finished growing.
    private var lastView: DraftView?

    func show(_ view: DraftView) {
        let opening = lastView == nil
        let wasExpanded = expanded
        lastView = view
        expanded = view.expanded
        let screen = ActivePolicy.presentationFrame
        let width = min(view.width ?? Self.width, screen.width - Self.margin * 2)
        let textWidth = width - Self.padX * 2

        // The text: settled before the cursor, the ghost dimmed at the
        // cursor, settled after it — the ghost is where the next spoken
        // words will land, which is not necessarily the end.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let settledAttributes: [NSAttributedString.Key: Any] = [
            .font: Self.font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ]
        let ghostAttributes: [NSAttributedString.Key: Any] = [
            .font: Self.font, .foregroundColor: BarTheme.secondaryColor, .paragraphStyle: paragraph,
        ]
        let before = String(view.buffer.characters[..<view.buffer.cursor])
        let after = String(view.buffer.characters[view.buffer.cursor...])
        let attributed = NSMutableAttributedString(string: before, attributes: settledAttributes)
        if !view.buffer.ghost.isEmpty {
            let lead = Draft.separator(after: view.buffer.characters[..<view.buffer.cursor],
                                       before: view.buffer.ghost)
            attributed.append(NSAttributedString(string: lead + view.buffer.ghost, attributes: ghostAttributes))
        }
        attributed.append(NSAttributedString(string: after, attributes: settledAttributes))
        // Spoken words are grey until they are final: the ghost, still
        // being heard, and wet ink, heard and still being checked. A range past the
        // cursor would be shifted by a standing ghost, so only what lies
        // before it is drawn while one stands.
        let drawable = { (range: Range<Int>) -> NSRange? in
            guard range.upperBound <= view.buffer.count,
                  view.buffer.ghost.isEmpty || range.upperBound <= view.buffer.cursor else { return nil }
            let lower = (String(view.buffer.characters[..<range.lowerBound]) as NSString).length
            let upper = (String(view.buffer.characters[..<range.upperBound]) as NSString).length
            return NSRange(location: lower, length: max(0, upper - lower))
        }
        if let wet = view.wet, let range = drawable(wet) {
            attributed.addAttribute(.foregroundColor, value: Self.wetInk, range: range)
        }
        for revision in view.revised {
            guard let range = drawable(revision) else { continue }
            attributed.addAttributes([
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: BarTheme.secondaryColor,
            ], range: range)
        }
        if let selection = view.selection, !selection.isEmpty, view.buffer.ghost.isEmpty {
            let lower = (String(view.buffer.characters[..<selection.lowerBound]) as NSString).length
            let upper = (String(view.buffer.characters[..<selection.upperBound]) as NSString).length
            attributed.addAttribute(.backgroundColor,
                                    value: NSColor.labelColor.withAlphaComponent(0.3),
                                    range: NSRange(location: lower, length: max(0, upper - lower)))
        }
        // The find lights recolor the letters themselves — nothing is
        // drawn behind them, because a background wash under this glass
        // is composited by vibrancy and can vanish entirely (the first
        // build of this feature shipped invisible that way). Painted only
        // with no ghost standing, like the selection: the ghost shifts
        // every position after the cursor.
        if view.buffer.ghost.isEmpty {
            let accent: [NSAttributedString.Key: Any] = [
                .foregroundColor: BarTheme.readableAccent, .font: Self.accentFont,
            ]
            let characterRange = { (range: Range<Int>) -> NSRange in
                let lower = (String(view.buffer.characters[..<range.lowerBound]) as NSString).length
                let upper = (String(view.buffer.characters[..<range.upperBound]) as NSString).length
                return NSRange(location: lower, length: max(0, upper - lower))
            }
            for target in view.findTargets where target < view.buffer.count {
                attributed.addAttributes(accent, range: characterRange(target..<target + 1))
            }
            // The editor's line, drawn by the text itself like the find
            // lights, so the glass cannot wash it out, and it follows the
            // words as they wrap.
            for mark in view.editorMarks where mark.location + mark.length <= attributed.length {
                attributed.addAttributes([
                    .underlineStyle: NSUnderlineStyle.thick.rawValue,
                    .underlineColor: BarTheme.accent,
                ], range: mark)
            }
        }
        // The glyph under a block cursor is drawn in the panel's ground,
        // so the block reads as a solid plate with the letter cut out of
        // it — the inversion terminals use, and the highest contrast a
        // cursor can have. A thin bar in insert mode needs no inversion.
        if view.editor != .insert, view.buffer.ghost.isEmpty,
           view.buffer.cursor < view.buffer.count,
           view.buffer.characters[view.buffer.cursor] != "\n" {
            let lower = (String(view.buffer.characters[..<view.buffer.cursor]) as NSString).length
            let upper = (String(view.buffer.characters[...view.buffer.cursor]) as NSString).length
            attributed.addAttribute(.foregroundColor, value: Self.ground,
                                    range: NSRange(location: lower, length: max(0, upper - lower)))
        }
        textView.textStorage?.setAttributedString(attributed)
        textView.frame.size.width = textWidth
        textView.textContainer?.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let used = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 0
        let lineHeight = textView.layoutManager?.defaultLineHeight(for: Self.font) ?? 22
        // Opened whole, the text grows the panel to the display's visible
        // height and scrolls past it — one rule for every door. A card
        // opened to be read wants all of itself on screen. Folded, it
        // holds four whole lines, so the screen behind stays in view.
        let chrome = Self.padTop + Self.footHeight + keysBand
        let maxTextHeight = max(Self.minTextHeight,
                                screen.height - view.standsAbove - Self.margin * 2 - chrome)

        // Where the words are arriving: the end of a standing ghost, or
        // the cursor when there is none.
        let cursorUTF16 = (String(view.buffer.characters[..<view.buffer.cursor]) as NSString).length
        let afterUTF16 = (String(view.buffer.characters[view.buffer.cursor...]) as NSString).length
        let focus = view.buffer.ghost.isEmpty ? cursorUTF16 : attributed.length - afterUTF16
        // Folded, the window is whole lines read off the layout itself,
        // ending on the focus's line: a line cut through at the top would
        // be a fade drawn with a ruler.
        var window: (top: CGFloat, height: CGFloat)?
        if !expanded, let layout = textView.layoutManager, layout.numberOfGlyphs > 0 {
            var lines: [NSRect] = []
            layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) {
                rect, _, _, _, _ in lines.append(rect)
            }
            // A text ending in a newline has one more line than its glyphs:
            // the empty one the caret stands on after ⇧⏎.
            let extra = layout.extraLineFragmentRect
            if extra.height > 0 { lines.append(extra) }
            if lines.count > Self.compactLines {
                // The focus's own line. A ghost's end is the character
                // before it; a cursor is the character under it, which at
                // the start of a line is that line, not the one above; at
                // the very end it is the last line, or the empty one.
                let focusLine: NSRect
                if !view.buffer.ghost.isEmpty || focus >= attributed.length {
                    if focus >= attributed.length, extra.height > 0 {
                        focusLine = extra
                    } else {
                        let glyph = layout.glyphIndexForCharacter(at: max(0, min(focus, attributed.length) - 1))
                        focusLine = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    }
                } else {
                    let glyph = layout.glyphIndexForCharacter(at: focus)
                    focusLine = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                }
                let end = lines.firstIndex { abs($0.minY - focusLine.minY) < 0.5 } ?? lines.count - 1
                let start = max(0, end - (Self.compactLines - 1))
                let last = min(lines.count - 1, start + Self.compactLines - 1)
                window = (lines[start].minY, min(maxTextHeight, lines[last].maxY - lines[start].minY))
            }
        }
        // The text box keeps a floor of its own so an empty draft is not a
        // slot — but that floor is slack under the words, and with keys
        // up it stacks on the keys' own air and reads as one gap of
        // twice the size. With keys up the box hugs instead; the air
        // between the words and their keys is then exactly the one inset
        // every other surface uses.
        let floor = keysShown ? lineHeight : Self.minTextHeight
        // Folded, the box is exactly its lines: a line cut through the
        // middle at the top would be a fade drawn by a ruler.
        let textHeight = window?.height ?? (expanded
            ? min(maxTextHeight, max(floor, used + lineHeight * 0.4))
            : min(maxTextHeight, max(floor, used)))
        // A scroller says there is more to read, which is true only when
        // reading is the task.
        scroll.hasVerticalScroller = expanded && used > maxTextHeight

        // Whole points: the window lands on them anyway, and a glass whose
        // edge falls between pixels is a soft edge.
        let height = (chrome + textHeight).rounded(.up)
        let frame = NSRect(x: (screen.midX - width / 2).rounded(),
                           y: screen.minY + Self.margin + view.standsAbove,
                           width: width, height: height)

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let from = panel.frame
        let outset = SoftShadow.outset(frame)
        target = frame
        panel.setFrame(outset, display: false)
        root.frame = SoftShadow.inset(NSRect(origin: .zero, size: outset.size))
        backdrop?.frame = root.bounds
        voiceLight.frame = root.bounds

        // The foot. Everything on it shares one vertical center,
        // and the rounding happens to the *edges* rather than the centre:
        // rounding `centre - h/2` puts an even-height view on a whole
        // pixel and an odd-height one on a half, which is a visible
        // stagger across a row that mixes glyphs, symbols and controls.
        let centerY = (Self.footHeight / 2).rounded()
        func place(_ v: NSView, x: CGFloat, width w: CGFloat, height h: CGFloat) {
            let top = (centerY + h / 2).rounded()
            v.frame = NSRect(x: x.rounded(), y: top - h.rounded(), width: w, height: h.rounded())
        }
        /// A label is centred on its *text*, not on whatever box it is
        /// handed. Two labels in two faces, each centred as a box, do not
        /// share a baseline — which is what made this line look off.
        func placeText(_ field: NSTextField, x: CGFloat, width w: CGFloat) {
            let natural = field.sizeThatFits(NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                    height: CGFloat.greatestFiniteMagnitude)).height
            place(field, x: x, width: w, height: natural)
        }
        var x = Self.padX
        if let card = view.card {
            // The card being edited, where the destination would stand:
            // there is no destination, since nothing here pastes.
            registerIcon.image = card.icon ?? NSImage(systemSymbolName: "doc.on.clipboard",
                                                      accessibilityDescription: "clipboard")
            registerIcon.contentTintColor = card.icon == nil ? BarTheme.secondaryColor : nil
            registerName.stringValue = card.name
        } else if let destination = view.destination {
            registerIcon.image = destination.icon
            registerIcon.contentTintColor = nil
            registerName.stringValue = destination.name
        } else {
            registerIcon.image = NSImage(systemSymbolName: "doc.on.clipboard",
                                         accessibilityDescription: "clipboard")
            registerIcon.contentTintColor = BarTheme.secondaryColor
            registerName.stringValue = "Clipboard"
        }
        place(registerIcon, x: x, width: 18, height: 18)
        x += 26
        registerName.sizeToFit()
        placeText(registerName, x: x, width: min(registerName.frame.width, 240))
        x += registerName.frame.width + 14

        // Where the text goes sits on the left; the microphone on the
        // right. The mode has no word: the caret's shape is the mode, and
        // the microphone has no glyph: the light is lit while it hears and
        // out while it is off or still opening, which is all a glyph said.
        var trailing = width - Self.padX

        // The clip door has no microphone, and names none.
        let noMic = view.card != nil
        let wanted = Self.micWanted(view) && !noMic
        // Grey is wanted but not heard: opening, a model still arriving,
        // or a microphone that failed, whose reason the note gives. Out
        // means only that the hand turned it off.
        if case .listening = view.speech, wanted {
            light = .live
        } else {
            light = wanted ? .waiting : .off
        }
        setLevel(view.level)

        // The input menu at the end, then whatever the recognizer has to
        // say, in the room that is left.
        let systemTitle = "System" + (view.systemInput.map { " (\($0))" } ?? "")
        let choices = [InputMenu.Choice(title: systemTitle, device: nil)]
            + view.inputs.map { InputMenu.Choice(title: $0, device: $0) }
        let chosenIndex = view.chosenInput.flatMap { view.inputs.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        if choices != inputChoices || chosenIndex != inputChosen {
            inputChoices = choices
            inputChosen = chosenIndex
            // A menu open over a changed list is a stale menu.
            inputMenu.hide()
        }
        inputButton.title = choices[chosenIndex].title
        // Named whenever the microphone is wanted: it is the one thing
        // about it the keys cannot choose.
        inputButton.isHidden = noMic || !view.micOn
        if inputButton.isHidden { inputMenu.hide() }
        // Sized to the name: the chevron sits beside it, not at the end of
        // the widest device.
        let buttonWidth = min(inputButton.naturalWidth, max(80, trailing - x - 8))
        if !inputButton.isHidden {
            place(inputButton, x: trailing - buttonWidth, width: buttonWidth, height: 22)
            trailing -= buttonWidth + 8
        }

        registerNote.stringValue = view.card?.detail ?? Self.note(for: view)
        registerNote.isHidden = registerNote.stringValue.isEmpty
        registerNote.sizeToFit()
        placeText(registerNote, x: x, width: max(0, min(registerNote.frame.width, trailing - x)))

        // The text.
        scroll.frame = NSRect(x: Self.padX, y: Self.footHeight + keysBand,
                              width: textWidth, height: textHeight)
        textView.frame = NSRect(x: 0, y: 0, width: textWidth, height: max(textHeight, used))
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        if let window {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: window.top))
            scroll.reflectScrolledClipView(scroll.contentView)
        } else if used > textHeight {
            // Keep in view where the words are arriving.
            textView.scrollRangeToVisible(NSRange(location: min(focus, attributed.length), length: 0))
        } else {
            scroll.contentView.scroll(to: .zero)
        }

        // The caret, at the cursor's glyph.
        if let layout = textView.layoutManager, let container = textView.textContainer {
            let cursorUTF16 = (String(view.buffer.characters[..<view.buffer.cursor]) as NSString).length
            let glyph = layout.glyphIndexForCharacter(at: min(cursorUTF16, max(0, attributed.length)))
            // A thin bar between characters in insert mode; a block over the
            // character under the cursor otherwise, the width of that glyph.
            let block = view.editor != .insert
            let bar: CGFloat = 3
            var rect: NSRect
            if attributed.length == 0 {
                rect = NSRect(x: 0, y: 0, width: block ? 8 : bar, height: lineHeight)
            } else if cursorUTF16 >= attributed.length {
                let last = layout.lineFragmentRect(forGlyphAt: max(0, glyph - 1), effectiveRange: nil)
                let lastLoc = layout.location(forGlyphAt: max(0, glyph - 1))
                let lastWidth = layout.boundingRect(forGlyphRange: NSRange(location: max(0, glyph - 1), length: 1), in: container).width
                let endsWithNewline = attributed.string.hasSuffix("\n")
                rect = endsWithNewline
                    ? NSRect(x: 0, y: last.maxY, width: block ? 8 : bar, height: lineHeight)
                    : NSRect(x: lastLoc.x + lastWidth, y: last.minY, width: block ? 8 : bar, height: last.height)
            } else {
                let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let loc = layout.location(forGlyphAt: glyph)
                let glyphWidth = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).width
                let underCursor: Character = view.buffer.cursor < view.buffer.count
                    ? view.buffer.characters[view.buffer.cursor] : " "
                let width = block ? (underCursor == "\n" ? 8 : max(4, glyphWidth)) : bar
                rect = NSRect(x: loc.x, y: line.minY, width: width, height: line.height)
            }
            // Text view coordinates are flipped; the root is not.
            let converted = textView.convert(rect, to: root)
            caret.frame = converted.insetBy(dx: 0, dy: 1)
            // A solid plate in normal mode; the system's own insertion
            // colour for the bar, which is what every field on the Mac
            // teaches the eye to look for.
            caret.layer?.backgroundColor = (block ? NSColor.labelColor : BarTheme.readableAccent).cgColor
        }

        placeKeys(width: width)

        CATransaction.commit()
        NSAnimationContext.endGrouping()

        // Folding or opening moves the glass quickly rather than not at
        // all: laid out where it is going, put back where it was, and
        // carried there on the subviews' masks, the keys' own method. A
        // render that lands mid-way carries the motion on.
        let folds = !opening && !restaging && panel.isVisible
            && (expanded != wasExpanded || foldMotion != 0)
        if folds, from != outset, !Accessibility.reduceMotion() {
            panel.setFrame(from, display: false)
            foldMotion += 1
            let motion = foldMotion
            // Correctness cannot depend on the animation: under load a
            // window animation can fail to move at all, so when its time
            // is up the glass is put exactly where the layout said,
            // whether or not the motion ran.
            let land = { [weak self] in
                guard let self, self.foldMotion == motion else { return }
                self.foldMotion = 0
                // Laid out again where it stands: the motion carried the
                // glass but the scroll view clamped its window on the way,
                // and the pointer gate read the old frame.
                if let last = self.lastView { self.show(last) }
            }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Self.foldSeconds
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(outset, display: true)
            }, completionHandler: land)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.foldSeconds + 0.05, execute: land)
        }

        if !panel.isVisible { panel.orderFrontRegardless() }
        gate.start()
    }

    // MARK: - The keys

    /// The height the glass owes its keys: zero while they are away.
    private var keysBand: CGFloat {
        guard keysShown, let keysView else { return 0 }
        return Self.keysAbove + keysView.frame.height
    }

    /// The keys sit under the text, on the foot, which is where the
    /// legend used to stand.
    ///
    /// Placed against the width the panel actually has, not against the
    /// draft's default one. The glass is 720 wide on every display a Mac
    /// has, and the columns want 454 of it, so the clamp does not bind
    /// in practice — but it was written against the constant, and a
    /// constant is the wrong thing to measure a variable against.
    private func placeKeys(width: CGFloat) {
        guard let keysView, keysShown else { return }
        let available = max(0, width - Self.padX * 2)
        keysView.frame = NSRect(x: Self.padX, y: Self.footHeight,
                                width: min(keysView.fittingSize.width, available),
                                height: keysView.frame.height)
    }

    /// `lode ?`, from the engine. The draft is the frontmost surface
    /// while it is open, so it answers before any bar does.
    func toggleKeys(_ sections: [CheatSheet.Section]) {
        if keysShown { hideKeys() } else { showKeys(sections) }
    }

    func showKeys(_ sections: [CheatSheet.Section]) {
        guard panel.isVisible, let last = lastView, !keysShown else { return }
        keysView?.removeFromSuperview()
        let columns = CheatSheet.columns(sections)
        // The draft places every view by frame; a stack that still
        // believes in its constraints would be zeroed by the first
        // layout pass.
        columns.translatesAutoresizingMaskIntoConstraints = true
        // The height is the columns' own; the width is settled by
        // `placeKeys` against the glass this draft actually has.
        columns.frame = NSRect(x: Self.padX, y: Self.footHeight,
                               width: columns.fittingSize.width,
                               height: columns.fittingSize.height)
        columns.autoresizingMask = [.maxYMargin]
        columns.alphaValue = 0
        root.addSubview(columns)
        keysView = columns
        keysShown = true
        KeysMotion.grow(panel, to: restaged(last).to, revealing: columns,
                        completion: { [weak self] in self?.relay() })
    }

    func hideKeys() {
        guard keysShown, let last = lastView else { return }
        keysShown = false
        let going = keysView
        keysView = nil
        KeysMotion.shrink(panel, to: restaged(last).to, hiding: going,
                          completion: { [weak self] in self?.relay() })
    }

    /// Lay the panel out for where it is going, then put the glass back
    /// where it was so the animation has somewhere to travel from.
    ///
    /// The layout used to be corrected in the animation's completion
    /// handler, and that was wrong twice over. A frame animation whose
    /// target equals its current value never runs, and AppKit never
    /// calls the handler — so a draft already standing at the top of the
    /// screen, which cannot grow, drew its keys straight over the last
    /// hundred points of its own text and left them there until some
    /// other keystroke happened to re-render it. Correctness cannot
    /// depend on an animation: the layout is right from the first frame
    /// now, and the motion only carries the glass between two frames
    /// that are both already true. The subviews ride on their
    /// autoresizing masks the whole way.
    /// Lay the panel out again where a motion left it: the glass is right,
    /// but a folded window's scroll was clamped while the frame travelled.
    private func relay() {
        guard panel.isVisible, let last = lastView else { return }
        show(last)
    }

    @discardableResult
    private func restaged(_ view: DraftView) -> (from: NSRect, to: NSRect) {
        let from = panel.frame
        // The keys' motion owns the glass now; a fold landing late must not
        // put it back where the fold was going.
        foldMotion = 0
        restaging = true
        show(view)
        restaging = false
        let to = panel.frame
        panel.setFrame(from, display: false)
        return (from, to)
    }

    /// What the microphone is doing, as the light shows it.
    private enum Light { case off, waiting, live }
    private var light = Light.off

    /// Move the light without a re-layout: the level arrives ten times a
    /// second, and moves it only while the microphone hears.
    func setLevel(_ level: Float) {
        switch light {
        case .off: voiceLight.show(.off)
        case .waiting: voiceLight.show(.waiting)
        case .live: voiceLight.show(.listening(level))
        }
    }

    /// The microphone writes: wanted, in insert mode, or over a selection,
    /// where speaking is a change said rather than typed.
    static func micWanted(_ view: DraftView) -> Bool {
        guard view.micOn else { return false }
        if view.mode == .insert { return true }
        if let selection = view.selection, !selection.isEmpty, case .visual = view.editor { return true }
        return false
    }

    static func note(for view: DraftView) -> String {
        if view.replacing { return "replaces the selection" }
        switch view.speech {
        case .preparing(let progress):
            if let progress, progress > 0 { return "preparing speech \(Int(progress * 100))%" }
            return "preparing speech"
        case .denied: return "microphone not allowed, typing only"
        case .unavailable: return "speech needs macOS 26, typing only"
        case .failed(let why): return why
        case .listening:
            // Off, or waiting for insert mode: the light is out, and that
            // is the whole message.
            guard micWanted(view) else { return "" }
            return view.silent ? "hearing nothing on \(view.input ?? "the microphone")" : ""
        case .paused: return ""
        case nil:
            // Between the door and the recognizer's first word about
            // itself the light is out: on a Bluetooth headset that is one
            // to three seconds, and the light coming on is the cue to
            // speak.
            return ""
        }
    }
}

#if DEBUG
extension DraftPanel {
    /// The ink drying, staged: the same dictation as wet, as rewritten,
    /// or played through from ghost to dry.
    fileprivate static func drying(_ which: String) -> DraftPanel {
        let panel = DraftPanel()
        let icon = NSWorkspace.shared.icon(forFile: "/System/Applications/Utilities/Terminal.app")
        let before = "The flex container has a gap of twelve but the cards still touch, so something is overriding it, probably the margin reset in globals.css. Check whether the card component sets its own margin."
        func frame(_ text: String, ghost: String = "", wet: Range<Int>? = nil, revised: [Range<Int>] = [],
                   level: Float = 0.5) -> DraftView {
            var buffer = Draft.Buffer(text: text)
            buffer.setCursor(buffer.count)
            if !ghost.isEmpty { buffer.showGhost(ghost) }
            var view = DraftView(buffer: buffer, mode: .insert, editor: .insert,
                                 speech: .listening(input: "MacBook Pro Microphone"),
                                 input: "MacBook Pro Microphone", level: level,
                                 inputs: ["MacBook Pro Microphone"], systemInput: "MacBook Pro Microphone",
                                 micOn: true, destination: ("Terminal", icon), replacing: false)
            view.wet = wet
            view.revised = revised
            return view
        }
        let misheard = before + " If it does, remove it and use the gap, then rerun the bill."
        let heard = before + " If it does, remove it and use the gap, then rerun the build."
        let spoken = before.count..<heard.count
        let spokenMisheard = before.count..<misheard.count
        let word = (heard.count - "build.".count)..<(heard.count - 1)
        switch which {
        case "wet":
            panel.show(frame(misheard, wet: spokenMisheard, level: 0.1))
        case "revised":
            panel.show(frame(heard, revised: [word], level: 0.1))
        default:
            // Ghost growing, settled wet, the second ear's fix, dry.
            let steps: [(Double, DraftView)] = [
                (0.0, frame(before, ghost: "If it does", level: 0.6)),
                (0.5, frame(before, ghost: "If it does, remove it and use", level: 0.7)),
                (1.0, frame(before, ghost: "If it does, remove it and use the gap, then", level: 0.55)),
                (1.5, frame(before, ghost: "If it does, remove it and use the gap, then rerun the bill", level: 0.6)),
                (2.1, frame(misheard, wet: spokenMisheard, level: 0.05)),
                (2.6, frame(heard, wet: spoken, revised: [word], level: 0.0)),
                (3.2, frame(heard, revised: [word], level: 0.0)),
            ]
            panel.show(steps[0].1)
            // A second and a half of standing still first, for the
            // recording to begin.
            for (at, view) in steps.dropFirst() {
                DispatchQueue.main.asyncAfter(deadline: .now() + at + 1.5) { panel.show(view) }
            }
        }
        return panel
    }

    /// The preview harness's lanes: 0 speaking with a ghost, 1 editing,
    /// 2 the website's photograph.
    static func preview(_ variant: Int) -> DraftPanel {
        // DRY=wet|revised stages the ink drying; DRY=film plays it, ghost to
        // dry, for a recording.
        if let dry = ProcessInfo.processInfo.environment["DRY"], variant == 0 { return drying(dry) }
        if variant == 2 {
            let panel = DraftPanel()
            var buffer = Draft.Buffer()
            let icon = NSWorkspace.shared.icon(forFile: "/System/Applications/Notes.app")
            buffer.settle("What does man gain by all the toil at which he toils under the sun?")
            buffer.settle("A generation goes, and a generation comes, but the earth remains forever.")
            buffer.settle("The sun rises, and the sun goes down,")
            buffer.showGhost("and hastens to the place where it rises")
            panel.show(DraftView(buffer: buffer, mode: .insert, editor: .insert,
                                 speech: .listening(input: "Cypress"),
                                 input: "Cypress", level: 0.55,
                                 inputs: ["Cypress", "MacBook Pro Microphone"],
                                 systemInput: "Cypress",
                                 micOn: true,
                                 destination: ("Notes", icon), replacing: false))
            return panel
        }
        let panel = DraftPanel()
        var buffer = Draft.Buffer()
        let icon = NSWorkspace.shared.icon(forFile: "/System/Applications/Messages.app")
        let inputs = ["MacBook Pro Microphone", "CalDigit Thunderbolt 3 Audio"]
        if variant == 0 {
            buffer.settle("Look at the inspector on the left. The flex container has a gap of twelve but the cards still touch, so something is overriding it, probably the margin reset in globals.css.")
            buffer.settle("Check whether the card component sets its own margin and if it does, remove it and use the gap instead.")
            buffer.type(" Run the migration for user_sessions")
            buffer.settle("and tail the log, then move the Asana card to the done column.")
            buffer.showGhost("and ping the channel")
            // WAIT=1 stages the microphone still opening: the grey floor.
            let waiting = ProcessInfo.processInfo.environment["WAIT"] == "1"
            if waiting { buffer = Draft.Buffer() }
            panel.show(DraftView(buffer: buffer, mode: .insert, editor: .insert,
                                 speech: waiting ? nil : .listening(input: "MacBook Pro Microphone"),
                                 input: "MacBook Pro Microphone",
                                 // LEVEL= stages another loudness: 1 curves into the corners.
                                 level: Float(ProcessInfo.processInfo.environment["LEVEL"] ?? "") ?? 0.6,
                                 inputs: inputs, systemInput: "Cypress", chosenInput: "MacBook Pro Microphone",
                                 micOn: true,
                                 destination: ("Messages", icon), replacing: false))
            // MENU=1 stages the input menu open beside the draft.
            if ProcessInfo.processInfo.environment["MENU"] == "1" { panel.toggleInputMenu() }
            // KEYS=1 stages the keys up, as lode ? shows them.
            if ProcessInfo.processInfo.environment["KEYS"] == "1" {
                panel.showKeys(HotkeyEngine.draftSections(editor: .insert, card: false))
            }
        } else {
            buffer = Draft.Buffer(text: "The quick brown fox\njumps over the lazy dog.", cursor: 10)
            panel.show(DraftView(buffer: buffer, mode: .normal, speech: nil,
                                 inputs: inputs, systemInput: "Cypress",
                                 destination: ("Messages", icon), replacing: true))
        }
        return panel
    }
}
#endif
