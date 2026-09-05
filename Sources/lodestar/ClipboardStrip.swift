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

    private static let cardWidth: CGFloat = 208
    /// One card size for both zones. A pin needs less preview than a recent
    /// — you already know what slot 2 holds — but a column of stubby cards
    /// beside full ones reads as a mistake, and the strip is something you
    /// look at every day.
    private static let cardHeight: CGFloat = 158
    private static let gap: CGFloat = 10
    private static let searchHeight: CGFloat = 54
    private static let margin: CGFloat = 22
    /// What stands above the row of recents: the clip door's floor.
    static let rowHeight: CGFloat = cardHeight + gap

    /// Where the pin column stands and how wide the band may be, decided
    /// from the screen alone so a test can ask about any screen. The
    /// column is centered on the screen's left edge, its own zone rather
    /// than an extension of the row; on a short screen it comes down no
    /// further than the row above the recents, where the band lives, and
    /// then the band keeps clear of it by starting to its right. The
    /// column is always drawn, one free slot past the highest in use:
    /// it is how a hand that has never pinned learns that it can.
    struct Layout: Equatable {
        /// Panel-relative y of the lowest drawn slot's bottom edge.
        var columnBottom: CGFloat
        /// Where the search band starts: zero when the column is clear of it.
        var bandLeft: CGFloat
        /// The panel's content height, before its outer margin.
        var height: CGFloat
    }

    static func layout(screenHeight: CGFloat, drawnSlots: Int) -> Layout {
        let row = cardHeight + gap
        let column = drawnSlots > 0 ? CGFloat(drawnSlots) * (cardHeight + gap) - gap : 0
        // The panel's origin sits one margin above the screen's bottom.
        let centered = screenHeight / 2 - margin - column / 2
        let bottom = drawnSlots > 0 ? max(row, centered) : row
        let clear = drawnSlots == 0 || bottom >= row + searchHeight + gap
        return Layout(columnBottom: bottom,
                      bandLeft: clear ? 0 : cardWidth + gap,
                      height: max(row + searchHeight, drawnSlots > 0 ? bottom + column : 0))
    }
    /// The frame the band last took, and where the column stood, for the
    /// tests and for the actions menu beside a pin.
    private(set) var bandFrame: NSRect?
    private var columnBottom: CGFloat = 0

    var isVisible: Bool { panel.isVisible }
    /// For the tests: the window casts no shadow of its own.
    var castsWindowShadow: Bool { panel.hasShadow }
    /// Which label each visible recent card answers to, in order.
    private(set) var shownRecents: [Clipboard.Clip] = []
    private(set) var shownPins: [Int: Clipboard.Clip] = [:]
    /// The pin column stepped aside for the clip door, since nothing in
    /// it can be pressed while the door stands.
    private(set) var pinsHidden = false
    /// What each card said about its length, and where it came from, by
    /// clip id — the tests read what the screen shows.
    private(set) var shownBadges: [String: String] = [:]
    private(set) var shownSources: [String: String] = [:]
    private(set) var shownCaptions: [String: String] = [:]
    /// Every plate's veil, in the order the cards were made — the tests
    /// read that a lit card is raised and the rest are the launcher's.
    private(set) var shownWeights: [Glass.Weight] = []
    /// The plates themselves, by clip id, so a test can look inside one.
    private(set) var shownCards: [String: NSView] = [:]
    /// The card's rows: the chip line at the top, the caption line at the
    /// foot, and the preview between them.
    private static let cardHead: CGFloat = 34
    private static let cardFoot: CGFloat = 26

    init() {
        panel = Glass.makePanel(level: .statusBar)
        panel.ignoresMouseEvents = true
        panel.contentView = root
        // The strip is separate cards in one window. A window shadow is
        // cut from the union of what is opaque, and on a pale ground its
        // rim drew a hairline around that union, bridging the gaps
        // between the column, the row, and a menu. Each plate casts its
        // own shadow instead; the window casts none.
        panel.hasShadow = false
    }

    func hide() { panel.orderOut(nil) }

    /// Lay the world out for one frame. Cheap enough to call on every
    /// keystroke while searching: previews come from the in-memory index and
    /// thumbnails are already decoded.
    func show(recents: [Clipboard.Clip], pins: [Clipboard.Clip],
              thumbnail: (String) -> NSImage?,
              band: Band, selection: Int, actingOn: String? = nil,
              pinsHidden: Bool = false) {
        let query: String?
        if case .search(let text) = band { query = text } else { query = nil }
        let screen = ActivePolicy.presentationFrame
        self.pinsHidden = pinsHidden
        shownBadges = [:]
        shownSources = [:]
        shownCaptions = [:]
        shownWeights = []
        shownCards = [:]

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
        let drawnSlots = pinsHidden ? 0 : Clipboard.pinSlotsToDraw(taken: Set(shownPins.keys))
        let placed = Self.layout(screenHeight: screen.height, drawnSlots: drawnSlots)
        columnBottom = placed.columnBottom
        bandFrame = nil
        let height = placed.height
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
            // The full width when the column is clear of this row; on a
            // short screen the column comes down to it, and the band
            // starts to the column's right instead.
            let frame = NSRect(x: placed.bandLeft, y: Self.cardHeight + Self.gap,
                               width: max(Self.cardWidth, stripWidth - placed.bandLeft),
                               height: Self.searchHeight)
            bandFrame = frame
            addSearchField(query: query, frame: frame)
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
            label.font = BarTheme.bodyFont
            label.textColor = BarTheme.secondaryColor
            label.alignment = .center
            label.sizeToFit()
            label.frame = NSRect(x: 0, y: (Self.cardHeight - label.frame.height) / 2,
                                 width: stripWidth, height: label.frame.height)
            card.addSubview(label)
            root.addSubview(card)
        }

        // Pins: their own column, centered on the screen's left edge,
        // numbered and permanent. An empty slot still draws, so the
        // numbers are always visible and a freed slot reads as reserved
        // rather than missing.
        for slot in stride(from: 1, through: drawnSlots, by: 1) {
            let card: NSView
            if let clip = shownPins[slot] {
                card = makeCard(clip: clip, label: address + "\(slot)", height: Self.cardHeight,
                                thumbnail: thumbnail(clip.id),
                                highlighted: clip.id == actingOn)
            } else {
                card = makeEmptyPin(slot: slot)
            }
            card.frame = NSRect(x: 0,
                                y: placed.columnBottom + CGFloat(slot - 1) * (Self.cardHeight + Self.gap),
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
        shownCards[clip.id] = card

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
            count.font = BarTheme.secondaryFont
            count.textColor = BarTheme.secondaryColor
            count.sizeToFit()
            count.frame.origin = NSPoint(x: chip.frame.maxX + 6,
                                         y: height - count.frame.height - 10)
            card.addSubview(count)
        }

        if let thumbnail {
            let view = NSImageView(image: thumbnail)
            view.imageScaling = .scaleProportionallyUpOrDown
            view.frame = NSRect(x: 11, y: Self.cardFoot, width: Self.cardWidth - 22,
                                height: height - Self.cardHead - Self.cardFoot)
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
            preview.font = BarTheme.bodyFont
            preview.textColor = BarTheme.secondaryColor
            // Wrap to the card, ellipsize only the last line. Assigning
            // .byTruncatingTail here collapses the field to a single line
            // whatever the line limit says — the ellipsis has to come from
            // the cell instead, or a taller card buys nothing but air.
            preview.lineBreakMode = .byWordWrapping
            preview.maximumNumberOfLines = 5
            preview.cell?.truncatesLastVisibleLine = true
            preview.frame = NSRect(x: 11, y: Self.cardFoot, width: Self.cardWidth - 22,
                                   height: height - Self.cardHead - Self.cardFoot)
            card.addSubview(preview)
        }

        // Where it came from, beside the icon that says so: the page a
        // browser copy was made on — the address the hand remembers, "the
        // one from GitHub", and the one the search reads — or, for any
        // other copy, the app's name. One line, one rule.
        var trailing = Self.cardWidth - 11
        if let bundleID = clip.sourceBundleID, let image = sourceIcon(bundleID: bundleID) {
            let icon = NSImageView(image: image)
            icon.frame = NSRect(x: Self.cardWidth - 28, y: height - 27, width: 17, height: 17)
            icon.alphaValue = 0.85
            card.addSubview(icon)
            trailing = Self.cardWidth - 33
        }
        if let origin = clip.sourceHost ?? clip.sourceAppName {
            let source = NSTextField(labelWithString: origin)
            source.font = BarTheme.secondaryFont
            source.textColor = BarTheme.secondaryColor
            source.lineBreakMode = .byTruncatingTail
            source.alignment = .right
            source.sizeToFit()
            // The room to the right of the chip and its item count.
            let width = min(source.frame.width, trailing - 64)
            source.frame = NSRect(x: trailing - width, y: height - 26,
                                  width: max(0, width), height: source.frame.height)
            card.addSubview(source)
            shownSources[clip.id] = origin
        }

        // The foot is one caption: how long, then how old. A card that
        // holds more than it shows says so, so the hand knows a card is
        // worth opening before it opens it; a card that shows all of
        // itself says only its age.
        let badge = Clipboard.lengthBadge(for: clip)
        if let badge { shownBadges[clip.id] = badge }
        let caption = Caption.line([badge, Clipboard.age(of: clip)])
        shownCaptions[clip.id] = caption
        let foot = NSTextField(labelWithString: caption)
        foot.font = BarTheme.secondaryFont
        foot.textColor = BarTheme.secondaryColor
        foot.sizeToFit()
        foot.frame.origin = NSPoint(x: Self.cardWidth - foot.frame.width - 11, y: 8)
        card.addSubview(foot)
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
            let pinTop = columnBottom + CGFloat(slot - 1) * row + Self.cardHeight
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
        let plate = Plate(radius: BarTheme.glassRadius)
        plate.frame = frame
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
            key.textColor = BarTheme.secondaryColor
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
        symbol.contentTintColor = BarTheme.secondaryColor
        symbol.frame = NSRect(x: 18, y: (Self.searchHeight - 18) / 2, width: 18, height: 18)
        plate.addSubview(symbol)

        let font = NSFont.systemFont(ofSize: 19, weight: .regular)
        let field = NSTextField(labelWithString: query.isEmpty ? "Search clips" : query)
        field.font = font
        field.textColor = query.isEmpty ? BarTheme.secondaryColor : .labelColor
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

    /// A card is the launcher's glass, small: the one backdrop recipe,
    /// with the veil's weight saying whether the card is lit or waiting.
    /// The card's content rides on the plate ABOVE the material, never
    /// inside it: the glass stamps its backdrop-adapted appearance onto
    /// its own subtree, and a labelColor caught in there can resolve
    /// against the wrong tone.
    private func glassPlate(radius: CGFloat, weight: Weight = .normal) -> NSView {
        let plate = Plate(radius: radius)
        let veil: Glass.Weight
        switch weight {
        case .normal: veil = .normal
        case .highlighted: veil = .raised
        case .empty: veil = .faint
        }
        Glass.installBackdrop(in: plate, cornerRadius: radius, weight: veil)
        shownWeights.append(veil)
        return plate
    }
}

/// A card's plate: it casts the shadow the strip's window does not,
/// shaped to its own rounded rectangle rather than to whatever the
/// glass composites, so the shadow is there whatever the material
/// decides to draw.
final class Plate: NSView {
    let radius: CGFloat

    init(radius: CGFloat) {
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.35).cgColor
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var frame: NSRect {
        didSet {
            layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius,
                                       cornerHeight: radius, transform: nil)
        }
    }
}
