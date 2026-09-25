import AppKit
import LodestarCore

/// The mark, for a hand on the mouse: rest the pointer on a line and a
/// small card says what the editor would change, with Accept and Keep as
/// written — the same two answers the lens gives by letter and by ⇧ and a
/// letter. The card never takes focus, so the field keeps its caret and a
/// fix typed into it lands where it should.
final class EditorHover {
    var marks: () -> [EditorController.Mark] = { [] }
    var accept: (EditorController.Mark) -> Void = { _ in }
    var keep: (EditorController.Mark) -> Void = { _ in }
    /// Where the pointer is, top-left origin like every mark — the
    /// screen's in the app, the test's own in the scenarios.
    var pointer: () -> CGPoint = EditorHover.systemPointer
    private let clock: Clock

    init(clock: Clock = .live) { self.clock = clock }

    /// A pointer resting this long on a mark opens its card — long enough
    /// that a pointer crossing the text opens nothing, short enough to feel
    /// like the word answered. Leaving the word and the card for `linger`
    /// closes it.
    static let dwell: TimeInterval = 0.12
    static let linger: TimeInterval = 0.35

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var dwellWork: DispatchWorkItem?
    private var dwellTarget: EditorIssue?
    private var leaveWork: DispatchWorkItem?
    private(set) var shown: EditorController.Mark?
    private(set) var panel: NSPanel?
    /// The card's two answers, as caps.
    private(set) var acceptCaps: Keycaps.CapGroup?
    private(set) var keepCaps: Keycaps.CapGroup?
    private var cardFrame = CGRect.null   // quartz

    // MARK: - Watching the pointer

    func start() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in self?.moved() }
        // Over the card itself the events are Lodestar's own.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.moved()
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        hide()
    }

    /// The marks moved or changed: a card for a mark that is gone goes too.
    func marksChanged() {
        guard let shown else { return }
        if !marks().contains(where: { $0.issue == shown.issue }) { hide() }
    }

    static func systemPointer() -> CGPoint {
        let location = NSEvent.mouseLocation
        let height = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: location.x, y: height - location.y)
    }

    /// The mark under a point: the word, a little wider, and down to where
    /// its line is drawn.
    static func mark(at point: CGPoint, in marks: [EditorController.Mark]) -> EditorController.Mark? {
        marks.first { mark in
            let r = mark.rect
            return CGRect(x: r.minX - 2, y: r.minY - 2, width: r.width + 4, height: r.height + 7).contains(point)
        }
    }

    func moved() {
        let point = pointer()
        if let shown {
            let overCard = cardFrame.insetBy(dx: -6, dy: -6).contains(point)
            let overWord = Self.mark(at: point, in: [shown]) != nil
            if overCard || overWord { leaveWork?.cancel(); leaveWork = nil; return }
        }
        guard let mark = Self.mark(at: point, in: marks()) else {
            cancelDwell()
            if shown != nil, leaveWork == nil {
                let work = DispatchWorkItem { [weak self] in self?.hide() }
                leaveWork = work
                clock.after(Self.linger, work)
            }
            return
        }
        guard mark.issue != shown?.issue else { return }
        // A card already open follows the pointer to the next mark at once.
        if shown != nil { show(mark); return }
        guard mark.issue != dwellTarget else { return }
        cancelDwell()
        dwellTarget = mark.issue
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.dwellWork = nil
            self.dwellTarget = nil
            // Still resting on it: open. A pointer that passed through does not.
            guard let under = Self.mark(at: self.pointer(), in: self.marks()), under.issue == mark.issue else { return }
            self.show(under)
        }
        dwellWork = work
        clock.after(Self.dwell, work)
    }

    // MARK: - The card

    private func cancelDwell() {
        dwellWork?.cancel()
        dwellWork = nil
        dwellTarget = nil
    }

    func hide() {
        cancelDwell()
        leaveWork?.cancel()
        leaveWork = nil
        shown = nil
        cardFrame = .null
        panel?.orderOut(nil)
    }

    /// What the card says: the change as a line, and underneath it what
    /// kind of mistake it is — or, when the replacement alone would not
    /// show it, what the change does.
    static func words(for issue: EditorIssue) -> (title: String, detail: String) {
        if let note = issue.note {
            return (note.prefix(1).uppercased() + note.dropFirst(), "\(issue.original) → \(issue.replacement)")
        }
        return ("\(issue.original) → \(issue.replacement)", issue.kind == .spelling ? "Spelling" : "Grammar")
    }

    func show(_ mark: EditorController.Mark) {
        let panel = self.panel ?? Glass.makePanel(level: NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1))
        self.panel = panel
        let root = NSView()
        panel.contentView = root
        Glass.installBackdrop(in: root, cornerRadius: BarTheme.glassRadius)

        let (title, detail) = Self.words(for: mark.issue)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(label(title, size: BarTheme.Scale.body, weight: .semibold, color: .labelColor))
        stack.addArrangedSubview(label(detail, size: BarTheme.Scale.meta, weight: .regular,
                                       color: BarTheme.secondaryColor))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        let answers = NSStackView()
        answers.orientation = .horizontal
        answers.alignment = .centerY
        answers.spacing = 8
        let acceptCaps = Keycaps.CapGroup(caps: [Keycaps.cap("Accept")]) { [weak self] in
            self?.hide()
            self?.accept(mark)
        }
        let keepCaps = Keycaps.CapGroup(caps: [Keycaps.cap("Keep as written")]) { [weak self] in
            self?.hide()
            self?.keep(mark)
        }
        self.acceptCaps = acceptCaps
        self.keepCaps = keepCaps
        answers.addArrangedSubview(acceptCaps)
        answers.addArrangedSubview(keepCaps)
        stack.addArrangedSubview(answers)

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 11),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -14),
        ])
        root.layoutSubtreeIfNeeded()
        let size = NSSize(width: max(200, stack.fittingSize.width + 28), height: stack.fittingSize.height + 22)

        // Below the word, where the eye already is; above it when the
        // screen ends first.
        guard let primary = NSScreen.screens.first else { return }
        let height = primary.frame.maxY
        var top = mark.rect.maxY + 8
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: mark.rect.midX, y: height - mark.rect.midY)) }
            ?? primary
        if height - (top + size.height) < screen.visibleFrame.minY { top = mark.rect.minY - 8 - size.height }
        let x = min(max(mark.rect.minX - 6, screen.visibleFrame.minX + 4), screen.visibleFrame.maxX - size.width - 4)
        cardFrame = CGRect(x: x, y: top, width: size.width, height: size.height)
        panel.setFrame(NSRect(x: x, y: height - top - size.height, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        shown = mark
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        return field
    }
}
