import AppKit
import LodestarCore

/// Send Feedback: a note, written in Lodestar's own glass, that reaches the
/// person who makes it. It replaced "Report an Issue", which sent people to
/// GitHub, where most of them have no account and the rest must write in
/// public. The note travels to the site's endpoint and on by email; the
/// address it lands at is never in the app (`Feedback`).
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
    private let noteBox = NSView()
    private let reply = NSTextField()
    private let attach = NSButton(checkboxWithTitle: "Include a diagnostic report", target: nil, action: nil)

    private enum Phase: Equatable {
        case writing
        case sending
        case sent(replying: Bool)
    }
    private var phase: Phase = .writing
    /// The one line under the note that answers the last Send: a problem
    /// with the note, or a failure to deliver it.
    private var status: String?

    /// The request goes through here, so the tests can stand in for the
    /// network. Answers the HTTP status, or nil when nothing came back.
    var deliver: (URLRequest, @escaping (Int?) -> Void) -> Void = { request, done in
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode
            DispatchQueue.main.async { done(code) }
        }.resume()
    }
    /// Where an unsent note is kept: the clipboard. A test hands it a
    /// private pasteboard, so a suite run never writes into the clipboard
    /// history of the Lodestar that is running on the Mac.
    var pasteboard: NSPasteboard = .general
    /// The report the checkbox attaches, asked for only at Send.
    var report: () -> String = { diagnoseReport() }

    private static let width: CGFloat = 520
    private static let inset: CGFloat = 26
    private static let noteHeight: CGFloat = 150

    var isVisible: Bool { panel.isVisible }

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

        let text = Self.width - Self.inset * 2
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: BarTheme.Scale.body)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
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
        noteBox.wantsLayer = true
        noteBox.layer?.cornerRadius = BarTheme.surfaceRadius
        noteBox.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        noteBox.layer?.borderWidth = 1
        noteBox.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
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

        reply.font = .systemFont(ofSize: BarTheme.Scale.body)
        reply.placeholderAttributedString = BarTheme.placeholder("Your email, if you would like a reply",
                                                                 like: reply.font)
        reply.bezelStyle = .roundedBezel
        reply.translatesAutoresizingMaskIntoConstraints = false
        reply.widthAnchor.constraint(equalToConstant: text).isActive = true

        attach.font = .systemFont(ofSize: BarTheme.Scale.body)
        attach.state = .off
    }

    // MARK: - Entry

    /// From the menu. A note already written and not sent is still there.
    func show() {
        if case .sent = phase { reset() }
        status = nil
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
        textView.string = ""
        reply.stringValue = ""
        attach.state = .off
    }

    // MARK: - Sending

    private var note: Feedback {
        Feedback(message: textView.string, replyTo: reply.stringValue)
    }

    @objc private func sendPressed() { send() }
    @objc private func cancelPressed() { close() }
    @objc private func closePressed() {
        reset()
        close()
    }

    /// Opens the report as it would be sent, before anything is sent.
    @objc private func seeReportPressed() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lodestar diagnostic report.txt")
        guard (try? report().write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
        NSWorkspace.shared.open(file)
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
        render()
        let replying = !feedback.replyTo.trimmingCharacters(in: .whitespaces).isEmpty
        deliver(feedback.request()) { [weak self] code in
            guard let self else { return }
            Log.info("feedback", ["status": code.map(String.init) ?? "none",
                                  "report": self.attach.state == .on ? "yes" : "no"])
            if code == 200 {
                self.phase = .sent(replying: replying)
                self.status = nil
            } else {
                // Nothing written is lost: the note goes to the clipboard,
                // and the window keeps it too.
                let board = self.pasteboard
                board.clearContents()
                board.setString(feedback.clipboardCopy, forType: .string)
                self.phase = .writing
                self.status = Self.failure
            }
            self.render()
            if self.phase == .writing { self.panel.makeFirstResponder(self.textView) }
        }
    }

    static let failure = "It could not be sent just now, so your note is on the clipboard. "
        + "Try again in a moment."

    // MARK: - Keys

    /// Escape leaves, ⌘return sends. Return alone is a new line in the note.
    private func key(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        switch (Keys.name(for: Int64(event.keyCode)), phase) {
        case ("escape", .sent):
            closePressed()
            return true
        case ("escape", _):
            close()
            return true
        case ("return", .sent):
            closePressed()
            return true
        case ("return", .writing) where command:
            send()
            return true
        default:
            return false
        }
    }

    func textDidChange(_ notification: Notification) {
        // A problem named for the last Send stops being true once they
        // write; failure stays, it is about the network, not the note.
        if status != nil, status != Self.failure {
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
            stack.addArrangedSubview(label("Send Feedback", size: 22, weight: .semibold, color: .labelColor))
            stack.addArrangedSubview(voice(
                "What works, what does not, or what you wish it did. It goes straight to the person who makes Lodestar.",
                width: text))
            stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)
            stack.addArrangedSubview(noteBox)
            stack.addArrangedSubview(reply)
            stack.setCustomSpacing(14, after: reply)
            let attachRow = NSStackView()
            attachRow.orientation = .horizontal
            attachRow.spacing = 10
            attachRow.addArrangedSubview(attach)
            attachRow.addArrangedSubview(smallLink("See what it contains", action: #selector(seeReportPressed)))
            stack.addArrangedSubview(attachRow)
            stack.setCustomSpacing(4, after: attachRow)
            stack.addArrangedSubview(wrapped(
                "Your displays, any settings problems and recent log lines. The log can name windows you had open.",
                size: BarTheme.Scale.meta, color: BarTheme.secondaryColor, width: text))
            if let status {
                stack.setCustomSpacing(14, after: stack.arrangedSubviews.last!)
                stack.addArrangedSubview(wrapped(status, size: BarTheme.Scale.body, color: .labelColor, width: text))
            }
            stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!)

            let footer = NSStackView()
            footer.orientation = .horizontal
            footer.spacing = 12
            footer.addArrangedSubview(label("Lodestar \(Lodestar.version) · macOS \(Feedback.macosVersion)",
                                            size: BarTheme.Scale.meta, weight: .regular,
                                            color: BarTheme.secondaryColor))
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            footer.addArrangedSubview(spacer)
            let go = NSButton(title: phase == .sending ? "Sending" : "Send", target: self,
                              action: #selector(sendPressed))
            go.bezelStyle = .rounded
            go.controlSize = .large
            go.keyEquivalent = "\r"
            go.keyEquivalentModifierMask = [.command]
            go.isEnabled = phase == .writing
            go.toolTip = "⌘ Return"
            footer.addArrangedSubview(go)
            footer.widthAnchor.constraint(equalToConstant: text).isActive = true
            stack.addArrangedSubview(footer)
            stack.addArrangedSubview(smallLink("Cancel", action: #selector(cancelPressed)))
            let editable = phase == .writing
            textView.isEditable = editable
            reply.isEditable = editable
            attach.isEnabled = editable
        case .sent(let replying):
            stack.addArrangedSubview(label("Thank you", size: 22, weight: .semibold, color: .labelColor))
            stack.addArrangedSubview(voice(replying
                    ? "Your note arrived and will be read. Any reply goes to the address you gave."
                    : "Your note arrived and will be read.",
                width: text))
            stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!)
            let done = NSButton(title: "Close", target: self, action: #selector(closePressed))
            done.bezelStyle = .rounded
            done.controlSize = .large
            done.keyEquivalent = "\r"
            stack.addArrangedSubview(done)
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
            ? NSPoint(x: panel.frame.minX, y: panel.frame.maxY - size.height)
            : NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2 + 40)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight,
                       color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }

    private func voice(_ text: String, width: CGFloat) -> NSTextField {
        let field = wrapped(text, size: BarTheme.Scale.body, color: BarTheme.secondaryColor, width: width)
        field.font = BarTheme.voiceFont
        return field
    }

    private func wrapped(_ text: String, size: CGFloat, color: NSColor, width: CGFloat) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: .regular)
        field.textColor = color
        field.isSelectable = false
        field.preferredMaxLayoutWidth = width
        field.widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true
        return field
    }

    private func smallLink(_ title: String, action: Selector) -> NSButton {
        let button = HandButton(title: title, target: self, action: action)
        button.isBordered = false
        button.font = BarTheme.secondaryFont
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
    var shownStatus: String? { status }
    var isSent: Bool { if case .sent = phase { return true } else { return false } }
    var noteText: String { textView.string }

    /// `lodestar __strip-preview 45` the note being written, 46 a note
    /// that could not be sent, 47 the thanks.
    static func preview(_ index: Int) -> FeedbackController {
        let controller = FeedbackController()
        controller.deliver = { _, done in done(index == 47 ? 200 : 503) }
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
