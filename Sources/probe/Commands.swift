import AppKit
import LodestarCore

// MARK: - Small helpers

func fail(_ message: String) -> Never {
    fputs("probe: \(message)\n", stderr)
    exit(1)
}

func requireTrust() {
    guard Permissions.isTrusted else {
        fail("""
        not trusted for Accessibility. Run `probe check --prompt`, grant your terminal
        access under System Settings > Privacy & Security > Accessibility, then retry.
        """)
    }
}

func value(of flag: String, in args: inout [String]) -> String? {
    guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
    let flagValue = args[index + 1]
    args.removeSubrange(index...(index + 1))
    return flagValue
}

func has(_ flag: String, in args: inout [String]) -> Bool {
    guard let index = args.firstIndex(of: flag) else { return false }
    args.remove(at: index)
    return true
}

func fmt(_ rect: CGRect) -> String {
    "(\(Int(rect.origin.x.rounded())), \(Int(rect.origin.y.rounded()))) \(Int(rect.width.rounded()))x\(Int(rect.height.rounded()))"
}

func fmt(_ point: CGPoint) -> String {
    "(\(Int(point.x.rounded())), \(Int(point.y.rounded())))"
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

func clip(_ text: String, _ width: Int) -> String {
    text.count <= width ? text : String(text.prefix(width - 1)) + "…"
}

func near(_ a: CGPoint, _ b: CGPoint, tolerance: CGFloat = 2) -> Bool {
    abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
}

func findApps(matching query: String) -> [NSRunningApplication] {
    let q = query.lowercased()
    return NSWorkspace.shared.runningApplications.filter { app in
        guard app.activationPolicy == .regular else { return false }
        let name = app.localizedName?.lowercased() ?? ""
        let bundle = app.bundleIdentifier?.lowercased() ?? ""
        return name.contains(q) || bundle.contains(q)
    }
}

func findWindow(id: CGWindowID) -> (AXApplication, AXWindow)? {
    for app in AXApplication.visibleApps() {
        guard let windows = app.windows() else { continue }
        if let window = windows.first(where: { $0.id == id }) { return (app, window) }
    }
    return nil
}

/// Poll until the window reports (roughly) the expected position — some apps
/// apply AX position changes asynchronously. Returns the last position seen.
func settlePosition(_ window: AXWindow, expecting point: CGPoint, timeout: TimeInterval = 1.5) -> CGPoint? {
    let deadline = Date() + timeout
    var last: CGPoint?
    while Date() < deadline {
        if let position = window.position {
            last = position
            if near(position, point) { return position }
        }
        usleep(50_000)
    }
    return last
}

// MARK: - check

func runCheck(_ args: inout [String]) {
    let prompt = has("--prompt", in: &args)
    let trusted = prompt ? Permissions.requestIfNeeded() : Permissions.isTrusted
    print("accessibility trust : \(trusted ? "TRUSTED" : "NOT TRUSTED")")
    let cgCount = CGWindows.list(onScreenOnly: true).count
    print("window server reach : \(cgCount) on-screen windows via CGWindowList\(cgCount == 0 ? "  (0 usually means no GUI session or a sandboxed process)" : "")")
    if !trusted {
        print("")
        print("The probe reads and moves other apps' windows, so this process must be")
        print("trusted for Accessibility. macOS attributes the grant to the app that")
        print("launched it — your terminal. Enable it under:")
        print("  System Settings > Privacy & Security > Accessibility")
        print(prompt ? "A system prompt was requested just now." : "Re-run with --prompt to trigger the system prompt.")
        exit(1)
    }
}

// MARK: - displays

func runDisplays(_ args: inout [String]) {
    let bounds = Displays.allBounds()
    guard !bounds.isEmpty else { fail("no active displays reported") }
    for (index, rect) in bounds.enumerated() {
        print("display \(index): \(fmt(rect))")
    }
    print("union    : \(fmt(Displays.unionBounds()))")
    print("parking  : \(fmt(Displays.parkingPosition())) (beyond every display)")
}

// MARK: - cg

func runCG(_ args: inout [String]) {
    let includeOffscreen = has("--all", in: &args)
    let rows = CGWindows.list(onScreenOnly: !includeOffscreen)
    print(pad("WID", 8) + pad("PID", 8) + pad("LAYER", 7) + pad("APP", 24) + "BOUNDS")
    for row in rows.sorted(by: { $0.id < $1.id }) where row.layer == 0 || includeOffscreen {
        print(pad(String(row.id), 8) + pad(String(row.pid), 8) + pad(String(row.layer), 7)
            + pad(clip(row.ownerName, 22), 24) + fmt(row.bounds))
    }
    print("")
    print("\(rows.count) windows from the window server (no Accessibility needed for this view)")
}

// MARK: - list

func runList(_ args: inout [String]) {
    requireTrust()
    let cgIDs = Set(CGWindows.list(onScreenOnly: false).map(\.id))
    var totalWindows = 0
    var bridged = 0
    var crossChecked = 0
    var unreachable: [String] = []
    var unbridgedByApp: [String: Int] = [:]

    print(pad("WID", 8) + pad("APP", 22) + pad("TITLE", 42) + pad("FRAME", 26) + "FLAGS")
    for app in AXApplication.regularApps().sorted(by: { $0.name.lowercased() < $1.name.lowercased() }) {
        guard let windows = app.windows() else {
            unreachable.append(app.name)
            continue
        }
        let unbridgedCount = app.unbridgedWindowCount()
        if unbridgedCount > 0 { unbridgedByApp[app.name] = unbridgedCount }
        totalWindows += unbridgedCount
        for window in windows {
            totalWindows += 1
            bridged += 1
            var flags: [String] = []
            if cgIDs.contains(window.id) { crossChecked += 1 } else { flags.append("not-in-cg-list") }
            if window.isMinimized { flags.append("minimized") }
            let frame = window.frame.map(fmt) ?? "?"
            print(pad(String(window.id), 8) + pad(clip(app.name, 20), 22)
                + pad(clip(window.title ?? "", 40), 42) + pad(frame, 26)
                + flags.joined(separator: ","))
        }
    }
    print("")
    print("windows \(totalWindows) | bridged via _AXUIElementGetWindow \(bridged) | cross-checked in window-server list \(crossChecked)/\(bridged)")
    if !unbridgedByApp.isEmpty {
        print("unbridged (private call failed): \(unbridgedByApp.map { "\($0.key) x\($0.value)" }.sorted().joined(separator: ", "))")
    }
    if !unreachable.isEmpty {
        print("AX-unreachable apps: \(unreachable.joined(separator: ", "))")
    }
}

// MARK: - park

func runPark(_ args: inout [String]) {
    requireTrust()
    let sliver = has("--sliver", in: &args)
    let seconds = value(of: "--seconds", in: &args).flatMap(Double.init) ?? 3
    let appQuery = value(of: "--app", in: &args)

    let app: AXApplication
    let window: AXWindow
    if let appQuery {
        guard let running = findApps(matching: appQuery).first else {
            fail("no running app matches '\(appQuery)'")
        }
        app = AXApplication(running)
        guard let found = app.focusedOrFirstWindow() else { fail("\(app.name) has no AX windows") }
        window = found
    } else if let widString = args.first, let wid = CGWindowID(widString) {
        guard let found = findWindow(id: wid) else { fail("no window with id \(wid) (see `probe list`)") }
        (app, window) = found
    } else {
        fail("usage: probe park <windowID> | probe park --app <name> [--seconds N] [--sliver]")
    }

    guard let original = window.frame else { fail("could not read the window's frame") }
    let union = Displays.unionBounds()
    let destination = sliver
        ? CGPoint(x: union.maxX - 2, y: union.maxY - 2)
        : Displays.parkingPosition()

    print("window   : id=\(window.id) '\(clip(window.title ?? "", 50))' of \(app.name)")
    print("original : \(fmt(original))")
    print("parking  : \(fmt(destination)) (\(sliver ? "sliver: 2px corner left visible" : "fully beyond the display union \(fmt(union))"))")

    guard window.setPosition(destination) else { fail("AX refused the position change") }
    let parkedAt = settlePosition(window, expecting: destination)
    if let parkedAt, near(parkedAt, destination) {
        print("parked   : PASS — window sits at \(fmt(parkedAt))")
    } else if let parkedAt {
        print("parked   : CLAMPED — asked for \(fmt(destination)), window reports \(fmt(parkedAt))")
        print("           (macOS or the app refused full off-screen; try --sliver and compare)")
    } else {
        print("parked   : could not read the position back")
    }

    let idWhileParked = windowID(of: window.element)
    print("identity : \(idWhileParked == window.id ? "id unchanged (\(window.id)) while parked" : "ID CHANGED while parked: \(idWhileParked.map(String.init) ?? "lost") — investigate!")")
    let onScreen = CGWindows.contains(window.id, onScreenOnly: true)
    let anywhere = CGWindows.contains(window.id, onScreenOnly: false)
    print("cg state : on-screen list \(onScreen ? "yes" : "no") | all-windows list \(anywhere ? "yes" : "no") (a parked window should stay live but leave the on-screen list)")

    print("restoring in \(Int(seconds))s — the window should be gone from every display right now")
    Thread.sleep(forTimeInterval: seconds)

    guard window.setPosition(original.origin) else {
        fail("AX refused the restore — the window is stranded at \(fmt(destination)); drag it back or rerun")
    }
    let restoredAt = settlePosition(window, expecting: original.origin)
    let idAfter = windowID(of: window.element)
    if let restoredAt, near(restoredAt, original.origin), idAfter == window.id {
        print("restored : PASS — back at \(fmt(restoredAt)), id still \(window.id)")
        print("")
        print("VERDICT: park/restore round-trip works; a live window's CGWindowID is a stable handle.")
    } else {
        print("restored : position \(restoredAt.map(fmt) ?? "?") | id \(idAfter.map(String.init) ?? "lost")")
        print("")
        print("VERDICT: round-trip incomplete — see the lines above.")
    }
}

// MARK: - move

func runMove(_ args: inout [String]) {
    requireTrust()
    guard args.count >= 3, let wid = CGWindowID(args[0]),
          let x = Double(args[1]), let y = Double(args[2]) else {
        fail("usage: probe move <windowID> <x> <y> [<w> <h>]")
    }
    guard let (_, window) = findWindow(id: wid) else { fail("no window with id \(wid)") }
    let before = window.frame
    if args.count >= 5, let width = Double(args[3]), let height = Double(args[4]) {
        window.setFrame(CGRect(x: x, y: y, width: width, height: height))
    } else {
        window.setPosition(CGPoint(x: x, y: y))
    }
    usleep(300_000)
    print("before : \(before.map(fmt) ?? "?")")
    print("after  : \(window.frame.map(fmt) ?? "?")")
}

// MARK: - watch

func runWatch(_ args: inout [String]) {
    requireTrust()
    let seconds = value(of: "--seconds", in: &args).flatMap(Double.init) ?? 60
    guard let query = args.first else { fail("usage: probe watch <app> [--seconds N]") }

    func snapshot() -> [CGWindowID: String] {
        var out: [CGWindowID: String] = [:]
        for running in findApps(matching: query) {
            for window in AXApplication(running).windows() ?? [] {
                out[window.id] = window.title ?? ""
            }
        }
        return out
    }

    let start = Date()
    func stamp() -> String { String(format: "[%6.1fs]", Date().timeIntervalSince(start)) }

    var present = snapshot()
    if findApps(matching: query).isEmpty {
        print("\(stamp()) no running app matches '\(query)' yet — launch it while I watch")
    }
    for (id, title) in present.sorted(by: { $0.key < $1.key }) {
        print("\(stamp()) baseline id=\(id) '\(clip(title, 60))'")
    }
    print("\(stamp()) watching for \(Int(seconds))s — close and reopen a window of the app now")

    var departed: [CGWindowID: String] = [:]
    var revealed = 0
    var churnedWindows = 0

    let deadline = start + seconds
    while Date() < deadline {
        usleep(300_000)
        let now = snapshot()
        for (id, title) in now where present[id] == nil {
            if let oldTitle = departed.removeValue(forKey: id) {
                revealed += 1
                print("\(stamp()) BACK    id=\(id) ('\(clip(oldTitle, 40))' -> '\(clip(title, 40))') — same id returned: it was hidden (tab-backgrounded), never closed")
            } else if let match = departed.first(where: { !$0.value.isEmpty && $0.value == title }) {
                churnedWindows += 1
                departed.removeValue(forKey: match.key)
                print("\(stamp()) CHURNED id=\(id) '\(clip(title, 40))' reopened with a new ID (was id=\(match.key))")
            } else {
                print("\(stamp()) NEW     id=\(id) '\(clip(title, 40))'")
            }
        }
        for (id, title) in present where now[id] == nil {
            departed[id] = title
            print("\(stamp()) GONE    id=\(id) '\(clip(title, 40))' (closed or tab-hidden — polling cannot tell which)")
        }
        present = now
    }

    print("")
    print("--- watch summary for '\(query)' ---")
    print("vanished and never returned            : \(departed.count)")
    print("reopened with a NEW id (title-matched) : \(churnedWindows)")
    print("vanished, then BACK with the same id   : \(revealed)")
    if churnedWindows > 0 || !departed.isEmpty {
        print("VERDICT: truly closed windows come back with fresh CGWindowIDs (expected on macOS).")
        print("A close is a hard identity break: breaths survive one only by best-effort re-matching.")
    }
    if revealed > 0 {
        print("NOTE: same-id returns are reveals, not reopens — the window was tab-backgrounded, still")
        print("alive, and kept its identity (as safe an anchor as parking). But hidden windows are")
        print("invisible to AX enumeration, so only a cached element can address them: the resolver")
        print("must be a cached model, not a re-enumerator.")
    }
    if churnedWindows == 0 && departed.isEmpty && revealed == 0 {
        print("VERDICT: no churn observed — close and reopen a window during the watch to get a signal.")
    }
}

// MARK: - Text selection

/// Can Lodestar point at characters, and can it move a selection?
///
/// Two questions decide whether a selection mode is buildable at all. The
/// first is geometry: `AXBoundsForRange` maps a character range to a screen
/// rectangle, which is what lets labels be drawn *at* words rather than at
/// whole elements. The second is authority: `AXSelectedTextRange` has to be
/// settable, or the mode can find a span it is not allowed to take.
///
/// Read-only by default — nothing is focused, nothing is typed. `--write`
/// additionally selects the first five characters of the frontmost app's
/// focused element, which is visible but not destructive.
func runSelection(_ args: inout [String]) {
    requireTrust()
    let write = args.contains("--write")
    let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXStaticText",
                                  "AXWebArea", "AXComboBox", "AXSearchField"]

    func settable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var flag: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &flag) == .success
        else { return false }
        return flag.boolValue
    }

    func bounds(_ element: AXUIElement, _ location: Int, _ length: Int) -> CGRect? {
        var range = CFRange(location: location, length: length)
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &out
        ) == .success, let raw = out, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(raw as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    print(String(format: "%-20@ %-13@ %6@ %9@ %7@ %7@",
                 "app" as NSString, "role" as NSString, "chars" as NSString,
                 "settable" as NSString, "bounds" as NSString, "params" as NSString))

    var visited = 0
    func walk(_ element: AXUIElement, app: String, depth: Int, budget: inout Int) {
        // Web content nests far deeper than native chrome; six levels
        // never reaches a Chromium text node.
        guard depth <= 24, budget > 0 else { return }
        budget -= 1
        visited += 1
        let role = AX.string(element, kAXRoleAttribute as String) ?? "?"
        if textRoles.contains(role) {
            let chars = AX.int(element, kAXNumberOfCharactersAttribute as String) ?? -1
            if chars != 0 {
                var names: CFArray?
                _ = AXUIElementCopyParameterizedAttributeNames(element, &names)
                let box = chars > 0 ? bounds(element, 0, min(3, chars)) : nil
                print(String(format: "%-20@ %-13@ %6d %9@ %7@ %7d",
                             app as NSString, role as NSString, chars,
                             (settable(element, kAXSelectedTextRangeAttribute as String)
                                ? "YES" : "no") as NSString,
                             ((box?.width ?? 0) > 0 ? "YES" : "no") as NSString,
                             ((names as? [String])?.count ?? 0)))
            }
        }
        guard let children = AX.elements(element, kAXChildrenAttribute as String) else { return }
        for child in children.prefix(60) {
            walk(child, app: app, depth: depth + 1, budget: &budget)
        }
    }

    for running in NSWorkspace.shared.runningApplications
    where running.activationPolicy == .regular {
        let app = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1.0)
        // Chromium and Electron build no AX tree until an assistive client
        // announces itself — the same flag the hints harvest flips, plus a
        // beat for the tree to materialize.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        usleep(300_000)
        guard let windows = AX.elements(app, kAXWindowsAttribute as String), !windows.isEmpty
        else { continue }
        var budget = 2500
        for window in windows.prefix(2) {
            walk(window, app: running.localizedName ?? "?", depth: 0, budget: &budget)
        }
    }
    print("\nvisited \(visited) nodes")

    guard write else { return }
    print("\n--- write test: frontmost app's focused element ---")
    guard let front = NSWorkspace.shared.frontmostApplication else { return }
    let app = AXUIElementCreateApplication(front.processIdentifier)
    guard let focused = AX.element(app, kAXFocusedUIElementAttribute as String) else {
        print("no focused element")
        return
    }
    let role = AX.string(focused, kAXRoleAttribute as String) ?? "?"
    var range = CFRange(location: 0, length: 5)
    guard let parameter = AXValueCreate(.cfRange, &range) else { return }
    let error = AXUIElementSetAttributeValue(
        focused, kAXSelectedTextRangeAttribute as CFString, parameter)
    let selected = AX.string(focused, kAXSelectedTextAttribute as String)
    print("\(front.localizedName ?? "?") \(role): set 0..<5 -> AXError \(error.rawValue), "
          + "selection now \(selected.map { "\"\($0)\"" } ?? "nil")")
    if let box = bounds(focused, 0, 5) { print("bounds of 0..<5: \(box)") }
}

// MARK: - Harvest diagnostics

/// Why does the select harvest starve in a browser? This instruments the
/// exact walk the controller does — same roles, same pruning — against a
/// named app's first window, and reports where the time and the budget
/// actually went: nodes per second, prune hits, leaves by depth, and the
/// cost of each AX round trip, single-attribute versus batched.
func runHarvest(_ args: inout [String]) {
    requireTrust()
    let appName = args.first ?? "Brave Browser"
    let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXStaticText",
                                  "AXWebArea", "AXComboBox", "AXSearchField"]

    guard let running = NSWorkspace.shared.runningApplications.first(where: {
        ($0.localizedName ?? "").localizedCaseInsensitiveContains(appName)
    }) else {
        print("no running app matching '\(appName)'")
        return
    }
    let app = AXUIElementCreateApplication(running.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 1.0)
    AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    if has("--enhanced", in: &args) {
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        print("AXEnhancedUserInterface set")
    }
    let settle = value(of: "--settle", in: &args).flatMap(Double.init) ?? 0.4
    let dump = has("--dump", in: &args)
    usleep(UInt32(settle * 1_000_000))
    let windowIndex = value(of: "--window", in: &args).flatMap(Int.init) ?? 0
    guard let windows = AX.elements(app, kAXWindowsAttribute as String),
          windows.indices.contains(windowIndex) else {
        print("no window at index \(windowIndex)")
        return
    }
    let window = windows[windowIndex]
    if let title = AX.string(window, kAXTitleAttribute as String) { print("window: \(title.prefix(60))") }
    guard let position = AX.point(window, kAXPositionAttribute as String),
          let size = AX.size(window, kAXSizeAttribute as String) else {
        print("window has no frame")
        return
    }
    let windowFrame = CGRect(origin: position, size: size)
    print("\(running.localizedName ?? "?") window \(Int(size.width))×\(Int(size.height))")

    // Measure raw AX round-trip cost first: 200 single-attribute reads vs
    // 200 batched (role+position+size+children in one call).
    var probeElement = window
    if let children = AX.elements(window, kAXChildrenAttribute as String),
       let first = children.first { probeElement = first }
    var t0 = Date()
    for _ in 0..<200 { _ = AX.string(probeElement, kAXRoleAttribute as String) }
    let singleMs = Date().timeIntervalSince(t0) * 1000 / 200
    let batchAttributes = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute,
                           kAXChildrenAttribute] as CFArray
    t0 = Date()
    for _ in 0..<200 {
        var values: CFArray?
        _ = AXUIElementCopyMultipleAttributeValues(probeElement, batchAttributes,
                                                   AXCopyMultipleAttributeOptions(rawValue: 0),
                                                   &values)
    }
    let batchMs = Date().timeIntervalSince(t0) * 1000 / 200
    print(String(format: "AX cost: %.3fms per single read · %.3fms per 4-attribute batch",
                 singleMs, batchMs))

    var visited = 0
    var pruned = 0
    var leaves = 0
    var leafChars = 0
    var byDepth: [Int: Int] = [:]
    var maxDepthSeen = 0
    var deadlineHit = false
    var budgetHit = false
    let deadline = Date().addingTimeInterval(6.0)
    let began = Date()

    func walk(_ element: AXUIElement, depth: Int) {
        if Date() >= deadline { deadlineHit = true; return }
        if visited >= 60_000 { budgetHit = true; return }
        visited += 1
        maxDepthSeen = max(maxDepthSeen, depth)

        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(
            element, batchAttributes, AXCopyMultipleAttributeOptions(rawValue: 0),
            &values) == .success, let array = values as? [CFTypeRef], array.count == 4
        else { return }

        let role = array[0] as? String
        var frame: CGRect?
        if CFGetTypeID(array[1]) == AXValueGetTypeID(),
           CFGetTypeID(array[2]) == AXValueGetTypeID() {
            var point = CGPoint.zero
            var sz = CGSize.zero
            if AXValueGetValue(array[1] as! AXValue, .cgPoint, &point),
               AXValueGetValue(array[2] as! AXValue, .cgSize, &sz) {
                frame = CGRect(origin: point, size: sz)
            }
        }
        if let frame, frame.width > 1, frame.height > 1,
           !frame.intersects(windowFrame.insetBy(dx: -8, dy: -8)) {
            pruned += 1
            return
        }
        if role == "AXWebArea" {
            let count = AX.elements(element, kAXChildrenAttribute as String)?.count ?? -1
            print("  AXWebArea at depth \(depth): \(count) children")
        }
        if let role, textRoles.contains(role), role != "AXWebArea",
           let frame, frame.width >= 4, frame.height >= 4,
           frame.intersects(windowFrame),
           let text = AX.string(element, kAXValueAttribute as String),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            leaves += 1
            leafChars += (text as NSString).length
            byDepth[depth, default: 0] += 1
            if dump && leaves <= 25 {
                var range = CFRange(location: 0, length: min(2, (text as NSString).length))
                var boundsOK = false
                var rect = CGRect.zero
                if let parameter = AXValueCreate(.cfRange, &range) {
                    var out: CFTypeRef?
                    if AXUIElementCopyParameterizedAttributeValue(
                        element, kAXBoundsForRangeParameterizedAttribute as CFString,
                        parameter, &out) == .success,
                        let raw = out, CFGetTypeID(raw) == AXValueGetTypeID(),
                        AXValueGetValue(raw as! AXValue, .cgRect, &rect),
                        rect.width > 0 { boundsOK = true }
                }
                if leaves == 1 {
                    var names: CFArray?
                    _ = AXUIElementCopyParameterizedAttributeNames(element, &names)
                    print("  first leaf param attrs: \((names as? [String] ?? []).joined(separator: " "))")
                }
                print("  leaf d\(depth) \(role) bounds=\(boundsOK ? "OK \(Int(rect.width))x\(Int(rect.height))" : "FAIL") '\(text.prefix(40))'")
            }
        }
        guard CFGetTypeID(array[3]) == CFArrayGetTypeID(),
              let children = array[3] as? [AXUIElement] else { return }
        for child in children {
            walk(child, depth: depth + 1)
        }
    }

    walk(window, depth: 0)
    let elapsed = Date().timeIntervalSince(began)
    print(String(format: "visited %d nodes in %.2fs (%.0f nodes/s) · pruned %d subtrees",
                 visited, elapsed, Double(visited) / max(elapsed, 0.001), pruned))
    print("text leaves \(leaves) · \(leafChars) chars · max depth \(maxDepthSeen)"
          + (deadlineHit ? " · DEADLINE HIT" : "") + (budgetHit ? " · BUDGET HIT" : ""))
    if !byDepth.isEmpty {
        let spread = byDepth.sorted { $0.key < $1.key }
            .map { "d\($0.key):\($0.value)" }.joined(separator: " ")
        print("leaves by depth: \(spread)")
    }
}

// MARK: - Terminal text shape

/// Is a terminal's AXTextArea the visible grid or the whole scrollback?
/// Decides whether line-count arithmetic can place highlights honestly.
func runTermtext(_ args: inout [String]) {
    requireTrust()
    let appName = args.first ?? "Ghostty"
    guard let running = NSWorkspace.shared.runningApplications.first(where: {
        ($0.localizedName ?? "").localizedCaseInsensitiveContains(appName)
    }) else { print("no app"); return }
    let app = AXUIElementCreateApplication(running.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 1.0)
    guard let windows = AX.elements(app, kAXWindowsAttribute as String) else { return }
    for window in windows.prefix(2) {
        var stack: [AXUIElement] = [window]
        while let element = stack.popLast() {
            if AX.string(element, kAXRoleAttribute as String) == "AXTextArea" {
                let raw = AX.copy(element, kAXValueAttribute as String)
                print("AXTextArea found · AXValue type: \(raw.map { String(describing: CFGetTypeID($0)) } ?? "nil") (string=\(CFStringGetTypeID()))")
                let chars = AX.int(element, kAXNumberOfCharactersAttribute as String) ?? -1
                print("  NumberOfCharacters: \(chars)")
                var out: CFTypeRef?
                var okStr = "n/a"
                var srange = CFRange(location: 0, length: min(200, max(0, chars)))
                if let parameter = AXValueCreate(.cfRange, &srange) {
                    let err = AXUIElementCopyParameterizedAttributeValue(element, "AXStringForRange" as CFString, parameter, &out)
                    okStr = err == .success ? "'\(String(describing: out).prefix(80))'" : "err \(err.rawValue)"
                }
                print("  AXStringForRange(0..200): \(okStr)")
                guard let text = raw as? String else { continue }
                let lines = text.components(separatedBy: "\n")
                let position = AX.point(element, kAXPositionAttribute as String)
                let size = AX.size(element, kAXSizeAttribute as String)
                print("AXTextArea: \(lines.count) lines, \((text as NSString).length) chars, frame \(size.map { "\(Int($0.width))x\(Int($0.height))" } ?? "?") at \(position.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? "?")")
                if let size {
                    print("  implied cell height: \(String(format: "%.2f", size.height / CGFloat(max(1, lines.count))))px")
                }
                let visible = AX.copy(element, "AXVisibleCharacterRange")
                print("  AXVisibleCharacterRange: \(visible.map { String(describing: $0) } ?? "absent")")
                print("  longest line: \(lines.map { ($0 as NSString).length }.max() ?? 0) chars")
                print("  first line: '\(lines.first.map { String($0.prefix(60)) } ?? "")'")
                print("  last nonempty: '\(lines.last(where: { !$0.isEmpty }).map { String($0.prefix(60)) } ?? "")'")
                return
            }
            if let children = AX.elements(element, kAXChildrenAttribute as String) {
                stack.append(contentsOf: children)
            }
        }
    }
    print("no AXTextArea found")
}

// MARK: - Select pipeline stress

/// The whole select pipeline against a live app, headless: harvest text
/// leaves the way the controller does, stitch them with `SelectRuns`,
/// seed `SelectCore` with queries drawn from the harvested text itself,
/// and verify that matches are found, labels assigned, spans normalized,
/// and geometry answers. Prints a verdict per query and a summary —
/// the robustness matrix, one app at a time.
func runSelectPipe(_ args: inout [String]) {
    requireTrust()
    let appName = args.first ?? "Slack"
    let windowIndex = value(of: "--window", in: &args).flatMap(Int.init) ?? 0
    let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXStaticText",
                                  "AXComboBox", "AXSearchField"]
    guard let running = NSWorkspace.shared.runningApplications.first(where: {
        ($0.localizedName ?? "").localizedCaseInsensitiveContains(appName)
    }) else { print("\(appName): app not running"); return }
    let app = AXUIElementCreateApplication(running.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 1.0)
    AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    usleep(300_000)
    guard let windows = AX.elements(app, kAXWindowsAttribute as String),
          windows.indices.contains(windowIndex) else {
        print("\(appName): no window \(windowIndex)")
        return
    }
    let window = windows[windowIndex]
    guard let position = AX.point(window, kAXPositionAttribute as String),
          let size = AX.size(window, kAXSizeAttribute as String) else {
        print("\(appName): no frame")
        return
    }
    let windowFrame = CGRect(origin: position, size: size)

    struct Leaf { let element: AXUIElement; let frame: CGRect; let text: String; let settable: Bool }
    var found: [Leaf] = []
    var visited = 0
    let deadline = Date().addingTimeInterval(4)
    let batch = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute,
                 kAXChildrenAttribute] as CFArray

    func walk(_ element: AXUIElement, depth: Int) {
        guard depth < 50, visited < 40_000, Date() < deadline else { return }
        visited += 1
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(
            element, batch, AXCopyMultipleAttributeOptions(rawValue: 0),
            &values) == .success, let array = values as? [CFTypeRef], array.count == 4
        else { return }
        let role = array[0] as? String
        var frame: CGRect?
        if CFGetTypeID(array[1]) == AXValueGetTypeID(), CFGetTypeID(array[2]) == AXValueGetTypeID() {
            var point = CGPoint.zero; var sz = CGSize.zero
            if AXValueGetValue(array[1] as! AXValue, .cgPoint, &point),
               AXValueGetValue(array[2] as! AXValue, .cgSize, &sz) {
                frame = CGRect(origin: point, size: sz)
            }
        }
        if let frame, frame.width > 1, frame.height > 1,
           !frame.intersects(windowFrame.insetBy(dx: -8, dy: -8)) { return }
        if let role, textRoles.contains(role), let frame,
           frame.width >= 4, frame.height >= 4, frame.intersects(windowFrame),
           let text = AX.string(element, kAXValueAttribute as String),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var flag: DarwinBoolean = false
            _ = AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &flag)
            found.append(Leaf(element: element, frame: frame, text: text, settable: flag.boolValue))
        }
        guard CFGetTypeID(array[3]) == CFArrayGetTypeID(),
              let children = array[3] as? [AXUIElement] else { return }
        for child in children { walk(child, depth: depth + 1) }
    }
    let began = Date()
    walk(window, depth: 0)
    var leaves = found
    leaves.sort { a, b in
        let dy = a.frame.minY - b.frame.minY
        if abs(dy) > SelectRuns.lineTolerance { return dy < 0 }
        return a.frame.minX < b.frame.minX
    }
    let readOnly = leaves.enumerated().filter { !$0.element.settable }
    let runs = SelectRuns.merge(readOnly.map {
        SelectRuns.Leaf(id: $0.offset, text: $0.element.text, frame: $0.element.frame)
    })
    let handles = Dictionary(uniqueKeysWithValues: readOnly.map { ($0.offset, $0.element.element) })
    let harvestMs = Int(Date().timeIntervalSince(began) * 1000)
    print("\(running.localizedName ?? appName): \(leaves.count) leaves → \(runs.count) runs"
          + " + \(leaves.count - readOnly.count) editable · \(visited) nodes · \(harvestMs)ms")

    // Queries drawn from the text itself: for sampled words, seed the core
    // with a prefix and verify the word's own run reports a match with
    // geometry behind it.
    var elements = runs.enumerated().map { SelectCore.Element(id: $0.offset, text: $0.element.text) }
    for (extra, leaf) in leaves.enumerated() where leaf.settable {
        elements.append(SelectCore.Element(id: runs.count + extra, text: leaf.text))
    }
    var sampled = 0, matched = 0, withGeometry = 0, boundsCalls = 0, boundsOK = 0
    var geometryMisses: [String] = []
    for (runIndex, run) in runs.enumerated() {
        let words = run.text.split(whereSeparator: { $0.isWhitespace })
            .filter { $0.count >= 4 && $0.allSatisfy { $0.isLetter || $0.isNumber } }
        guard let word = words.max(by: { $0.count < $1.count }), sampled < 25 else { continue }
        sampled += 1
        var core = SelectCore(elements: elements, alphabet: "asdfghjkl")
        core.seed(query: String(word.prefix(4)).lowercased())
        let hits = core.matches.filter { $0.element == runIndex }
        if hits.isEmpty { continue }
        matched += 1
        var anyGeometry = false
        for hit in hits.prefix(2) {
            for slice in runs[runIndex].slices(of: hit.range) {
                guard let element = handles[slice.leaf] else { continue }
                boundsCalls += 1
                var cfRange = CFRange(location: slice.localRange.location,
                                      length: slice.localRange.length)
                guard let parameter = AXValueCreate(.cfRange, &cfRange) else { continue }
                var out: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(
                    element, kAXBoundsForRangeParameterizedAttribute as CFString,
                    parameter, &out) == .success,
                   let raw = out, CFGetTypeID(raw) == AXValueGetTypeID() {
                    var rect = CGRect.zero
                    if AXValueGetValue(raw as! AXValue, .cgRect, &rect), rect.width > 0 {
                        boundsOK += 1
                        anyGeometry = true
                    }
                }
            }
        }
        if anyGeometry { withGeometry += 1 } else {
            geometryMisses.append(String(word.prefix(18)))
        }
    }
    print("  queries: \(sampled) sampled · \(matched) matched · \(withGeometry) with geometry"
          + " · bounds \(boundsOK)/\(boundsCalls)")
    if !geometryMisses.isEmpty {
        print("  geometry misses: \(geometryMisses.prefix(6).joined(separator: " · "))")
    }
}

// MARK: - Live OCR

/// Capture + recognize a live window, preflight-gated: never prompts.
func runOCRLive(_ args: inout [String]) {
    requireTrust()
    guard CGPreflightScreenCaptureAccess() else {
        print("no Screen Recording permission for this shell — skipping (no prompt)")
        return
    }
    let appName = args.first ?? "Slack"
    guard let running = NSWorkspace.shared.runningApplications.first(where: {
        ($0.localizedName ?? "").localizedCaseInsensitiveContains(appName)
    }) else { print("app not running"); return }
    let cg = CGWindows.list(onScreenOnly: true).first { $0.pid == running.processIdentifier && $0.layer == 0 }
    guard let cg else { print("no on-screen window"); return }
    let began = Date()
    guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, cg.id,
                                              [.boundsIgnoreFraming, .bestResolution]) else {
        print("capture failed")
        return
    }
    let captureMs = Int(Date().timeIntervalSince(began) * 1000)
    let ocrStart = Date()
    let lines = OCRSense.recognize(image: image, windowFrame: cg.bounds)
    let ocrMs = Int(Date().timeIntervalSince(ocrStart) * 1000)
    print("\(running.localizedName ?? "?"): \(lines.count) lines · capture \(captureMs)ms · ocr \(ocrMs)ms · image \(image.width)×\(image.height)")
    for line in lines.prefix(12) {
        print("  [\(Int(line.frame.minX)),\(Int(line.frame.minY))] '\(line.text.prefix(60))'")
    }
}

// MARK: - Select bench

/// Select's bench, against a live window and without touching focus: the
/// window is captured by id, read by both recognition passes, stitched
/// the way the controller stitches, and then every visible word is typed
/// through the auto-anchoring grammar to see where uniqueness lands —
/// on the word, on a wrong word, or off into a span. The numbers that
/// set the two-character floor came from this; run it before changing
/// anything about commit-on-unique.
func runSelectSense(_ args: inout [String]) {
    guard CGPreflightScreenCaptureAccess() else {
        print("no Screen Recording permission for this shell — skipping (no prompt)")
        return
    }
    let listUnits = has("--units", in: &args)
    let appName = args.first ?? "Brave"
    let candidates = CGWindows.list(onScreenOnly: true).filter {
        $0.ownerName.localizedCaseInsensitiveContains(appName) && $0.layer == 0
            && $0.bounds.width > 400 && $0.bounds.height > 300
    }
    guard let cg = candidates.max(by: {
        $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height
    }) else { print("\(appName): no on-screen window"); return }
    guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, cg.id,
                                              [.boundsIgnoreFraming, .bestResolution]) else {
        print("capture failed")
        return
    }
    print("\(cg.ownerName) \(fmt(cg.bounds)) · image \(image.width)×\(image.height)")

    struct Unit { let run: SelectRuns.Run; let lines: [Int: OCRSense.Line]; let frame: CGRect }
    struct World {
        let name: String
        let lines: [OCRSense.Line]
        let units: [Unit]
        var elements: [SelectCore.Element] {
            units.enumerated().map {
                SelectCore.Element(id: $0.offset, text: $0.element.run.text, frame: $0.element.frame)
            }
        }
        func rects(_ match: SelectCore.Match) -> [CGRect] {
            let unit = units[match.element]
            return unit.run.slices(of: match.range).flatMap {
                unit.lines[$0.leaf]?.rects(for: $0.localRange) ?? []
            }
        }
    }
    func build(_ lines: [OCRSense.Line], name: String) -> World {
        var leaves = lines.enumerated().map {
            SelectRuns.Leaf(id: $0.offset, text: $0.element.text, frame: $0.element.frame)
        }
        func reading(_ a: CGRect, _ b: CGRect) -> Bool {
            let dy = a.minY - b.minY
            if abs(dy) > SelectRuns.lineTolerance { return dy < 0 }
            return a.minX < b.minX
        }
        leaves.sort { reading($0.frame, $1.frame) }
        var units: [Unit] = []
        for run in SelectRuns.merge(leaves, windows: [cg.bounds]) {
            let used = Set(run.fragments.map(\.leaf))
            let byLeaf = Dictionary(uniqueKeysWithValues: used.map { ($0, lines[$0]) })
            units.append(Unit(run: run, lines: byLeaf,
                              frame: byLeaf.values.reduce(CGRect.null) { $0.union($1.frame) }))
        }
        units.sort { reading($0.frame, $1.frame) }
        return World(name: name, lines: lines, units: units)
    }

    var worlds: [World] = []
    for level in [OCRSense.Level.fast, .accurate] {
        let began = Date()
        let lines = OCRSense.recognize(image: image, windowFrame: cg.bounds, level: level)
        let ms = Int(Date().timeIntervalSince(began) * 1000)
        let world = build(lines, name: level == .fast ? "fast" : "accurate")
        worlds.append(world)
        print("\(world.name): \(lines.count) lines → \(world.units.count) units · \(ms)ms")
    }
    guard let accurate = worlds.last else { return }
    if listUnits {
        for (index, unit) in accurate.units.enumerated() {
            print("  \(pad(String(index), 3)) \(fmt(unit.frame)) lines=\(unit.lines.count)"
                  + " '\(clip(unit.run.text.replacingOccurrences(of: "\n", with: "⏎"), 70))'")
        }
    }

    // The truth: every distinct word the accurate pass can see, with the
    // rectangles it sits in, so an anchor can be judged by where it lands.
    struct Word { let text: String; let rects: [CGRect] }
    var words: [Word] = []
    var seen = Set<String>()
    for line in accurate.lines {
        var location = 0
        for token in line.text.split(separator: " ", omittingEmptySubsequences: false) {
            let length = (String(token) as NSString).length
            defer { location += length + 1 }
            let text = String(token)
            guard text.count >= 3, text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
                  seen.insert(text.lowercased()).inserted else { continue }
            words.append(Word(text: text, rects: line.rects(for: NSRange(location: location, length: length))))
        }
    }
    print("\(words.count) distinct words on screen; typing each into an auto-anchoring core:")

    enum Verdict: String, CaseIterable {
        case manual = "never auto-fired (a capital would pick)"
        case right = "anchored on the word, tail absorbed"
        case leak = "anchored on the word, tail leaked into the far end"
        case wrong = "anchored on a WRONG word"
        case span = "ran away into a SPAN before the word ended"
    }
    for world in worlds {
        var tally: [Verdict: Int] = [:]
        var firedAfter: [Int: Int] = [:]
        var samples: [Verdict: [String]] = [:]
        for word in words {
            var core = SelectCore(elements: world.elements, alphabet: "asdfghjkl", autoAnchor: true)
            var verdict = Verdict.manual
            var landed = false
            for (index, character) in word.text.lowercased().enumerated() {
                switch core.key(String(character), shift: false) {
                case .anchored:
                    firedAfter[min(index + 1, 6), default: 0] += 1
                    let hit = core.anchor.map(world.rects) ?? []
                    landed = hit.contains { rect in word.rects.contains { $0.intersects(rect) } }
                    verdict = landed ? .right : .wrong
                case .selected:
                    verdict = .span
                case .updated:
                    if verdict == .right, !core.query.isEmpty { verdict = .leak }
                case .none:
                    break
                }
                if verdict == .span { break }
            }
            tally[verdict, default: 0] += 1
            if verdict == .wrong || verdict == .span, samples[verdict, default: []].count < 6 {
                samples[verdict, default: []].append(word.text)
            }
        }
        print("  \(world.name) world:")
        for verdict in Verdict.allCases {
            let count = tally[verdict] ?? 0
            let share = words.isEmpty ? 0 : 100 * count / words.count
            var line = "    \(pad("\(count) (\(share)%)", 11)) \(verdict.rawValue)"
            if let sample = samples[verdict], !sample.isEmpty { line += "  e.g. \(sample.joined(separator: ", "))" }
            print(line)
        }
        let histogram = firedAfter.sorted { $0.key < $1.key }
            .map { "\($0.key)\($0.key == 6 ? "+" : ""):\($0.value)" }.joined(separator: " ")
        if !histogram.isEmpty { print("    fired after N characters — \(histogram)") }
        var singles: [String: Int] = [:]
        for unit in world.units {
            for token in unit.run.text.split(whereSeparator: { $0.isWhitespace }) where token.count == 1 {
                singles[SelectCore.confusionFolded(String(token)).lowercased(), default: 0] += 1
            }
        }
        let lone = singles.filter { $0.value == 1 }.keys.sorted().joined(separator: " ")
        print("    standalone single characters unique on screen: \(lone.isEmpty ? "none" : lone)")
    }
}

// MARK: - Pressables

/// The click door's harvest, measured: the same batched, viewport-pruned
/// walk `HintTargets` runs, plus the one question it does not ask — which
/// elements expose the press action outside the role list it harvests.
/// Read-only, no focus change. The numbers decide whether harvesting by
/// action is worth its cost, app by app.
func runPressables(_ args: inout [String]) {
    requireTrust()
    let appName = args.first ?? "Brave"
    guard let running = NSWorkspace.shared.runningApplications.first(where: {
        ($0.localizedName ?? "").localizedCaseInsensitiveContains(appName)
    }) else { print("\(appName): app not running"); return }
    let app = AXUIElementCreateApplication(running.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 1.0)
    AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    usleep(300_000)
    guard let window = AX.elements(app, kAXWindowsAttribute as String)?.first,
          let position = AX.point(window, kAXPositionAttribute as String),
          let size = AX.size(window, kAXSizeAttribute as String) else {
        print("\(appName): no window frame")
        return
    }
    let windowFrame = CGRect(origin: position, size: size)
    let harvested: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXMenuButton", "AXComboBox", "AXDisclosureTriangle", "AXMenuItem",
        "AXSegment", "AXSwitch", "AXToggle", "AXTextField", "AXTextArea", "AXSearchField",
    ]
    struct Tally { var total = 0; var press = 0; var textless = 0 }
    var byRole: [String: Tally] = [:]
    var visited = 0
    var pruned = 0
    let deadline = Date().addingTimeInterval(4)
    let batch = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute,
                 kAXChildrenAttribute] as CFArray

    func walk(_ element: AXUIElement, depth: Int) {
        guard depth < 28, visited < 2800, Date() < deadline else { return }
        visited += 1
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(
            element, batch, AXCopyMultipleAttributeOptions(rawValue: 0),
            &values) == .success, let array = values as? [CFTypeRef], array.count == 4
        else { return }
        var frame: CGRect?
        if CFGetTypeID(array[1]) == AXValueGetTypeID(), CFGetTypeID(array[2]) == AXValueGetTypeID() {
            var point = CGPoint.zero, sz = CGSize.zero
            if AXValueGetValue(array[1] as! AXValue, .cgPoint, &point),
               AXValueGetValue(array[2] as! AXValue, .cgSize, &sz) {
                frame = CGRect(origin: point, size: sz)
            }
        }
        if let frame, frame.width > 1, frame.height > 1,
           !frame.intersects(windowFrame.insetBy(dx: -8, dy: -8)) { pruned += 1; return }
        if let role = array[0] as? String, let frame,
           frame.width >= 5, frame.height >= 5, frame.intersects(windowFrame) {
            var actions: CFArray?
            AXUIElementCopyActionNames(element, &actions)
            let presses = (actions as? [String] ?? []).contains(kAXPressAction as String)
            var tally = byRole[role] ?? Tally()
            tally.total += 1
            if presses {
                tally.press += 1
                let text = (AX.string(element, kAXTitleAttribute as String) ?? "")
                    + (AX.string(element, kAXDescriptionAttribute as String) ?? "")
                    + (AX.string(element, kAXValueAttribute as String) ?? "")
                if text.trimmingCharacters(in: .whitespaces).isEmpty { tally.textless += 1 }
            }
            byRole[role] = tally
        }
        guard CFGetTypeID(array[3]) == CFArrayGetTypeID(),
              let children = array[3] as? [AXUIElement] else { return }
        for child in children { walk(child, depth: depth + 1) }
    }
    let began = Date()
    walk(window, depth: 0)
    let ms = Int(Date().timeIntervalSince(began) * 1000)
    print("\(running.localizedName ?? appName): \(visited) nodes · \(pruned) subtrees pruned off-window · \(ms)ms")
    print("  \(pad("role", 22)) \(pad("total", 6)) \(pad("press", 6)) \(pad("no text", 8))")
    for (role, tally) in byRole.sorted(by: { $0.value.press > $1.value.press })
    where tally.press > 0 || harvested.contains(role) {
        print("  \(pad(role, 22)) \(pad(String(tally.total), 6)) \(pad(String(tally.press), 6))"
              + " \(pad(String(tally.textless), 8)) \(harvested.contains(role) ? "harvested" : "")")
    }
    let inside = byRole.filter { harvested.contains($0.key) }.values.reduce(0) { $0 + $1.total }
    let outside = byRole.filter { !harvested.contains($0.key) }.values.reduce(0) { $0 + $1.press }
    let textless = byRole.filter { !harvested.contains($0.key) }.values.reduce(0) { $0 + $1.textless }
    print("  harvested by role: \(inside) · pressables outside the role list: \(outside) (\(textless) with no text to type)")
}
