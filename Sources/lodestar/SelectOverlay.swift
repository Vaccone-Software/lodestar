import AppKit
import LodestarCore

/// Select's glass: an accent underline under every match, a key at each,
/// the anchor's line heavier, and the editor lens's tags. Every label is
/// the one key, and the only paint is the accent's line.
/// Never key, ignores the mouse — the window underneath keeps focus and
/// receives the selection when the mode commits.
final class SelectOverlay {
    struct Chip: Equatable {
        /// A text match wears its wash — the highlight is the answer — and
        /// its label just above the word. An element target is a box, not
        /// a word: its frame often wraps padding or a whole clickable
        /// region, so a wash is noise and a label floated above the box
        /// detaches from the text the eye actually reads. Targets pin the
        /// label at the frame's top-left corner, overlapping it, the way
        /// hints always did.
        enum Style: Equatable {
            case match, target
            /// The editor's lens: the key and the fix in words, on a tag
            /// above the word; the word's own underline is the editor's.
            case tag(String)
        }

        let label: String
        /// One rect per fragment the match crosses — a phrase over a bold
        /// boundary highlights as several honest rectangles.
        let frames: [CGRect]
        var style: Style = .match

        /// The fix a lens tag carries, if this is one.
        var fix: String? {
            if case .tag(let word) = style { return word }
            return nil
        }
    }

    private let panel: NSPanel
    private let root = NSView()
    private let highlightHost = NSView()
    private let chipHost = NSView()
    private var decorations: [NSView] = []

    /// Clear water between the band and the bottom of the usable screen.

    init() {
        panel = Glass.makePanel(level: .statusBar, takesKeys: false)
        panel.ignoresMouseEvents = true
        // Each mark draws its own soft shadow. The window server's would trace
        // a hard ring round every one.
        panel.hasShadow = false
        panel.contentView = root

        highlightHost.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(highlightHost)
        chipHost.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(chipHost)
        for host in [highlightHost, chipHost] {
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: root.topAnchor),
                host.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                host.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ])
        }

    }

    private static func lift(_ view: NSView) {
        view.wantsLayer = true
        view.layer?.masksToBounds = false
        view.layer?.shadowColor = NSColor.black.withAlphaComponent(0.4).cgColor
        view.layer?.shadowOpacity = 1
        view.layer?.shadowRadius = 3.5
        view.layer?.shadowOffset = CGSize(width: 0, height: -1)
    }

    /// The glass goes up over the window before anything is known: the
    /// pill says what is being read; this only takes its place.
    func showScanning(over windowFrame: CGRect) {
        clear()
        present(over: windowFrame)
    }

    /// The chips a partial capital leaves standing: only those the typed
    /// letters can still complete, so a pick's progress is visible on the
    /// glass and never in the pill.
    static func narrowed(_ chips: [Chip], typed: String) -> [Chip] {
        guard !typed.isEmpty else { return chips }
        return chips.filter { $0.label.lowercased().hasPrefix(typed.lowercased()) }
    }

    /// What stands, for the tests.
    private(set) var shownChips: [Chip] = []
    /// The rest of what the last draw was made of. Four hundred frosted
    /// chips cost a quarter second of the main thread to build, and the
    /// door redraws whenever a new world lands — the harvest, then the
    /// sketch, then the settled read — each time with the identical
    /// labels in the identical places. Drawing that three times is three
    /// stalls the hand feels and one picture it cannot tell apart, so a
    /// draw that would change nothing is not made.
    private var shownAnchor: [CGRect] = []
    private var shownFrame: CGRect = .null
    private var shownTyped: String?

    func show(chips: [Chip], anchor: [CGRect], over windowFrame: CGRect, typed: String = "") {
        if panel.isVisible, chips == shownChips, anchor == shownAnchor,
           windowFrame == shownFrame, typed == shownTyped {
            Log.info("chips", ["count": chips.count, "ms": 0, "reused": true])
            return
        }
        shownChips = chips
        shownAnchor = anchor
        shownFrame = windowFrame
        shownTyped = typed
        // Dozens of frosted chips at once: the instrument times itself.
        let began = Date()
        defer {
            Log.info("chips", ["count": chips.count,
                               "ms": Int(Date().timeIntervalSince(began) * 1000)])
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        defer {
            NSAnimationContext.endGrouping()
            CATransaction.commit()
        }
        clear()
        present(over: windowFrame)
        guard let primary = NSScreen.screens.first else { return }
        let primaryHeight = primary.frame.maxY

        func appKitRect(_ quartz: CGRect) -> NSRect {
            NSRect(x: quartz.minX - panel.frame.minX,
                   y: primaryHeight - quartz.maxY - panel.frame.minY,
                   width: quartz.width, height: quartz.height)
        }

        // The anchor first: the start of the span, its line heavier for as
        // long as the far end is being chosen.
        for rect in anchor {
            let line = KeyMark.underline(under: appKitRect(rect), weight: KeyMark.heavyUnderline)
            highlightHost.addSubview(line)
            decorations.append(line)
        }

        let lit = !typed.isEmpty
        var placedTags: [NSRect] = []
        for chip in Self.narrowed(chips, typed: typed) {
            guard let first = chip.frames.first else { continue }
            let target = appKitRect(first)
            switch chip.style {
            case .tag(let word):
                let tag = KeyMark.tag(letter: chip.label, word: word, lit: lit)
                let placed = Self.place(tag.frame.size, above: target, avoiding: placedTags,
                                        within: NSRect(origin: .zero, size: panel.frame.size))
                tag.frame.origin = placed.frame.origin
                if let x = placed.connectorX {
                    let line = NSView(frame: NSRect(x: x, y: target.maxY, width: 1,
                                                    height: max(0, placed.frame.minY - target.maxY)))
                    line.wantsLayer = true
                    line.layer?.backgroundColor = Glass.resolved(KeyMark.connector, in: root)
                    highlightHost.addSubview(line)
                    decorations.append(line)
                }
                placedTags.append(placed.frame)
                chipHost.addSubview(tag)
                decorations.append(tag)
                continue
            case .match:
                // The match itself, underlined in the accent: the key
                // names it, the line is it.
                for rect in chip.frames {
                    let line = KeyMark.underline(under: appKitRect(rect), weight: KeyMark.underline)
                    highlightHost.addSubview(line)
                    decorations.append(line)
                }
            case .target:
                break
            }
            let key = KeyMark.key(chip.label, lit: lit)
            let width = key.frame.width, height = key.frame.height
            let x = min(max(target.minX - 2, 0), panel.frame.width - width)
            // A match's key floats just above the word; a target's pins to
            // the frame's top-left corner, overlapping it — attached to the
            // box it fires, however large the box.
            let raw = chip.style == .match ? target.maxY + 2 : target.maxY - height + 4
            let y = min(max(raw, 0), panel.frame.height - height)
            key.frame.origin = NSPoint(x: x, y: y)
            chipHost.addSubview(key)
            decorations.append(key)
        }
    }

    /// Where a lens tag stands: just above its word, aligned to it. A tag
    /// that would cover one already placed steps up a row until it is
    /// clear, and a stepped tag is joined to its word by a hairline that
    /// runs clear of the tags beneath it. An undisturbed tag needs none.
    static func place(_ size: NSSize, above target: NSRect, avoiding placed: [NSRect],
                      within bounds: NSRect) -> (frame: NSRect, connectorX: CGFloat?) {
        let gap: CGFloat = 4
        let x = min(max(target.minX - 3, bounds.minX), bounds.maxX - size.width)
        var frame = NSRect(x: x, y: target.maxY + gap, width: size.width, height: size.height)
        var steps = 0
        while steps < 4, placed.contains(where: { $0.insetBy(dx: -gap / 2, dy: -gap / 2).intersects(frame) }) {
            frame.origin.y += size.height + gap
            steps += 1
        }
        frame.origin.y = min(frame.origin.y, bounds.maxY - size.height)
        guard steps > 0 else { return (frame, nil) }
        // The line drops from the tag's foot to the word; it starts near
        // the word's front and moves right past any tag it would cross.
        var lineX = target.minX + 8
        for other in placed.sorted(by: { $0.minX < $1.minX })
        where other.minY < frame.minY && other.maxY > target.maxY && other.minX <= lineX && other.maxX >= lineX {
            lineX = other.maxX + 4
        }
        lineX = min(lineX, max(target.minX + 2, target.maxX - 2))
        lineX = min(max(lineX, frame.minX + 6), frame.maxX - 6)
        return (frame, lineX.rounded())
    }

    /// The held highlight that outlives the mode: the span's rectangles
    /// stay lit and nothing else remains — no band, no chip, no words.
    /// The highlight is the entire statement; what it answers to (⌘C, or
    /// any key to dismiss) lives in the hands and the guide, not on the
    /// glass.
    func hold(spans: [CGRect], over windowFrame: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        clear()
        present(over: windowFrame)
        guard let primary = NSScreen.screens.first else { return }
        let primaryHeight = primary.frame.maxY
        for rect in spans {
            let appKit = NSRect(x: rect.minX - panel.frame.minX,
                                y: primaryHeight - rect.maxY - panel.frame.minY,
                                width: rect.width, height: rect.height)
            let line = KeyMark.underline(under: appKit, weight: KeyMark.heavyUnderline)
            highlightHost.addSubview(line)
            decorations.append(line)
        }
    }

    func hide() {
        clear()
        shownChips = []
        shownAnchor = []
        shownFrame = .null
        shownTyped = nil
        panel.orderOut(nil)
    }

    private func clear() {
        for view in decorations { view.removeFromSuperview() }
        decorations.removeAll()
    }

    private func present(over windowFrame: CGRect) {
        guard let primary = NSScreen.screens.first else { return }
        let primaryHeight = primary.frame.maxY
        let appKit = NSRect(x: windowFrame.minX,
                            y: primaryHeight - windowFrame.maxY,
                            width: windowFrame.width, height: windowFrame.height)
        panel.setFrame(appKit, display: true)
        panel.orderFrontRegardless()
    }
}
