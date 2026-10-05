import AppKit
import LodestarCore

/// The draft's one mouse target: which microphone it hears. Drawn the way
/// Lodestar draws everything, not as a system popup: the system's menu
/// paints its highlight in the Mac's accent, its chevrons in its own
/// grey, and is the one control on the glass that is a system window in
/// costume. Here the name sits quietly in the foot, and choosing opens a
/// small card beside the draft — beside, never over, so the words stay
/// in view — whose rows rise under the pointer like the bars' rows, with
/// the accent marking the microphone that is chosen.
final class InputMenu {
    struct Choice: Equatable {
        let title: String
        /// The device's name, or nil for the system's default.
        let device: String?
    }

    private let panel = Glass.makePanel(level: .popUpMenu)
    private let root = NSView()
    private let gate: PointerGate
    private var rows: [InputMenuRow] = []
    private var monitors: [Any] = []
    /// A click in this window is the button's to handle, so it can close
    /// the menu it opened rather than reopen it.
    weak var owner: NSWindow?
    var onChoose: ((String?) -> Void)?

    static let inset: CGFloat = 6
    static let rowHeight: CGFloat = 36
    static let gap: CGFloat = 12

    init() {
        SoftShadow.host(root, in: panel, cornerRadius: BarTheme.glassRadius)
        gate = PointerGate(panel: panel)
        Glass.installBackdrop(in: root, cornerRadius: BarTheme.glassRadius)
    }

    var isVisible: Bool { panel.isVisible }
    /// The rows' titles, top to bottom, and which is chosen, for the tests.
    var titles: [String] { rows.map(\.choice.title) }
    var chosenTitle: String? { rows.first(where: \.chosen)?.choice.title }
    /// The card's glass, without the shadow's margin.
    var frame: NSRect { SoftShadow.inset(panel.frame) }

    /// Open beside `glass` (the draft's frame), level with its foot.
    func present(_ choices: [Choice], chosen: Int, beside glass: NSRect) {
        rows.forEach { $0.removeFromSuperview() }
        let font = BarTheme.rowLabelFont
        let widest = choices.map { ($0.title as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let width = (max(220, widest + 64)).rounded(.up)
        let height = Self.inset * 2 + Self.rowHeight * CGFloat(choices.count)
        rows = choices.enumerated().map { index, choice in
            let row = InputMenuRow(choice: choice, chosen: index == chosen)
            row.frame = NSRect(x: Self.inset, y: height - Self.inset - Self.rowHeight * CGFloat(index + 1),
                               width: width - Self.inset * 2, height: Self.rowHeight)
            row.onPick = { [weak self] in self?.pick(choice) }
            root.addSubview(row)
            return row
        }

        let visible = ActivePolicy.presentationFrame
        var x = glass.maxX + Self.gap
        if x + width > visible.maxX - 8 { x = glass.minX - width - Self.gap }
        let card = NSRect(x: x, y: glass.minY, width: width, height: height)
        panel.setFrame(SoftShadow.outset(card), display: true)
        panel.orderFrontRegardless()
        gate.start()
        watchForClicksElsewhere()
    }

    func hide() {
        guard panel.isVisible else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        gate.stop()
        panel.orderOut(nil)
    }

    /// Choose a row by its title, as the pointer would, for the tests.
    func choose(_ title: String) {
        guard let row = rows.first(where: { $0.choice.title == title }) else { return }
        pick(row.choice)
    }

    private func pick(_ choice: Choice) {
        hide()
        onChoose?(choice.device)
    }

    /// A click anywhere but the card closes it, as a menu does.
    private func watchForClicksElsewhere() {
        guard monitors.isEmpty else { return }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            self?.hide()
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            guard let self else { return event }
            if event.window !== self.panel, event.window !== self.owner { self.hide() }
            return event
        }) { monitors.append(local) }
    }
}

/// One microphone: its name, and the accent's dot before it when chosen.
/// Rises under the pointer, the bars' raised row, because the pointer is
/// where the hand is going.
final class InputMenuRow: RaisedRow {
    let choice: InputMenu.Choice
    let chosen: Bool
    var onPick: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()

    init(choice: InputMenu.Choice, chosen: Bool) {
        self.choice = choice
        self.chosen = chosen
        super.init(frame: .zero)
        setupRaised()
        label.stringValue = choice.title
        label.font = BarTheme.rowLabelFont
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        dot.wantsLayer = true
        dot.layer?.cornerRadius = BarTheme.dotRadius
        dot.layer?.backgroundColor = BarTheme.accent.cgColor
        dot.isHidden = !chosen
        addSubview(dot)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(choice.title)
        setAccessibilitySelected(chosen)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let leading: CGFloat = 14
        dot.frame = NSRect(x: leading, y: ((bounds.height - BarTheme.dotDiameter) / 2).rounded(),
                           width: BarTheme.dotDiameter, height: BarTheme.dotDiameter)
        let text = leading + BarTheme.dotDiameter + 10
        let natural = label.sizeThatFits(NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                height: CGFloat.greatestFiniteMagnitude)).height
        label.frame = NSRect(x: text, y: ((bounds.height - natural) / 2).rounded(),
                             width: bounds.width - text - leading, height: natural)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .cursorUpdate],
                                       owner: self))
    }

    /// The card is never key: the first click is the choice.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { applyRaised(true) }
    override func mouseExited(with event: NSEvent) { applyRaised(false) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPick?() }
    }
    override func accessibilityPerformPress() -> Bool { onPick?(); return true }
}

/// The microphone's name in the draft's foot, with a small chevron that
/// says it opens. Quiet until the pointer is on it.
final class InputButton: NSView {
    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    var onClick: (() -> Void)?

    static let chevronGap: CGFloat = 5

    var title: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            setAccessibilityValue(newValue)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = BarTheme.secondaryFont
        label.textColor = BarTheme.secondaryColor
        label.lineBreakMode = .byTruncatingTail
        chevron.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(BarTheme.symbol)
        chevron.contentTintColor = BarTheme.secondaryColor
        addSubview(label)
        addSubview(chevron)
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel("Microphone input")
        toolTip = "The microphone the draft listens to"
    }

    required init?(coder: NSCoder) { nil }

    /// The width it wants: the name, the gap, the chevron.
    var naturalWidth: CGFloat {
        // Measured by the field that draws it: a string's own size leaves
        // out the field's padding, and the name was cut a letter short.
        let text = label.sizeThatFits(NSSize(width: CGFloat.greatestFiniteMagnitude,
                                             height: CGFloat.greatestFiniteMagnitude)).width
        return (text + Self.chevronGap + chevronSize.width + 1).rounded(.up)
    }

    private var chevronSize: NSSize {
        let size = chevron.image?.size ?? NSSize(width: 8, height: 12)
        return NSSize(width: min(size.width, 10), height: min(size.height, 12))
    }

    override func layout() {
        super.layout()
        let c = chevronSize
        chevron.frame = NSRect(x: bounds.width - c.width, y: ((bounds.height - c.height) / 2).rounded(),
                               width: c.width, height: c.height)
        let natural = label.sizeThatFits(NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                height: CGFloat.greatestFiniteMagnitude)).height
        label.frame = NSRect(x: 0, y: ((bounds.height - natural) / 2).rounded(),
                             width: max(0, chevron.frame.minX - Self.chevronGap), height: natural)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .cursorUpdate],
                                       owner: self))
    }

    private func lit(_ on: Bool) {
        label.textColor = on ? .labelColor : BarTheme.secondaryColor
        chevron.contentTintColor = label.textColor
    }

    /// The draft is never key: the first click is the click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { lit(true) }
    override func mouseExited(with event: NSEvent) { lit(false) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}
