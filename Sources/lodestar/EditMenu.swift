import AppKit

/// The Edit menu an accessory app has to install for itself.
///
/// AppKit routes ⌘X, ⌘C, ⌘V, ⌘A, ⌘Z through the main menu's key
/// equivalents, and a menu-bar app with no main menu has none — so the
/// launcher, the commands bar, and Ask, all real text fields in key
/// panels, took every keystroke except a paste. The menu is never shown;
/// it exists so the field editor under a key panel hears the chords every
/// text field on the Mac answers, and sends them to the first responder
/// the way the system does. Nothing else lives on it — no Quit, no
/// Window — because a key equivalent it carries is a key equivalent an
/// app of ours can fire by accident.
enum EditMenu {
    static func make() -> NSMenu {
        let main = NSMenu(title: "Main")
        // The first item is the application menu by convention; AppKit
        // wants one there before it reads the rest.
        let application = NSMenuItem(title: "Lodestar", action: nil, keyEquivalent: "")
        application.submenu = NSMenu(title: "Lodestar")
        main.addItem(application)

        let edit = NSMenu(title: "Edit")
        func add(_ title: String, _ action: Selector, _ key: String,
                 _ modifiers: NSEvent.ModifierFlags = [.command]) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            edit.addItem(item)
        }
        add("Undo", Selector(("undo:")), "z")
        add("Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add("Cut", #selector(NSText.cut(_:)), "x")
        add("Copy", #selector(NSText.copy(_:)), "c")
        add("Paste", #selector(NSText.paste(_:)), "v")
        add("Select All", #selector(NSText.selectAll(_:)), "a")

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }

    /// The paste item, for a test to read.
    static func item(_ menu: NSMenu, keyEquivalent: String) -> NSMenuItem? {
        for item in menu.items {
            if item.keyEquivalent == keyEquivalent, item.action != nil { return item }
            if let sub = item.submenu, let found = self.item(sub, keyEquivalent: keyEquivalent) {
                return found
            }
        }
        return nil
    }

    static func install() {
        NSApp.mainMenu = make()
    }
}
