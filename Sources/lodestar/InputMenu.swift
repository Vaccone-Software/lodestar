import AppKit
import LodestarCore

/// The draft's one mouse target: which microphone it hears. Drawn the way
/// Lodestar draws everything, not as a system popup: the system's menu
/// paints its highlight in the Mac's accent, its chevrons in its own
/// grey, and is the one control on the glass that is a system window in
/// costume. Here the name sits quietly in the foot, and choosing opens a
/// small card beside the draft — beside, never over, so the words stay
/// in view — whose row under the pointer is the slab, the bars' chosen
/// row, with a dot marking the microphone in use.
final class InputMenu {
    struct Choice: Equatable {
        let title: String
        /// The device's name, or nil for the system's default.
        let device: String?
    }

    private let panel = Ceramic.makePanel(level: .popUpMenu)
    private let root = NSView()
    private let gate: PointerGate
    private var rows: [InputMenuRow] = []
    private var monitors: [Any] = []
    /// A click in this window is the button's to handle, so it can close
    /// the menu it opened rather than reopen it.
    weak var owner: NSWindow?
    var onChoose: ((String?) -> Void)?

    /// The lines of the row contract (design/13-row.md): 32 tall, touching,
    /// 8 inside the menu on every side.
    static let inset = BarTheme.lineInset
    static let rowHeight = BarTheme.lineHeight
    static let gap = Grid.part

    init() {
        gate = SoftShadow.host(root, in: panel, cornerRadius: BarTheme.surfaceRadius)
        // Choosing a microphone must not take the keyboard from the app the
        // draft lands in.
        panel.becomesKeyOnlyIfNeeded = true
        Ceramic.installPane(in: root, cornerRadius: BarTheme.surfaceRadius)
    }

    var isVisible: Bool { panel.isVisible }
    /// The rows' titles, top to bottom, and which is chosen, for the tests.
    var titles: [String] { rows.map(\.choice.title) }
    var currentTitle: String? { rows.first(where: \.current)?.choice.title }
    /// The row the pointer has chosen, which is the slab, for the tests.
    var slabTitle: String? { rows.first(where: \.chosen)?.choice.title }
    /// The rows, for the tests.
    var slabRows: [SlabRow] { rows }
    /// The card, without the shadow's margin.
    var frame: NSRect { SoftShadow.inset(panel.frame) }

    /// Open beside `glass` (the draft's frame), level with its foot.
    func present(_ choices: [Choice], chosen: Int, beside glass: NSRect) {
        rows.forEach { $0.removeFromSuperview() }
        let widest = choices.map { BarTheme.width(of: $0.title, in: .body) }.max() ?? 0
        // The line's words stand 12 inside it, after a dot column and 12 more.
        let width = (widest + Self.inset * 2 + InputMenuRow.padding * 2 + BarTheme.dotColumnWidth + Grid.part).rounded(.up)
        let height = Self.inset * 2 + Self.rowHeight * CGFloat(choices.count)
        rows = choices.enumerated().map { index, choice in
            let row = InputMenuRow(choice: choice, current: index == chosen)
            row.frame = NSRect(x: Self.inset, y: height - Self.inset - Self.rowHeight * CGFloat(index + 1),
                               width: width - Self.inset * 2, height: Self.rowHeight)
            row.onPick = { [weak self] in self?.pick(choice) }
            root.addSubview(row)
            return row
        }

        // Beside the draft, right then left; a draft as wide as the screen
        // (code) leaves neither, and then the card stands above it at its
        // right end, still off the words' line, never off the screen.
        let visible = ActivePolicy.presentationFrame
        var card = NSRect(x: glass.maxX + Self.gap, y: glass.minY, width: width, height: height)
        if card.maxX > visible.maxX - Grid.close { card.origin.x = glass.minX - width - Self.gap }
        if card.minX < visible.minX + Grid.close {
            card.origin = NSPoint(x: glass.maxX - width, y: glass.maxY + Self.gap)
        }
        card.origin.x = min(max(card.minX, visible.minX + Grid.close), visible.maxX - Grid.close - width).rounded()
        card.origin.y = min(card.minY, visible.maxY - Grid.close - height).rounded()
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

/// One microphone: its name, and a dot before it when it is the one in use.
/// A line of the row contract (`ListLine`): the dot column, then the name.
/// The row under the pointer is the slab, the bars' chosen row, because the
/// pointer is where the hand is going and this card takes no keys.
final class InputMenuRow: ListLine {
    let choice: InputMenu.Choice
    /// The microphone the draft is using.
    let current: Bool
    var onPick: (() -> Void)?
    /// The row's own padding, so its words stand where a bar's rows' do.
    static let padding = Grid.part

    init(choice: InputMenu.Choice, current: Bool) {
        self.choice = choice
        self.current = current
        super.init(frame: .zero)
        label.stringValue = choice.title
        setLead(DotColumn(marked: current))
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(choice.title)
        setAccessibilitySelected(current)
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .cursorUpdate],
                                       owner: self))
    }

    /// The card is never key: the first click is the choice.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { choose(true) }
    override func mouseExited(with event: NSEvent) { choose(false) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
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

    static let chevronGap = Grid.tight

    var title: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            setAccessibilityValue(newValue)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.setRole(.meta)
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
        return (text + Self.chevronGap + chevronSize.width + Grid.hair).rounded(.up)
    }

    private var chevronSize: NSSize {
        let size = chevron.image?.size ?? NSSize(width: Grid.close, height: Grid.part)
        return NSSize(width: min(size.width, Grid.close + Grid.hair), height: min(size.height, Grid.part))
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
        label.textColor = on ? BarTheme.ink : BarTheme.secondaryColor
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
