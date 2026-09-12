#if DEBUG
import AppKit
import LodestarCore

/// A harness for the draft's keys leaving it sideways, so the motion can
/// be judged from Apple's own material rather than from a drawing of it.
///
/// Three glass views inside one `NSGlassEffectContainerView`: the draft
/// in the middle at its real 720, and a narrow panel either side. The
/// container merges descendants within `spacing` of each other, so at
/// rest the panels are inside the draft's own glass and the split is the
/// system drawing the neck thinning and breaking — not anything we draw.
///
/// `LODESTAR_SPLIT` freezes it at a progress from 0 to 1 so a frame can
/// be photographed exactly; unset, it runs the motion on a loop.
@available(macOS 26.0, *)
enum SplitPreview {
    static let draftWidth: CGFloat = 720
    /// Equal heights on purpose. A panel taller than the draft meets it
    /// at a step, and the container fillets that step into a flare that
    /// reads as the draft's own corner bulging outward — which is not a
    /// neck and does not look like one.
    /// Swept by `LODESTAR_DRAFT_H`: the real draft's height is its
    /// text's, anywhere from 112 empty to the screen's own ceiling.
    static var draftHeight: CGFloat = 168
    /// Measured from the rows, not chosen: the keys decide how wide and
    /// how tall their panel has to be.
    static var panelWidth: CGFloat = 240
    /// The keys' own content height, unless `LODESTAR_PANEL_MATCH` asks
    /// the panels to take the draft's instead.
    static var panelHeight: CGFloat = 168
    /// Each panel's own, so the pair need not be level.
    static var leftHeight: CGFloat = 168
    static var rightHeight: CGFloat = 168
    static let panelContentHeight: CGFloat = 168
    /// Where the panel has finished widening and starts pulling away.
    static let emergeThrough: CGFloat = 0.45
    /// Open far enough to clear `spacing`, or the panels never break off.
    static let openGap: CGFloat = 56
    /// How far apart the container keeps bridging. Larger holds the neck
    /// through more of the gesture, which is the part worth seeing; the
    /// gap has to finish well past it or the panels never let go.
    static let spacing: CGFloat = 55

    private static var held: [NSWindow] = []

    static func run() {
        let env = ProcessInfo.processInfo.environment
        if let h = env["LODESTAR_DRAFT_H"].flatMap(Double.init) { draftHeight = CGFloat(h) }
        // Two answers to the height question, so they can be compared
        // rather than argued about: the keys keep their own height and
        // meet a taller draft at a step, or they take the draft's and
        // stand mostly empty.
        panelHeight = env["LODESTAR_PANEL_MATCH"] == "1" ? draftHeight : panelContentHeight
        let screen = NSScreen.main!.frame
        var width = panelWidth * 2 + openGap * 2 + draftWidth + 120
        var height = max(panelHeight, draftHeight) + 160
        let window = NSPanel(
            contentRect: NSRect(x: screen.midX - width / 2, y: screen.minY + 80,
                                width: width, height: height),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.appearance = NSAppearance(named: .darkAqua)

        let root = NSView(frame: NSRect(origin: .zero, size: NSSize(width: width, height: height)))
        window.contentView = root

        let container = NSGlassEffectContainerView()
        container.frame = root.bounds
        container.autoresizingMask = [.width, .height]
        container.spacing = spacing
        let inner = NSView(frame: root.bounds)
        inner.autoresizingMask = [.width, .height]
        container.contentView = inner
        root.addSubview(container)

        let (left, leftKeys, leftSize) = glass(Self.draftSections)
        let (right, rightKeys, rightSize) = glass(Self.editorSections)
        // Both panels take the wider and the taller, so the pair is
        // symmetric and the draft sits between two equals.
        panelWidth = max(leftSize.width, rightSize.width)
        // Each panel takes its own content's height by default: the
        // editor has four times as much to say as the draft, and forcing
        // them level leaves the left one more than half empty glass.
        // `LODESTAR_PANEL_EQUAL` levels them, to compare.
        let level = env["LODESTAR_PANEL_EQUAL"] == "1"
        let tallest = max(leftSize.height, rightSize.height)
        leftHeight = level ? tallest : leftSize.height
        rightHeight = level ? tallest : rightSize.height
        if env["LODESTAR_PANEL_MATCH"] == "1" {
            leftHeight = draftHeight
            rightHeight = draftHeight
        }
        panelHeight = max(leftHeight, rightHeight)
        Log.info("split", ["panel": "\(Int(panelWidth))x\(Int(panelHeight))",
                           "draft": Int(draftHeight)])
        // The window was sized before the rows had been measured; it has
        // to hold whatever they came to.
        width = panelWidth * 2 + openGap * 2 + draftWidth + 120
        height = max(panelHeight, draftHeight) + 160
        window.setFrame(NSRect(x: screen.midX - width / 2, y: screen.minY + 80,
                               width: width, height: height), display: false)
        root.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        container.frame = root.bounds
        inner.frame = root.bounds
        let middle = draftGlass()
        for view in [left, middle, right] { inner.addSubview(view) }

        /// `KeysMotion`'s own curve — cubic-bezier(0.25, 0.1, 0.25, 1),
        /// the system's for a window changing frame — so the harness is
        /// judged on the timing the surface would actually ship with,
        /// and not on a smoothstep that flatters it.
        func ease(_ t: CGFloat) -> CGFloat {
            var lo: CGFloat = 0, hi: CGFloat = 1, u: CGFloat = t
            func bez(_ a: CGFloat, _ b: CGFloat, _ s: CGFloat) -> CGFloat {
                3 * a * s * (1 - s) * (1 - s) + 3 * b * s * s * (1 - s) + s * s * s
            }
            for _ in 0..<20 {
                u = (lo + hi) / 2
                if bez(0.25, 0.25, u) < t { lo = u } else { hi = u }
            }
            return bez(0.1, 1, u)
        }

        func layout(_ progress: CGFloat) {
            // Two beats. The panel widens out from the draft's edge at no
            // gap, then the pair pulls apart and the bridge thins and
            // breaks. Width and gap on one curve was the original
            // mistake: by the time a panel was wide enough to bridge, the
            // gap had passed `spacing` and the shapes only ever touched.
            //
            // Sliding a full-width panel out from *inside* the draft is
            // the other way to do this, and it costs more than it saves —
            // two tinted glasses overlapping tint twice, so the draft
            // wears vertical bands wherever a panel is parked behind it,
            // for most of the gesture.
            let p = max(0, min(1, progress))
            let widen = ease(min(1, p / emergeThrough))
            let part = ease(max(0, (p - emergeThrough) / (1 - emergeThrough)))
            let gap = openGap * part
            let w = panelWidth * widen
            let floor: CGFloat = 60
            let midX = width / 2
            middle.frame = NSRect(x: midX - draftWidth / 2, y: floor,
                                  width: draftWidth, height: draftHeight)
            left.frame = NSRect(x: midX - draftWidth / 2 - gap - w, y: floor,
                                width: w, height: leftHeight)
            right.frame = NSRect(x: midX + draftWidth / 2 + gap, y: floor,
                                 width: w, height: rightHeight)
            // Nothing at all below a width that can hold its own corner
            // radius: a sliver narrower than its curve merges into the
            // draft as a lump on the edge rather than as a panel leaving.
            for panel in [left, right] { panel.isHidden = w < BarTheme.glassRadius * 2 }
            // The rows appear only once the panel is its full width. They
            // used to be drawn into whatever width the panel had reached,
            // which sliced them mid-word on the way out and, worse, on
            // the way back — the last thing the gesture showed was a
            // column of half-cut words being swallowed.
            let shown = ease(max(0, min(1, (widen - 0.72) / 0.28)))
            leftKeys.alphaValue = shown
            rightKeys.alphaValue = shown
        }

        if let frozen = ProcessInfo.processInfo.environment["LODESTAR_SPLIT"],
           let progress = Double(frozen) {
            layout(CGFloat(progress))
        } else {
            layout(0)
            // The shipping cadence: `KeysMotion.growSeconds` out,
            // `shrinkSeconds` back, and long enough at each end to read
            // the state before it moves again.
            let grow = 0.30, shrink = 0.22, hold = 1.4
            let cycleLength = grow + hold + shrink + hold
            var t = 0.0
            Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
                t += 1.0 / 60
                let c = t.truncatingRemainder(dividingBy: cycleLength)
                let progress: Double
                if c < grow {
                    progress = c / grow
                } else if c < grow + hold {
                    progress = 1
                } else if c < grow + hold + shrink {
                    progress = 1 - (c - grow - hold) / shrink
                } else {
                    progress = 0
                }
                layout(CGFloat(progress))
            }
        }

        window.orderFrontRegardless()
        held.append(window)
    }

    /// The veil as a tint on the glass rather than a view inside it.
    ///
    /// `EqualizerScrim` is a subview clipped to one glass view's bounds,
    /// and a merge is a property of the glass, not of the content: the
    /// neck between two merging views is glass that no scrim covers, so
    /// it shows the adaptive tone and reads as a different material.
    /// `tintColor` tints "the background and glass effect", which is the
    /// thing that merges.
    static var veil: NSColor { NSColor.black.withAlphaComponent(Glass.Weight.normal.bases.dark) }

    /// The draft's own keys, and the editor's whole grammar.
    ///
    /// Built from `CheatSheet.Section` and rendered by
    /// `CheatSheet.columns`, which is what every other surface uses — so
    /// a key is a cap with a chip behind it and a label is plain text,
    /// and the two cannot be mistaken for each other. A harness that
    /// draws its own rows proves nothing about the thing that ships.
    static let draftSections: [CheatSheet.Section] = [
        .init(header: "draft", rows: [
            GuideRow(key: "⏎", label: "paste where it lands"),
            GuideRow(key: "⇧⏎", label: "new line"),
            GuideRow(key: "esc", label: "normal mode"),
        ]),
        .init(header: "typing", rows: [
            GuideRow(key: "⌘Z", label: "undo · ⇧⌘Z redo"),
            GuideRow(key: "⌘A", label: "all of it"),
            GuideRow(key: "⌥⌫", label: "back a word · ⌘⌫ the line"),
        ]),
        .init(header: "doors", rows: [
            GuideRow(keys: ["lode", "."], label: "speak"),
            GuideRow(keys: ["lode", "⇧."], label: "edit what is focused"),
        ]),
    ]

    /// Most of the grammar, deliberately. The point of the right-hand
    /// panel is the motions nobody can guess — and the surrounds and the
    /// quote and bracket objects are not vim at all.
    static let editorSections: [CheatSheet.Section] = [
        .init(header: "move", rows: [
            GuideRow(key: "h j k l", label: "left · down · up · right"),
            GuideRow(key: "w b e", label: "by word · ⇧ by WORD"),
            GuideRow(key: "0 ^ $", label: "line start · first word · end"),
            GuideRow(keys: ["g", "g"], label: "the top · ⇧G the bottom"),
            GuideRow(key: "f t", label: "onto · up to a letter · ⇧ backwards"),
            GuideRow(key: "; ,", label: "that again · and back"),
            GuideRow(key: "{ }", label: "by paragraph"),
            GuideRow(key: "%", label: "the matching bracket"),
        ]),
        .init(header: "change", rows: [
            GuideRow(key: "d c y", label: "delete · change · yank, with a motion"),
            GuideRow(key: "⇧D ⇧C ⇧Y", label: "the same, to the line's end"),
            GuideRow(key: "x r", label: "cut a letter · replace one"),
            GuideRow(key: "p ⇧P", label: "put after · before"),
            GuideRow(key: "~", label: "flip the case"),
            GuideRow(key: ".", label: "that change again"),
            GuideRow(key: "u", label: "undo"),
        ]),
        .init(header: "select", rows: [
            GuideRow(key: "v ⇧V", label: "by character · by line"),
            GuideRow(key: "d c y", label: "on the selection"),
            GuideRow(key: "o", label: "jump to its other end"),
        ]),
        .init(header: "wrap · not vim", rows: [
            GuideRow(keys: ["s", "a"], label: "surround a span"),
            GuideRow(keys: ["s", "d"], label: "unwrap it"),
            GuideRow(keys: ["s", "r"], label: "swap the delimiters"),
            GuideRow(key: "q b", label: "any quote · any bracket, as objects"),
        ]),
    ]

    /// One panel: the sections down a column, in the app's own rows.
    private static func glass(_ sections: [CheatSheet.Section])
        -> (NSGlassEffectView, NSView, NSSize) {
        let view = NSGlassEffectView()
        view.cornerRadius = BarTheme.glassRadius
        view.tintColor = veil
        let host = NSView()
        host.wantsLayer = true
        host.autoresizingMask = [.width, .height]
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = ModePill.inset
        stack.translatesAutoresizingMaskIntoConstraints = false
        for section in sections {
            stack.addArrangedSubview(CheatSheet.columns([section]))
        }
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: BarKeys.inset),
            stack.topAnchor.constraint(equalTo: host.topAnchor, constant: BarKeys.inset),
        ])
        host.clipsToBounds = true
        view.contentView = host
        stack.layoutSubtreeIfNeeded()
        let fitting = stack.fittingSize
        let natural = NSSize(width: (fitting.width + BarKeys.inset * 2).rounded(.up),
                             height: (fitting.height + BarKeys.inset * 2).rounded(.up))
        return (view, host, natural)
    }

    private static func draftGlass() -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.cornerRadius = BarTheme.glassRadius
        view.tintColor = veil
        let scrim = NSView()
        scrim.wantsLayer = true
        scrim.autoresizingMask = [.width, .height]
        let name = NSTextField(labelWithString: "Messages")
        name.font = BarTheme.rowLabelFont
        name.textColor = .labelColor
        name.translatesAutoresizingMaskIntoConstraints = false
        let mode = NSTextField(labelWithString: "INSERT")
        mode.font = BarTheme.chipFont
        mode.textColor = BarTheme.secondaryColor
        mode.translatesAutoresizingMaskIntoConstraints = false
        let words = NSTextField(labelWithString:
            "Run the migration for user_sessions and tail the log, then move the\nAsana card to the done column, then let the team know it landed\nand check the dashboard once the backfill has caught up.")
        words.font = BarTheme.readingMono
        words.textColor = .labelColor
        words.maximumNumberOfLines = 3
        words.translatesAutoresizingMaskIntoConstraints = false
        for v in [name, mode, words] { scrim.addSubview(v) }
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: scrim.leadingAnchor, constant: 22),
            name.topAnchor.constraint(equalTo: scrim.topAnchor, constant: 12),
            mode.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 14),
            mode.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            words.leadingAnchor.constraint(equalTo: scrim.leadingAnchor, constant: 22),
            words.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 8),
        ])
        scrim.clipsToBounds = true
        view.contentView = scrim
        return view
    }
}
#endif
