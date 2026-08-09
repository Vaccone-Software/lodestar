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
        print("A close is a hard identity break: marks/breaths survive one only by best-effort re-matching.")
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
