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
    /// The recents alphabet: home row, left to right, so the keys under your
    /// fingers are laid out in the same order as the cards under your eyes.
    /// Its own alphabet, not the hints one — hint labels are arbitrary
    /// assignments to screen positions, these are ordinal.
    static let labels = Array("asdfghjkl").map(String.init)

    private let panel: NSPanel
    private let root = NSView()
    private var cards: [String: NSView] = [:]

    private static let cardWidth: CGFloat = 156
    private static let cardHeight: CGFloat = 96
    private static let gap: CGFloat = 10
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
              query: String?, selection: Int) {
        let screen = ActivePolicy.presentationFrame

        let visibleRecents = Array(recents.prefix(Self.labels.count))
        shownRecents = visibleRecents
        shownPins = Dictionary(uniqueKeysWithValues: pins.compactMap { clip in
            clip.pinnedSlot.map { ($0, clip) }
        })

        root.subviews.forEach { $0.removeFromSuperview() }
        cards.removeAll()

        let stripWidth = CGFloat(max(visibleRecents.count, 1)) * (Self.cardWidth + Self.gap) - Self.gap
        let pinColumnHeight = CGFloat(Clipboard.pinSlots) * (Self.cardHeight + Self.gap)
        let height = Self.cardHeight + Self.gap + pinColumnHeight + (query != nil ? 34 : 0)
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

        var y: CGFloat = 0
        if let query {
            addSearchField(query: query, width: root.bounds.width)
            y = 34
        }

        // Recents: the bottom row, newest at the left where the pins are.
        for (offset, clip) in visibleRecents.enumerated() {
            let label = Self.labels[offset]
            let card = makeCard(clip: clip, label: label,
                                thumbnail: thumbnail(clip.id),
                                highlighted: query != nil && offset == selection)
            card.frame = NSRect(x: CGFloat(offset) * (Self.cardWidth + Self.gap),
                                y: y, width: Self.cardWidth, height: Self.cardHeight)
            root.addSubview(card)
            cards[label] = card
        }

        // Pins: climbing from the same corner, numbered and permanent. An
        // empty slot still draws, so the numbers are always visible and a
        // freed slot reads as reserved rather than missing.
        for slot in 1...Clipboard.pinSlots {
            let card: NSView
            if let clip = shownPins[slot] {
                card = makeCard(clip: clip, label: "\(slot)",
                                thumbnail: thumbnail(clip.id), highlighted: false)
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

    private func makeCard(clip: Clipboard.Clip, label: String,
                          thumbnail: NSImage?, highlighted: Bool) -> NSView {
        let card = glassPlate(radius: BarTheme.rowRadius, highlighted: highlighted)

        let chip = NSTextField(labelWithString: label.uppercased())
        chip.font = BarTheme.chipFont
        chip.textColor = .labelColor
        chip.sizeToFit()
        chip.frame.origin = NSPoint(x: 10, y: Self.cardHeight - chip.frame.height - 8)
        card.addSubview(chip)

        if let thumbnail {
            let view = NSImageView(image: thumbnail)
            view.imageScaling = .scaleProportionallyUpOrDown
            view.frame = NSRect(x: 10, y: 8, width: Self.cardWidth - 20, height: Self.cardHeight - 34)
            card.addSubview(view)
        } else {
            let preview = NSTextField(wrappingLabelWithString: String(clip.preview.prefix(160)))
            preview.font = BarTheme.secondaryFont
            preview.textColor = .secondaryLabelColor
            preview.maximumNumberOfLines = 3
            preview.frame = NSRect(x: 10, y: 20, width: Self.cardWidth - 20, height: Self.cardHeight - 46)
            card.addSubview(preview)
        }

        if let bundleID = clip.sourceBundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: url.path))
            icon.frame = NSRect(x: Self.cardWidth - 24, y: 8, width: 15, height: 15)
            icon.alphaValue = 0.75
            card.addSubview(icon)
        }
        return card
    }

    private func makeEmptyPin(slot: Int) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = BarTheme.rowRadius
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        let chip = NSTextField(labelWithString: "\(slot)")
        chip.font = BarTheme.chipFont
        chip.textColor = .tertiaryLabelColor
        chip.sizeToFit()
        chip.frame.origin = NSPoint(x: 10, y: Self.cardHeight - chip.frame.height - 8)
        card.addSubview(chip)
        return card
    }

    private func addSearchField(query: String, width: CGFloat) {
        let field = NSTextField(labelWithString: "/ \(query)")
        field.font = BarTheme.titleFont
        field.textColor = .labelColor
        field.frame = NSRect(x: 4, y: 4, width: width - 8, height: 26)
        root.addSubview(field)
    }

    /// The locked recipe: clear liquid glass over a scrim of our own, never
    /// a tint — tinting flashes, because the glass animates it internally
    /// beyond a transaction's reach.
    private func glassPlate(radius: CGFloat, highlighted: Bool) -> NSView {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let scrim = NSView()
        scrim.wantsLayer = true
        let base: CGFloat = highlighted ? (dark ? 0.62 : 0.72) : (dark ? 0.45 : 0.55)
        scrim.layer?.backgroundColor = (dark
            ? NSColor.black.withAlphaComponent(base)
            : NSColor.white.withAlphaComponent(base)).cgColor
        scrim.layer?.cornerRadius = radius
        scrim.autoresizingMask = [.width, .height]

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = radius
            glass.style = .clear
            glass.contentView = scrim
            return glass
        }
        let fallback = NSView()
        Glass.installBackdrop(in: fallback, cornerRadius: radius)
        fallback.addSubview(scrim)
        return fallback
    }
}
