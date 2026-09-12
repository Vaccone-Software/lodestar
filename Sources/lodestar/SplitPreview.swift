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
    static let draftHeight: CGFloat = 168
    static let panelWidth: CGFloat = 240
    static let panelHeight: CGFloat = 168
    /// Where the panel has finished widening and starts pulling away.
    /// Width and gap used to grow together, so by the time a panel was
    /// big enough to bridge, the gap had already passed `spacing` and
    /// there was nothing to bridge: the shapes only ever touched, and a
    /// union is not a neck. The panel comes out from under the draft
    /// first, then leaves.
    static let emergeThrough: CGFloat = 0.45
    /// Open far enough to clear `spacing`, or the panels never break off.
    static let openGap: CGFloat = 56
    /// How far apart the container keeps bridging. Larger holds the neck
    /// through more of the gesture, which is the part worth seeing; the
    /// gap has to finish well past it or the panels never let go.
    static let spacing: CGFloat = 55

    private static var held: [NSWindow] = []

    static func run() {
        let screen = NSScreen.main!.frame
        let width = panelWidth * 2 + openGap * 2 + draftWidth + 120
        let height = panelHeight + draftHeight + 160
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

        let left = glass(rows: [("⏎", "paste"), ("⇧⏎", "new line"), ("esc", "normal mode"),
                                ("⌘Z", "undo"), ("lode .", "speak")], header: "draft")
        let right = glass(rows: [("h j k l", "move"), ("w b e", "by word"), ("d c y", "change"),
                                 ("sa sd sr", "surround"), ("v V", "select")], header: "editor")
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
            let p = max(0, min(1, progress))
            // Two beats in one gesture: the panel widens out from under
            // the draft, then the pair pulls apart and the bridge between
            // them thins and breaks.
            let widen = ease(min(1, p / emergeThrough))
            let part = ease(max(0, (p - emergeThrough) / (1 - emergeThrough)))
            let eased = widen
            let gap = openGap * part
            let w = panelWidth * widen
            let floor: CGFloat = 60
            let midX = width / 2
            middle.frame = NSRect(x: midX - draftWidth / 2, y: floor,
                                  width: draftWidth, height: draftHeight)
            // The panels sit on the draft's own floor and grow out of its
            // edges, so at rest they are inside its glass entirely.
            // Full height from the first frame: only the width opens. A
            // panel that grows in both directions pinches the merge into
            // a droplet at one corner; at full height the neck spans the
            // whole edge the two shapes share.
            left.frame = NSRect(x: midX - draftWidth / 2 - gap - w, y: floor,
                                width: w, height: panelHeight)
            right.frame = NSRect(x: midX + draftWidth / 2 + gap, y: floor,
                                 width: w, height: panelHeight)
            for panel in [left, right] { panel.alphaValue = min(1, max(0, (eased - 0.15) / 0.5)) }
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

    private static func glass(rows: [(String, String)], header: String) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.cornerRadius = BarTheme.glassRadius
        view.tintColor = veil
        let scrim = NSView()
        scrim.wantsLayer = true
        scrim.autoresizingMask = [.width, .height]
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: header)
        title.font = BarTheme.bodyFont
        title.textColor = BarTheme.secondaryColor
        stack.addArrangedSubview(title)
        for (cap, label) in rows {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            let key = NSTextField(labelWithString: cap)
            key.font = BarTheme.readingMono
            key.textColor = .labelColor
            let text = NSTextField(labelWithString: label)
            text.font = BarTheme.bodyFont
            text.textColor = .labelColor
            row.addArrangedSubview(key)
            row.addArrangedSubview(text)
            stack.addArrangedSubview(row)
        }
        scrim.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scrim.leadingAnchor, constant: 20),
            stack.topAnchor.constraint(equalTo: scrim.topAnchor, constant: 18),
        ])
        scrim.clipsToBounds = true
        view.contentView = scrim
        return view
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
