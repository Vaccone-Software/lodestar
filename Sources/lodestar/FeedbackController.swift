import AppKit
import LodestarCore
import Stoic
#if DEBUG
import StoicHTTP
#endif

/// Send Feedback: a note, written in Lodestar's own glass, that reaches the
/// person who makes it. It replaced "Report an Issue", which sent people to
/// GitHub, where most of them have no account and the rest must write in
/// public. The note travels to the site's endpoint and on by email; the
/// address it lands at is never in the app (`Feedback`).
///
/// A note is kept before it is sent (`FeedbackQueue`): Send saves it, tries
/// once, and then the window says which of four things happened. It
/// arrived; or it is saved and Lodestar sends it on its own, now or at the
/// next launch, with the same key so it can never arrive twice; or the site
/// refused it for good and the note stays here and on the clipboard; or it
/// could not be saved at all, and is on the clipboard.
///
/// Nothing is attached unless they ask. The diagnostic report is one
/// checkbox, off, with a way to read it first, because its log tail can
/// name windows that were open.
final class FeedbackController: NSObject, NSTextViewDelegate {
    /// Keyable on purpose: this is a place to type.
    private let panel = KeyablePanel(
        contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let root = NSView()

    // Made once and carried across renders, so nothing typed is lost when
    // the window redraws around it.
    private let textView = NSTextView()
    private let scroll = NSScrollView()
    private let noteBox = ToneView(fill: BarTheme.well, edge: BarTheme.hairline, edgeWidth: 1)
    private let replyBox = RoomField(placeholder: "Your email, if you would like a reply")
    private var reply: NSTextField { replyBox.field }
    /// Settings' own switch, not the system's checkbox: a room's controls
    /// are Lodestar's.
    private let attach = AccentSwitch(frame: .zero)

    private enum Phase: Equatable {
        case writing
        case sending
        case sent(replying: Bool)
        /// Saved in the queue, not yet delivered: the person's part is done.
        case saved
    }
    private var phase: Phase = .writing
    /// The one line under the note that answers the last Send: a problem
    /// with the note, or the site's refusal of it.
    private var status: String?
    /// The note the last Send took, for the clipboard once it is saved.
    private var lastNote: Feedback?
    /// The Send in flight, so a test can wait for it.
    private var sending: Task<Void, Never>?

    /// Where notes wait and are delivered from. The app has one for the
    /// life of the process, so the schedule that retries and the window that
    /// sends are never two queues over one directory.
    private let queue: FeedbackQueue
    /// Where a note goes when the person asks for it, and when it is
    /// refused or could not be saved. A test hands it a private pasteboard,
    /// so a suite run never writes into the clipboard history of the
    /// Lodestar that is running on the Mac.
    var pasteboard: NSPasteboard = .general
    /// The report the checkbox attaches, asked for only at Send.
    var report: () -> String = { diagnoseReport() }

    private static let width: CGFloat = 520
    private static let inset: CGFloat = 26
    private static let noteHeight: CGFloat = 150

    var isVisible: Bool { panel.isVisible }

    init(queue: FeedbackQueue) {
        self.queue = queue
        super.init()
        panel.level = .modalPanel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        SoftShadow.host(root, in: panel, cornerRadius: BarTheme.glassRadius)
        _ = Glass.installBackdrop(in: root, cornerRadius: BarTheme.glassRadius)
        panel.onKeyDown = { [weak self] event in self?.key(event) ?? false }
        Movable.enable(panel)

        let text = Self.width - Self.inset * 2
        textView.isRichText = false
        textView.allowsUndo = true
        textView.setRole(.body)
        textView.textColor = BarTheme.ink
        textView.insertionPointColor = BarTheme.ink
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.setAccessibilityLabel("Your note")
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        // The frame is its own view: a scroll view's clip view paints over
        // any layer the scroll view itself is given.
        noteBox.layer?.cornerRadius = BarTheme.surfaceRadius
        noteBox.translatesAutoresizingMaskIntoConstraints = false
        noteBox.widthAnchor.constraint(equalToConstant: text).isActive = true
        noteBox.heightAnchor.constraint(equalToConstant: Self.noteHeight).isActive = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        noteBox.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: noteBox.topAnchor, constant: 2),
            scroll.bottomAnchor.constraint(equalTo: noteBox.bottomAnchor, constant: -2),
            scroll.leadingAnchor.constraint(equalTo: noteBox.leadingAnchor, constant: 2),
            scroll.trailingAnchor.constraint(equalTo: noteBox.trailingAnchor, constant: -2),
        ])

        replyBox.widthAnchor.constraint(equalToConstant: text).isActive = true
        attach.state = .off
        attach.setAccessibilityLabel("Include a diagnostic report")
    }

    // MARK: - Entry

    /// From the menu. A note already written and not sent is still there.
    func show() {
        switch phase {
        case .sent, .saved: reset()
        default: break
        }
        // A refusal is about the note, and stays until they change it.
        if status != Self.refusal { status = nil }
        render()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
    }

    /// Closed, not ordered out: a closed panel leaves the app's window
    /// list, and one that is not released comes back on the next show.
    func close() {
        panel.close()
    }

    deinit { panel.close() }

    private func reset() {
        phase = .writing
        status = nil
        lastNote = nil
        textView.string = ""
        reply.stringValue = ""
        attach.state = .off
    }

    // MARK: - Sending

    private var note: Feedback {
        Feedback(message: textView.string, replyTo: reply.stringValue)
    }

    @objc private func closePressed() {
        reset()
        close()
    }

    /// Opens the report as it would be sent, before anything is sent.
    @objc private func seeReportPressed() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lodestar diagnostic report.txt")
        guard (try? report().write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
        SystemEvents.open(file)
    }

    private func send() {
        guard phase == .writing else { return }
        var feedback = note
        if let problem = feedback.problem {
            status = problem.sentence
            render()
            return
        }
        if attach.state == .on { feedback.diagnostics = report() }
        phase = .sending
        status = nil
        lastNote = feedback
        render()
        let replying = !feedback.replyTo.trimmingCharacters(in: .whitespaces).isEmpty
        // The task inherits the ambient context (clock, instrumentation) of
        // the run loop that made it, and finishes on the main actor.
        sending = Task { @MainActor [weak self, queue] in
            let submission = await queue.submit(feedback)
            self?.finish(submission, replying: replying)
        }
    }

    private func finish(_ submission: FeedbackQueue.Submission, replying: Bool) {
        switch submission {
        case .delivered:
            phase = .sent(replying: replying)
            status = nil
        case .queued:
            // Kept on disk and sent by the queue on its own: the window has
            // nothing more to hold, and keeping the text here would only
            // invite sending the same note twice.
            phase = .saved
            status = nil
        case .refused:
            // The site will never take this note, and the queue has let go
            // of it: the window keeps it, and so does the clipboard.
            copyNote()
            phase = .writing
            status = Self.refusal
        case .notSaved:
            // Nothing was kept anywhere, so the clipboard and the window are
            // all there is.
            copyNote()
            phase = .writing
            status = Self.unsaved
        }
        render()
        if phase == .writing, panel.isVisible { panel.makeFirstResponder(textView) }
    }

    private func copyNote() {
        guard let lastNote else { return }
        let board = pasteboard
        board.clearContents()
        board.setString(lastNote.clipboardCopy, forType: .string)
    }

    static let refusal = "The site would not take that note, so it is still here and on the clipboard. "
        + "Change it a little and try again."
    static let unsaved = "Lodestar could not save that note to send later, so it is still here and on the "
        + "clipboard. Try again in a moment."

    static let savedSentence = "Your note is saved and could not be sent just now. Lodestar will send it on "
        + "its own as soon as it can, even after a quit."

    // MARK: - Keys

    /// Escape leaves, ⌘return sends. Return alone is a new line in the note.
    private func key(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        switch (Keys.name(for: Int64(event.keyCode)), phase) {
        case ("escape", .sent), ("escape", .saved):
            closePressed()
            return true
        case ("escape", _):
            close()
            return true
        case ("return", .sent), ("return", .saved):
            closePressed()
            return true
        case ("c", .saved) where command:
            copyNote()
            return true
        case ("return", .writing) where command:
            send()
            return true
        default:
            return false
        }
    }

    func textDidChange(_ notification: Notification) {
        // A problem named for the last Send stops being true once they write.
        if status != nil {
            status = nil
            render()
        }
    }

    // MARK: - Drawing

    private func render() {
        for view in root.subviews where view is NSStackView { view.removeFromSuperview() }
        let text = Self.width - Self.inset * 2
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        switch phase {
        case .writing, .sending:
            stack.addArrangedSubview(roomTitle("Send Feedback"))
            stack.addArrangedSubview(voice(
                "What works, what does not, or what you wish it did. It goes straight to the person who makes Lodestar.",
                width: text))
            stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)
            stack.addArrangedSubview(noteBox)
            stack.addArrangedSubview(replyBox)
            stack.setCustomSpacing(14, after: replyBox)
            let attachRow = NSStackView()
            attachRow.orientation = .horizontal
            attachRow.alignment = .centerY
            attachRow.spacing = 10
            attachRow.addArrangedSubview(attach)
            attachRow.addArrangedSubview(label("Include a diagnostic report", role: .body, color: BarTheme.ink))
            attachRow.addArrangedSubview(smallLink("See what it contains", action: #selector(seeReportPressed)))
            stack.addArrangedSubview(attachRow)
            stack.setCustomSpacing(4, after: attachRow)
            stack.addArrangedSubview(wrapped(
                "Your displays, any settings problems and recent log lines. The log can name windows you had open.",
                role: .meta, color: BarTheme.secondaryColor, width: text))
            if let status {
                stack.setCustomSpacing(14, after: stack.arrangedSubviews.last!)
                stack.addArrangedSubview(wrapped(status, role: .body, color: BarTheme.ink, width: text))
            }
            stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!)

            let footer = NSStackView()
            footer.orientation = .horizontal
            footer.spacing = 12
            footer.addArrangedSubview(label("Lodestar \(Lodestar.version) · macOS \(Feedback.macosVersion)",
                                            role: .meta,
                                            color: BarTheme.secondaryColor))
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            footer.addArrangedSubview(spacer)
            // The room's actions are its keys, pressed or clicked: ⌘⏎
            // sends (⏎ alone is a new line in the note), esc leaves.
            let sending = phase == .sending
            footer.addArrangedSubview(Keycaps.line([
                .init(["esc"], "Cancel", action: { [weak self] in self?.close() }, quiet: sending),
                .init(["⌘", "⏎"], sending ? "Sending" : "Send",
                      action: { [weak self] in self?.send() }, lit: true, quiet: sending),
            ]))
            footer.widthAnchor.constraint(equalToConstant: text).isActive = true
            stack.addArrangedSubview(footer)
            let editable = phase == .writing
            textView.isEditable = editable
            reply.isEditable = editable
            attach.isEnabled = editable
        case .saved:
            stack.addArrangedSubview(roomTitle("Saved"))
            stack.addArrangedSubview(voice(Self.savedSentence, width: text))
            stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!)
            // Quiet, and the way out lit: the note is safe, so copying it is
            // only for the person who wants it somewhere else too.
            stack.addArrangedSubview(Keycaps.line([
                .init(["⌘", "C"], "Copy note", action: { [weak self] in self?.copyNote() }, quiet: true),
                .init(["⏎"], "Close", action: { [weak self] in self?.closePressed() }, lit: true),
            ]))
        case .sent(let replying):
            stack.addArrangedSubview(roomTitle("Thank you"))
            stack.addArrangedSubview(voice(replying
                    ? "Your note arrived and will be read. Any reply goes to the address you gave."
                    : "Your note arrived and will be read.",
                width: text))
            stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!)
            stack.addArrangedSubview(Keycaps.line([
                .init(["⏎"], "Close", action: { [weak self] in self?.closePressed() }, lit: true),
            ]))
        }

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.inset),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.inset),
        ])
        root.layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.width, height: stack.fittingSize.height + Self.inset * 2)
        // Kept where it stands once it is up: a window that jumps between
        // the note and the thanks loses the eye that was on it.
        let visible = ActivePolicy.presentationFrame
        let origin = panel.isVisible
            ? NSPoint(x: panel.glassFrame.minX, y: panel.glassFrame.maxY - size.height)
            : NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2 + 40)
        panel.setGlassFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func label(_ text: String, role: BarTheme.Role,
                       color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.setRole(role)
        field.textColor = color
        return field
    }

    private func roomTitle(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.setRole(.roomTitle)
        field.textColor = BarTheme.ink
        return field
    }

    private func voice(_ text: String, width: CGFloat) -> NSTextField {
        let field = wrapped(text, role: .voice, color: BarTheme.secondaryColor, width: width)
        return field
    }

    private func wrapped(_ text: String, role: BarTheme.Role, color: NSColor, width: CGFloat) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.setRole(role)
        field.textColor = color
        field.isSelectable = false
        field.preferredMaxLayoutWidth = width
        field.widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true
        return field
    }

    private func smallLink(_ title: String, action: Selector) -> NSButton {
        let button = HandButton(title: title, target: self, action: action)
        button.isBordered = false
        button.setRole(.meta)
        button.contentTintColor = BarTheme.secondaryColor
        return button
    }

    // MARK: - Tests and staging

    #if DEBUG
    /// For the tests: fill the window as a person would.
    func fill(message: String, replyTo: String = "", attachReport: Bool = false) {
        textView.string = message
        reply.stringValue = replyTo
        attach.state = attachReport ? .on : .off
    }

    func pressSend() { send() }
    /// Waits for the Send in flight to be answered and shown.
    func settled() async { await sending?.value }
    func pressCopy() { copyNote() }
    var shownStatus: String? { status }
    var isSent: Bool { if case .sent = phase { return true } else { return false } }
    var isSaved: Bool { phase == .saved }
    var isSending: Bool { phase == .sending }
    var noteText: String { textView.string }

    /// `lodestar __strip-preview 45` the note being written, 46 a note
    /// that is saved and not yet sent, 47 the thanks.
    static func preview(_ index: Int) -> FeedbackController {
        let transport = ScriptedTransport()
        transport.on(.post(Feedback.path, body: [], contentType: "application/json"),
                     respond: [index == 47 ? .json(#"{"ok":true}"#) : .status(503)])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-feedback-preview-\(UUID().uuidString)", isDirectory: true)
        let controller = FeedbackController(queue: FeedbackQueue(
            directory: directory, client: Feedback.client(transport: transport)))
        DispatchQueue.main.async {
            controller.show()
            guard index > 45 else { return }
            controller.fill(message: "The launcher opened on the wrong screen after I unplugged the display.",
                            replyTo: index == 47 ? "someone@example.com" : "")
            controller.send()
        }
        return controller
    }
    #endif
}
