import AppKit
import LodestarCore

/// The mark, for a hand on the mouse: rest the pointer on a line and the
/// card is the answers themselves, lifted just above the word. The fix is
/// the lit key, your own word beside it leaves the text as written, and on
/// a spelling mark Learn teaches the word: the lens's letter, ⇧ and a
/// letter, and ⌥ and a letter. No headline and no labels: the answer is
/// the word, and the pointer barely moves to give it. The card never takes
/// focus, so the field keeps its caret and a fix lands where it should.
final class EditorHover: NSObject {
    var marks: () -> [EditorController.Mark] = { [] }
    var accept: (EditorController.Mark) -> Void = { _ in }
    var ignore: (EditorController.Mark) -> Void = { _ in }
    var learn: (EditorController.Mark) -> Void = { _ in }
    /// Whether a mark has a word to learn: a spelling mark on one word.
    var learnable: (EditorController.Mark) -> Bool = { _ in false }
    /// Where the pointer is, top-left origin like every mark — the
    /// screen's in the app, the test's own in the scenarios.
    var pointer: () -> CGPoint = EditorHover.systemPointer
    private let clock: Clock

    init(clock: Clock = .live) {
        self.clock = clock
        super.init()
    }

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
    /// What the drawn shadow hosts; each card is built inside it.
    private let holder = NSView()
    /// The card's answers. A card for the pointer has no key of its own,
    /// so they are Lodestar's buttons, the fix the one lit.
    private(set) var fixButton: RoomButton?
    private(set) var ignoreButton: RoomButton?
    private(set) var learnButton: RoomButton?
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

    /// The words on the card's two keys: the fix, and your own words as
    /// written. A change the replacement alone would not show (a comma
    /// gone) says what it does instead, and so does a word that should go.
    static func answers(for issue: EditorIssue) -> (fix: String, written: String) {
        let fix: String
        if let note = issue.note {
            fix = note.prefix(1).uppercased() + note.dropFirst()
        } else if issue.replacement.isEmpty {
            fix = "Remove"
        } else {
            fix = issue.replacement
        }
        let written = issue.original.trimmingCharacters(in: .whitespaces)
        return (fix, written.isEmpty ? "Keep as written" : written)
    }

    func show(_ mark: EditorController.Mark) {
        let panel: NSPanel
        if let existing = self.panel {
            panel = existing
        } else {
            panel = Glass.makePanel(level: NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1))
            // The drawn shadow, hosted once; each card is built into it.
            SoftShadow.host(holder, in: panel, cornerRadius: BarTheme.glassRadius)
            self.panel = panel
        }
        holder.subviews.forEach { $0.removeFromSuperview() }
        let root = NSView(frame: holder.bounds)
        root.autoresizingMask = [.width, .height]
        holder.addSubview(root)
        Glass.installBackdrop(in: root, cornerRadius: BarTheme.glassRadius)

        let words = Self.answers(for: mark.issue)
        let answers = NSStackView()
        answers.orientation = .horizontal
        answers.alignment = .centerY
        answers.spacing = 6
        answers.translatesAutoresizingMaskIntoConstraints = false
        func button(_ title: String, _ action: Selector, lit: Bool = false) -> RoomButton {
            let button = RoomButton(frame: .zero)
            button.answer = true
            button.title = title
            button.primary = lit
            button.target = self
            button.action = action
            answers.addArrangedSubview(button)
            return button
        }
        // Only the recommendation is lit; your words and Learn are the same
        // raised key, so the one light is the one answer suggested.
        fixButton = button(words.fix, #selector(fixPressed), lit: true)
        ignoreButton = button(words.written, #selector(ignorePressed))
        ignoreButton?.setAccessibilityLabel("Keep \(words.written) as written")
        learnButton = learnable(mark) ? button("Learn", #selector(learnPressed)) : nil
        learnButton?.setAccessibilityLabel("Learn \(EditorController.word(mark.issue))")

        root.addSubview(answers)
        let inset: CGFloat = 8
        NSLayoutConstraint.activate([
            answers.topAnchor.constraint(equalTo: root.topAnchor, constant: inset),
            answers.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
        ])
        root.layoutSubtreeIfNeeded()
        let size = NSSize(width: (answers.fittingSize.width + inset * 2).rounded(.up),
                          height: (answers.fittingSize.height + inset * 2).rounded(.up))

        // Just above the word, so the pointer resting on it is a few points
        // from every answer and the lines being written stay in sight;
        // below it when the screen ends first.
        guard let primary = NSScreen.screens.first else { return }
        let height = primary.frame.maxY
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: mark.rect.midX, y: height - mark.rect.midY)) }
            ?? primary
        var top = (mark.rect.minY - 6 - size.height).rounded()
        if top < height - screen.visibleFrame.maxY { top = (mark.rect.maxY + 8).rounded() }
        let x = min(max((mark.rect.minX - inset - 2).rounded(), screen.visibleFrame.minX + 4),
                    screen.visibleFrame.maxX - size.width - 4)
        cardFrame = CGRect(x: x, y: top, width: size.width, height: size.height)
        panel.setGlassFrame(NSRect(x: x, y: height - top - size.height, width: size.width, height: size.height),
                            display: true)
        panel.orderFrontRegardless()
        shown = mark
    }

    @objc private func fixPressed() {
        guard let mark = shown else { return }
        hide()
        accept(mark)
    }

    @objc private func ignorePressed() {
        guard let mark = shown else { return }
        hide()
        ignore(mark)
    }

    @objc private func learnPressed() {
        guard let mark = shown else { return }
        hide()
        learn(mark)
    }
}
