import AppKit
import LodestarCore

/// The paste surface: recents along the bottom, pins climbing the left.
///
/// The right angle is deliberate. Both of the places you are most likely to
/// want — a pin, or the thing you just copied — sit at the same corner, so
/// the eye has one hot region instead of two ends of a wide strip to choose
/// between. Older clips trail off to the right, where you rarely look.
///
/// Never key: the strip reads its keys from the event tap, so the window you
/// are typing in keeps focus and its insertion point the whole time. That is
/// what lets the paste be a plain ⌘V into an app that never lost the cursor.
final class ClipboardStrip {
    /// Source-app icons by bundle id, misses cached too. The cards rebuild
    /// on every keystroke of a strip search, and each icon was a fresh
    /// LaunchServices lookup plus an icon load — the same ~3.5ms-cold call
    /// AppIndex measured and cached, here paid per card per keystroke.
    private var sourceIcons: [String: NSImage?] = [:]

    private func sourceIcon(bundleID: String) -> NSImage? {
        if let cached = sourceIcons[bundleID] { return cached }
        let resolved = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        sourceIcons[bundleID] = resolved
        return resolved
    }

    static let labels = Clipboard.recentLabels

    /// What the region beside the pins is carrying, when it is carrying
    /// anything. Idle it stays empty — a bar sitting there permanently is
    /// furniture, and the strip is something you look at every day.
    enum Band {
        case none
        case search(String)
        /// A card's actions, drawn as a card: a row of text where a card
        /// belongs reads as a caption, not as a menu.
        case actions([Action])
    }

    /// One line of the actions menu. The symbol and the destructive flag are
    /// most of what makes it read as a menu rather than a legend: something
    /// to recognise the row by without reading it, and a colour that says
    /// this one does not undo.
    struct Action {
        let key: String
        let label: String
        let symbol: String
        var isDestructive = false
    }

    private let panel: NSPanel
    private let root = NSView()

    private static let cardWidth: CGFloat = 186
    /// One card size for both zones. A pin needs less preview than a recent
    /// — you already know what slot 2 holds — but a column of stubby cards
    /// beside full ones reads as a mistake, and the strip is something you
    /// look at every day.
    private static let cardHeight: CGFloat = 124
    private static let gap: CGFloat = 10
    private static let searchHeight: CGFloat = 54
    private static let margin: CGFloat = 22

    var isVisible: Bool { panel.isVisible }
    /// Which label each visible recent card answers to, in order.
    private(set) var shownRecents: [Clipboard.Clip] = []
    private(set) var shownPins: [Int: Clipboard.Clip] = [:]

    init() {
        panel = Glass.makePanel(level: .statusBar)
        panel.ignoresMouseEvents = true
        panel.contentView = root
    }

    func hide() { panel.orderOut(nil) }

    /// Lay the world out for one frame. Cheap enough to call on every
    /// keystroke while searching: previews come from the in-memory index and
    /// thumbnails are already decoded.
    func show(recents: [Clipboard.Clip], pins: [Clipboard.Clip],
              thumbnail: (String) -> NSImage?,
              band: Band, selection: Int, actingOn: String? = nil) {
        let query: String?
        if case .search(let text) = band { query = text } else { query = nil }
        let screen = ActivePolicy.presentationFrame

        // As many cards as the display can hold at a readable size, never
        // more than the alphabet — the guide panel already adapts this way.
        let usable = screen.width - Self.margin * 2
        let fit = max(1, Int((usable + Self.gap) / (Self.cardWidth + Self.gap)))
        let visibleRecents = Array(recents.prefix(min(fit, Self.labels.count)))
        shownRecents = visibleRecents
        // Last-wins, never a trap: a hand-edited or drifted index can hold
        // two clips claiming one slot, and the strip opening is the wrong
        // place to die over it.
        shownPins = Dictionary(pins.compactMap { clip in
            clip.pinnedSlot.map { ($0, clip) }
        }, uniquingKeysWith: { _, second in second })

        root.subviews.forEach { $0.removeFromSuperview() }

        // Searching holds the full width whatever the results do. Sized to
        // the matches, the field would resize on every keystroke and vanish
        // entirely when a query matched nothing.
        let lanes = query != nil
            ? min(fit, Self.labels.count)
            : max(visibleRecents.count, 1)
        let stripWidth = CGFloat(lanes) * (Self.cardWidth + Self.gap) - Self.gap
        // Slots through the highest in use and one free one after it: the
        // next pin's number is visible, and four empty cards do not stand
        // for slots nobody has reached. Positions never move.
        let drawnSlots = Clipboard.pinSlotsToDraw(taken: Set(shownPins.keys))
        let pinColumnHeight = CGFloat(drawnSlots) * (Self.cardHeight + Self.gap)
        let height = Self.cardHeight + Self.gap + pinColumnHeight
        let width = max(stripWidth, Self.cardWidth) + Self.margin * 2

        let frame = NSRect(x: screen.minX + Self.margin,
                           y: screen.minY + Self.margin,
                           width: min(width, screen.width - Self.margin * 2),
                           height: height + Self.margin)

        // Everything built inside one disabled-animation transaction: liquid
        // glass animates its own construction otherwise, and a strip that
        // fades in is a strip that is late.
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        panel.setFrame(frame, display: false)
        root.frame = NSRect(origin: .zero, size: frame.size)

        // Recents are the bottom row, always — opening search must not
        // shift the cards you are looking at.
        let y: CGFloat = 0
        // While the band is open every letter is query text, so a chip that
        // still read "A" would be naming a key that no longer does this.
        // ⌥ is what addresses a card mid-search, and the chip says so for
        // as long as that is true.
        let address = query != nil ? "⌥" : ""
        switch band {
        case .none:
            break
        case .search(let query):
            // The band fills space the one-card-wide pin column already
            // leaves empty, so nothing moves and nothing disappears.
            let bandLeft = Self.cardWidth + Self.gap
            addSearchField(query: query,
                           frame: NSRect(x: bandLeft, y: Self.cardHeight + Self.gap,
                                         width: max(Self.cardWidth, stripWidth - bandLeft),
                                         height: Self.searchHeight))
        case .actions(let actions):
            let size = actionSize(actions)
            addActionCard(actions, frame: actionFrame(for: actingOn, size: size,
                                                      stripWidth: stripWidth))
        }

        for (offset, clip) in visibleRecents.enumerated() {
            let label = Self.labels[offset]
            let card = makeCard(clip: clip, label: address + label, height: Self.cardHeight,
                                thumbnail: thumbnail(clip.id),
                                highlighted: clip.id == actingOn
                                    || (query != nil && offset == selection))
            card.frame = NSRect(x: CGFloat(offset) * (Self.cardWidth + Self.gap),
                                y: y, width: Self.cardWidth, height: Self.cardHeight)
            root.addSubview(card)
        }

        // Nothing matched, and that is a fact about the whole region rather
        // than about one slot. An empty *pin* is card-shaped because it is
        // still addressable — you can press 4. Nothing answers to a label
        // here, so it must not wear a card's shape and imply otherwise.
        if query != nil, visibleRecents.isEmpty {
            let card = glassPlate(radius: BarTheme.rowRadius, weight: .empty)
            card.frame = NSRect(x: 0, y: y, width: stripWidth, height: Self.cardHeight)
            let label = NSTextField(labelWithString: "No matches")
            label.font = .systemFont(ofSize: 13, weight: .regular)
            label.textColor = .tertiaryLabelColor
            label.alignment = .center
            label.sizeToFit()
            label.frame = NSRect(x: 0, y: (Self.cardHeight - label.frame.height) / 2,
                                 width: stripWidth, height: label.frame.height)
            card.addSubview(label)
            root.addSubview(card)
        }

        // Pins: climbing from the same corner, numbered and permanent. An
        // empty slot still draws, so the numbers are always visible and a
        // freed slot reads as reserved rather than missing.
        for slot in 1...drawnSlots {
            let card: NSView
            if let clip = shownPins[slot] {
                card = makeCard(clip: clip, label: address + "\(slot)", height: Self.cardHeight,
                                thumbnail: thumbnail(clip.id),
                                highlighted: clip.id == actingOn)
            } else {
                card = makeEmptyPin(slot: slot)
            }
            card.frame = NSRect(x: 0,
                                y: y + Self.cardHeight + Self.gap
                                    + CGFloat(slot - 1) * (Self.cardHeight + Self.gap),
                                width: Self.cardWidth, height: Self.cardHeight)
            root.addSubview(card)
        }

        panel.orderFrontRegardless()
        CATransaction.commit()
        NSAnimationContext.endGrouping()
    }

    // MARK: - Cards

    private func makeCard(clip: Clipboard.Clip, label: String, height: CGFloat,
                          thumbnail: NSImage?, highlighted: Bool) -> NSView {
        let card = glassPlate(radius: BarTheme.rowRadius, weight: highlighted ? .highlighted : .normal)

        let chip = NSTextField(labelWithString: label.uppercased())
        chip.font = BarTheme.chipFont
        chip.textColor = .labelColor
        chip.sizeToFit()
        chip.frame.origin = NSPoint(x: 11, y: height - chip.frame.height - 9)
        card.addSubview(chip)

        // A copy of several things reads as one card, and without this it
        // reads as one *thing* — three files copied together look exactly
        // like the first of them until they are pasted.
        if let items = clip.itemsLabel {
            let count = NSTextField(labelWithString: items)
            count.font = .systemFont(ofSize: 10, weight: .medium)
            count.textColor = .tertiaryLabelColor
            count.sizeToFit()
            count.frame.origin = NSPoint(x: chip.frame.maxX + 6,
                                         y: height - count.frame.height - 11)
            card.addSubview(count)
        }

        if let thumbnail {
            let view = NSImageView(image: thumbnail)
            view.imageScaling = .scaleProportionallyUpOrDown
            view.frame = NSRect(x: 11, y: 9, width: Self.cardWidth - 22, height: height - 36)
            card.addSubview(view)
        } else {
            let preview = NSTextField(wrappingLabelWithString: String(clip.preview.prefix(220)))
            // Not BarTheme.secondaryFont: that size is for supporting text
            // under a title. Here the preview *is* the content, so it takes
            // a reading size rather than a captioning one.
            //
            // A point below the menus' 13: a card is read at a glance to
            // tell clips apart, and the extra line it buys is worth more
            // than the point of size it costs.
            preview.font = .systemFont(ofSize: 12, weight: .regular)
            preview.textColor = .secondaryLabelColor
            // Wrap to the card, ellipsize only the last line. Assigning
            // .byTruncatingTail here collapses the field to a single line
            // whatever the line limit says — the ellipsis has to come from
            // the cell instead, or a taller card buys nothing but air.
            preview.lineBreakMode = .byWordWrapping
            preview.maximumNumberOfLines = 5
            preview.cell?.truncatesLastVisibleLine = true
            preview.frame = NSRect(x: 11, y: 9, width: Self.cardWidth - 22, height: height - 38)
            card.addSubview(preview)
        }

        var trailing = Self.cardWidth - 11
        if let bundleID = clip.sourceBundleID, let image = sourceIcon(bundleID: bundleID) {
            let icon = NSImageView(image: image)
            icon.frame = NSRect(x: Self.cardWidth - 26, y: height - 24, width: 15, height: 15)
            icon.alphaValue = 0.7
            card.addSubview(icon)
            trailing = Self.cardWidth - 30
        }
        // The page a browser copy came from, beside the app that made it:
        // the address the hand remembers — "the one from GitHub" — and
        // the one the search reads too.
        if let host = clip.sourceHost {
            let page = NSTextField(labelWithString: host)
            page.font = .systemFont(ofSize: 10, weight: .medium)
            page.textColor = .tertiaryLabelColor
            page.lineBreakMode = .byTruncatingTail
            page.alignment = .right
            page.sizeToFit()
            let width = min(page.frame.width, 96)
            page.frame = NSRect(x: trailing - width, y: height - 24,
                                width: width, height: page.frame.height)
            card.addSubview(page)
        }

        let age = NSTextField(labelWithString: Clipboard.age(of: clip))
        age.font = .systemFont(ofSize: 10, weight: .medium)
        age.textColor = .tertiaryLabelColor
        age.sizeToFit()
        age.frame.origin = NSPoint(x: Self.cardWidth - age.frame.width - 11, y: 8)
        card.addSubview(age)
        return card
    }

    /// An empty slot keeps the material and loses the frosting. An outline
    /// drew a hard rectangle on the content behind it, half opacity faded
    /// the number along with the card, and a flat fill was fainter still —
    /// what works is the same glass, less dense, with the number legible.
    private func makeEmptyPin(slot: Int) -> NSView {
        let card = glassPlate(radius: BarTheme.rowRadius, weight: .empty)
        let chip = NSTextField(labelWithString: "\(slot)")
        chip.font = BarTheme.chipFont
        chip.textColor = .tertiaryLabelColor
        chip.sizeToFit()
        chip.frame.origin = NSPoint(x: 11, y: Self.cardHeight - chip.frame.height - 9)
        card.addSubview(chip)
        return card
    }

    // MARK: - Actions

    /// Menu metrics. The row height is fixed rather than divided out of the
    /// card: a menu whose rows stretch when it has two actions and compress
    /// when it has four reads as a different control every time it opens.
    private static let actionRow: CGFloat = 32
    private static let actionPadY: CGFloat = 12
    private static let actionInset: CGFloat = 14
    private static let actionChipGap = BarTheme.rowGap
    private static let actionKeyGap = BarTheme.rowKeyGap
    private static let actionIcon = BarTheme.rowIcon
    private static let actionSeparator: CGFloat = 11
    private static let actionChip = NSSize(width: BarTheme.chipMinWidth,
                                           height: BarTheme.chipHeight)
    private static let actionFont = BarTheme.rowLabelFont

    /// What a label needs, measured through the control that will draw it.
    /// A glyph-run measurement comes up a few points short — the field's
    /// cell keeps its own inset — and the whole menu is sized off this, so
    /// being short by two points truncates the longest action.
    private func actionLabelWidth(_ text: String) -> CGFloat {
        let field = NSTextField(labelWithString: text)
        field.font = Self.actionFont
        field.sizeToFit()
        return ceil(field.frame.width)
    }

    /// Where the rule falls: before the first destructive action, and only
    /// when something benign precedes it. Grouping is derived rather than
    /// declared, so a new action lands on the correct side of the line by
    /// saying what it is.
    private func separatorIndex(_ actions: [Action]) -> Int? {
        guard let first = actions.firstIndex(where: \.isDestructive), first > 0 else { return nil }
        return first
    }

    /// Sized to its contents, not to the grid — bounded below by a card so
    /// it never looks like a scrap, and above so a long label wraps the
    /// menu rather than the strip.
    private func actionSize(_ actions: [Action]) -> NSSize {
        let widest = actions.map { actionLabelWidth($0.label) }.max() ?? 0
        let width = Self.actionInset * 2 + Self.actionIcon + Self.actionChipGap
            + widest + Self.actionKeyGap + Self.actionChip.width
        var height = CGFloat(actions.count) * Self.actionRow + Self.actionPadY * 2
        if separatorIndex(actions) != nil { height += Self.actionSeparator }
        return NSSize(width: min(max(width, Self.cardWidth), 340), height: height)
    }

    /// Where a card's actions belong, relative to the card they act on.
    ///
    /// A pin opens to its right, top edges level, the way a menu unfurls
    /// from the item it belongs to — the pin column is one card wide, so
    /// that space is always free. A recent opens upward from just above
    /// itself. The exception is the first recent: it sits directly under
    /// pin one, so its menu shifts one column right rather than covering
    /// a pin.
    private func actionFrame(for id: String?, size: NSSize, stripWidth: CGFloat) -> NSRect {
        let column = Self.cardWidth + Self.gap
        let row = Self.cardHeight + Self.gap
        var origin = NSPoint(x: column, y: row)

        if let id, let slot = shownPins.first(where: { $0.value.id == id })?.key {
            let pinTop = row + CGFloat(slot - 1) * row + Self.cardHeight
            origin = NSPoint(x: column, y: pinTop - size.height)
        } else if let id, let index = shownRecents.firstIndex(where: { $0.id == id }) {
            origin = NSPoint(x: CGFloat(max(index, 1)) * column, y: row)
        }
        // Never down over the recents, never off the right edge. A menu
        // taller than its pin grows upward instead.
        origin.y = max(origin.y, row)
        origin.x = min(origin.x, max(column, stripWidth - size.width))
        return NSRect(origin: origin, size: size)
    }

    private func addActionCard(_ actions: [Action], frame: NSRect) {
        // The graph card's material exactly — plain glass, no scrim of our
        // own. The strip's cards wear a scrim because they sit in a grid you
        // read across; a menu floats above everything and belongs to the
        // family of floating panels instead.
        let plate = NSView(frame: frame)
        _ = Glass.installBackdrop(in: plate, cornerRadius: BarTheme.glassRadius)

        let rule = separatorIndex(actions)
        var top = frame.height - Self.actionPadY
        for (offset, action) in actions.enumerated() {
            if offset == rule {
                let line = NSView(frame: NSRect(
                    x: Self.actionInset, y: top - Self.actionSeparator / 2,
                    width: frame.width - Self.actionInset * 2, height: 1))
                line.wantsLayer = true
                line.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
                plate.addSubview(line)
                top -= Self.actionSeparator
            }
            let bottom = top - Self.actionRow
            let tint: NSColor = action.isDestructive ? .systemRed : .labelColor

            // Icon, name, then key — the order a menu is read in. The cheat
            // sheet leads with the key because it answers "what does this
            // do"; a menu answers "what can I do", so the name leads.
            let icon = NSImageView(image: NSImage(
                systemSymbolName: action.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) ?? NSImage())
            icon.contentTintColor = tint
            icon.frame = NSRect(x: Self.actionInset,
                                y: bottom + (Self.actionRow - Self.actionIcon) / 2,
                                width: Self.actionIcon, height: Self.actionIcon)
            plate.addSubview(icon)

            let label = NSTextField(labelWithString: action.label)
            label.font = Self.actionFont
            label.textColor = tint
            label.lineBreakMode = .byTruncatingTail
            label.sizeToFit()
            let labelX = Self.actionInset + Self.actionIcon + Self.actionChipGap
            let keyX = frame.width - Self.actionInset - Self.actionChip.width
            label.frame = NSRect(x: labelX,
                                 y: bottom + (Self.actionRow - label.frame.height) / 2,
                                 width: max(0, keyX - Self.actionKeyGap - labelX),
                                 height: label.frame.height)
            plate.addSubview(label)

            // Right-aligned and quiet, where a shortcut sits in every menu
            // the user already knows.
            let chip = NSView(frame: NSRect(
                x: keyX, y: bottom + (Self.actionRow - Self.actionChip.height) / 2,
                width: Self.actionChip.width, height: Self.actionChip.height))
            chip.wantsLayer = true
            chip.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.09).cgColor
            chip.layer?.cornerRadius = BarTheme.chipRadius
            let key = NSTextField(labelWithString: action.key.uppercased())
            key.font = BarTheme.chipFont
            key.textColor = .secondaryLabelColor
            key.alignment = .center
            key.sizeToFit()
            key.frame = NSRect(x: 0, y: (Self.actionChip.height - key.frame.height) / 2,
                               width: Self.actionChip.width, height: key.frame.height)
            chip.addSubview(key)
            plate.addSubview(chip)

            top = bottom
        }
        root.addSubview(plate)
    }

    /// The same input surface the searcher and the web bar use, sitting
    /// directly under the cards it filters. A typed prefix read as a vim
    /// prompt; a glass field with a magnifier reads as the thing everyone
    /// already knows a search box to be.
    private func addSearchField(query: String, frame: NSRect) {
        let width = frame.width
        let plate = glassPlate(radius: BarTheme.rowRadius)
        plate.frame = frame

        let symbol = NSImageView(image: NSImage(
            systemSymbolName: "magnifyingglass",
            accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium)) ?? NSImage())
        symbol.contentTintColor = .secondaryLabelColor
        symbol.frame = NSRect(x: 18, y: (Self.searchHeight - 18) / 2, width: 18, height: 18)
        plate.addSubview(symbol)

        let font = NSFont.systemFont(ofSize: 19, weight: .regular)
        let field = NSTextField(labelWithString: query.isEmpty ? "Search clips" : query)
        field.font = font
        field.textColor = query.isEmpty ? .tertiaryLabelColor : .labelColor
        field.lineBreakMode = .byTruncatingHead
        field.sizeToFit()
        field.frame = NSRect(x: 46, y: (Self.searchHeight - field.frame.height) / 2,
                             width: min(field.frame.width, width - 70), height: field.frame.height)
        plate.addSubview(field)

        // A still caret, never a blinking one — nothing in Lodestar pulses.
        //
        // Positioned from the measured glyphs, not from the field's frame:
        // an NSTextField reports a width including the cell's trailing
        // inset, which put the caret a space past the last letter.
        if !query.isEmpty {
            let glyphs = (query as NSString).size(withAttributes: [.font: font]).width
            let caret = NSView()
            caret.wantsLayer = true
            caret.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
            caret.frame = NSRect(x: field.frame.minX + min(glyphs, field.frame.width) + 2,
                                 y: (Self.searchHeight - 20) / 2, width: 1.5, height: 20)
            plate.addSubview(caret)
        }
        root.addSubview(plate)
    }

    enum Weight {
        case normal, highlighted
        /// An empty pin: the same material, less frosted. Keeping the glass
        /// holds the column visually together; the lighter scrim is what
        /// says the slot is waiting rather than full.
        case empty
    }

    /// The locked recipe: clear liquid glass over a scrim of our own, never
    /// a tint — tinting flashes, because the glass animates it internally
    /// beyond a transaction's reach.
    private func glassPlate(radius: CGFloat, weight: Weight = .normal) -> NSView {
        let scrim = EqualizerScrim()
        switch weight {
        case .normal: (scrim.darkBase, scrim.lightBase) = (0.45, 0.55)
        case .highlighted: (scrim.darkBase, scrim.lightBase) = (0.62, 0.72)
        case .empty: (scrim.darkBase, scrim.lightBase) = (0.28, 0.34)
        }
        scrim.wantsLayer = true
        scrim.layer?.cornerRadius = radius
        scrim.autoresizingMask = [.width, .height]

        // The card's content rides on a plain wrapper ABOVE the material,
        // never inside it: the glass stamps its backdrop-adapted appearance
        // onto its own subtree, and a labelColor caught in there can
        // resolve against the system tone the scrim equalizes toward.
        let plate = NSView()
        let backdrop: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = radius
            glass.style = .clear
            glass.contentView = scrim
            backdrop = glass
        } else {
            let fallback = NSView()
            Glass.installBackdrop(in: fallback, cornerRadius: radius)
            fallback.addSubview(scrim)
            backdrop = fallback
        }
        backdrop.frame = plate.bounds
        backdrop.autoresizingMask = [.width, .height]
        plate.addSubview(backdrop)
        return plate
    }
}
