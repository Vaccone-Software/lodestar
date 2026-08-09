import ApplicationServices
import Foundation

/// Menu-bar harvesting for menu search: every enabled, actionable item of an
/// app's menus, with its path and native shortcut. Bounded walk — depth and
/// visit caps keep giant menu trees quick.
public enum MenuItems {
    public struct Item {
        public let element: AXUIElement
        public let path: [String]
        public let shortcut: String?
    }

    public static func items(forAppWithPID pid: pid_t, limit: Int = 400) -> [Item] {
        let app = AXUIElementCreateApplication(pid)
        guard let menuBar = AX.element(app, kAXMenuBarAttribute) else { return [] }
        guard let topLevel = AX.elements(menuBar, kAXChildrenAttribute) else { return [] }

        var collected: [Item] = []
        var visited = 0

        for barItem in topLevel {
            guard let title = AX.string(barItem, kAXTitleAttribute), !title.isEmpty,
                  title != "Apple" else { continue }
            guard let menus = AX.elements(barItem, kAXChildrenAttribute) else { continue }
            for menu in menus {
                walk(menu, path: [title], into: &collected, visited: &visited, limit: limit)
            }
            if collected.count >= limit { break }
        }
        return collected
    }

    @discardableResult
    public static func press(_ item: Item) -> Bool {
        AXUIElementPerformAction(item.element, kAXPressAction as CFString) == .success
    }

    // MARK: - Internals

    private static func walk(_ menu: AXUIElement, path: [String],
                             into collected: inout [Item], visited: inout Int, limit: Int) {
        guard collected.count < limit, visited < 1500, path.count <= 5 else { return }
        guard let children = AX.elements(menu, kAXChildrenAttribute) else { return }

        for child in children {
            visited += 1
            guard collected.count < limit, visited < 1500 else { return }
            guard let title = AX.string(child, kAXTitleAttribute), !title.isEmpty else { continue }
            guard AX.bool(child, kAXEnabledAttribute) ?? true else { continue }

            if let submenus = AX.elements(child, kAXChildrenAttribute), !submenus.isEmpty {
                for submenu in submenus {
                    walk(submenu, path: path + [title], into: &collected, visited: &visited, limit: limit)
                }
            } else {
                collected.append(Item(
                    element: child,
                    path: path + [title],
                    shortcut: shortcut(of: child)
                ))
            }
        }
    }

    private static func shortcut(of item: AXUIElement) -> String? {
        guard let char = AX.string(item, kAXMenuItemCmdCharAttribute), !char.isEmpty else {
            return nil
        }
        // Carbon menu modifier mask: 0 = ⌘ alone; +1 ⇧, +2 ⌥, +4 ⌃, +8 = no ⌘.
        let mask = AX.int(item, kAXMenuItemCmdModifiersAttribute) ?? 0
        var parts = ""
        if mask & 4 != 0 { parts += "⌃" }
        if mask & 2 != 0 { parts += "⌥" }
        if mask & 1 != 0 { parts += "⇧" }
        if mask & 8 == 0 { parts += "⌘" }
        return parts + char.uppercased()
    }
}
