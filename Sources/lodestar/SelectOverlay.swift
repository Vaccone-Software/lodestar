import AppKit
import LodestarCore

/// Select's glass: accent highlights on every match, a capital chip at
/// each, the anchor held in a stronger tint, and a query band along the
/// bottom that shows what has been typed and what stage the span is in.
/// Never key, ignores the mouse — the window underneath keeps focus and
/// receives the selection when the mode commits.
final class SelectOverlay {
    struct Chip {
        let label: String
        /// One rect per fragment the match crosses — a phrase over a bold
        /// boundary highlights as several honest rectangles.
        let frames: [CGRect]
    }

    struct State {
        let appName: String
        let query: String
        let typedLabel: String
        let shown: Int
        let total: Int
        let stage: Stage
        let scanning: Bool

        enum Stage { case start, end }
    }

    private let panel: NSPanel
    private let root = NSView()
    private let highlightHost = NSView()
    private let chipHost = NSView()
    private var decorations: [NSView] = []
    private let status = NSTextField(labelWithString: "")
    private let statusChip = NSView()

    private static let chipFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    private static let chipHeight: CGFloat = 18

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

        statusChip.translatesAutoresizingMaskIntoConstraints = false
        Glass.installBackdrop(in: statusChip, cornerRadius: 10)
        Self.lift(statusChip)
        status.font = .monospacedSystemFont(ofSize: 11.5, weight: .medium)
        status.textColor = .labelColor
        status.translatesAutoresizingMaskIntoConstraints = false
        statusChip.addSubview(status)
        root.addSubview(statusChip)
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: statusChip.leadingAnchor, constant: 9),
            status.trailingAnchor.constraint(equalTo: statusChip.trailingAnchor, constant: -9),
            status.topAnchor.constraint(equalTo: statusChip.topAnchor, constant: 4),
            status.bottomAnchor.constraint(equalTo: statusChip.bottomAnchor, constant: -4),
            statusChip.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            statusChip.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])
    }

    private static func lift(_ view: NSView) {
        view.wantsLayer = true
        view.layer?.masksToBounds = false
        view.layer?.shadowColor = NSColor.black.withAlphaComponent(0.4).cgColor
        view.layer?.shadowOpacity = 1
        view.layer?.shadowRadius = 3.5
        view.layer?.shadowOffset = CGSize(width: 0, height: -1)
    }

    func showScanning(over windowFrame: CGRect, appName: String) {
        clear()
        present(over: windowFrame)
        statusChip.isHidden = false
        status.stringValue = "⌖ select · \(appName) · scanning…"
    }

    func show(chips: [Chip], anchor: [CGRect], over windowFrame: CGRect, state: State) {
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
        statusChip.isHidden = false
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
            view.layer?.backgroundColor = NSColor.controlAccentColor
                .withAlphaComponent(0.45).cgColor
            view.layer?.cornerRadius = 3
            view.frame = appKitRect(rect).insetBy(dx: -1.5, dy: -1.5)
            highlightHost.addSubview(view)
            decorations.append(view)
        }

        for chip in chips {
            // The match itself, washed in accent — the chip names it, the
            // highlight is it.
            for rect in chip.frames {
                let highlight = NSView()
                highlight.wantsLayer = true
                highlight.layer?.backgroundColor = NSColor.controlAccentColor
                    .withAlphaComponent(0.22).cgColor
                highlight.layer?.cornerRadius = 3
                highlight.frame = appKitRect(rect).insetBy(dx: -1.5, dy: -1.5)
                highlightHost.addSubview(highlight)
                decorations.append(highlight)
            }
            guard let first = chip.frames.first else { continue }

            // Literally the hints chip — one design, one factory.
            let (cap, label) = GlassChip.make(chip.label)
            let width = label.frame.width + 7
            let height = GlassChip.height
            let target = appKitRect(first)
            // Above the match, hugging its start; clamped to the overlay.
            let x = min(max(target.minX - 2, 0), panel.frame.width - width)
            let y = min(max(target.maxY + 1, 0), panel.frame.height - height)
            cap.frame = NSRect(x: x, y: y, width: width, height: height)
            label.frame = NSRect(x: 0, y: (height - label.frame.height) / 2,
                                 width: width, height: label.frame.height)
            chipHost.addSubview(cap)
            decorations.append(cap)
        }

        status.attributedStringValue = Self.bandLine(state: state, empty: chips.isEmpty)
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
            view.layer?.backgroundColor = NSColor.controlAccentColor
                .withAlphaComponent(0.35).cgColor
            view.layer?.cornerRadius = 3
            view.frame = NSRect(x: rect.minX - panel.frame.minX - 1.5,
                                y: primaryHeight - rect.maxY - panel.frame.minY - 1.5,
                                width: rect.width + 3, height: rect.height + 3)
            highlightHost.addSubview(view)
            decorations.append(view)
        }
        statusChip.isHidden = true
    }

    /// The band's line, typeset so the query is the protagonist: what you
    /// have typed stands large in the accent — the same accent that means
    /// "your typed prefix" on a narrowing hint chip — while everything
    /// around it recedes to quiet secondary text. One field, mixed sizes,
    /// baseline-aligned; no new surfaces, no ornament.
    static func bandLine(state: State, empty: Bool) -> NSAttributedString {
        let line = NSMutableAttributedString()
        func quiet(_ text: String) {
            line.append(NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        func loud(_ text: String, color: NSColor = .controlAccentColor) {
            line.append(NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .bold),
                .foregroundColor: color,
            ]))
        }
        quiet("⌖ ")
        if state.query.isEmpty {
            quiet(state.stage == .start
                ? "type what you see"
                : "now the far end · ⌫ re-opens the start")
        } else {
            loud(state.query)
            if !state.typedLabel.isEmpty {
                loud(" " + state.typedLabel.uppercased() + "…", color: .labelColor)
            }
            quiet(state.shown == state.total
                ? "  ·  \(state.shown)"
                : "  ·  \(state.shown) of \(state.total)+")
            quiet("  ·  ⇧letter " + (state.stage == .start ? "anchors" : "selects"))
        }
        quiet("  ·  esc")
        return line
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
