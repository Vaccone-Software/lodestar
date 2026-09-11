import AppKit
import LodestarCore

/// One line of the chain guide: keycap → destination, with its app icon.
struct GuideRow {
    /// One entry per cap. A row whose keys are *alternatives* ("J K" —
    /// either one) passes a single string and gets a single cap; a row
    /// that is a *sequence* ("lode" then "lode") passes them separately
    /// and gets one cap each. The distinction cannot be read off the
    /// string, so the caller states it.
    let keys: [String]
    let label: String
    let icon: NSImage?
    /// What the caps do when clicked instead of typed. Only offers set it;
    /// a chain guide's rows are a readout of what the keyboard can do next,
    /// not a set of controls, and giving them a pointer would promise an
    /// interaction the surface does not have.
    let action: (() -> Void)?
    /// Drawn quiet: a gesture the hand has not fired in a season, on the
    /// cheat sheet, with the line that would retire it in its label.
    let dimmed: Bool

    var key: String { keys.joined(separator: " ") }

    init(key: String, label: String, icon: NSImage? = nil,
         action: (() -> Void)? = nil, dimmed: Bool = false) {
        self.keys = [key]
        self.label = label
        self.icon = icon
        self.action = action
        self.dimmed = dimmed
    }

    init(keys: [String], label: String, icon: NSImage? = nil,
         action: (() -> Void)? = nil) {
        self.keys = keys
        self.label = label
        self.icon = icon
        self.action = action
        self.dimmed = false
    }
}

/// The chain guide: a floating glass panel that IS the pending state made
/// visible. While a chain is active it stays up, showing the typed prefix
/// and every legal continuation; flashes fade on their own. Rows flow into
/// columns sized by the screen — a laptop gets two, a big display three or
/// four.
final class HUD {
    /// Something else is taking the panel. The coach's chip is the only
    /// thing that lives here long enough to be stolen from, and a chip that
    /// has left the screen must not still answer to lode lode.
    var onTakeover: (() -> Void)?

    /// Who the panel belongs to right now. Every writer goes through
    /// `handOver`, so there is exactly one place a takeover can be missed
    /// and it is a place with a test on it.
    private(set) var owner: SurfaceOwner = .none
    /// The sentence the voice surface shows, for the stage.
    private(set) var voiceSentence: String?
    /// The last flash or guide title as drawn: its mark and its words.
    private(set) var titleSymbol: String?
    private(set) var titleText: String?

    private let panel: NSPanel
    private let root = NSView()
    private var content: NSStackView?
    private var hideWork: DispatchWorkItem?
    /// A flash is one line and takes the width of its words; a guide
    /// keeps a floor so a short map does not draw as a sliver.
    private var showingFlash = false
    /// The occupant this drawing is replacing — read by `present` to tell a
    /// chip being redrawn from a chip arriving.
    private var cameFromCoach = false
    private let clock: Clock

    init(clock: Clock = .live) {
        self.clock = clock
        panel = Glass.makePanel(level: .statusBar)
        panel.ignoresMouseEvents = true
        panel.contentView = root
        Glass.installBackdrop(in: root, cornerRadius: BarTheme.glassRadius)
    }

    // MARK: - Public surface

    /// Persistent guide for an active chain. Stays until updated or hidden.
    /// The header is the chain so far, drawn as the keys it is, led by a
    /// mark when the chain has one (a breath wears the wind). A footer is
    /// only ever a note about the last press; the keys live on the sheet.
    /// The coach passes `.coach`; everything else is the guide, which is
    /// what makes a guide drawn over a chip a recorded takeover.
    func showGuide(mark: String? = nil, keys: [String], rows: [GuideRow], footer: String? = nil,
                   owner: SurfaceOwner = .guide) {
        handOver(to: owner)
        hideWork?.cancel()
        hideWork = nil
        showingFlash = false
        build(mark: mark, keys: keys, text: nil, titleIcon: nil, rows: Array(rows.prefix(24)), footer: footer)
        present()
    }

    /// Lodestar speaking: one sentence in the voice, which is what says
    /// who is speaking, then the keymap as keys and the measurements in
    /// the interface's face, and the answers as key rows. With `seconds`
    /// it is a note that goes on its own, the way a flash does; without,
    /// it stands like a guide.
    func showVoice(sentence: String, keymap: Coach.Keymap? = nil, detail: String?, rows: [GuideRow],
                   owner: SurfaceOwner = .coach, seconds: TimeInterval? = nil) {
        handOver(to: owner)
        hideWork?.cancel()
        hideWork = nil
        showingFlash = false
        buildVoice(sentence: sentence, keymap: keymap, detail: detail, rows: rows)
        present()
        guard let seconds else { return }
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        clock.after(seconds, work)
    }

    /// A transient message, optionally wearing the app it acted on. It
    /// stays as long as it takes to read unless a caller says otherwise.
    func flash(_ text: String, icon: NSImage? = nil, seconds: TimeInterval? = nil) {
        let seconds = seconds ?? Readability.flashSeconds(for: text)
        handOver(to: .flash)
        showingFlash = true
        let mark = FlashMark.parse(text)
        build(mark: mark.symbol, keys: [], text: mark.text, titleIcon: icon, rows: [], footer: nil)
        present()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        clock.after(seconds, work)
    }

    func hide() {
        handOver(to: .none)
        hideWork?.cancel()
        hideWork = nil
        voiceSentence = nil
        panel.orderOut(nil)
    }

    /// The owner moves before the notification goes out, so a listener that
    /// responds by hiding the panel — which the coach does — finds the
    /// handover already recorded and stops, instead of recurring.
    private func handOver(to next: SurfaceOwner) {
        let previous = owner
        cameFromCoach = previous == .coach
        owner = next
        // The glass takes the mouse only for the one occupant that is an
        // offer. A chain guide is the pending state of a gesture already in
        // progress and stands over whatever you are working in; if it took
        // clicks it would eat them mid-chain, and if it could be dragged a
        // stray press would move it while your hand was still typing. The
        // coach's chip is the opposite: it waits, it asks, and it is the
        // thing you might want out of the way.
        let offering = next == .coach
        panel.ignoresMouseEvents = !offering
        panel.isMovable = offering
        panel.isMovableByWindowBackground = offering
        panel.acceptsMouseMovedEvents = offering
        if Surface.displacesCoach(from: previous, to: next) { onTakeover?() }
    }

    // MARK: - Construction

    private func buildVoice(sentence: String, keymap: Coach.Keymap?, detail: String?, rows: [GuideRow]) {
        content?.removeFromSuperview()
        voiceSentence = sentence
        let stack = VoiceCard.build(sentence: sentence, keymap: keymap, detail: detail, rows: rows)
        root.addSubview(stack)
        let inset = ModePill.inset
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -inset),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
        ])
        content = stack
    }

    private func build(mark: String?, keys: [String], text: String?, titleIcon: NSImage?,
                       rows: [GuideRow], footer: String?) {
        content?.removeFromSuperview()
        voiceSentence = nil
        titleSymbol = mark
        titleText = text ?? keys.joined(separator: " ")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 4
        // The mark, in the pill's configuration: what kind of line this
        // is, drawn the way the pill draws its mode.
        if let mark, let image = NSImage(systemSymbolName: mark, accessibilityDescription: nil)?
            .withSymbolConfiguration(BarTheme.symbol) {
            let view = NSImageView(image: image)
            view.contentTintColor = .labelColor
            view.setContentHuggingPriority(.required, for: .horizontal)
            titleRow.addArrangedSubview(view)
            titleRow.setCustomSpacing(ModePill.wordGap, after: view)
        }
        if let titleIcon {
            let iconView = NSImageView(image: titleIcon)
            iconView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                iconView.widthAnchor.constraint(equalToConstant: 20),
                iconView.heightAnchor.constraint(equalToConstant: 20),
            ])
            titleRow.addArrangedSubview(iconView)
            titleRow.setCustomSpacing(8, after: iconView)
        }
        // A chain's header is its keys; a flash's is its words, in the
        // interface's face. Neither is the hand's text, so neither is mono.
        for key in keys { titleRow.addArrangedSubview(Keycaps.cap(key)) }
        if let text {
            let titleLabel = NSTextField(labelWithString: text)
            titleLabel.font = BarTheme.bodyFont
            titleLabel.textColor = .labelColor
            titleRow.addArrangedSubview(titleLabel)
        }
        stack.addArrangedSubview(titleRow)

        if !rows.isEmpty {
            stack.setCustomSpacing(ModePill.wingGap, after: titleRow)
            stack.addArrangedSubview(GuideRows.columns(rows))
        }

        if let footer {
            let footerLabel = NSTextField(labelWithString: footer)
            footerLabel.font = BarTheme.footerFont
            footerLabel.textColor = BarTheme.secondaryColor
            if let last = stack.arrangedSubviews.last {
                stack.setCustomSpacing(10, after: last)
            }
            stack.addArrangedSubview(footerLabel)
        }

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -18),
        ])
        content = stack
    }

    private func present() {
        root.layoutSubtreeIfNeeded()
        var size = root.fittingSize
        size.width = min(max(size.width, showingFlash || voiceSentence != nil ? 0 : 200), 1100)
        size.height = max(size.height, 44)

        // A chip redrawn in place keeps where it was put; anything else
        // takes the panel's home. Without the second half, a chip dragged
        // once would hand its position to the next chain guide, which has
        // no business being anywhere but centred.
        if owner == .coach, cameFromCoach, panel.isVisible {
            Movable.place(panel, size: size) { panel.frame.origin }
        } else {
            let visible = ActivePolicy.presentationFrame
            panel.setFrame(NSRect(origin: NSPoint(x: visible.midX - size.width / 2,
                                                  y: visible.minY + 96),
                                  size: size), display: true)
        }
        panel.orderFrontRegardless()
    }
}
