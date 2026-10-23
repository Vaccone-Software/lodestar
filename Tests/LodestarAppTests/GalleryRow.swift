import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// design/13-row.md as pictures, made of the real views: the four rows (a
/// row, a setting, a line, a legend) at rest, chosen, unable to act, with a
/// long name and a long sentence, and quiet keys beside resting and lit ones;
/// then the surfaces that gained a state with it: a Settings page with rows
/// that wait, the ⌘K card, the cheat sheet.
enum GalleryRow {
    private static func icon(_ path: String) -> NSImage? {
        FileManager.default.fileExists(atPath: path) ? NSWorkspace.shared.icon(forFile: path) : nil
    }

    /// The longest names the sheet and the tests use: an app, a title, a file.
    static let longName = "The quarterly planning review for the whole engineering organisation, third quarter"
    static let longSentence = "Lodestar adjusts its own surfaces through the day to be easier on your eyes: dimmer and softer after sunset, dimmer still late at night, and quieter when you are not using them. What you copy and view is never changed"

    // MARK: - The four rows

    /// A row of a bar: an icon, a name, its keys at the end, ⏎ lit when chosen.
    static func row(_ title: String, detail: String = "", keys: [String], chosen: Bool = false, unable: Bool = false,
                    app: String = "/System/Applications/Notes.app", width: CGFloat = 640) -> ListRow {
        let row = ListRow(height: detail.isEmpty ? BarTheme.rowHeight : BarTheme.detailRowHeight)
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        row.setLead(RowIcon.view(icon(app)))
        row.title.stringValue = title
        row.detailText = detail
        var trailing: [NSView] = []
        if !keys.isEmpty { trailing.append(KeyStrokes(keys, quiet: unable)) }
        if chosen {
            let enter = Key("⏎")
            enter.lit = true
            trailing.append(enter)
        }
        row.setTrailing(trailing)
        // A row that cannot act: its words and its keys quiet, nothing faded.
        if unable {
            row.title.textColor = BarTheme.secondaryColor
            row.detail.textColor = BarTheme.secondaryColor
        }
        row.choose(chosen)
        return row
    }

    /// A menu of lines the way a Settings popup draws it.
    static func menu(width: CGFloat, items: [(title: String, current: Bool, enabled: Bool)], chosen: Int?,
                     made: inout [AnyObject]) -> NSView {
        let popup = NSPopUpButton()
        popup.autoenablesItems = false
        for item in items {
            popup.addItem(withTitle: item.title)
            popup.lastItem?.isEnabled = item.enabled
        }
        made.append(popup)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: BarTheme.lineInset, left: 0, bottom: BarTheme.lineInset, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (index, item) in popup.itemArray.enumerated() {
            let line = ChoiceMenuItemView(item: item, current: items[index].current, width: width, popup: popup)
            line.highlighted = index == chosen
            line.translatesAutoresizingMaskIntoConstraints = false
            line.widthAnchor.constraint(equalToConstant: width).isActive = true
            line.heightAnchor.constraint(equalToConstant: ChoiceMenuItemView.height).isActive = true
            stack.addArrangedSubview(line)
            made.append(line)
        }
        return stack
    }

    // MARK: - The sheet

    static let width: CGFloat = 760

    /// The sheet is as tall as its sections: drawn once to measure, again at that height.
    static func sheet(look: GalleryLook) -> (NSWindow, [AnyObject]) {
        let (probe, _) = sheet(look: look, height: 3000)
        probe.contentView?.layoutSubtreeIfNeeded()
        let column = probe.contentView?.subviews.compactMap { $0 as? NSStackView }.first
        let height = ceil((column?.fittingSize.height ?? 1400) + Grid.section * 2)
        probe.close()
        return sheet(look: look, height: height)
    }

    private static func sheet(look: GalleryLook, height: CGFloat) -> (NSWindow, [AnyObject]) {
        var made: [AnyObject] = []
        let settings = GallerySettings.controller()
        made.append(settings)
        let window = GalleryHost.pane(size: NSSize(width: width, height: height), look: look) { root in
            let column = NSStackView()
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = Grid.group
            column.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(column)
            NSLayoutConstraint.activate([
                column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Grid.section),
                column.topAnchor.constraint(equalTo: root.topAnchor, constant: Grid.section),
            ])
            func caption(_ text: String) {
                let label = NSTextField(wrappingLabelWithString: text)
                label.setRole(.meta)
                label.textColor = BarTheme.secondaryColor
                label.preferredMaxLayoutWidth = width - Grid.section * 2
                label.translatesAutoresizingMaskIntoConstraints = false
                label.widthAnchor.constraint(equalToConstant: width - Grid.section * 2).isActive = true
                column.addArrangedSubview(label)
                column.setCustomSpacing(Grid.close, after: label)
            }

            // A row: 48, or 52 with a line beneath, 2 apart.
            caption("row · 48, or 52 with a line beneath, 2 apart: at rest, chosen, unable to act, a long name, a long detail")
            let rows = NSStackView()
            rows.orientation = .vertical
            rows.alignment = .leading
            rows.spacing = BarTheme.rowGap
            let items: [ListRow] = [
                row("Notes", keys: ["n"]),
                row("Mail", keys: ["e", "p"], chosen: true, app: "/System/Applications/Mail.app"),
                row("Terminal", detail: "Needs accessibility", keys: ["t"], unable: true,
                    app: "/System/Applications/Utilities/Terminal.app"),
                row(longName, keys: ["lode", "'", "w"]),
                row("Paste Style", detail: Row.path(["Format", "Font", longName]), keys: ["⌥⌘V"]),
            ]
            for item in items { rows.addArrangedSubview(item); made.append(item) }
            column.addArrangedSubview(rows)

            // A setting: at least 48, growing with its detail.
            caption("setting · at least 48, growing with its detail: a letter key in a column as wide as the widest, a switch on and unavailable, a long sentence wrapping")
            let card = SettingsController.card()
            let list = NSStackView()
            list.orientation = .vertical
            list.alignment = .leading
            list.spacing = 0
            list.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(list)
            let rowsWidth: CGFloat = 640
            NSLayoutConstraint.activate([
                list.topAnchor.constraint(equalTo: card.topAnchor, constant: BarTheme.paneInset),
                list.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -BarTheme.paneInset),
                list.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: BarTheme.paneInset),
                list.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -BarTheme.paneInset),
                card.widthAnchor.constraint(equalToConstant: rowsWidth + BarTheme.paneInset * 2),
            ])
            var model: [SettingsModel.Row] = [
                SettingsModel.Row(title: "Start at login", path: "app.login", control: .toggle(true), isDefault: true),
                SettingsModel.Row(title: "Exact keyboard", path: "health.exact-keyboards", control: .toggle(true),
                                  detail: "Needs health", isDefault: false, dimmed: true),
                SettingsModel.Row(title: "Limit", path: "observations.health-mb",
                                  control: .number(1024, min: 64, max: 16_384, unit: "MB"),
                                  detail: "Needs health", dimmed: true),
                SettingsModel.Row(title: "Settings", path: "gestures.settings", control: .toggle(true),
                                  detail: longSentence, keycaps: ["lode", ","]),
            ]
            for index in model.indices { model[index].letter = String(UnicodeScalar(UInt8(97 + index))) }
            let letterWidth = model.compactMap(\.letter).map { Key.width(of: $0) }.max() ?? 0
            for (index, row) in model.enumerated() {
                if index > 0 { list.addArrangedSubview(SettingsController.hairline(width: rowsWidth)) }
                let line = settings.settingRowForTesting(row, index: index, width: rowsWidth, letterWidth: letterWidth)
                list.addArrangedSubview(line)
            }
            column.addArrangedSubview(card)

            // A line: 32, touching, 8 inside its menu.
            caption("line · 32, touching, 8 inside its menu: the current choice's dot, the chosen line the slab, a choice that cannot be taken, a long name")
            let lines = GalleryRow.menu(width: 320, items: [
                ("Apple speech", true, true), ("Parakeet", false, true), ("Qwen3 ASR", false, false),
                (longName, false, true), ("Off", false, true),
            ], chosen: 1, made: &made)
            let menuPane = SettingsController.card()
            menuPane.addSubview(lines)
            NSLayoutConstraint.activate([
                lines.topAnchor.constraint(equalTo: menuPane.topAnchor),
                lines.bottomAnchor.constraint(equalTo: menuPane.bottomAnchor),
                lines.leadingAnchor.constraint(equalTo: menuPane.leadingAnchor),
                lines.trailingAnchor.constraint(equalTo: menuPane.trailingAnchor),
            ])
            column.addArrangedSubview(menuPane)

            // A legend: its keys first, then what they do, 8 apart.
            caption("legend · 24, 8 apart: keys, then the words on the key's line; a footer's meta words on the legend's baseline")
            let legends = CheatSheet.columns([CheatSheet.Section(header: "Draft", rows: [
                GuideRow(key: "j k", label: "Down · up"), GuideRow(key: "d u", label: "Half-page down · up"),
                GuideRow(key: "/", label: "Aim at a word"), GuideRow(key: "⌘K", label: "More for this row", dimmed: true),
            ])])
            column.addArrangedSubview(legends)
            made.append(legends)
            let footer = Keycaps.line([.init(["esc"], "Back"), .init(["⏎"], "Choose", lit: true),
                                       .init(["lode", "⌫"], "Not now")])
            column.addArrangedSubview(footer)

            // Quiet keys: a resting key left unfilled, beside resting and lit keys.
            caption("keys · resting, quiet (a resting key left unfilled), lit; and the large key quiet")
            let keys = NSStackView()
            keys.orientation = .horizontal
            keys.alignment = .centerY
            keys.spacing = Grid.close
            let resting = KeyStrokes(["lode", "'", "w"])
            let quiet = KeyStrokes(["lode", "'", "w"], quiet: true)
            let lit = KeyStrokes(["lode"], double: true, lit: true)
            let mixed = NSStackView(views: [Key("lode", state: .quiet), Key("a"), Key("b", state: .quiet), Key("c", state: .lit)])
            mixed.orientation = .horizontal
            mixed.alignment = .centerY
            mixed.spacing = Grid.tight
            for view in [resting, quiet, lit, mixed] { keys.addArrangedSubview(view) }
            keys.addArrangedSubview(Key("7", size: .large, state: .quiet))
            keys.addArrangedSubview(Key("7", size: .large))
            column.addArrangedSubview(keys)
            made += [resting, quiet, lit, mixed]
        }
        return (window, [window] + made)
    }

    // MARK: - The surfaces

    /// Settings with the places that wait on another drawn quiet: the logbook and
    /// health off, "Exact keyboard" on and unavailable.
    static func waiting() throws -> (NSView, [AnyObject]) {
        ActivePolicy.frameOverride = Stage.screen
        return try GalleryHost.surface(made: {
            let settings = GallerySettings.controller()
            var config = settings.config
            config.logbookEnabled = false
            config.observationsHealth = false
            config.healthExactKeyboards = true
            settings.config = config
            settings.renderForTesting(place: SettingsModel.placeIndex("Observations"))
            return [settings]
        }, settle: 0.05, where: { $0 is KeyablePanel }, frame: NSRect(x: 0, y: 0, width: 1000, height: 680))
    }

    /// The ⌘K card beside a row: actions with a chain and a long name.
    static func optionsCard(_ which: Int) throws -> (NSView, [AnyObject]) {
        ActivePolicy.frameOverride = Stage.screen
        return try GalleryHost.surface(made: {
            OptionsCard.preview(which) as [AnyObject]
        })
    }

    /// The cheat sheet, as `lode ?` opens it.
    static func cheatSheet() throws -> (NSView, [AnyObject]) {
        ActivePolicy.frameOverride = Stage.screen
        return try GalleryHost.surface(made: {
            let sheet = CheatSheet()
            sheet.toggle {
                [CheatSheet.Section(header: "Windows", rows: [
                    GuideRow(key: "lode", label: "Summon a chain"), GuideRow(keys: ["lode"], double: true, label: "Jump back"),
                    GuideRow(key: "z o", label: "Fold the window"), GuideRow(key: "⌘K", label: "Options for the row"),
                ]),
                 CheatSheet.Section(header: "Write", rows: [
                    GuideRow(key: "esc", label: "Leave"), GuideRow(key: "h j k l", label: "Move"),
                    GuideRow(key: "d u", label: "Half-page down · up", dimmed: true),
                    GuideRow(key: "/", label: "Aim at a word"),
                ])]
            }
            return [sheet]
        })
    }

    static var shots: [GalleryShot] {
        func shot(_ surface: String, _ state: String, _ make: @escaping (GalleryLook) throws -> (NSView, [AnyObject])) -> GalleryShot {
            GalleryShot(surface: surface, state: state, looks: GalleryLook.all, build: make)
        }
        return [
            shot("foundation", "row") { look in
                let (window, keep) = sheet(look: look)
                window.contentView?.layoutSubtreeIfNeeded()
                return (window.contentView!, keep)
            },
            shot("settings", "observations-waiting") { _ in try waiting() },
            shot("optionscard", "remove-two-chains") { _ in try optionsCard(0) },
            shot("optionscard", "profile-cascade") { _ in try optionsCard(5) },
            shot("cheatsheet", "two-sections") { _ in try cheatSheet() },
        ]
    }
}
