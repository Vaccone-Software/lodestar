import AppKit
import LodestarCore

/// Uninstall, asked in Lodestar's own glass: the plan shown whole before
/// anything is touched, a switch for whether everything Lodestar has kept
/// goes too, and the room's actions as its keys. It replaced the system's
/// alert, the last bezel, checkbox and system button left in the app.
///
/// `⌘⏎` uninstalls: a deliberate chord, never a stray return. `esc` leaves.
/// `R` turns the switch, and the plan above it changes to say so.
final class UninstallRoom: NSObject {
    private let panel = KeyablePanel(
        contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let root = NSView()
    /// Settings' own switch, not the system's checkbox.
    private let everything = AccentSwitch(frame: .zero)

    /// The plan for a choice; the tests point it at a scratch world.
    var plan: (Bool) -> UninstallPlan = { UninstallPlan.live(purge: $0) }
    /// What runs on `⌘⏎`, with the switch's answer.
    var onUninstall: ((Bool) -> Void)?

    private static let width: CGFloat = 480
    private static let inset: CGFloat = 26

    var isVisible: Bool { panel.isVisible }
    var removesEverything: Bool { everything.state == .on }

    override init() {
        super.init()
        panel.level = .modalPanel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.contentView = root
        _ = Glass.installBackdrop(in: root, cornerRadius: BarTheme.glassRadius)
        panel.onKeyDown = { [weak self] event in self?.key(event) ?? false }
        Movable.enable(panel)
        everything.state = .off
        everything.target = self
        everything.action = #selector(switchFlipped)
        everything.setAccessibilityLabel("Also remove everything Lodestar has kept")
    }

    deinit { panel.close() }

    func show() {
        everything.state = .off
        render()
        SystemEvents.activateLodestar()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() { panel.close() }

    @objc private func switchFlipped() { render() }

    private func toggle() {
        everything.set(everything.state == .on ? .off : .on, animated: true)
        render()
    }

    private func confirm() {
        let purge = removesEverything
        close()
        onUninstall?(purge)
    }

    // MARK: - Keys

    private func key(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        switch Keys.name(for: Int64(event.keyCode)) {
        case "escape":
            close()
            return true
        case "return" where command:
            confirm()
            return true
        case "r" where !command:
            toggle()
            return true
        default:
            return false
        }
    }

    // MARK: - Drawing

    private func render() {
        for view in root.subviews where view is NSStackView { view.removeFromSuperview() }
        let text = Self.width - Self.inset * 2
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Uninstall Lodestar")
        title.font = BarTheme.roomTitleFont
        title.textColor = .labelColor
        stack.addArrangedSubview(title)
        stack.setCustomSpacing(12, after: title)

        let current = plan(removesEverything)
        for step in current.steps {
            let first = step.name.prefix(1).uppercased() + step.name.dropFirst()
            stack.addArrangedSubview(wrapped(first, color: .labelColor, width: text))
        }
        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)

        let choice = NSStackView()
        choice.orientation = .horizontal
        choice.alignment = .centerY
        choice.spacing = 10
        choice.addArrangedSubview(everything)
        choice.addArrangedSubview(Keycaps.line([
            .init(["R"], "Also remove everything Lodestar has kept", action: { [weak self] in self?.toggle() }),
        ]))
        stack.addArrangedSubview(choice)
        stack.addArrangedSubview(wrapped(
            removesEverything
                ? "Settings, breaths, the clipboard, observations, the health record and downloaded models go too"
                : "Settings, breaths, the clipboard, observations, the health record and downloaded models stay, so a reinstall finds them",
            color: BarTheme.secondaryColor, width: text, size: BarTheme.Scale.meta))
        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(wrapped(UninstallPlan.closing.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
                                         color: BarTheme.secondaryColor, width: text, size: BarTheme.Scale.meta))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.spacing = 12
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer.addArrangedSubview(spacer)
        footer.addArrangedSubview(Keycaps.line([
            .init(["esc"], "Cancel", action: { [weak self] in self?.close() }),
            .init(["⌘", "⏎"], "Uninstall", action: { [weak self] in self?.confirm() }, lit: true),
        ]))
        footer.widthAnchor.constraint(equalToConstant: text).isActive = true
        stack.addArrangedSubview(footer)

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.inset),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.inset),
        ])
        root.layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.width, height: stack.fittingSize.height + Self.inset * 2)
        let visible = ActivePolicy.presentationFrame
        let origin = panel.isVisible
            ? NSPoint(x: panel.frame.minX, y: panel.frame.maxY - size.height)
            : NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2 + 40)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func wrapped(_ text: String, color: NSColor, width: CGFloat,
                         size: CGFloat = BarTheme.Scale.body) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = size == BarTheme.Scale.body ? BarTheme.bodyFont : BarTheme.secondaryFont
        field.textColor = color
        field.isSelectable = false
        field.preferredMaxLayoutWidth = width
        field.widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true
        return field
    }

    // MARK: - Tests

    #if DEBUG
    func pressToggle() { toggle() }
    func pressUninstall() { confirm() }
    /// The lines the plan shows, as drawn.
    var shownLines: [String] {
        (root.subviews.first { $0 is NSStackView } as? NSStackView)?.arrangedSubviews
            .compactMap { ($0 as? NSTextField)?.stringValue } ?? []
    }
    #endif
}
