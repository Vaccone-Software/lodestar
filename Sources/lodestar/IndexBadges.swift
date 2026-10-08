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
            // The one key at peek size, on room for its shadow.
            let key = KeyMark.key("\(item.index)", lit: false, peek: true)
            let margin: CGFloat = 16
            let size = key.frame.width + margin * 2
            let origin = NSPoint(
                x: (item.frame.midX - size / 2).rounded(),
                y: (primaryHeight - item.frame.midY - size / 2).rounded()
            )
            let panel = Glass.makePanel(level: .statusBar)
            panel.ignoresMouseEvents = true
            panel.hasShadow = false
            let root = NSView()
            panel.contentView = root
            key.frame.origin = NSPoint(x: margin, y: margin)
            root.addSubview(key)

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
