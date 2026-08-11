import AppKit

/// Liquid Glass where the OS provides it (macOS 26+), vibrancy fallback
/// everywhere else. The backdrop is installed as a sibling pinned under the
/// content, so both paths behave identically.
enum Glass {
    @discardableResult
    static func installBackdrop(in root: NSView, cornerRadius: CGFloat) -> NSView {
        let backdrop: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            backdrop = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = cornerRadius
            effect.layer?.masksToBounds = true
            backdrop = effect
        }
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(backdrop, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: root.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        return backdrop
    }

    static func makePanel(level: NSWindow.Level) -> NSPanel {
        let panel = GlassPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = level
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        return panel
    }
}

/// A borderless glass panel whose shadow survives reframing. The window
/// server derives a window's shadow from its opaque content, but glass
/// composites out-of-process: the shape it sees at order-in is empty, and
/// it never asks again. Without the shadow the pane sits flush on the
/// wallpaper and its rim reads as a drawn rectangle instead of an edge.
/// Re-deriving after every reframe and every ordering keeps it lifted.
class GlassPanel: NSPanel {
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        invalidateShadow()
    }

    override func orderFront(_ sender: Any?) {
        super.orderFront(sender)
        invalidateShadow()
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        invalidateShadow()
    }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        invalidateShadow()
    }
}

/// One visual system for every bar. The searcher, web bar, and menu
/// search must feel like a single instrument — same width, rhythm, and
/// type — so the tokens live here, where drift can't hide in literals.
enum BarTheme {
    static let panelWidth: CGFloat = 640
    static let inputHeight: CGFloat = 60
    static let rowHeight: CGFloat = 48
    static let footerHeight: CGFloat = 24
    static let glassRadius: CGFloat = 18
    static let rowRadius: CGFloat = 11
    static let chipRadius: CGFloat = 5

    static let inputFont = NSFont.systemFont(ofSize: 23, weight: .regular)
    static let inputSymbol = NSImage.SymbolConfiguration(pointSize: 19, weight: .medium)
    static let titleFont = NSFont.systemFont(ofSize: 16, weight: .regular)
    static let secondaryFont = NSFont.systemFont(ofSize: 11.5, weight: .regular)
    static let chipFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold)
    static let footerFont = NSFont.systemFont(ofSize: 11, weight: .regular)
}
