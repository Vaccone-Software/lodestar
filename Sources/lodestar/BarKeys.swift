import AppKit
import LodestarCore

/// The keys a bar holds when asked: the sections as columns beneath its
/// rows, inside the bar's own glass, with air and no line between. The
/// bar grows to hold them and shrinks when they go; nothing arrives
/// beside it.
final class BarKeys {
    private weak var root: NSView?
    private weak var rows: NSView?
    private var view: NSView?
    private(set) var isShown = false

    /// The columns' inset from the glass, the field's own.
    static let inset: CGFloat = 22
    /// Air between the last row and the columns, the pill's own.
    static let above: CGFloat = ModePill.inset

    func install(root: NSView, below rows: NSView) {
        self.root = root
        self.rows = rows
    }

    /// The height the bar owes its keys: zero while they are away.
    var height: CGFloat {
        guard isShown, let view else { return 0 }
        return Self.above + view.fittingSize.height + ModePill.inset
    }

    /// Builds the keys in place, invisible, and reports the view so the
    /// bar can reveal it once its glass has grown.
    @discardableResult
    func show(_ sections: [CheatSheet.Section]) -> NSView? {
        guard let root, let rows else { return nil }
        view?.removeFromSuperview()
        let columns = CheatSheet.columns(sections)
        columns.alphaValue = 0
        root.addSubview(columns)
        // Below required, so a wide label truncates inside the bar rather
        // than pushing the glass wider than the bar it belongs to.
        let trailing = columns.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -Self.inset)
        trailing.priority = .init(999)
        NSLayoutConstraint.activate([
            trailing,
            columns.topAnchor.constraint(equalTo: rows.bottomAnchor, constant: Self.above),
            columns.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.inset),
        ])
        view = columns
        isShown = true
        return columns
    }

    /// Takes the keys out of the layout at once; the caller fades and
    /// removes the view it is handed.
    @discardableResult
    func hide() -> NSView? {
        guard isShown else { return nil }
        isShown = false
        let going = view
        view = nil
        return going
    }
}

/// One object changing size: the glass leads, the words follow. The
/// timing is the system's own for a window changing frame, no overshoot
/// and no spring, and the surface itself never fades, only what it
/// reveals. Reduced motion shows the result in place.
enum KeysMotion {
    static let growSeconds: TimeInterval = 0.3
    static let shrinkSeconds: TimeInterval = 0.22
    static let revealDelay: TimeInterval = 0.08

    static var animates: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// The window to `frame`, then the keys in.
    static func grow(_ panel: NSPanel, to frame: NSRect, revealing view: NSView?,
                     completion: @escaping () -> Void = {}) {
        guard animates else {
            panel.setFrame(frame, display: true)
            view?.alphaValue = 1
            completion()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = growSeconds
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: completion)
        guard let view else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + revealDelay) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = growSeconds - revealDelay
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                view.animator().alphaValue = 1
            }
        }
    }

    /// The keys out, then the window to `frame`; the view is removed
    /// once it is gone.
    static func shrink(_ panel: NSPanel, to frame: NSRect, hiding view: NSView?,
                       completion: @escaping () -> Void = {}) {
        guard animates else {
            view?.removeFromSuperview()
            panel.setFrame(frame, display: true)
            completion()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = shrinkSeconds
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
            view?.animator().alphaValue = 0
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: {
            view?.removeFromSuperview()
            completion()
        })
    }
}
