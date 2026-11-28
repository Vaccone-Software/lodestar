import AppKit
import ApplicationServices
import Foundation
import LodestarCore
import Stoic
import StoicProcess
import Synchronization

/// Safari's profiles, through accessibility only — no Apple Events, so no
/// Automation prompt, and nothing of Safari's on disk, so no Files &
/// Folders switch. Measured on Safari 27.2 (2026-11-27 and -28 probes):
///
/// - The profiles are File ▸ New Window's items, identified
///   `New<Name>Window?isDefaultProfile=…`, readable only while Safari runs;
///   the last list read is kept in `safari-profiles.json` for when it
///   does not.
/// - A new tab in a profile's window: that window made main, File ▸ New
///   Tab pressed, and the new tab told apart by one more tab button and a
///   different address field (the field is a child of the tab in front).
///   An empty field proves nothing — a new window's Start Page is empty too.
/// - A new window of a profile: its New Window item pressed; it appears in
///   200–330 ms, typeable at once.
/// - Launched from not running with `open -g -a Safari`, it stays behind
///   and lists its profiles about two seconds later.
///
/// Every read and press runs on one serial queue, so two links clicked
/// together never press and type into each other's tabs.
final class SafariDriver: Sendable {
    static let shared = SafariDriver()

    private let queue = DispatchQueue(label: "com.vaccone.lodestar.safari-profiles", qos: .userInitiated)
    /// The profiles last read from Safari's menu; nil when Safari has never
    /// been seen running.
    private let known: Mutex<[SafariProfiles.MenuProfile]?>
    private let file = Paths.data.appendingPathComponent("safari-profiles.json")

    private init() {
        known = Mutex(Self.load(from: file))
    }

    private static func load(from file: URL) -> [SafariProfiles.MenuProfile]? {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            // Not written yet: Safari has not been seen running.
            return nil
        }
        do {
            return try JSONDecoder().decode([SafariProfiles.MenuProfile].self, from: data)
        } catch {
            Log.warning("safari: \(file.lastPathComponent) unreadable, read again when Safari runs",
                        ["error": "\(error)"])
            return nil
        }
    }

    func listing() -> ProfileListing {
        guard let menu = known.withLock({ $0 }) else { return .notSeen }
        return .profiles(menu.map { ListedProfile(name: $0.name, locator: $0.identifier) })
    }

    /// Keep a list read from Safari. An empty read is never kept: it is far
    /// likelier a menu not built yet than every profile deleted, and a
    /// Safari with no profiles is better told "not seen" than "no profile
    /// named" (an open still reads the live menu, so nothing is lost).
    @discardableResult
    private func remember(_ menu: [SafariProfiles.MenuProfile]) -> Bool {
        guard !menu.isEmpty else { return false }
        let changed = known.withLock { current -> Bool in
            guard current != menu else { return false }
            current = menu
            return true
        }
        if changed {
            do {
                DurableFile.save(try JSONEncoder().encode(menu), to: file, as: "safari profiles")
            } catch {
                Log.error("safari: could not encode its profiles", ["error": "\(error)"])
            }
        }
        return changed
    }

    /// Whether a refresh is already waiting on the queue, so a run of
    /// activations reads the menu once.
    private let refreshing = Mutex(false)

    /// Read the menu again, if Safari runs; `then` runs on main afterwards.
    /// A Safari just launched builds its menu's profiles about two seconds
    /// after it comes forward (measured), so an empty read is asked again
    /// until it lists them or six seconds pass.
    func refresh(then: @escaping () -> Void) {
        guard let pid = Self.runningPid(),
              refreshing.withLock({ busy in defer { busy = true }; return !busy }) else { return }
        queue.async { [self] in
            defer { refreshing.withLock { $0 = false } }
            let app = AXUIElementCreateApplication(pid)
            let deadline = Deadline.after(.seconds(6))
            repeat {
                let menu = SafariProfiles.menuProfiles(fromIdentifiers: Array(Self.menuItems(app).keys))
                if !menu.isEmpty {
                    remember(menu)
                    break
                }
                usleep(250_000)
            } while !deadline.hasPassed
            DispatchQueue.main.async(execute: then)
        }
    }

    /// Open the profile: a new tab in a window it has when there is a URL,
    /// else a new window. `completion` runs on main with whether the page
    /// was handed to Safari.
    func open(profile name: String, url: String?, completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            let opened = perform(profile: name, url: url)
            DispatchQueue.main.async { completion(opened) }
        }
    }

    private func perform(profile name: String, url: String?) -> Bool {
        if let url, !SafariProfiles.mayType(url) {
            Log.error("safari: a javascript: link is never typed into the address field")
            return false
        }
        guard let app = launched() else {
            Log.error("safari: did not list its profiles in time")
            return false
        }
        // One walk of the menu bar for everything this open presses.
        let items = Self.menuItems(app)
        let profiles = SafariProfiles.menuProfiles(fromIdentifiers: Array(items.keys))
        remember(profiles)
        let wanted = name.lowercased()
        guard let profile = profiles.first(where: { $0.name.lowercased() == wanted }) else {
            Log.error("safari: no profile named '\(name)'")
            return false
        }
        let names = profiles.map(\.name)
        let before = Self.windows(app)
        let own = before.filter {
            SafariProfiles.profile(ofTitle: Self.string($0, kAXTitleAttribute) ?? "", among: names)?
                .lowercased() == wanted
        }
        if let url, let window = own.first, let newTab = items[SafariProfiles.newTabMenuID],
           let opened = self.newTab(in: window, pressing: newTab, url: url) {
            return opened
        }
        guard let item = items[profile.identifier],
              AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
            Log.error("safari: could not press New \(profile.name) Window")
            return false
        }
        let deadline = Deadline.after(.seconds(3))
        while !deadline.hasPassed {
            let fresh = Self.windows(app).first { window in
                !before.contains { CFEqual($0, window) }
                    && SafariProfiles.profile(ofTitle: Self.string(window, kAXTitleAttribute) ?? "",
                                              among: names)?.lowercased() == wanted
            }
            if let fresh, let field = Self.addressField(fresh) {
                guard let url else { return true }
                return Self.type(url, into: field)
            }
            usleep(25_000)
        }
        Log.error("safari: no \(profile.name) window appeared")
        return false
    }

    /// A new tab in `window`, told apart from the tab that was in front by
    /// both signals measured together: one more tab button, and a different
    /// address field (it is a child of the tab in front). Nil, before
    /// anything is pressed, when the window shows neither — the caller then
    /// opens a new window of the profile, which never types over a page.
    private func newTab(in window: AXUIElement, pressing item: AXUIElement, url: String) -> Bool? {
        let tabsBefore = Self.tabCount(window)
        guard tabsBefore > 0, let fieldBefore = Self.addressField(window) else {
            Log.info("safari: the window shows no tabs, so a new window instead")
            return nil
        }
        // New Tab acts on the main window, which this makes the profile's
        // without bringing Safari forward.
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
            Log.error("safari: could not press New Tab")
            return false
        }
        let deadline = Deadline.after(.milliseconds(1500))
        while !deadline.hasPassed {
            if let field = Self.addressField(window), !CFEqual(fieldBefore, field),
               Self.tabCount(window) > tabsBefore {
                return Self.type(url, into: field)
            }
            usleep(20_000)
        }
        Log.error("safari: the new tab did not appear")
        return false
    }

    /// Safari's application element once it lists its profiles, launching
    /// it behind the app in front when it is not running.
    private func launched() -> AXUIElement? {
        if Self.runningPid() == nil {
            do {
                try SystemEvents.start(Programs.quiet("/usr/bin/open", ["-g", "-a", "Safari"]),
                                       timeout: .seconds(30), what: "safari: open")
            } catch {
                Log.error("safari: open failed: \(error)")
                return nil
            }
        }
        // Measured: a second after launch for the first window, two for the
        // menu's profiles.
        let deadline = Deadline.after(.seconds(6))
        while !deadline.hasPassed {
            if let pid = Self.runningPid() {
                let app = AXUIElementCreateApplication(pid)
                if !SafariProfiles.menuProfiles(fromIdentifiers: Array(Self.menuItems(app).keys)).isEmpty {
                    return app
                }
            }
            usleep(50_000)
        }
        return nil
    }

    // MARK: - Accessibility

    private static func runningPid() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Browser.safari.bundleID)
            .first { !$0.isTerminated }?.processIdentifier
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        AX.string(element, attribute)
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        AX.elements(element, kAXChildrenAttribute) ?? []
    }

    /// Every element under `element`, to `depth` levels, that `matches`.
    private static func find(_ element: AXUIElement, depth: Int,
                             _ matches: (AXUIElement) -> Bool) -> [AXUIElement] {
        var found = matches(element) ? [element] : []
        guard depth > 0 else { return found }
        for child in children(element) {
            found += find(child, depth: depth - 1, matches)
        }
        return found
    }

    /// The menu bar's items this driver presses, by identifier: every
    /// New‹Profile›Window and New Tab. One walk, five levels down (bar,
    /// bar item, menu, New Window, its submenu's items); empty when the
    /// menu bar cannot be read.
    private static func menuItems(_ app: AXUIElement) -> [String: AXUIElement] {
        guard let menuBar = AX.element(app, kAXMenuBarAttribute) else { return [:] }
        var items: [String: AXUIElement] = [:]
        for item in find(menuBar, depth: 5, { _ in true }) {
            guard let identifier = string(item, kAXIdentifierAttribute),
                  identifier == SafariProfiles.newTabMenuID
                    || identifier.contains("Window?isDefaultProfile=") else { continue }
            items[identifier] = items[identifier] ?? item
        }
        return items
    }

    private static func windows(_ app: AXUIElement) -> [AXUIElement] {
        AX.elements(app, kAXWindowsAttribute) ?? []
    }

    /// The window's toolbar, where the tabs and the address field live —
    /// searched alone, so a page's own tree is never walked.
    private static func toolbar(_ window: AXUIElement) -> AXUIElement? {
        children(window).first { string($0, kAXRoleAttribute) == kAXToolbarRole }
    }

    private static func tabs(_ window: AXUIElement) -> [AXUIElement] {
        guard let toolbar = toolbar(window) else { return [] }
        return find(toolbar, depth: 4) { string($0, kAXSubroleAttribute) == SafariProfiles.tabButtonSubrole }
    }

    private static func tabCount(_ window: AXUIElement) -> Int { tabs(window).count }

    /// The address field of the tab in front.
    private static func addressField(_ window: AXUIElement) -> AXUIElement? {
        let isField = { (element: AXUIElement) in
            string(element, kAXIdentifierAttribute) == SafariProfiles.addressFieldID
        }
        if let active = tabs(window).first(where: {
            SafariProfiles.isActiveTab(identifier: string($0, kAXIdentifierAttribute))
        }), let field = children(active).first(where: isField) {
            return field
        }
        guard let toolbar = toolbar(window) else { return nil }
        return find(toolbar, depth: 6, isField).first
    }

    private static func type(_ url: String, into field: AXUIElement) -> Bool {
        guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, url as CFString) == .success,
              AXUIElementPerformAction(field, "AXConfirm" as CFString) == .success else {
            Log.error("safari: the address field would not take the page")
            return false
        }
        return true
    }
}
