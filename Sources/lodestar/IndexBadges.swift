import AppKit

/// Big numerals over each layout member while lode is held (peek):
/// `lode 1…9` taught the same way peek teaches the graph. Static — they
/// appear, sit still, and vanish on release.
final class IndexBadges {
    private var panels: [NSPanel] = []

    /// Frames arrive in Quartz coordinates (top-left origin).
    func show(_ items: [(index: Int, frame: CGRect)]) {
        hide()
        guard let primary = NSScreen.screens.first else { return }
        let primaryHeight = primary.frame.maxY

        for item in items.prefix(10) {
            let size: CGFloat = 56
            let origin = NSPoint(
                x: item.frame.midX - size / 2,
                y: primaryHeight - item.frame.midY - size / 2
            )
            let panel = Glass.makePanel(level: .statusBar)
            panel.ignoresMouseEvents = true
            let root = NSView()
            panel.contentView = root
            Glass.installBackdrop(in: root, cornerRadius: 14)

            let label = NSTextField(labelWithString: "\(item.index)")
            let base = NSFont.systemFont(ofSize: 27, weight: .bold)
            let rounded = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 27) }
            label.font = rounded ?? base
            label.textColor = .labelColor
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: root.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            ])

            panel.setFrame(NSRect(origin: origin, size: NSSize(width: size, height: size)), display: true)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
    }

    func hide() {
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
    }
}
