import AppKit
import LodestarCore

/// The keys a bar holds when asked: the sections as columns beneath its
/// rows, inside the bar's own glass, with air and no line between. The
/// bar takes the room for them at once and gives it back when they go;
/// nothing arrives beside it.
final class BarKeys {
    private weak var root: NSView?
    private weak var rows: NSView?
    private var view: NSView?
    private(set) var isShown = false

    /// The columns' inset from the glass, the field's own.
    static let inset = BarTheme.fieldInset
    /// Air between the last row and the columns, the pill's own.
    static let above: CGFloat = Grid.section

    func install(root: NSView, below rows: NSView) {
        self.root = root
        self.rows = rows
    }

    /// The height the bar owes its keys: zero while they are away.
    var height: CGFloat {
        guard isShown, let view else { return 0 }
        return Self.above + view.fittingSize.height + Grid.section
    }

    /// Builds the keys in place and reports the view; the bar then takes
    /// its end frame at once.
    @discardableResult
    func show(_ sections: [CheatSheet.Section]) -> NSView? {
        guard let root, let rows else { return nil }
        view?.removeFromSuperview()
        let columns = CheatSheet.columns(sections)
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

    /// Takes the keys out of the layout at once; the caller removes the
    /// view it is handed.
    @discardableResult
    func hide() -> NSView? {
        guard isShown else { return nil }
        isShown = false
        let going = view
        view = nil
        return going
    }
}

/// One object changing size, at once: the glass takes its end frame and
/// the keys are there or gone with it. Nothing grows and nothing fades in
/// (design/05-motion.md): a surface opened four hundred times a day does
/// not make the hand wait for the eye. The end state is the whole of it,
/// so Reduce Motion needs no case of its own.
enum KeysSheet {
    /// The window to `frame`; its keys, already in the view tree, are
    /// there. `completion` runs before this returns.
    static func open(_ panel: NSPanel, to frame: NSRect, completion: () -> Void = {}) {
        panel.setFrame(frame, display: true)
        completion()
    }

    /// The keys out of the view tree, then the window to `frame`.
    /// `completion` runs before this returns.
    static func close(_ panel: NSPanel, to frame: NSRect, removing view: NSView?, completion: () -> Void = {}) {
        view?.removeFromSuperview()
        panel.setFrame(frame, display: true)
        completion()
    }
}
