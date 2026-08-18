import AppKit

/// The app's tone: the system's choice, and nothing else. Liquid Glass
/// would rather adapt per panel to whatever sits behind it — that is how
/// the launcher and its ⌘K card once resolved to opposite tones a foot
/// apart, and how dark-mode text landed on light-adapted glass and
/// vanished. We keep the frost and take away the material's vote.
enum Tone {
    static var systemDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

/// The quiet layer between glass and text that guarantees the two agree.
/// Text everywhere resolves from the system appearance; the material
/// adapts to its backdrop and stamps that choice onto its contentView's
/// appearance — this view's. The scrim uses the stamp as a sensor and
/// equalizes toward the system's tone: a light veil when the material
/// already agrees (the frost stays the star), a heavy one when the
/// backdrop pulled it the other way. Live, so theme switches and
/// backdrop changes both re-resolve.
final class EqualizerScrim: NSView {
    /// Veil strength when the material agrees with the system tone.
    /// Callers tune these; the opposed-material weights are fixed.
    var darkBase: CGFloat = 0.32
    var lightBase: CGFloat = 0.42

    private var themeObserver: NSObjectProtocol?

    override var wantsUpdateLayer: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, themeObserver == nil else { return }
        // The material's stamp does not change when the user switches
        // themes (it tracks the backdrop), so a long-lived scrim would
        // never hear about the new target without listening for it.
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.needsDisplay = true }
        }
    }

    deinit {
        if let themeObserver {
            DistributedNotificationCenter.default().removeObserver(themeObserver)
        }
    }

    override func updateLayer() {
        let materialDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if Tone.systemDark {
            layer?.backgroundColor = NSColor.black
                .withAlphaComponent(materialDark ? darkBase : max(darkBase, 0.72)).cgColor
        } else {
            layer?.backgroundColor = NSColor.white
                .withAlphaComponent(materialDark ? max(lightBase, 0.80) : lightBase).cgColor
        }
    }
}

/// Liquid Glass where the OS provides it (macOS 26+), vibrancy fallback
/// everywhere else. The backdrop is installed as a sibling pinned under the
/// content, so both paths behave identically.
enum Glass {
    @discardableResult
    static func installBackdrop(in root: NSView, cornerRadius: CGFloat) -> NSView {
        let backdrop: NSView
        if #available(macOS 26.0, *) {
            // Regular glass, deliberately: the frost is the panel's beauty
            // AND half its contrast — clear glass let the world through
            // sharp and made everything worse. The scrim rides inside it.
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            let scrim = EqualizerScrim()
            scrim.wantsLayer = true
            scrim.layer?.cornerRadius = cornerRadius
            scrim.autoresizingMask = [.width, .height]
            glass.contentView = scrim
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
        // Titled + fullSizeContentView, exactly like the searcher's
        // KeyablePanel — and not for the shadow this time. Liquid Glass
        // senses its backdrop through the window: behind a raw borderless
        // panel it reads the wallpaper and adapts tone per panel, so the
        // ⌘K card could resolve white beside a charcoal launcher. Behind a
        // titled window it honors the window's appearance — the pinned
        // dark holds.
        let panel = GlassPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovable = false
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
    static let rowRadius: CGFloat = 18
    static let chipRadius: CGFloat = 5
    /// One key-and-label row, shared by every surface that draws them: the
    /// chain guide, the cheat sheet, and the clipboard's actions menu. Left
    /// to themselves they drifted into three chip shapes, three keycap
    /// sizes and three icon sizes; this is the one set.
    static let chipMinWidth: CGFloat = 30
    static let chipHeight: CGFloat = 20
    static let chipPadX: CGFloat = 6
    static let rowGap: CGFloat = 9
    static let rowIcon: CGFloat = 17
    /// Clear water between the longest label and the key column, so the two
    /// never read as one run of text.
    static let rowKeyGap: CGFloat = 28

    static let inputFont = NSFont.systemFont(ofSize: 23, weight: .regular)
    static let inputSymbol = NSImage.SymbolConfiguration(pointSize: 19, weight: .medium)
    static let titleFont = NSFont.systemFont(ofSize: 16, weight: .regular)
    static let secondaryFont = NSFont.systemFont(ofSize: 11.5, weight: .regular)
    /// What a key's row says it does — the reading size, not a caption.
    static let rowLabelFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let chipFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold)
    static let footerFont = NSFont.systemFont(ofSize: 11, weight: .regular)
}
