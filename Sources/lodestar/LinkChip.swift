import AppKit
import LodestarCore

/// The chip a clicked link leaves behind when it declines to take the screen.
///
/// It exists for exactly one situation: an arrangement was standing, so the
/// link went to the browser without moving anything, and the screen therefore
/// shows no evidence that the click did anything at all. Without this the
/// protected case is indistinguishable from the bug the whole change was for.
///
/// Its own panel, never the shared glass. The chip has to outlive the gesture
/// that drew it, and the glass belongs to whichever hand touched it last — a
/// chain guide or a flash would erase this a third of a second in, which is
/// the failure the surface owner type was introduced to catch. The meeting
/// chip learned this first; this follows it.
///
/// A minute, then it goes. Long enough to look up from what you were reading
/// and take it, short enough that it is never furniture. It does not wait to
/// be earned back by a visit, because a chip that outlives the moment it
/// describes stops being about that moment.
final class LinkChip {
    /// How long the chip stands. One minute, by the clock and nothing else.
    static let life: TimeInterval = 60
    static let width: CGFloat = 330

    /// Take the offer — `lode lode`.
    var summon: (() -> Void)?
    /// The chip took the screen, so anything longer-lived that was standing
    /// (the coach) hears about it. Only fired on the way up.
    var onShown: () -> Void = {}
    /// Voices that outrank a link: the walk holds the floor, and a meeting
    /// at the door is more urgent and sits in the same corner.
    var suppressed: () -> Bool = { false }

    private let panel = Ceramic.makePanel(level: .floating, takesKeys: false)
    private let root = NSView()
    private var expiry: Timer?

    init() {
        SoftShadow.host(root, in: panel, cornerRadius: BarTheme.surfaceRadius)
        Movable.enable(panel)
        _ = Ceramic.installPane(in: root, cornerRadius: BarTheme.surfaceRadius)
    }

    var isUp: Bool { panel.isVisible }

    /// Offer the link. `destination` is where it went, already resolved and
    /// fit to be read: "Brave · Xonar".
    func show(destination: String, icon: NSImage?) {
        guard !suppressed() else {
            // Rare — a meeting chip or the walk owns the corner. The link
            // still opened; it just goes unannounced rather than drawn on
            // top of something more urgent.
            Log.info("link-chip", ["held": "another surface holds the floor"])
            return
        }
        render(destination: destination, icon: icon)
        expiry?.invalidate()
        expiry = Timer.scheduledTimer(withTimeInterval: Self.life, repeats: false) {
            [weak self] _ in self?.hide()
        }
    }

    /// `lode lode` while the chip is up: go to the browser, and spend the
    /// chip doing it. False when there is nothing standing, which is what
    /// lets the gesture stay shared with the walk, meetings, and the coach.
    func take() -> Bool {
        guard isUp else { return false }
        hide()
        summon?()
        return true
    }

    /// `lode ⌫` while the chip is up: this link, dismissed unread.
    func dismiss() -> Bool {
        guard isUp else { return false }
        hide()
        return true
    }

    func hide() {
        expiry?.invalidate()
        expiry = nil
        panel.orderOut(nil)
    }

    // MARK: - Drawn

    private func render(destination: String, icon: NSImage?) {
        for view in root.subviews where view is NSStackView { view.removeFromSuperview() }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Grid.tight
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(label("Link", role: .name,
                                       color: BarTheme.secondaryColor))

        let title = NSStackView()
        title.orientation = .horizontal
        title.alignment = .centerY
        title.spacing = Grid.close
        if let icon {
            let view = NSImageView(image: icon)
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.widthAnchor.constraint(equalToConstant: BarTheme.symbolSize),
                view.heightAnchor.constraint(equalToConstant: BarTheme.symbolSize),
            ])
            title.addArrangedSubview(view)
        }
        title.addArrangedSubview(label(destination, role: .emphasis,
                                       color: BarTheme.ink))
        stack.addArrangedSubview(title)

        stack.setCustomSpacing(Grid.close, after: stack.arrangedSubviews.last!)
        // Verbs stay short because the line is width-bound: four caps and
        // two words have about 298pt inside a 330pt chip, and the labels
        // truncate rather than wrap. "goes there" measured 299.8.
        stack.addArrangedSubview(Keycaps.line([
            .init(["lode", "lode"], "Go", action: { [weak self] in _ = self?.take() }),
            .init(["lode", "⌫"], "Dismiss", action: { [weak self] in _ = self?.dismiss() }),
        ]))

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: Grid.group),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Grid.group),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Grid.group),
        ])
        root.layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.width, height: stack.fittingSize.height + Grid.group * 2)
        let wasVisible = panel.isVisible
        Movable.place(panel, size: size) {
            let visible = ActivePolicy.presentationFrame
            return NSPoint(x: visible.maxX - size.width - Grid.section,
                           y: visible.maxY - size.height - Grid.section)
        }
        panel.orderFrontRegardless()
        // Only on the way up: a second link inside the same minute redraws
        // a chip that is already standing, and that is not a fresh claim.
        if !wasVisible { onShown() }
    }

    private func label(_ text: String, role: BarTheme.Role,
                       color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.setRole(role)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }
}
