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

    var key: String { keys.joined(separator: " ") }

    init(key: String, label: String, icon: NSImage? = nil,
         action: (() -> Void)? = nil) {
        self.keys = [key]
        self.label = label
        self.icon = icon
        self.action = action
    }

    init(keys: [String], label: String, icon: NSImage? = nil,
         action: (() -> Void)? = nil) {
        self.keys = keys
        self.label = label
        self.icon = icon
        self.action = action
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

    private let panel: NSPanel
    private let root = NSView()
    private var content: NSStackView?
    private var hideWork: DispatchWorkItem?
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
    /// The coach passes `.coach`; everything else is the guide, which is
    /// what makes a guide drawn over a chip a recorded takeover.
    func showGuide(title: String, rows: [GuideRow], footer: String,
                   owner: SurfaceOwner = .guide) {
        handOver(to: owner)
        hideWork?.cancel()
        hideWork = nil
        build(title: title, titleIcon: nil, rows: Array(rows.prefix(24)), footer: footer)
        present()
    }

    /// A transient message, optionally wearing the app it acted on.
    func flash(_ text: String, icon: NSImage? = nil, seconds: TimeInterval = 1.4) {
        handOver(to: .flash)
        build(title: text, titleIcon: icon, rows: [], footer: nil)
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

    private func build(title: String, titleIcon: NSImage?, rows: [GuideRow], footer: String?) {
        content?.removeFromSuperview()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        if let titleIcon {
            let iconView = NSImageView(image: titleIcon)
            iconView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                iconView.widthAnchor.constraint(equalToConstant: 20),
                iconView.heightAnchor.constraint(equalToConstant: 20),
            ])
            titleRow.addArrangedSubview(iconView)
        }
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .monospacedSystemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleRow.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(titleRow)

        if !rows.isEmpty {
            stack.setCustomSpacing(10, after: titleRow)
            stack.addArrangedSubview(makeColumns(rows))
        }

        if let footer {
            let footerLabel = NSTextField(labelWithString: footer)
            footerLabel.font = .systemFont(ofSize: 11, weight: .regular)
            footerLabel.textColor = .secondaryLabelColor
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

    /// Screen width decides the column count; rows fill column-major so the
    /// eye scans top-to-bottom.
    private func makeColumns(_ rows: [GuideRow]) -> NSView {
        let screenWidth = ActivePolicy.presentationFrame.width
        let maxColumns = max(1, min(4, Int(screenWidth * 0.7 / 330)))
        let perColumnTarget = 6
        let columns = min(maxColumns, max(1, (rows.count + perColumnTarget - 1) / perColumnTarget))
        let perColumn = (rows.count + columns - 1) / columns

        // Hold the icon column only when this guide actually has icons —
        // otherwise every label in a set like the scroll guide is indented
        // against nothing.
        let hasIcons = rows.contains { $0.icon != nil }

        let grid = NSStackView()
        grid.orientation = .horizontal
        grid.alignment = .top
        grid.spacing = 30

        for column in 0..<columns {
            let start = column * perColumn
            guard start < rows.count else { break }
            let slice = rows[start..<min(start + perColumn, rows.count)]
            let columnStack = NSStackView()
            columnStack.orientation = .vertical
            // Equal widths down the column, which is what lets each row's
            // key sit at the same trailing edge instead of trailing its own
            // label.
            columnStack.alignment = .width
            columnStack.spacing = 6
            for row in slice {
                columnStack.addArrangedSubview(makeRow(row, reserveIcon: hasIcons))
            }
            grid.addArrangedSubview(columnStack)
        }
        return grid
    }

    private func makeRow(_ guideRow: GuideRow, reserveIcon: Bool) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = BarTheme.rowGap

        // Icon, name, then key — the order the clipboard's actions menu
        // reads in. The icon's slot is held even when a row has none, so
        // the names line up down the column rather than stepping in and out.
        var iconView: NSImageView?
        if reserveIcon {
            let view = NSImageView(image: guideRow.icon ?? NSImage())
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.widthAnchor.constraint(equalToConstant: BarTheme.rowIcon),
                view.heightAnchor.constraint(equalToConstant: BarTheme.rowIcon),
            ])
            iconView = view
        }

        let text = NSTextField(labelWithString: guideRow.label)
        text.font = BarTheme.rowLabelFont
        text.textColor = .labelColor
        text.lineBreakMode = .byTruncatingTail
        text.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        // Absorbs the slack, so the key lands at the trailing edge where a
        // menu keeps its shortcut.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.widthAnchor.constraint(
            greaterThanOrEqualToConstant: BarTheme.rowKeyGap).isActive = true

        // One cap per press, through the shared shape. A row whose keys are
        // alternatives rather than a sequence passes them as one string and
        // still gets one cap, which is what `J K` — either one — needs.
        let chip: NSView
        let caps = guideRow.keys.map { Keycaps.cap($0) }
        if let action = guideRow.action {
            chip = Keycaps.CapGroup(caps: caps, action: action)
        } else if caps.count == 1 {
            chip = caps[0]
        } else {
            let group = NSStackView(views: caps)
            group.orientation = .horizontal
            group.alignment = .centerY
            group.spacing = 4
            group.setContentHuggingPriority(.required, for: .horizontal)
            chip = group
        }

        if let iconView { row.addArrangedSubview(iconView) }
        row.addArrangedSubview(text)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(chip)
        return row
    }

    private func present() {
        root.layoutSubtreeIfNeeded()
        var size = root.fittingSize
        size.width = min(max(size.width, 200), 1100)
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
