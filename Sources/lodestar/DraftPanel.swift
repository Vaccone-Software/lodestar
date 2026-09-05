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
}

/// The draft's glass: bottom center, fixed in place, growing upward with
/// the text. Never key — the app under it keeps its cursor the whole
/// time — but it takes the mouse for two things on its register line:
/// the microphone, which toggles, and the input, which is a menu.
final class DraftPanel {
    let panel: NSPanel
    private let root = NSView()
    private var backdrop: NSView?

    // The register line: made once, placed on every render, so a menu
    // that is open survives the next volatile word.
    private let registerIcon = NSImageView()
    private let registerName = NSTextField(labelWithString: "")
    private let registerNote = NSTextField(labelWithString: "")
    private let inputPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modeLabel = NSTextField(labelWithString: "")
    private var meterBars: [NSView] = []
    private let micButton = HandButton(frame: .zero)

    /// Internal so the tests can read the storage the screen reads: the
    /// find lights once shipped as background washes that vibrancy ate,
    /// and only a test against the rendered attributes catches that class
    /// of nothing-appears bug.
    let textView = NSTextView()
    private let scroll = NSScrollView()
    private let caret = NSView()
    private let footer = NSTextField(labelWithString: "")

    /// The mic was clicked: on becomes off, off becomes on.
    var onToggleMic: (() -> Void)?
    /// An input was chosen from the menu; nil is the system default.
    var onChooseInput: ((String?) -> Void)?
    private var popupTitles: [String] = []

    private static let width: CGFloat = 720
    private static let margin: CGFloat = 22
    private static let padX: CGFloat = 22
    private static let registerHeight: CGFloat = 40
    private static let footerHeight: CGFloat = 26
    private static let minTextHeight: CGFloat = 58
    private static let meterCount = 5
    /// The system's mono face: a block cursor in a proportional face is
    /// a fresh width on every character, `j` and `k` walk columns that
    /// lie, and a lit letter's semibold reflows the line. Mono makes all
    /// three constant — the advance survives the weight by design.
    private static let font = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
    /// The find lights' weight: heavier than the text so a lit letter
    /// reads at a glance, and in the mono face the same width, so
    /// nothing reflows.
    private static let accentFont = NSFont.monospacedSystemFont(ofSize: 16, weight: .semibold)
    /// macOS paints "the microphone is on" orange, in the menu bar and in
    /// Control Center; the panel says it in the same color.
    private static let live = NSColor.systemOrange

    var isVisible: Bool { panel.isVisible }

    init() {
        panel = Glass.makePanel(level: .statusBar)
        // The mouse reaches the register line's two controls. The panel
        // never becomes key, so the app underneath keeps its cursor.
        panel.ignoresMouseEvents = false
        panel.contentView = root
        backdrop = Glass.installBackdrop(in: root, cornerRadius: BarTheme.glassRadius)

        registerName.font = BarTheme.rowLabelFont
        registerName.textColor = .labelColor
        registerName.lineBreakMode = .byTruncatingTail
        registerNote.font = BarTheme.secondaryFont
        registerNote.textColor = .secondaryLabelColor
        registerNote.lineBreakMode = .byTruncatingTail
        modeLabel.font = BarTheme.chipFont
        modeLabel.textColor = .secondaryLabelColor

        inputPopup.isBordered = false
        inputPopup.font = BarTheme.secondaryFont
        inputPopup.controlSize = .small
        inputPopup.target = self
        inputPopup.action = #selector(inputChosen)
        inputPopup.toolTip = "The microphone the draft listens to"

        micButton.isBordered = false
        micButton.imagePosition = .imageOnly
        micButton.imageScaling = .scaleProportionallyDown
        micButton.target = self
        micButton.action = #selector(micClicked)
        micButton.toolTip = "Microphone on or off"

        for i in 0..<Self.meterCount {
            let bar = NSView()
            bar.wantsLayer = true
            bar.layer?.cornerRadius = 1
            bar.frame = NSRect(x: 0, y: 0, width: 3, height: CGFloat(5 + i * 2))
            meterBars.append(bar)
        }

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
        // Every view here is placed by frame on each render; nothing may
        // opt into Auto Layout, or the first layout pass zeroes it.

        caret.wantsLayer = true
        caret.layer?.cornerRadius = 1

        footer.font = BarTheme.footerFont
        footer.textColor = .secondaryLabelColor

        for view in [registerIcon, registerName, registerNote, inputPopup, modeLabel, micButton,
                     scroll, caret, footer] + meterBars {
            root.addSubview(view)
        }
    }

    @objc private func micClicked() { onToggleMic?() }

    @objc private func inputChosen() {
        let index = inputPopup.indexOfSelectedItem
        onChooseInput?(index <= 0 ? nil : inputPopup.itemTitle(at: index))
    }

    func hide() { panel.orderOut(nil) }

    /// Where the panel stands and what its lines say, for the tests.
    var frame: NSRect { panel.frame }
    var registerText: String { registerName.stringValue }
    var registerDetail: String { registerNote.stringValue }
    var footerText: String { footer.stringValue }
    var micVisible: Bool { !micButton.isHidden }

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

    func show(_ view: DraftView) {
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
            .font: Self.font, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: paragraph,
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
        if let selection = view.selection, !selection.isEmpty, view.buffer.ghost.isEmpty {
            let lower = (String(view.buffer.characters[..<selection.lowerBound]) as NSString).length
            let upper = (String(view.buffer.characters[..<selection.upperBound]) as NSString).length
            attributed.addAttribute(.backgroundColor,
                                    value: NSColor.labelColor.withAlphaComponent(0.22),
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
                .foregroundColor: NSColor.controlAccentColor, .font: Self.accentFont,
            ]
            let characterRange = { (range: Range<Int>) -> NSRange in
                let lower = (String(view.buffer.characters[..<range.lowerBound]) as NSString).length
                let upper = (String(view.buffer.characters[..<range.upperBound]) as NSString).length
                return NSRange(location: lower, length: max(0, upper - lower))
            }
            for target in view.findTargets where target < view.buffer.count {
                attributed.addAttributes(accent, range: characterRange(target..<target + 1))
            }
        }
        textView.textStorage?.setAttributedString(attributed)
        textView.frame.size.width = textWidth
        textView.textContainer?.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let used = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 0
        let lineHeight = textView.layoutManager?.defaultLineHeight(for: Self.font) ?? 22
        // The text grows the panel to the display's visible height and
        // scrolls past it — one rule for every door. A card opened to be
        // read wants all of itself on screen, and a long dictation is no
        // worse for the room.
        let chrome = Self.registerHeight + Self.footerHeight + 14
        let maxTextHeight = max(Self.minTextHeight,
                                screen.height - view.standsAbove - Self.margin * 2 - chrome)
        let textHeight = min(maxTextHeight, max(Self.minTextHeight, used + lineHeight * 0.4))
        scroll.hasVerticalScroller = used > maxTextHeight

        let height = chrome + textHeight
        let frame = NSRect(x: screen.midX - width / 2,
                           y: screen.minY + Self.margin + view.standsAbove,
                           width: width, height: height)

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        panel.setFrame(frame, display: false)
        root.frame = NSRect(origin: .zero, size: frame.size)
        backdrop?.frame = root.bounds

        // The register line. Everything on it shares one vertical center.
        let registerY = height - Self.registerHeight
        let centerY = registerY + Self.registerHeight / 2
        func place(_ v: NSView, x: CGFloat, width w: CGFloat, height h: CGFloat) {
            v.frame = NSRect(x: x.rounded(), y: (centerY - h / 2).rounded(), width: w, height: h)
        }
        var x = Self.padX
        if let card = view.card {
            // The card being edited, where the destination would stand:
            // there is no destination, since nothing here pastes.
            registerIcon.image = card.icon ?? NSImage(systemSymbolName: "doc.on.clipboard",
                                                      accessibilityDescription: "clipboard")
            registerIcon.contentTintColor = card.icon == nil ? .secondaryLabelColor : nil
            registerName.stringValue = card.name
        } else if let destination = view.destination {
            registerIcon.image = destination.icon
            registerIcon.contentTintColor = nil
            registerName.stringValue = destination.name
        } else {
            registerIcon.image = NSImage(systemSymbolName: "doc.on.clipboard",
                                         accessibilityDescription: "clipboard")
            registerIcon.contentTintColor = .secondaryLabelColor
            registerName.stringValue = "Clipboard"
        }
        place(registerIcon, x: x, width: 18, height: 18)
        x += 26
        registerName.sizeToFit()
        place(registerName, x: x, width: min(registerName.frame.width, 240), height: 17)
        x += registerName.frame.width + 14

        // Where the text goes and what the keys mean sit together on the
        // left; everything about the microphone sits together on the right.
        switch view.editor {
        case .insert: modeLabel.stringValue = "INSERT"
        case .normal: modeLabel.stringValue = view.pending ? "NORMAL ·" : "NORMAL"
        case .visual(let line): modeLabel.stringValue = line ? "V-LINE" : "VISUAL"
        }
        modeLabel.sizeToFit()
        place(modeLabel, x: x, width: modeLabel.frame.width, height: 15)
        x += modeLabel.frame.width + 16

        var trailing = width - Self.padX

        let listening: Bool
        if case .listening = view.speech { listening = true } else { listening = false }
        let micLive = view.micOn && listening && view.mode == .insert
        micButton.image = NSImage(systemSymbolName: view.micOn ? "mic.fill" : "mic.slash.fill",
                                  accessibilityDescription: view.micOn ? "microphone on" : "microphone off")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        micButton.contentTintColor = micLive ? Self.live : .secondaryLabelColor
        // The clip door has no microphone, and draws none: a glyph that
        // could be clicked would promise what the door refuses.
        let noMic = view.card != nil
        micButton.isHidden = noMic
        if !noMic {
            place(micButton, x: trailing - 20, width: 20, height: 20)
            trailing -= 28
        }
        for (i, bar) in meterBars.enumerated() {
            let h = bar.frame.height
            bar.isHidden = !listening || noMic
            place(bar, x: trailing - 3 - CGFloat(Self.meterCount - 1 - i) * 5, width: 3, height: h)
        }
        if listening, !noMic { trailing -= CGFloat(Self.meterCount) * 5 + 10 }
        setLevel(listening ? view.level : 0, live: micLive)

        // The input menu beside the meter it feeds, then whatever the
        // recognizer has to say, in the room that is left.
        let systemTitle = "System" + (view.systemInput.map { " (\($0))" } ?? "")
        let titles = [systemTitle] + view.inputs
        if titles != popupTitles {
            inputPopup.removeAllItems()
            inputPopup.addItems(withTitles: titles)
            popupTitles = titles
        }
        let chosenIndex = view.chosenInput.flatMap { view.inputs.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        if inputPopup.indexOfSelectedItem != chosenIndex { inputPopup.selectItem(at: chosenIndex) }
        inputPopup.isHidden = (view.speech == nil && !view.micOn) || noMic
        // Sized to the title on show, not the longest item: the arrow
        // sits beside the name, not at the end of the widest device.
        let titleWidth = (inputPopup.titleOfSelectedItem ?? "").size(withAttributes: [.font: BarTheme.secondaryFont]).width
        let popupWidth = min(titleWidth + 30, max(80, trailing - x - 8))
        if !inputPopup.isHidden {
            place(inputPopup, x: trailing - popupWidth, width: popupWidth, height: 22)
            trailing -= popupWidth + 8
        }

        registerNote.stringValue = view.card?.detail ?? Self.note(for: view)
        registerNote.isHidden = registerNote.stringValue.isEmpty
        registerNote.sizeToFit()
        place(registerNote, x: x, width: max(0, min(registerNote.frame.width, trailing - x)), height: 15)

        // The text.
        scroll.frame = NSRect(x: Self.padX, y: Self.footerHeight + 6, width: textWidth, height: textHeight)
        textView.frame = NSRect(x: 0, y: 0, width: textWidth, height: max(textHeight, used))
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        if used > textHeight {
            // Keep the cursor's line in view, wherever it is.
            let cursorUTF16 = (String(view.buffer.characters[..<view.buffer.cursor]) as NSString).length
            textView.scrollRangeToVisible(NSRange(location: min(cursorUTF16, attributed.length), length: 0))
        }

        // The caret, at the cursor's glyph.
        if let layout = textView.layoutManager, let container = textView.textContainer {
            let cursorUTF16 = (String(view.buffer.characters[..<view.buffer.cursor]) as NSString).length
            let glyph = layout.glyphIndexForCharacter(at: min(cursorUTF16, max(0, attributed.length)))
            // A thin bar between characters in insert mode; a block over the
            // character under the cursor otherwise, the width of that glyph.
            let block = view.editor != .insert
            var rect: NSRect
            if attributed.length == 0 {
                rect = NSRect(x: 0, y: 0, width: block ? 8 : 2, height: lineHeight)
            } else if cursorUTF16 >= attributed.length {
                let last = layout.lineFragmentRect(forGlyphAt: max(0, glyph - 1), effectiveRange: nil)
                let lastLoc = layout.location(forGlyphAt: max(0, glyph - 1))
                let lastWidth = layout.boundingRect(forGlyphRange: NSRange(location: max(0, glyph - 1), length: 1), in: container).width
                let endsWithNewline = attributed.string.hasSuffix("\n")
                rect = endsWithNewline
                    ? NSRect(x: 0, y: last.maxY, width: block ? 8 : 2, height: lineHeight)
                    : NSRect(x: lastLoc.x + lastWidth, y: last.minY, width: block ? 8 : 2, height: last.height)
            } else {
                let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let loc = layout.location(forGlyphAt: glyph)
                let glyphWidth = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).width
                let underCursor: Character = view.buffer.cursor < view.buffer.count
                    ? view.buffer.characters[view.buffer.cursor] : " "
                let width = block ? (underCursor == "\n" ? 8 : max(4, glyphWidth)) : 2
                rect = NSRect(x: loc.x, y: line.minY, width: width, height: line.height)
            }
            // Text view coordinates are flipped; the root is not.
            let converted = textView.convert(rect, to: root)
            caret.frame = converted.insetBy(dx: 0, dy: 2)
            caret.layer?.backgroundColor = (block
                ? NSColor.labelColor.withAlphaComponent(0.35) : NSColor.labelColor).cgColor
        }

        let commit = noMic ? "⏎ save to the card" : "⏎ paste"
        let leave = noMic ? "esc back to the clipboard" : "esc close, kept in the clipboard"
        switch view.editor {
        case .insert: footer.stringValue = "\(commit)    ⇧⏎ new line    esc normal mode"
        case .normal: footer.stringValue = "\(commit)    i insert    \(leave)"
        case .visual: footer.stringValue = "\(commit)    d c y on the selection    esc normal mode"
        }
        footer.sizeToFit()
        footer.frame = NSRect(x: Self.padX, y: 8, width: width - Self.padX * 2, height: 15)

        CATransaction.commit()
        NSAnimationContext.endGrouping()

        if !panel.isVisible {
            // The footer fades on the way in, once per opening: the mode
            // legend is a recallable answer like any bar's.
            footerFade.apply(to: footer, delay: footerDelay())
            panel.orderFrontRegardless()
        }
    }

    /// How long the footer waits before painting — `SurfaceFade`'s
    /// verdict for the draft, asked at each opening.
    var footerDelay: () -> TimeInterval = { 0 }
    private let footerFade = FooterFade()

    /// Move the meter without a re-layout: it arrives ten times a second.
    func setLevel(_ level: Float, live: Bool? = nil) {
        let lit = Int((level * Float(Self.meterCount)).rounded(.up))
        let isLive = live ?? (micButton.contentTintColor == Self.live)
        let color = isLive ? Self.live : NSColor.secondaryLabelColor
        for (i, bar) in meterBars.enumerated() {
            bar.layer?.backgroundColor = (i < lit
                ? color.withAlphaComponent(0.95)
                : NSColor.labelColor.withAlphaComponent(0.18)).cgColor
        }
    }

    private static func note(for view: DraftView) -> String {
        if view.replacing { return "replaces the selection" }
        switch view.speech {
        case .preparing(let progress):
            if let progress, progress > 0 { return "preparing speech \(Int(progress * 100))%" }
            return "preparing speech"
        case .denied: return "microphone not allowed, typing only"
        case .unavailable: return "speech needs macOS 26, typing only"
        case .failed(let why): return why
        case .listening:
            if !view.micOn { return "microphone off" }
            return view.mode == .insert ? "" : "microphone waits for insert mode"
        case .paused: return ""
        case nil:
            // Between the door and the recognizer's first word about
            // itself the line used to be blank, and the only cue that the
            // mic was not yet open was the glyph's tint. On a Bluetooth
            // headset that gap is one to three seconds, and words spoken
            // into it are gone.
            return view.micOn ? "opening the microphone" : ""
        }
    }
}

#if DEBUG
extension DraftPanel {
    /// The preview harness's lanes: 0 speaking with a ghost, 1 editing,
    /// 2 the website's photograph.
    static func preview(_ variant: Int) -> DraftPanel {
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
            buffer.settle("Run the migration for")
            buffer.type(" user_sessions")
            buffer.settle("and tail the log, then move the Asana card to the done column.")
            buffer.showGhost("and ping the channel")
            panel.show(DraftView(buffer: buffer, mode: .insert, editor: .insert,
                                 speech: .listening(input: "MacBook Pro Microphone"),
                                 input: "MacBook Pro Microphone", level: 0.6,
                                 inputs: inputs, systemInput: "Cypress", chosenInput: "MacBook Pro Microphone",
                                 micOn: true,
                                 destination: ("Messages", icon), replacing: false))
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
