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

    private let textView = NSTextView()
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
    private static let font = NSFont.systemFont(ofSize: 17, weight: .regular)
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

    func show(_ view: DraftView) {
        let screen = ActivePolicy.presentationFrame
        let width = min(Self.width, screen.width - Self.margin * 2)
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
        textView.textStorage?.setAttributedString(attributed)
        textView.frame.size.width = textWidth
        textView.textContainer?.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let used = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 0
        let lineHeight = textView.layoutManager?.defaultLineHeight(for: Self.font) ?? 22
        let maxTextHeight = max(Self.minTextHeight, screen.height * 0.4)
        let textHeight = min(maxTextHeight, max(Self.minTextHeight, used + lineHeight * 0.4))
        scroll.hasVerticalScroller = used > maxTextHeight

        let height = Self.registerHeight + textHeight + Self.footerHeight + 14
        let frame = NSRect(x: screen.midX - width / 2,
                           y: screen.minY + Self.margin,
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
        if let destination = view.destination {
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
        place(micButton, x: trailing - 20, width: 20, height: 20)
        trailing -= 28
        for (i, bar) in meterBars.enumerated() {
            let h = bar.frame.height
            bar.isHidden = !listening
            place(bar, x: trailing - 3 - CGFloat(Self.meterCount - 1 - i) * 5, width: 3, height: h)
        }
        if listening { trailing -= CGFloat(Self.meterCount) * 5 + 10 }
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
        inputPopup.isHidden = view.speech == nil && !view.micOn
        // Sized to the title on show, not the longest item: the arrow
        // sits beside the name, not at the end of the widest device.
        let titleWidth = (inputPopup.titleOfSelectedItem ?? "").size(withAttributes: [.font: BarTheme.secondaryFont]).width
        let popupWidth = min(titleWidth + 30, max(80, trailing - x - 8))
        if !inputPopup.isHidden {
            place(inputPopup, x: trailing - popupWidth, width: popupWidth, height: 22)
            trailing -= popupWidth + 8
        }

        registerNote.stringValue = Self.note(for: view)
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

        switch view.editor {
        case .insert: footer.stringValue = "⏎ paste    ⇧⏎ new line    esc normal mode"
        case .normal: footer.stringValue = "⏎ paste    i insert    esc close, kept in the clipboard"
        case .visual: footer.stringValue = "⏎ paste    d c y on the selection    esc normal mode"
        }
        footer.sizeToFit()
        footer.frame = NSRect(x: Self.padX, y: 8, width: width - Self.padX * 2, height: 15)

        CATransaction.commit()
        NSAnimationContext.endGrouping()

        if !panel.isVisible { panel.orderFrontRegardless() }
    }

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
        case .paused, nil: return ""
        }
    }
}

#if DEBUG
extension DraftPanel {
    /// The preview harness's lanes: 0 speaking with a ghost, 1 editing.
    static func preview(_ variant: Int) -> DraftPanel {
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
