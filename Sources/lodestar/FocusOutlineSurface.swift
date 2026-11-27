import AppKit
import LodestarCore

/// The faint accent line round the window the keys go to, while that window
/// is one of a Lodestar layout of two or more and still where the layout
/// left it. `FocusOutline` decides; this draws, and asks again whenever the
/// focus, a frame, the layout, the Space or the apps' visibility changes.
///
/// It stands one level above normal windows: the window it outlines may
/// rise past anything at the normal level (activating an app raises all its
/// windows, and a click on a title bar raises one), so an outline ordered
/// just above its window sank under it after most switches. Above the
/// normal level nothing can rise over it, and whatever another app puts
/// over the window hides the outline instead (`FocusOutline`). Palettes,
/// menus and Lodestar's own bars stand higher still, over the outline.
final class FocusOutlineSurface {
    private let model: WindowModel
    private let layout: LayoutController
    /// The window server's on-screen windows, front to back. A seam for
    /// tests, which have no other app's windows to ask about.
    var stack: () -> [CGWindowRecord] = { CGWindows.list(onScreenOnly: true) }

    private var panel: NSPanel?
    private let shape = CAShapeLayer()
    private var shownFrame: CGRect?
    private var tokens: [any NSObjectProtocol] = []

    /// What is outlined now, in Quartz coordinates; nil when nothing is.
    var outlined: CGRect? { shownFrame }

    init(model: WindowModel, layout: LayoutController) {
        self.model = model
        self.layout = layout
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
    }

    func refresh() {
        guard let focused = model.focusedWindow,
              let display = layout.display(of: focused.id),
              let placed = layout.placedFrame(of: focused.id) else { return hide() }
        let members = layout.members(on: display)
        // The window list is asked for only once everything cheaper agrees.
        guard members.count >= 2, FocusOutline.stands(focused.frame, at: placed) else { return hide() }
        guard let frame = FocusOutline.frame(focused: focused, members: members,
                                             placed: placed, stack: stack()) else { return hide() }
        show(frame)
    }

    private func show(_ frame: CGRect) {
        let panel = self.panel ?? makeWindow()
        let cocoa = NSRect(x: frame.minX, y: Screens.primaryHeight - frame.maxY,
                           width: frame.width, height: frame.height).integral
        if shownFrame != frame || !panel.isVisible {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            panel.setFrame(cocoa, display: false)
            let inset = BarTheme.Outline.width / 2
            shape.frame = CGRect(origin: .zero, size: cocoa.size)
            shape.path = CGPath(roundedRect: shape.bounds.insetBy(dx: inset, dy: inset),
                                cornerWidth: BarTheme.Outline.corner, cornerHeight: BarTheme.Outline.corner,
                                transform: nil)
            CATransaction.commit()
        }
        // Resolved each time it is shown, so the look the Mac is in now is
        // the one it is drawn in.
        shape.strokeColor = Ceramic.resolved(BarTheme.accent, in: panel.contentView)
        shownFrame = frame
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func hide() {
        shownFrame = nil
        panel?.orderOut(nil)
    }

    private func makeWindow() -> NSPanel {
        // A line, not a pane: no glass, so no surface's shadow either (the
        // chrome's grammar), and never a key window, so no title bar is
        // needed to keep the window server from etching an edge.
        let panel = NSPanel(contentRect: BarTheme.unplaced, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        let root = NSView()
        root.wantsLayer = true
        shape.fillColor = nil
        shape.lineWidth = BarTheme.Outline.width
        root.layer?.addSublayer(shape)
        panel.contentView = root
        self.panel = panel
        return panel
    }
}
