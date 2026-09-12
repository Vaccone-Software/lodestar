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
    static let draftHeight: CGFloat = 112
    static let panelWidth: CGFloat = 240
    static let panelHeight: CGFloat = 168
    /// Open far enough to clear `spacing`, or the panels never break off.
    static let openGap: CGFloat = 44
    static let spacing: CGFloat = 30

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

        func layout(_ progress: CGFloat) {
            let eased = progress * progress * (3 - 2 * progress)
            let gap = openGap * eased
            let w = panelWidth * eased
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
            var t = 0.0
            Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
                t += 1.0 / 60
                let cycle = t.truncatingRemainder(dividingBy: 4.0)
                layout(CGFloat(cycle < 2 ? min(1, cycle / 1.2) : max(0, 1 - (cycle - 2) / 1.2)))
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
            "Run the migration for user_sessions and tail the log, then move the\nAsana card to the done column.")
        words.font = BarTheme.readingMono
        words.textColor = .labelColor
        words.maximumNumberOfLines = 2
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
