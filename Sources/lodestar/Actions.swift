import AppKit
import CoreGraphics
import LodestarCore

/// Every verb in the system. One instance, main-thread only.
final class Actions {
    private let model: WindowModel
    private let parking: ParkingLot
    private let layout: LayoutController
    private let appIndex: AppIndex
    private let store: StateStore
    private let hud: HUD

    private var intents = IntentQueue()
    private let history = FocusHistory()

    init(model: WindowModel, parking: ParkingLot, layout: LayoutController,
         appIndex: AppIndex, store: StateStore, hud: HUD) {
        self.model = model
        self.parking = parking
        self.layout = layout
        self.appIndex = appIndex
        self.store = store
        self.hud = hud
    }

    func attach() {
        model.onFocus = { [weak self] id in self?.history.recordFocus(id) }
        model.onCreated = { [weak self] id in self?.windowAppeared(id) }
        model.onTitleChanged = { [weak self] id in self?.windowAppeared(id) }
        model.onDestroyed = { [weak self] id in
            guard let self else { return }
            self.layout.remove(id)
            self.parking.forget(id)
            self.store.setParked(self.parking.snapshot())
        }
        layout.onChange = { [weak self] in
            guard let self else { return }
            self.store.setParked(self.parking.snapshot())
        }
        parking.adopt(store.parkedSpots)
    }

    // MARK: - Summoning

    func summon(_ target: GraphTarget, beside: Bool) {
        switch target {
        case .app(let name):
            summonApp(named: name, beside: beside)
        case .browserProfile(_, let profile):
            summonBrowser(profile, beside: beside)
        }
    }

    /// The web bar's verb: open a URL in a profile, then go there.
    func openWeb(url: String, profile: BrowserProfile, beside: Bool) {
        Log.info("open-web", ["url": url, "browser": profile.browser.rawValue,
                              "profile": profile.display, "beside": beside])
        guard ChromiumProfiles.openURL(url, in: profile) else {
            hud.flash("✕ profile '\(profile.display)' not found in \(profile.browser.label)")
            return
        }
        if let window = ChromiumProfiles.window(for: profile, in: model) {
            place(window, beside: beside)
            return
        }
        hud.flash("… opening \(profile.browser.label) · \(profile.display)",
                  icon: icon(forAppNamed: profile.browser.appName))
        expect(seconds: 12, matches: { window in
            window.bundleID == profile.browser.bundleID
                && profile.browser.windowMatches(title: window.title, profile: profile.display)
        }, action: { [weak self] window in
            self?.place(window, beside: beside)
        })
    }

    /// "Going to lodestar" reveals the (possibly hidden) menu bar.
    var revealLodestar: (() -> Void)?

    // Successful navigation is silent — the screen changing IS the
    // feedback. Flashes are reserved for what you cannot see: pending
    // launches, invisible state changes (binds, deletes), and failures.
    func pick(_ entry: AppIndex.Entry, beside: Bool) {
        if entry.bundleID == Bundle.main.bundleIdentifier
            || entry.name.lowercased() == "lodestar" {
            revealLodestar?()
            return
        }
        if let window = bestAliveWindow(bundleID: entry.bundleID, appName: entry.name) {
            place(window, beside: beside)
            return
        }
        launch(entry, beside: beside)
    }

    private func summonApp(named name: String, beside: Bool) {
        let entry = appIndex.entry(named: name)
        Log.info("summon", [
            "target": name, "resolved": entry?.name ?? "none",
            "candidates": aliveCandidates(bundleID: entry?.bundleID, appName: entry?.name ?? name).map(\.id),
        ])
        // Lodestar has no window to summon — going there reveals the menu bar.
        if name.lowercased() == "lodestar" || entry?.bundleID == Bundle.main.bundleIdentifier {
            revealLodestar?()
            return
        }
        if let window = bestAliveWindow(bundleID: entry?.bundleID, appName: entry?.name ?? name) {
            place(window, beside: beside)
            return
        }
        guard let entry else {
            hud.flash("✕ no app matches '\(name)'")
            return
        }
        launch(entry, beside: beside)
    }

    private func summonBrowser(_ profile: BrowserProfile, beside: Bool) {
        if let window = ChromiumProfiles.window(for: profile, in: model) {
            place(window, beside: beside)
            return
        }
        hud.flash("… opening \(profile.browser.label) · \(profile.display)",
                  icon: icon(forAppNamed: profile.browser.appName))
        expect(seconds: 12, matches: { window in
            window.bundleID == profile.browser.bundleID
                && profile.browser.windowMatches(title: window.title, profile: profile.display)
        }, action: { [weak self] window in
            self?.place(window, beside: beside)
        })
        if !ChromiumProfiles.openWindow(profile) {
            hud.flash("✕ \(profile.browser.label) profile '\(profile.display)' not found")
        }
    }

    private func launch(_ entry: AppIndex.Entry, beside: Bool) {
        let appIcon = NSWorkspace.shared.icon(forFile: entry.url.path)
        hud.flash("… launching \(entry.name)", icon: appIcon)
        let bundleID = entry.bundleID
        let name = entry.name
        expect(seconds: 12, matches: { window in
            (bundleID != nil && window.bundleID == bundleID)
                || window.appName.lowercased() == name.lowercased()
        }, action: { [weak self] window in
            self?.place(window, beside: beside)
        })
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: entry.url, configuration: configuration) { _, error in
            if let error {
                DispatchQueue.main.async { Log.error("launch \(name): \(error.localizedDescription)") }
            }
        }
    }

    /// lode 0 — the focused window fills the display: the summon treatment
    /// for a window that arrived by other means. Everything already in the
    /// layout parks, and the window itself joins it, so from here it answers
    /// to index jumps, breaths, and undo like anything Lodestar summoned.
    /// ⇧ joins beside instead of taking over.
    func maximizeFocused(beside: Bool) {
        guard let window = model.focusedWindow, model.verify(window.id) else {
            hud.flash("✕ no focused window to maximize")
            return
        }
        Log.info("maximize", ["window": window.id, "app": window.appName, "beside": beside])
        place(window, beside: beside)
    }

    /// Summon a specific window by id (the window chooser's verb).
    func summonWindow(_ id: CGWindowID, beside: Bool) {
        guard let window = model.window(id), model.verify(id) else {
            hud.flash("✕ that window is gone")
            return
        }
        place(window, beside: beside)
    }

    /// Badge positions for peek: each layout member's index at its center.
    func indexBadgeItems() -> [(index: Int, frame: CGRect)] {
        guard let active = layout.activeDisplay() else { return [] }
        let ordered = layout.orderedByPosition(on: active.id)
        guard ordered.count > 1 else { return [] }
        return ordered.enumerated().compactMap { offset, id in
            guard let window = model.window(id), window.isAlive else { return nil }
            return (offset + 1, window.frame)
        }
    }

    /// Every graph leaf flattened for the cheat sheet ("E O" → Outlook).
    func graphCheatRows(_ node: GraphNode, prefix: [String] = []) -> [GuideRow] {
        var rows: [GuideRow] = []
        for letter in node.children.keys.sorted() {
            let child = node.children[letter]!
            let path = prefix + [letter.uppercased()]
            if let target = child.target, child.children.isEmpty {
                let rowIcon: NSImage?
                switch target {
                case .app(let name): rowIcon = icon(forAppNamed: name)
                case .browserProfile(_, let profile): rowIcon = icon(forAppNamed: profile.browser.appName)
                }
                rows.append(GuideRow(key: path.joined(separator: " "), label: target.label, icon: rowIcon))
            } else {
                rows.append(contentsOf: graphCheatRows(child, prefix: path))
            }
        }
        return rows
    }

    // MARK: - Layout verbs

    func undoLayout() {
        if let display = layout.undo() {
            focusFirst(on: display)
            hud.flash("⟲ layout")
        } else {
            hud.flash("✕ nothing to undo")
        }
    }

    func redoLayout() {
        if let display = layout.redo() {
            focusFirst(on: display)
            hud.flash("⟳ layout")
        } else {
            hud.flash("✕ nothing to redo")
        }
    }

    /// lode [ / ]: throw the focused window to the neighbor display —
    /// plain arrives full-screen there, shift arrives beside.
    func moveFocusedDisplay(direction: Int, beside: Bool) {
        guard let focused = model.focusedWindow, model.verify(focused.id) else {
            hud.flash("✕ no focused window")
            return
        }
        guard let home = Displays.display(containing: focused.frame),
              let destination = Displays.neighbor(of: home, direction: direction) else {
            hud.flash("✕ only one display")
            return
        }
        Log.info("move-display", ["window": focused.id, "from": home.id,
                                  "to": destination.id, "beside": beside])
        if beside {
            layout.add(focused.id, on: destination.id)
        } else {
            layout.replace(with: focused.id, on: destination.id)
        }
        raise(focused)
    }

    /// lode X / ⇧X: walk the attention timeline. A back-jump is a summon
    /// of the previous destination using the standard placement rules.
    func goBack() {
        guard let id = history.stepBack(isAlive: { self.model.verify($0) }),
              let window = model.window(id) else {
            hud.flash("✕ nothing further back")
            return
        }
        Log.info("back", ["to": id, "app": window.appName])
        place(window, beside: false)
    }

    func goForward() {
        guard let id = history.stepForward(isAlive: { self.model.verify($0) }),
              let window = model.window(id) else {
            hud.flash("✕ nothing forward")
            return
        }
        Log.info("forward", ["to": id, "app": window.appName])
        place(window, beside: false)
    }

    /// lode ⇧digit: slide the focused window into that position on its
    /// display (insert-and-shift; 9 = last).
    func reorderFocused(toDigit digit: Int) {
        guard let focused = model.focusedWindow, model.verify(focused.id),
              let display = layout.display(of: focused.id) else {
            hud.flash("✕ the focused window is not in a layout")
            return
        }
        guard layout.move(focused.id, toDigit: digit, on: display) else {
            hud.flash("✕ can't move to position \(digit)")
            return
        }
        raise(focused)
    }

    private func focusFirst(on display: CGDirectDisplayID) {
        guard let first = layout.orderedByPosition(on: display).first,
              let window = model.window(first), window.isAlive else { return }
        raise(window)
    }


    // MARK: - Index + orientation

    func indexJump(_ digit: Int) {
        guard let active = layout.activeDisplay(),
              let id = layout.windowID(atDigit: digit, on: active.id),
              let window = model.window(id), model.verify(id) else {
            hud.flash("✕ no window \(digit)")
            return
        }
        raise(window)
    }

    func flipOrientation() {
        guard let active = layout.activeDisplay() else { return }
        layout.flipOrientation(on: active.id)
        hud.flash("↺ \(layout.orientation(on: active.id).rawValue)")
    }

    /// Rows for the persistent breath guide: layouts saved under this prefix.
    func breathGuide(prefix: String) -> [GuideRow] {
        store.state.breaths
            .filter { $0.path.hasPrefix(prefix) && $0.path != prefix }
            .sorted { $0.path < $1.path }
            .map { record in
                let remaining = record.path.dropFirst(prefix.count)
                    .uppercased().map(String.init).joined(separator: " ")
                let names = record.members.map(\.appName).joined(separator: " · ")
                let clipped = names.count > 48 ? String(names.prefix(47)) + "…" : names
                return GuideRow(key: remaining,
                                label: "\(record.members.count)▢  \(clipped)",
                                icon: record.members.first.flatMap { icon(forAppNamed: $0.appName) })
            }
    }

    /// Rows for the graph guide, with each destination's app icon.
    func graphGuideRows(_ node: GraphNode) -> [GuideRow] {
        node.guideRows().map { key, label in
            let icon: NSImage?
            if label.hasPrefix("→") {
                icon = nil
            } else if let browser = ChromiumBrowser.allCases.first(where: { label.hasPrefix("\($0.label) (") }) {
                icon = self.icon(forAppNamed: browser.appName)
            } else {
                icon = self.icon(forAppNamed: label)
            }
            return GuideRow(key: key, label: label, icon: icon)
        }
    }

    func icon(forAppNamed name: String) -> NSImage? {
        guard let entry = appIndex.entry(named: name) else { return nil }
        return NSWorkspace.shared.icon(forFile: entry.url.path)
    }

    /// The focused window's app, for the window chooser.
    func focusedAppInfo() -> (pid: pid_t, name: String)? {
        guard let focused = model.focusedWindow else { return nil }
        return (focused.pid, focused.appName)
    }

    /// Delete-armed resolution: an exact path deletes; a prefix keeps
    /// collecting; a free path is a miss.
    func deleteBreathStep(_ letters: [String]) -> ChainStep {
        let path = letters.joined()
        if store.breath(at: path) != nil {
            _ = store.deleteBreath(at: path)
            return .done(flash: "◎ breath \(path.uppercased()) deleted")
        }
        if store.isBreathPrefix(path) { return .continuing(hint: nil) }
        return .failed(flash: "✕ no breath at \(path.uppercased())")
    }

    // MARK: - Breaths

    func breathChain(_ letters: [String]) -> ChainStep {
        let path = letters.joined()
        if let record = store.breath(at: path) {
            restoreBreath(record)
            return .done(flash: nil)
        }
        return .continuing(hint: nil)
    }

    func bindBreath(_ letters: [String]) -> ChainStep {
        let path = letters.joined()
        guard !path.isEmpty, path != "b" else { return .failed(flash: "✕ invalid breath path") }
        if let shadowed = store.breathWouldShadow(path) {
            return .failed(flash: "✕ \(path.uppercased()) would shadow breath \(shadowed.uppercased())")
        }
        let members = currentBreathMembers()
        guard !members.isEmpty else { return .failed(flash: "✕ nothing on screen to save") }
        let orientation = layout.activeDisplay().map { layout.orientation(on: $0.id) } ?? .horizontal
        store.setBreath(BreathRecord(path: path, orientation: orientation.rawValue, members: members))
        return .done(flash: "◎ breath \(path.uppercased()) saved · \(members.count) window\(members.count == 1 ? "" : "s")")
    }

    func updateLatestBreath() -> ChainStep {
        guard let latest = store.state.latestBreath, var record = store.breath(at: latest) else {
            return .failed(flash: "✕ no latest breath to update")
        }
        let members = currentBreathMembers()
        guard !members.isEmpty else { return .failed(flash: "✕ nothing on screen") }
        record.members = members
        let orientation = layout.activeDisplay().map { layout.orientation(on: $0.id) } ?? .horizontal
        record.orientation = orientation.rawValue
        store.setBreath(record)
        return .done(flash: "◎ breath \(latest.uppercased()) updated · \(members.count) window\(members.count == 1 ? "" : "s")")
    }

    private func currentBreathMembers() -> [BreathMember] {
        model.sweepAgainstWindowServer()
        return layout.worldOrderedByPosition().compactMap { id in
            guard let w = model.window(id), w.isAlive else { return nil }
            return BreathMember(
                windowID: UInt32(id), bundleID: w.bundleID,
                appName: w.appName, title: w.title, frame: w.frame
            )
        }
    }

    private func restoreBreath(_ record: BreathRecord) {
        var resolvedPairs: [(member: BreathMember, id: CGWindowID)] = []
        var missing: [BreathMember] = []
        for member in record.members {
            if let window = model.window(CGWindowID(member.windowID)), model.verify(window.id) {
                resolvedPairs.append((member, window.id))
                continue
            }
            let taken = Set(resolvedPairs.map(\.id))
            let candidates = aliveCandidates(bundleID: member.bundleID, appName: member.appName)
                .filter { !taken.contains($0.id) }
            if let best = bestTitleMatch(member.title, in: candidates) {
                store.rebindBreathMember(path: record.path, oldID: member.windowID,
                                         newID: UInt32(best.id), title: best.title)
                resolvedPairs.append((member, best.id))
            } else {
                missing.append(member)
            }
        }

        let orientation = Orientation(rawValue: record.orientation) ?? .horizontal
        if !resolvedPairs.isEmpty {
            // Members go home: each restores to the display its stored frame
            // was on; members of a since-unplugged display join the active one.
            let fallback = layout.activeDisplay()?.id ?? Displays.ordered().first?.id
            var groups: [CGDirectDisplayID: [CGWindowID]] = [:]
            for (member, id) in resolvedPairs {
                let display = Displays.display(containing: member.frame)?.id ?? fallback
                guard let display else { continue }
                groups[display, default: []].append(id)
            }
            layout.adoptGroups(groups, orientation: orientation)
            for (_, id) in resolvedPairs.reversed() {
                if let w = model.window(id) { AXWindow(element: w.element)?.raise() }
            }
            if let first = resolvedPairs.first, let w = model.window(first.id) { raise(w) }
        }
        store.touchLatestBreath(record.path)

        if !missing.isEmpty {
            let names = missing.map(\.appName).joined(separator: ", ")
            hud.flash("◎ \(record.path.uppercased()) · relaunching \(names)",
                      icon: missing.first.flatMap { icon(forAppNamed: $0.appName) })
            for (index, member) in missing.enumerated() {
                relaunchIntoBreath(member, path: record.path, orientation: orientation,
                                   raiseOnArrival: resolvedPairs.isEmpty && index == 0)
            }
        }
    }

    /// The post-reboot path: every stored ID is dead, the app may not even
    /// be running. Launch it quietly, catch its window, and seat it in the
    /// breath's arrangement — the first member of an all-missing restore
    /// carries focus so the breath lands somewhere deliberate.
    private func relaunchIntoBreath(_ member: BreathMember, path: String,
                                    orientation: Orientation, raiseOnArrival: Bool) {
        guard let entry = appIndex.entry(named: member.appName) else { return }
        expect(seconds: 15, matches: { [bundleID = member.bundleID, appName = member.appName] window in
            (bundleID != nil && window.bundleID == bundleID) || window.appName == appName
        }, action: { [weak self] window in
            guard let self else { return }
            self.store.rebindBreathMember(path: path, oldID: member.windowID,
                                          newID: UInt32(window.id), title: window.title)
            let display = Displays.display(containing: member.frame)?.id
                ?? self.layout.activeDisplay()?.id
            if let display {
                if self.layout.members(on: display).isEmpty {
                    self.layout.setOrientation(orientation, on: display)
                }
                self.layout.add(window.id, on: display)
            }
            if raiseOnArrival { self.raise(window) }
        })
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: entry.url, configuration: configuration)
    }

    // MARK: - Parking

    func restoreAllParked() {
        var count = 0
        for (id, _) in parking.snapshot() {
            if let window = model.window(id), window.isAlive {
                if parking.unpark(window) { count += 1 }
            } else {
                parking.forget(id)
            }
        }
        store.setParked(parking.snapshot())
        hud.flash("⤺ restored \(count) parked window\(count == 1 ? "" : "s")")
    }

    // MARK: - Plumbing

    /// A window Lodestar did not summon is left exactly where its app put
    /// it. The only claim on an arriving window is an intent: something
    /// this process asked for and is still waiting on (a launch, a browser
    /// profile opening). Everything else floats, macOS-style.
    private func windowAppeared(_ id: CGWindowID) {
        guard let window = model.window(id), window.isAlive else { return }
        if let action = intents.claim(window) {
            action(window)
        }
    }

    private func expect(seconds: TimeInterval,
                        matches: @escaping (WindowModel.Window) -> Bool,
                        action: @escaping (WindowModel.Window) -> Void) {
        intents.expect(.init(matches: matches, action: action,
                             expires: Date().addingTimeInterval(seconds)))
    }

    private func place(_ window: WindowModel.Window, beside: Bool) {
        // Backstop for every path that hands an id straight here: a window
        // that died without telling anyone must not become a layout member.
        guard model.verify(window.id) else {
            hud.flash("✕ that window is gone")
            return
        }
        let began = Date()
        defer {
            Log.info("placed", ["window": window.id,
                                "ms": Int(Date().timeIntervalSince(began) * 1000)])
        }
        store.touchUsage(window.bundleID)
        parking.claim(window.id)
        if window.isMinimized {
            AXWindow(element: window.element)?.setMinimized(false)
        }
        guard let active = layout.activeDisplay() else {
            raise(window)
            return
        }
        let action = Placement.decide(beside: beside,
                                      memberOfDisplay: layout.display(of: window.id),
                                      activeDisplay: active.id)
        Log.info("place", ["window": window.id, "app": window.appName,
                           "action": "\(action)", "display": active.id])
        switch action {
        case .add: layout.add(window.id, on: active.id)
        case .replace: layout.replace(with: window.id, on: active.id)
        case .visit: break // take me there — its arrangement stays untouched
        }
        raise(window)
    }

    private func raise(_ window: WindowModel.Window) {
        let ax = AXWindow(element: window.element)
        ax?.makeMain()
        ax?.raise()
        if let app = NSRunningApplication(processIdentifier: window.pid) {
            if #available(macOS 14.0, *) {
                app.activate()
            } else {
                app.activate(options: [.activateIgnoringOtherApps])
            }
        }
    }

    private func bestAliveWindow(bundleID: String?, appName: String) -> WindowModel.Window? {
        let candidates = aliveCandidates(bundleID: bundleID, appName: appName)
        guard let anyone = candidates.first else { return nil }
        if let best = model.bestWindow(pid: anyone.pid),
           candidates.contains(where: { $0.id == best.id }) {
            return best
        }
        return WindowModel.mostCurrent(candidates)
    }

    private func aliveCandidates(bundleID: String?, appName: String) -> [WindowModel.Window] {
        if let bundleID, !model.aliveWindows(bundleID: bundleID).isEmpty {
            return model.aliveWindows(bundleID: bundleID)
        }
        return model.aliveWindows(appNamed: appName)
    }

    /// Title similarity for re-matching a dead breath member: exact,
    /// containment, then longest common prefix.
    private func bestTitleMatch(_ target: String, in candidates: [WindowModel.Window]) -> WindowModel.Window? {
        guard !candidates.isEmpty else { return nil }
        if let exact = candidates.first(where: { $0.title == target }) { return exact }
        let t = target.lowercased()
        if !t.isEmpty {
            if let contains = candidates.first(where: {
                let c = $0.title.lowercased()
                return !c.isEmpty && (c.contains(t) || t.contains(c))
            }) {
                return contains
            }
            let scored = candidates.map { ($0, commonPrefixLength(t, $0.title.lowercased())) }
                .sorted { $0.1 > $1.1 }
            if let best = scored.first, best.1 >= 4 { return best.0 }
        }
        return candidates.first
    }

    private func commonPrefixLength(_ a: String, _ b: String) -> Int {
        zip(a, b).prefix { $0 == $1 }.count
    }

    private func shortTitle(_ window: WindowModel.Window) -> String {
        let title = window.title.isEmpty ? window.appName : window.title
        return title.count > 34 ? String(title.prefix(33)) + "…" : title
    }
}
