import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// design/11-slab.md as a picture, made of the real views: a pane with three
/// rows, the middle one the slab, holding words, quiet words, an icon,
/// resting keys, the lit ⏎, a dot and a chip; a Keep card as the slab; and a
/// slab pressed.
enum GallerySlab {
    static let size = NSSize(width: 720, height: 520)

    /// One row of the pane: an icon, a name, a note in quiet words, a dot and
    /// a chip, the address keys at rest, and ⏎ when it is the one chosen.
    static func row(_ name: String, note: String, chosen: Bool, pressed: Bool = false,
                    width: CGFloat = 640) -> (SlabRow, [AnyObject]) {
        let row = SlabRow(frame: .zero)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setupSlab()
        row.choose(chosen)
        let icon = NSImageView(image: NSImage(systemSymbolName: "envelope", accessibilityDescription: nil)?
            .withSymbolConfiguration(BarTheme.symbolRow) ?? NSImage())
        icon.contentTintColor = BarTheme.ink
        let title = BarTheme.label(name, role: .title, color: BarTheme.ink)
        let quiet = BarTheme.label(note, role: .meta, color: BarTheme.secondaryColor)
        let dot = ToneView(fill: BarTheme.secondaryColor, radius: BarTheme.dotRadius)
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: BarTheme.dotDiameter).isActive = true
        dot.heightAnchor.constraint(equalToConstant: BarTheme.dotDiameter).isActive = true
        let chip = FlatChip()
        chip.translatesAutoresizingMaskIntoConstraints = false
        let chipWord = BarTheme.label("Work", role: .key, color: BarTheme.secondaryColor)
        chipWord.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(chipWord)
        NSLayoutConstraint.activate([
            chipWord.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: Grid.half),
            chipWord.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -Grid.half),
            chipWord.topAnchor.constraint(equalTo: chip.topAnchor, constant: Grid.hair),
            chipWord.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -Grid.hair),
        ])
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let address = KeyStrokes(["e", "p"])
        let enter = Key("⏎")
        enter.lit = true
        enter.isHidden = !chosen
        let stack = NSStackView(views: [icon, title, quiet, dot, chip, spacer, address, enter])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Grid.part
        stack.edgeInsets = NSEdgeInsets(top: 0, left: Grid.part, bottom: 0, right: Grid.part)
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(stack)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: width),
            row.heightAnchor.constraint(equalToConstant: BarTheme.rowHeight),
            stack.topAnchor.constraint(equalTo: row.topAnchor),
            stack.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
        ])
        if pressed { row.press(true) }
        return (row, [row, enter])
    }

    /// The sheet: the pane of three rows, a Keep card as the slab beside a
    /// pressed row, the card with its picture as it is.
    static func sheet(look: GalleryLook) -> (NSWindow, [AnyObject]) {
        var made: [AnyObject] = []
        let window = GalleryHost.pane(size: size, look: look) { root in
            let column = NSStackView()
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 0
            column.translatesAutoresizingMaskIntoConstraints = false
            let rows = [("Safari", "Browser", false), ("Mail", "Inbox · 3 new", true), ("Notes", "Quick notes", false)]
            for (name, note, chosen) in rows {
                let (row, keep) = Self.row(name, note: note, chosen: chosen)
                column.addArrangedSubview(row)
                made += keep
            }
            root.addSubview(column)

            let caption = BarTheme.label("A Keep card as the slab, its picture as it is · a slab pressed: its side one point",
                                         role: .meta, color: BarTheme.secondaryColor)
            caption.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(caption)

            let (pressed, keep) = Self.row("Pressed", note: "side 4 to 1", chosen: true, pressed: true, width: 560)
            made += keep
            root.addSubview(pressed)

            let strip = ClipboardStrip()
            let clip = Clipboard.Clip(id: "card", kind: .image, created: Date().addingTimeInterval(-60),
                                      sourceBundleID: nil, sourceAppName: "Ghostty", preview: "image 1600×1000",
                                      bytes: 100, nativeTypes: [], pinnedSlot: nil)
            let card = strip.makeCard(clip: clip, key: "j", lit: true, size: NSSize(width: 190, height: 170),
                                      reading: nil, thumbnail: StripPreview.sampleImage(width: 640, height: 400),
                                      chosen: true)
            card.translatesAutoresizingMaskIntoConstraints = true
            root.addSubview(card)
            made += [strip, card]

            NSLayoutConstraint.activate([
                column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Grid.section),
                column.topAnchor.constraint(equalTo: root.topAnchor, constant: Grid.section),
                caption.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Grid.section),
                caption.topAnchor.constraint(equalTo: column.bottomAnchor, constant: Grid.section),
                pressed.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Grid.section),
                pressed.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: Grid.section),
            ])
            card.frame = NSRect(x: size.width - Grid.section - 190 - Grid.part, y: Grid.section + Grid.part,
                                width: 190, height: 170)
        }
        return (window, [window] + made)
    }

    /// The draft's microphone menu with the pointer on the second row: the
    /// pointer chooses here, so the pointer moves the slab.
    static func inputMenu() throws -> (NSView, [AnyObject]) {
        ActivePolicy.frameOverride = Stage.screen
        return try GalleryHost.surface(made: {
            let menu = InputMenu()
            menu.present([.init(title: "System default", device: nil),
                          .init(title: "MacBook Pro Microphone", device: "MacBook Pro Microphone"),
                          .init(title: "CalDigit Thunderbolt 3 Audio", device: "CalDigit")],
                         chosen: 0, beside: NSRect(x: 300, y: 300, width: 500, height: 260))
            menu.slabRows[1].choose(true)
            return [menu]
        })
    }

    static var shots: [GalleryShot] {
        [GalleryShot(surface: "foundation", state: "slab", looks: GalleryLook.all) { look in
            let (window, keep) = sheet(look: look)
            window.contentView?.layoutSubtreeIfNeeded()
            return (window.contentView!, keep)
        },
         GalleryShot(surface: "inputmenu", state: "pointer-chosen", looks: GalleryLook.all) { _ in try inputMenu() }]
    }
}
