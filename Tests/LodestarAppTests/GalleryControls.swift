import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The controls that are keys and switches, each in every state, on a pane.
enum GalleryControls {
    private static func column(in root: NSView, inset: CGFloat = 24) -> NSStackView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 16
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            column.topAnchor.constraint(equalTo: root.topAnchor, constant: inset - 2),
        ])
        return column
    }

    /// A caption over a row of things, each over its own caption.
    private static func labelled(_ title: String, _ items: [(String, NSView)]) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 22
        for (name, view) in items {
            let cell = NSStackView(views: [view, GalleryKeys.caption(name)])
            cell.orientation = .vertical
            cell.alignment = .centerX
            cell.spacing = 8
            row.addArrangedSubview(cell)
        }
        let block = NSStackView(views: [GalleryKeys.caption(title), row])
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 8
        return block
    }

    static func switches(look: GalleryLook) -> (NSWindow, [AnyObject]) {
        var made: [AnyObject] = []
        let window = GalleryHost.pane(size: NSSize(width: 400, height: 130), look: look) { root in
            let column = column(in: root)
            func make(_ on: Bool, enabled: Bool = true) -> AccentSwitch {
                let toggle = AccentSwitch(frame: .zero)
                toggle.state = on ? .on : .off
                toggle.isEnabled = enabled
                made.append(toggle)
                return toggle
            }
            column.addArrangedSubview(labelled("switches", [("off", make(false)), ("on", make(true)),
                                                            ("disabled off", make(false, enabled: false)),
                                                            ("disabled on", make(true, enabled: false))]))
        }
        return (window, [window] + made)
    }

    static func buttons(look: GalleryLook) -> (NSWindow, [AnyObject]) {
        var made: [AnyObject] = []
        let window = GalleryHost.pane(size: NSSize(width: 640, height: 130), look: look) { root in
            let column = column(in: root)
            func button(_ title: String, primary: Bool = false, enabled: Bool = true,
                        answer: Bool = false) -> RoomButton {
                let button = RoomButton(frame: .zero)
                button.title = title
                button.primary = primary
                button.answer = answer
                button.isEnabled = enabled
                made.append(button)
                return button
            }
            column.addArrangedSubview(labelled("room buttons", [
                ("primary", button("Send", primary: true)), ("normal", button("Cancel")),
                ("disabled", button("Continue", enabled: false)), ("answer", button("receive", answer: true)),
            ]))
        }
        return (window, [window] + made)
    }

    /// A choice menu open: the rows are the Settings popup's own, the
    /// current one carrying a dot and the one the pointer is on the slab.
    static func openMenu(look: GalleryLook) -> (NSWindow, [AnyObject]) {
        var made: [AnyObject] = []
        let window = GalleryHost.pane(size: NSSize(width: 300, height: 190), look: look) { root in
            let popup = NSPopUpButton()
            popup.addItems(withTitles: ["Apple speech", "Parakeet", "Qwen3 ASR", "Off"])
            popup.selectItem(at: 1)
            made.append(popup)
            let menu = NSStackView()
            menu.orientation = .vertical
            menu.alignment = .leading
            menu.spacing = 0
            menu.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(menu)
            for (index, item) in popup.itemArray.enumerated() {
                let row = ChoiceMenuItemView(item: item, current: index == 1, width: 244, popup: popup)
                // The pointer is on the third row, which is the slab.
                row.highlighted = index == 2
                // A menu item's view has a frame, not constraints: the stack is told its size.
                row.translatesAutoresizingMaskIntoConstraints = false
                row.widthAnchor.constraint(equalToConstant: 244).isActive = true
                row.heightAnchor.constraint(equalToConstant: ChoiceMenuItemView.height).isActive = true
                menu.addArrangedSubview(row)
                made.append(row)
            }
            NSLayoutConstraint.activate([
                menu.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
                menu.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            ])
        }
        return (window, [window] + made)
    }

    /// The lens's and the clicks' marks, and the keys of a guide.
    static func hints(look: GalleryLook) -> (NSWindow, [AnyObject]) {
        var made: [AnyObject] = []
        let window = GalleryHost.pane(size: NSSize(width: 640, height: 250), look: look) { root in
            let column = column(in: root)
            // A mark is built by hand, without layout: it stands in a holder
            // of its own size, with room for its shadow, so a stack can place it.
            func shown(_ view: NSView) -> NSView {
                made.append(view)
                let holder = NSView(frame: .zero)
                holder.translatesAutoresizingMaskIntoConstraints = false
                holder.addSubview(view)
                NSLayoutConstraint.activate([
                    holder.widthAnchor.constraint(equalToConstant: view.frame.width),
                    holder.heightAnchor.constraint(equalToConstant: view.frame.height),
                ])
                view.frame.origin = .zero
                return holder
            }
            column.addArrangedSubview(labelled("hint marks", [
                ("one", shown(KeyMark.key("a"))), ("two", shown(KeyMark.key("jk"))),
                ("typed j", shown(KeyMark.key("jk", typed: "j"))), ("g", shown(KeyMark.key("g"))),
                ("digit", shown(KeyMark.key("7"))), ("peek", shown(KeyMark.peek("3"))),
            ]))
            column.addArrangedSubview(labelled("the lens's tag", [
                ("fix", shown(KeyMark.tag(letter: "a", word: "receive"))),
                ("typed", shown(KeyMark.tag(letter: "ab", word: "separate", typed: "a"))),
            ]))
        }
        return (window, [window] + made)
    }

    static var shots: [GalleryShot] {
        func shot(_ surface: String, _ state: String,
                  _ make: @escaping (GalleryLook) -> (NSWindow, [AnyObject])) -> GalleryShot {
            GalleryShot(surface: surface, state: state, looks: GalleryLook.all) { look in
                let (window, keep) = make(look)
                return (window.contentView!, keep)
            }
        }
        return [
            shot("switches", "states", switches), shot("roombuttons", "states", buttons),
            shot("choice", "menu-open", openMenu), shot("hints", "marks-and-tags", hints),
        ]
    }
}
