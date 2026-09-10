import AppKit
import LodestarCore

/// Select's glass: accent highlights on every match, a capital chip at
/// each, the anchor held in a stronger tint, and a query band along the
/// bottom that shows what has been typed and what stage the span is in.
/// Never key, ignores the mouse — the window underneath keeps focus and
/// receives the selection when the mode commits.
final class SelectOverlay {
    struct Chip {
        /// A text match wears its wash — the highlight is the answer — and
        /// its label just above the word. An element target is a box, not
        /// a word: its frame often wraps padding or a whole clickable
        /// region, so a wash is noise and a label floated above the box
        /// detaches from the text the eye actually reads. Targets pin the
        /// label at the frame's top-left corner, overlapping it, the way
        /// hints always did.
        enum Style { case match, target }

        let label: String
        /// One rect per fragment the match crosses — a phrase over a bold
        /// boundary highlights as several honest rectangles.
        let frames: [CGRect]
        var style: Style = .match
    }

    private let panel: NSPanel
    private let root = NSView()
    private let highlightHost = NSView()
    private let chipHost = NSView()
    private var decorations: [NSView] = []

    private static let chipFont = NSFont.monospacedSystemFont(ofSize: BarTheme.Scale.meta, weight: .bold)
    private static let chipHeight: CGFloat = 20
    /// Clear water between the band and the bottom of the usable screen.

    init() {
        panel = Glass.makePanel(level: .statusBar)
        panel.ignoresMouseEvents = true
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

    func show(chips: [Chip], anchor: [CGRect], over windowFrame: CGRect, typed: String = "") {
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

        // The anchor first: the start of the span, held in a stronger tint
        // for as long as the far end is being chosen.
        for rect in anchor {
            let view = NSView()
            view.wantsLayer = true
            view.layer?.backgroundColor = BarTheme.accent
                .withAlphaComponent(0.45).cgColor
            view.layer?.cornerRadius = BarTheme.highlightRadius
            view.frame = appKitRect(rect).insetBy(dx: -1.5, dy: -1.5)
            highlightHost.addSubview(view)
            decorations.append(view)
        }

        for chip in Self.narrowed(chips, typed: typed) {
            if chip.style == .match {
                // The match itself, washed in accent — the chip names it,
                // the highlight is it.
                for rect in chip.frames {
                    let highlight = NSView()
                    highlight.wantsLayer = true
                    highlight.layer?.backgroundColor = BarTheme.accent
                        .withAlphaComponent(0.22).cgColor
                    highlight.layer?.cornerRadius = BarTheme.highlightRadius
                    highlight.frame = appKitRect(rect).insetBy(dx: -1.5, dy: -1.5)
                    highlightHost.addSubview(highlight)
                    decorations.append(highlight)
                }
            }
            guard let first = chip.frames.first else { continue }

            // Literally the hints chip — one design, one factory. The
            // letters already typed of the label wear the accent.
            let (cap, label) = GlassChip.make(chip.label, lit: typed.count)
            let width = label.frame.width + 7
            let height = GlassChip.height
            let target = appKitRect(first)
            let x = min(max(target.minX - 2, 0), panel.frame.width - width)
            // A match's label floats just above the word; a target's pins
            // to the frame's top-left corner, overlapping it — attached to
            // the box it fires, however large the box.
            let raw = chip.style == .match ? target.maxY + 1 : target.maxY - height + 4
            let y = min(max(raw, 0), panel.frame.height - height)
            cap.frame = NSRect(x: x, y: y, width: width, height: height)
            label.frame = NSRect(x: 0, y: (height - label.frame.height) / 2,
                                 width: width, height: label.frame.height)
            chipHost.addSubview(cap)
            decorations.append(cap)
        }
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
            let view = NSView()
            view.wantsLayer = true
            view.layer?.backgroundColor = BarTheme.accent
                .withAlphaComponent(0.35).cgColor
            view.layer?.cornerRadius = BarTheme.highlightRadius
            view.frame = NSRect(x: rect.minX - panel.frame.minX - 1.5,
                                y: primaryHeight - rect.maxY - panel.frame.minY - 1.5,
                                width: rect.width + 3, height: rect.height + 3)
            highlightHost.addSubview(view)
            decorations.append(view)
        }
    }

    func hide() {
        clear()
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
