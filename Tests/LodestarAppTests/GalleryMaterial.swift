import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// design/04-material.md as a picture, made of the real views: a pane with
/// its rim, edge and shadow over a light and a dark desktop; the three roles
/// side by side (stands up, sinks, flat); and a key at rest.
enum GalleryMaterial {
    static let size = NSSize(width: 1040, height: 896)
    /// The two desktops a pane is seen over.
    static let light = NSColor(srgbRed: 0.84, green: 0.83, blue: 0.81, alpha: 1)
    static let dark = NSColor(srgbRed: 0.14, green: 0.14, blue: 0.15, alpha: 1)

    private static func backdrop(_ color: NSColor, frame: NSRect) -> NSView {
        let view = NSView(frame: frame)
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
        return view
    }

    private static func caption(_ text: String, color: NSColor = BarTheme.secondaryColor,
                                role: BarTheme.Role = .meta) -> NSTextField {
        let label = BarTheme.label(text, role: role, color: color)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    /// A pane hosted as a panel hosts it: its shadow cast in the margin
    /// round it, the pane `SoftShadow.margin` inside `frame`.
    private static func hosted(_ content: NSView, in frame: NSRect) -> ShadowHostView {
        Ceramic.installPane(in: content, cornerRadius: BarTheme.surfaceRadius)
        let host = ShadowHostView(content: content, cornerRadius: BarTheme.surfaceRadius)
        host.frame = frame
        return host
    }

    private static func column(_ views: [NSView], spacing: CGFloat = Grid.close) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private static func row(_ views: [NSView], spacing: CGFloat = Grid.close) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    static func sheet(look: GalleryLook) -> (NSWindow, [AnyObject]) {
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        let margin = SoftShadow.margin
        let half = size.width / 2

        // One: the pane over a light desktop and a dark one.
        let top = size.height - 330
        for (index, desk) in [light, dark].enumerated() {
            let frame = NSRect(x: CGFloat(index) * half, y: top, width: half, height: 330)
            let ground = backdrop(desk, frame: frame)
            root.addSubview(ground)
            let content = NSView(frame: .zero)
            let words = caption(index == 0 ? "A pane over a light desktop" : "A pane over a dark desktop",
                                color: BarTheme.ink, role: .roomTitle)
            let detail = caption("One opaque step, a rim along its top, a hairline round it, and one soft shadow.")
            detail.maximumNumberOfLines = 2
            detail.preferredMaxLayoutWidth = half - margin * 2 - Grid.section * 2
            detail.lineBreakMode = .byWordWrapping
            let stack = column([words, detail], spacing: Grid.tight)
            content.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Grid.section),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Grid.section),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: Grid.section),
            ])
            let host = hosted(content, in: NSRect(origin: .zero, size: frame.size))
            ground.addSubview(host)
        }

        // Two: the three roles on one pane, over the look's ground.
        let rolesFrame = NSRect(x: 0, y: size.height - 330 - 328, width: size.width, height: 328)
        let ground = NSView(frame: rolesFrame)
        ground.wantsLayer = true
        ground.layer?.backgroundColor = Ceramic.resolved(BarTheme.dynamic { $0.ground.color }, in: root)
        root.addSubview(ground)

        let roles = NSView(frame: .zero)
        // Stands up: what you press.
        let rest = Key("esc")
        let lit = Key("⏎")
        lit.lit = true
        let open = RoomButton(title: "Open", target: nil, action: nil)
        let chosen = ListRow(height: BarTheme.rowHeight, titleRole: .body)
        chosen.title.stringValue = "The chosen row"
        chosen.choose(true)
        chosen.widthAnchor.constraint(equalToConstant: 250).isActive = true
        let stands = column([caption("Stands up: a face on a side"), row([rest, lit, open]), chosen], spacing: Grid.part)

        // Sinks: where you put something.
        let field = WellField(frame: .zero)
        field.setRole(.body)
        field.textColor = BarTheme.ink
        field.setPlaceholder("Where to?")
        field.widthAnchor.constraint(equalToConstant: 250).isActive = true
        let note = WellView(cornerRadius: BarTheme.controlRadius)
        note.widthAnchor.constraint(equalToConstant: 250).isActive = true
        note.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let sinks = column([caption("Sinks: a well, an edge, nothing more"), field, note], spacing: Grid.part)

        // Flat: everything else.
        let quiet = Key("tab")
        quiet.quiet = true
        let chip = FlatChip()
        let chipWord = caption("chip", role: .key)
        chip.addSubview(chipWord)
        chip.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            chipWord.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: Grid.half),
            chipWord.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -Grid.half),
            chipWord.topAnchor.constraint(equalTo: chip.topAnchor, constant: Grid.hair),
            chipWord.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -Grid.hair),
        ])
        let group = ToneView(fill: BarTheme.paneFill, edge: BarTheme.hairline, edgeWidth: Ceramic.Edge.line,
                             radius: BarTheme.surfaceRadius)
        group.translatesAutoresizingMaskIntoConstraints = false
        let groupWord = caption("A group, with a hairline", role: .body)
        group.addSubview(groupWord)
        NSLayoutConstraint.activate([
            group.widthAnchor.constraint(equalToConstant: 250),
            group.heightAnchor.constraint(equalToConstant: BarTheme.rowHeight + Grid.part),
            groupWord.leadingAnchor.constraint(equalTo: group.leadingAnchor, constant: Grid.part),
            groupWord.centerYAnchor.constraint(equalTo: group.centerYAnchor),
        ])
        let flat = column([caption("Flat: its own fill, at most a hairline"), row([quiet, chip]), group], spacing: Grid.part)

        let columns = row([stands, sinks, flat], spacing: Grid.column)
        columns.alignment = .top
        roles.addSubview(columns)
        NSLayoutConstraint.activate([
            columns.leadingAnchor.constraint(equalTo: roles.leadingAnchor, constant: Grid.margin),
            columns.topAnchor.constraint(equalTo: roles.topAnchor, constant: Grid.section),
        ])
        ground.addSubview(hosted(roles, in: NSRect(origin: .zero, size: rolesFrame.size)))

        // Three: a key, resting and lit.
        let keysFrame = NSRect(x: 0, y: 0, width: size.width, height: size.height - 330 - 328)
        let keysGround = NSView(frame: keysFrame)
        keysGround.wantsLayer = true
        keysGround.layer?.backgroundColor = Ceramic.resolved(BarTheme.dynamic { $0.ground.color }, in: root)
        root.addSubview(keysGround)
        let keys = NSView(frame: .zero)
        func pair(_ legend: String, lit: Bool = false) -> NSView {
            let resting = Key(legend)
            resting.lit = lit
            return column([row([resting], spacing: Grid.part)], spacing: Grid.tight)
        }
        let largeRow = row([Key("7", size: .large)], spacing: Grid.part)
        let legend = row([
            caption("a key at rest: a 3-point side, a 5-point side when large"),
        ])
        let keyColumns = row([pair("a"), pair("⏎", lit: true), pair("space"), largeRow], spacing: Grid.margin)
        let all = column([legend, keyColumns], spacing: Grid.part)
        keys.addSubview(all)
        NSLayoutConstraint.activate([
            all.leadingAnchor.constraint(equalTo: keys.leadingAnchor, constant: Grid.margin),
            all.topAnchor.constraint(equalTo: keys.topAnchor, constant: Grid.section),
        ])
        keysGround.addSubview(hosted(keys, in: NSRect(origin: .zero, size: keysFrame.size)))

        let window = GalleryHost.window(root, size: size, look: look)
        root.layoutSubtreeIfNeeded()
        return (window, [window])
    }

    static var shots: [GalleryShot] {
        [GalleryShot(surface: "foundation", state: "material", looks: GalleryLook.all) { look in
            let (window, keep) = sheet(look: look)
            return (window.contentView!, keep)
        }]
    }
}
