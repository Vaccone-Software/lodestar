import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// design/12-well.md as a picture, made of the real views: a bar's field,
/// a field empty and typed and selected, the focused well beside a resting
/// one, a note, Keep's band, an empty slot, and a well inside the slab. Each
/// field is a real field in a panel of its own that has the keys while it is
/// drawn, so the caret and the selection are the ones a person would see; the
/// panels stand where no display is.
enum GalleryWell {
    /// One real field, in a window of its own that can take the keys.
    struct Cell {
        let caption: String
        let panel: KeyablePanel
        let root: NSView
        /// What holds the caret, if anything does.
        let focus: NSView?
    }

    /// A cell's window: clear, so what is drawn in it lies on the sheet's pane.
    private static func cell(_ caption: String, size: NSSize, look: GalleryLook,
                             _ build: (NSView) -> NSView?) -> Cell {
        let panel = KeyablePanel(contentRect: NSRect(origin: GalleryRender.away, size: size),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        DisplayScale.pin()
        DisplayScale.keepNative(panel)
        panel.appearance = NSAppearance(named: look.appearance)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        panel.contentView = root
        panel.setContentSize(size)
        let focus = build(root)
        root.layoutSubtreeIfNeeded()
        if let focus { panel.makeFirstResponder(focus) }
        return Cell(caption: caption, panel: panel, root: root, focus: focus)
    }

    private static func end(of field: NSTextField) {
        field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
    }

    /// A bar's field: a well one pane inset from its pane's edge, 60 tall,
    /// holding a symbol and a line of the field's role.
    private static func bar(_ caption: String, text: String?, focused: Bool, look: GalleryLook) -> Cell {
        let size = NSSize(width: 560, height: BarTheme.inputHeight)
        let made = cell(caption, size: size, look: look) { root in
            let well = WellView()
            let field = InputField()
            field.setRole(.field)
            field.textColor = BarTheme.ink
            field.setPlaceholder("Where to?")
            if let text { field.stringValue = text }
            field.translatesAutoresizingMaskIntoConstraints = false
            let symbol = NSImageView(image: NSImage(systemSymbolName: "macwindow.on.rectangle",
                                                    accessibilityDescription: nil) ?? NSImage())
            symbol.symbolConfiguration = BarTheme.inputSymbol
            symbol.contentTintColor = BarTheme.secondaryColor
            symbol.translatesAutoresizingMaskIntoConstraints = false
            well.hold(field)
            root.addSubview(well)
            root.addSubview(symbol)
            root.addSubview(field)
            NSLayoutConstraint.activate([
                well.topAnchor.constraint(equalTo: root.topAnchor),
                well.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                well.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                well.heightAnchor.constraint(equalToConstant: BarTheme.inputHeight),
                symbol.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: BarTheme.paneInset),
                symbol.centerYAnchor.constraint(equalTo: root.centerYAnchor),
                field.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: Grid.part),
                field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -BarTheme.paneInset),
                field.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            ])
            return focused ? field : nil
        }
        if let field = made.focus as? NSTextField { end(of: field) }
        return made
    }

    /// A field of a room: a well 32 tall.
    private static func field(_ caption: String, text: String?, focused: Bool, selected: Bool = false,
                              look: GalleryLook) -> Cell {
        let size = NSSize(width: 560, height: BarTheme.fieldHeight)
        let made = cell(caption, size: size, look: look) { root in
            let field = WellField(frame: .zero)
            field.setRole(.body)
            field.textColor = BarTheme.ink
            field.setPlaceholder("Search every setting")
            if let text { field.stringValue = text }
            root.addSubview(field)
            NSLayoutConstraint.activate([
                field.topAnchor.constraint(equalTo: root.topAnchor),
                field.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ])
            return focused ? field : nil
        }
        if let field = made.focus as? NSTextField, !selected { end(of: field) }
        return made
    }

    /// Two fields, the second the one the caret is in: the edge says which.
    private static func pair(look: GalleryLook) -> Cell {
        let size = NSSize(width: 560, height: BarTheme.fieldHeight * 2 + Grid.close)
        let made = cell("focused beside resting: the edge at twice its weight", size: size, look: look) { root in
            let resting = WellField(frame: .zero), focused = WellField(frame: .zero)
            for (field, text) in [(resting, "me@example.com"), (focused, "Lodestar")] {
                field.setRole(.body)
                field.textColor = BarTheme.ink
                field.stringValue = text
                root.addSubview(field)
                field.leadingAnchor.constraint(equalTo: root.leadingAnchor).isActive = true
                field.trailingAnchor.constraint(equalTo: root.trailingAnchor).isActive = true
            }
            resting.topAnchor.constraint(equalTo: root.topAnchor).isActive = true
            focused.topAnchor.constraint(equalTo: resting.bottomAnchor, constant: Grid.close).isActive = true
            return focused
        }
        if let field = made.focus as? NSTextField { end(of: field) }
        return made
    }

    /// A note: a well at least four lines tall, the caret in its words.
    private static func note(look: GalleryLook) -> Cell {
        let size = NSSize(width: 560, height: 150)
        return cell("a note, 150 tall: the words 12 in, the caret in them", size: size, look: look) { root in
            let well = NoteWell(height: 150)
            well.text.isRichText = false
            well.text.setRole(.body)
            well.text.textColor = BarTheme.ink
            well.text.string = "The launcher opened on the wrong screen\nafter I unplugged the display."
            root.addSubview(well)
            NSLayoutConstraint.activate([
                well.topAnchor.constraint(equalTo: root.topAnchor),
                well.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                well.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ])
            return well.text
        }
    }

    /// Every cell of the sheet whose field is real, for a test to look into.
    static func cells(look: GalleryLook) -> [Cell] {
        var cells = [
            bar("a bar's field, 60 tall, resting: its placeholder in the words' size", text: nil, focused: false, look: look),
            bar("a bar's field, typed: the caret and the deeper edge", text: "ma", focused: true, look: look),
            field("a field, 32 tall, empty: the placeholder, quiet ink", text: nil, focused: false, look: look),
            field("a field, typed: the caret, 1.5 wide, still", text: "clipboard", focused: true, look: look),
            field("a field, selected: ink at 30% behind the words", text: "clipboard", focused: true, selected: true,
                  look: look),
            pair(look: look),
            note(look: look),
        ]
        // An empty field focused, for the caret at the start of its placeholder.
        cells.insert(field("a field, empty and focused: the caret where the words will be", text: nil, focused: true,
                           look: look), at: 4)
        return cells
    }

    /// Keep's band, an empty slot and a name being written on a chosen card,
    /// cut from one strip: the three are drawn by Lodestar itself.
    static func strip(look: GalleryLook) throws -> (images: [NSImage], keep: [AnyObject]) {
        let clips = [Clipboard.Clip(id: "p1", kind: .text, created: Date().addingTimeInterval(-180), sourceBundleID: nil,
                                    sourceAppName: nil, preview: "https://lodestar.vaccone.software", bytes: 34,
                                    nativeTypes: [], pinnedSlot: 1),
                     Clipboard.Clip(id: "p2", kind: .text, created: Date().addingTimeInterval(-180), sourceBundleID: nil,
                                    sourceAppName: nil, preview: "hello@example.com", bytes: 17,
                                    nativeTypes: [], pinnedSlot: 2)]
        let recents = [Clipboard.Clip(id: "r0", kind: .text, created: Date().addingTimeInterval(-12), sourceBundleID: nil,
                                      sourceAppName: nil, preview: "swift build -c release", bytes: 22,
                                      nativeTypes: [], pinnedSlot: nil)]
        let (view, keep) = try GalleryKeep.strip(look: look) {
            $0.show(recents: recents, pins: clips, thumbnail: { _ in nil }, band: .search("re"), selection: 0,
                    matches: 4, naming: .init(id: "p1", text: "Lodestar", selected: false))
        }
        let strip = try XCTUnwrap(keep.compactMap { $0 as? ClipboardStrip }.first)
        let rep = GalleryRender.bitmapBySiblings(of: view)
        // The strip's panel is the screen the gallery sets, so its places are
        // in the view's own coordinates.
        let frames = [try XCTUnwrap(strip.bandFrame), try XCTUnwrap(strip.shownFreePlaces.values.first).frame,
                      try XCTUnwrap(strip.shownCards["p1"]).frame]
        // Cut to the thing itself: its shadow belongs to the strip, and a cut one reads as a flaw.
        return (frames.map { crop(rep, $0) }, keep)
    }

    /// The part of a bitmap a rectangle in the view's own coordinates covers.
    static func crop(_ rep: NSBitmapImageRep, _ rect: NSRect) -> NSImage {
        let image = NSImage(size: rect.size)
        image.lockFocus()
        rep.draw(in: NSRect(origin: .zero, size: rect.size), from: rect, operation: .sourceOver, fraction: 1,
                 respectFlipped: false, hints: nil)
        image.unlockFocus()
        return image
    }

    static let size = NSSize(width: 1390, height: 840)

    /// The sheet: the cells' pictures and the strip's cuts, each captioned,
    /// in two columns on a pane.
    static func sheet(look: GalleryLook) throws -> (NSWindow, [AnyObject]) {
        let cells = cells(look: look)
        let pictures = cells.map { cell in NSImage.picture(GalleryRender.bitmap(of: cell.root)) }
        let (cuts, stripKeep) = try strip(look: look)
        let cutCaptions = ["a band's field, 32 tall, 4 inside its band, which rounds at 12.4: Keep's search",
                           "an empty slot: the card's own radius", "a well inside the slab: naming a keepsake"]
        var items = zip(cells.map(\.caption), pictures).map { ($0, $1) }
        items += zip(cutCaptions, cuts).map { ($0, $1) }
        let window = GalleryHost.pane(size: size, look: look) { root in
            let columns = NSStackView()
            columns.orientation = .horizontal
            columns.alignment = .top
            columns.spacing = Grid.section
            columns.translatesAutoresizingMaskIntoConstraints = false
            let left = column(), right = column()
            let half = (items.count + 1) / 2
            for (offset, item) in items.enumerated() {
                let target = offset < half ? left : right
                target.addArrangedSubview(GalleryKeys.caption(item.0))
                let picture = NSImageView(image: item.1)
                picture.imageScaling = .scaleNone
                picture.translatesAutoresizingMaskIntoConstraints = false
                target.addArrangedSubview(picture)
                target.setCustomSpacing(Grid.section, after: picture)
            }
            columns.addArrangedSubview(left)
            columns.addArrangedSubview(right)
            root.addSubview(columns)
            NSLayoutConstraint.activate([
                columns.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Grid.section),
                columns.topAnchor.constraint(equalTo: root.topAnchor, constant: Grid.section),
            ])
        }
        return (window, [window] + cells.map { $0.panel } + stripKeep)
    }

    private static func column() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Grid.close
        return stack
    }

    static var shots: [GalleryShot] {
        [GalleryShot(surface: "foundation", state: "well", looks: GalleryLook.all) { look in
            let (window, keep) = try sheet(look: look)
            window.contentView?.layoutSubtreeIfNeeded()
            return (window.contentView!, keep)
        }]
    }
}

private extension NSImage {
    /// A bitmap as a picture of the points it was drawn at.
    static func picture(_ rep: NSBitmapImageRep) -> NSImage {
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
