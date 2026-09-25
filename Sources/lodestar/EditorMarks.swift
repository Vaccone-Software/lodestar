import AppKit
import LodestarCore

/// Where the marks are drawn — the screen in the app, a ledger in the tests.
protocol EditorMarksDrawing: AnyObject {
    func show(_ rects: [CGRect], over window: CGRect)
    func hide()
}

/// The line under each mistake: thin, in the accent, drawn over the app on
/// a pane that ignores the mouse and never takes focus. Nothing else — no
/// widget, no count, no motion. Silence is the statement that all is well.
final class EditorMarks: EditorMarksDrawing {
    private let panel: NSPanel
    private let canvas = Canvas()
    private(set) var shown: [CGRect] = []

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = canvas
    }

    /// Rects in quartz coordinates (top-left origin), over `window`.
    func show(_ rects: [CGRect], over window: CGRect) {
        guard !rects.isEmpty, let primary = NSScreen.screens.first else { hide(); return }
        if panel.isVisible, rects == shown, canvas.window == panel, panel.frame == appKit(window, primary) { return }
        shown = rects
        let frame = appKit(window, primary)
        panel.setFrame(frame, display: false)
        canvas.lines = rects.map { rect in
            // The rectangle's bottom edge is the text's descent: the line
            // sits just inside it, where an underline belongs.
            let y = primary.frame.maxY - rect.maxY - frame.minY + 1.5
            return (x: rect.minX - frame.minX, width: rect.width, y: y)
        }
        canvas.needsDisplay = true
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        guard panel.isVisible || !shown.isEmpty else { return }
        shown = []
        panel.orderOut(nil)
    }

    private func appKit(_ quartz: CGRect, _ primary: NSScreen) -> NSRect {
        NSRect(x: quartz.minX, y: primary.frame.maxY - quartz.maxY, width: quartz.width, height: quartz.height)
    }

    private final class Canvas: NSView {
        var lines: [(x: CGFloat, width: CGFloat, y: CGFloat)] = []
        override var isOpaque: Bool { false }
        override func draw(_ dirtyRect: NSRect) {
            BarTheme.accent.withAlphaComponent(0.9).setStroke()
            for line in lines {
                let path = NSBezierPath()
                path.lineWidth = 2
                path.lineCapStyle = .round
                path.move(to: NSPoint(x: line.x + 1, y: line.y))
                path.line(to: NSPoint(x: line.x + line.width - 1, y: line.y))
                path.stroke()
            }
        }
    }
}
