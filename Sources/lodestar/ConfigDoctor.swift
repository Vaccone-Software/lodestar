import AppKit
import EventKit
import Foundation
import LodestarCore

/// The checks that go beyond parsing: ground truth against the browser,
/// semantic warnings, schema emission. Shared by startup, Reload Config,
/// and `lodestar --check`.
enum ConfigDoctor {
    /// References naming profiles the browser doesn't actually have. A
    /// browser with no readable Local State (not installed, never
    /// launched) validates nothing — absence of ground truth is not a
    /// verdict.
    static func groundTruthProblems(_ config: Config) -> [String] {
        var problems: [String] = []
        // Intent lives in the config, authorization in the machine, and a
        // feature that looks enabled but can never work is exactly what
        // this check exists to say out loud. Found the hard way: 0.21.0
        // asked without the entitlement and macOS declined silently.
        if config.meetingsEnabled {
            let status = EKEventStore.authorizationStatus(for: .event)
            let granted: Bool
            if #available(macOS 14.0, *) { granted = status == .fullAccess }
            else { granted = status == .authorized }
            if !granted, status != .notDetermined {
                problems.append("meetings.enabled is true but calendar access is denied "
                    + "— allow Lodestar under Privacy & Security → Calendars")
            }
        }
        // Each reference checked where it was written, so the finding
        // lands under the row (and the line) that can fix it.
        for (path, key) in profileReferences(config).sorted(by: { $0.0 < $1.0 }) {
            guard let profile = config.browserProfiles[key] else { continue }
            let known = ChromiumProfiles.knownDisplayNames(for: profile.browser)
            guard !known.isEmpty, !known.contains(profile.display.lowercased()) else { continue }
            problems.append("\(path): \(profile.browser.label) has no profile "
                + "named '\(profile.display)'")
        }
        return problems
    }

    /// Every place the config names a profile, as (path, canonical
    /// reference) — the doctor's worklist.
    static func profileReferences(_ config: Config) -> [(String, String)] {
        var references: [(String, String)] = []
        if config.webFallback != "most-recent" {
            references.append(("web.fallback", config.webFallback))
        }
        for (pattern, key) in config.webRoutes {
            references.append(("web.routes.\(pattern)", key))
        }
        for link in config.webLinks {
            if let key = link.profileKey {
                references.append(("web.links.\(link.name).profile", key))
            }
        }
        for (calendar, key) in config.meetingsCalendars {
            references.append(("meetings.calendars.\(calendar)", key))
        }
        for (path, target) in graphTargets(config.graph, prefix: "") {
            if case .browserProfile(let profile) = target {
                references.append(("graph.\(path)", profile.canonical))
            }
        }
        return references
    }

    /// Typo'd app names.
    static func semanticWarnings(_ config: Config, appIndex: AppIndex) -> [String] {
        var warnings: [String] = []
        for (path, name) in appLeaves(config.graph, prefix: "") {
            let exact = appIndex.entries.contains { $0.name.lowercased() == name.lowercased() }
            if !exact {
                if let suggestion = appIndex.entry(named: name), suggestion.name.lowercased() != name.lowercased() {
                    warnings.append("graph.\(path): no app named '\(name)' — did you mean '\(suggestion.name)'?")
                } else {
                    warnings.append("graph.\(path): no installed app named '\(name)'")
                }
            }
        }
        return warnings
    }

    /// Write the editor-facing JSON Schema next to the config, generated
    /// from the same table that validates reloads — they cannot drift.
    static func emitSchema() {
        let json = ConfigSchema.jsonSchema(for: Config.schema, title: "lodestar configuration")
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: Config.directory.appendingPathComponent("lodestar-schema.json"))
    }

    // MARK: - Walks

    private static func appLeaves(_ node: GraphNode, prefix: String) -> [(String, String)] {
        graphTargets(node, prefix: prefix).compactMap { path, target in
            if case .app(let name) = target { return (path, name) }
            return nil
        }
    }

    private static func graphTargets(_ node: GraphNode, prefix: String) -> [(String, GraphTarget)] {
        var out: [(String, GraphTarget)] = []
        for (letter, child) in node.children.sorted(by: { $0.key < $1.key }) {
            let path = prefix.isEmpty ? letter : "\(prefix).\(letter)"
            if let target = child.target, child.children.isEmpty {
                out.append((path, target))
            } else {
                out.append(contentsOf: graphTargets(child, prefix: path))
            }
        }
        return out
    }
}

/// `lodestar --check`: full validation from the command line, no app.
func collectConfigProblems() -> [String] {
    let (config, problems) = Config.load()
    let appIndex = AppIndex()
    appIndex.refresh()
    return problems
        + ConfigDoctor.groundTruthProblems(config)
        + ConfigDoctor.semanticWarnings(config, appIndex: appIndex)
}

func runConfigCheck(json: Bool) -> Never {
    let all = collectConfigProblems()
    ConfigDoctor.emitSchema()
    if json {
        let payload: [String: Any] = ["ok": all.isEmpty, "problems": all,
                                      "config": Config.file.path,
                                      "version": Lodestar.version]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
        exit(all.isEmpty ? 0 : 1)
    }
    print("Lodestar check · \(Config.file.path)")
    if all.isEmpty {
        print("✓ no problems")
        exit(0)
    }
    for problem in all {
        print("• \(problem)")
    }
    exit(1)
}

/// One paste-able report: everything a bug conversation needs to start
/// with evidence instead of archaeology.
func runDiagnose() -> Never {
    var lines: [String] = []
    lines.append("═══ Lodestar diagnose · v\(Lodestar.version) · \(ISO8601DateFormatter().string(from: Date()))")
    lines.append("")

    let pidPath = Paths.pidFile
    if let raw = try? String(contentsOf: pidPath, encoding: .utf8),
       let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
       kill(pid, 0) == 0 {
        lines.append("instance: running (pid \(pid))")
    } else {
        lines.append("instance: NOT RUNNING")
    }
    lines.append("accessibility: \(Permissions.isTrusted ? "trusted" : "NOT TRUSTED")")
    lines.append("")

    lines.append("displays:")
    for info in Displays.ordered() {
        let uuid = Displays.uuid(for: info.id) ?? "?"
        lines.append("  \(info.id) \(Int(info.bounds.width))x\(Int(info.bounds.height)) at (\(Int(info.bounds.minX)),\(Int(info.bounds.minY))) uuid=\(uuid.prefix(8))…")
    }
    lines.append("")

    let problems = collectConfigProblems()
    lines.append("config: \(Config.file.path)")
    lines.append(problems.isEmpty ? "  ✓ valid" : problems.map { "  • \($0)" }.joined(separator: "\n"))
    lines.append("")

    let store = StateStore()
    store.load()
    lines.append("state: \(store.state.breaths.count) breaths, \(store.state.parked.count) parked, version \(store.state.version.map(String.init) ?? "unversioned")")
    if let warning = store.bootWarning { lines.append("  ⚠ \(warning)") }
    lines.append("")

    lines.append("log tail (\(Log.file.path)):")
    if let content = try? String(contentsOf: Log.file, encoding: .utf8) {
        for line in content.split(separator: "\n").suffix(40) {
            lines.append("  \(line)")
        }
    } else {
        lines.append("  (no log)")
    }
    print(lines.joined(separator: "\n"))
    exit(0)
}

/// Back up the current config, write fresh defaults, reload if running.
/// The backup makes it reversible — reset must never cost the user their
/// registry, graph, or links.
func runResetConfig() -> Never {
    let fm = FileManager.default
    try? fm.createDirectory(at: Config.directory, withIntermediateDirectories: true)
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    for source in [Config.file] where fm.fileExists(atPath: source.path) {
        let backup = Config.directory.appendingPathComponent("\(source.lastPathComponent).backup-\(stamp)")
        do {
            try fm.copyItem(at: source, to: backup)
            print("backed up \(source.lastPathComponent) → \(backup.lastPathComponent)")
        } catch {
            print("✕ could not back up \(source.lastPathComponent) (\(error.localizedDescription)) — aborting, nothing changed")
            exit(1)
        }
    }
    do {
        try Config.write(tree: [:])
    } catch {
        print("✕ could not write the default config: \(error.localizedDescription)")
        exit(1)
    }
    print("✓ fresh default config written — \(Config.file.path)")
    let pidPath = Paths.pidFile
    if let raw = try? String(contentsOf: pidPath, encoding: .utf8),
       let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
       kill(pid, 0) == 0 {
        kill(pid, SIGUSR2)
        print("✓ reloaded the running instance (pid \(pid))")
    }
    exit(0)
}

/// Remove lodestar from the machine: agent, PATH link, app bundle. User
/// data (config, breaths) stays unless --purge; --dry-run prints
/// the plan and touches nothing. A clean exit is part of professionalism.
func runUninstall(dryRun: Bool, purge: Bool) -> Never {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let agentPlist = home.appendingPathComponent("Library/LaunchAgents/com.vaccone.lodestar.plist")
    let appBundle = home.appendingPathComponent("Applications/lodestar.app")
    let links = ["/opt/homebrew/bin/lodestar", "/usr/local/bin/lodestar"]
    let roots = [Paths.config, Paths.data]

    var plan: [(String, () -> Void)] = []

    // Give the browser role back first, while we are still here to do it.
    // Removing the app that answers for http and leaving macOS to guess is
    // how someone ends up with links that open nothing.
    let (uninstallConfig, _) = Config.load()
    // The recorded browser, or the system's best other answer. The fallback
    // is not politeness: a config that recorded *us* is dropped to empty at
    // load, and skipping the restore on empty is how somebody ends up with
    // the http handler deleted and every link on the machine opening
    // nothing. `discoverBrowser` never returns Lodestar.
    let restoreTo: URL? = ClickRouter.handoffBrowser(uninstallConfig.webClickBrowser)
        .flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        ?? ClickHandler.discoverBrowser()
    if uninstallConfig.webHandleClicks, let browser = restoreTo {
        let name = browser.deletingPathExtension().lastPathComponent
        plan.append(("restore \(name) as your default browser", {
            let done = DispatchSemaphore(value: 0)
            NSWorkspace.shared.setDefaultApplication(at: browser,
                                                    toOpenURLsWithScheme: "https") { _ in
                NSWorkspace.shared.setDefaultApplication(at: browser,
                                                         toOpenURLsWithScheme: "http") { _ in
                    done.signal()
                }
            }
            _ = done.wait(timeout: .now() + 5)
        }))
    }

    plan.append(("unload login agent (stops the running instance)", {
        let uid = getuid()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["bootout", "gui/\(uid)/com.vaccone.lodestar"]
        try? task.run()
        task.waitUntilExit()
    }))
    if fm.fileExists(atPath: agentPlist.path) {
        plan.append(("remove \(agentPlist.path)", { try? fm.removeItem(at: agentPlist) }))
    }
    for link in links where fm.fileExists(atPath: link) {
        plan.append(("remove \(link)", { try? fm.removeItem(atPath: link) }))
    }
    if fm.fileExists(atPath: appBundle.path) {
        plan.append(("remove \(appBundle.path)", { try? fm.removeItem(at: appBundle) }))
    }
    if purge {
        for root in roots where fm.fileExists(atPath: root.path) {
            plan.append(("remove \(root.path)", { try? fm.removeItem(at: root) }))
        }
    }

    if dryRun {
        print("uninstall would:")
        for (step, _) in plan { print("  • \(step)") }
        if !purge { print("  (keeping \(Paths.config.path) and \(Paths.data.path) — add --purge to remove your config, breaths, and clipboard)") }
        exit(0)
    }
    for (step, action) in plan {
        print("• \(step)")
        action()
    }
    if !purge {
        print("kept \(Paths.config.path) and \(Paths.data.path) — your config, breaths, and clipboard survive a reinstall")
        print("(remove it later with: lodestar uninstall --purge, or rm -rf)")
    }
    print("✓ Lodestar uninstalled. The Accessibility entry can be removed in System Settings → Privacy & Security.")
    exit(0)
}

/// `lodestar config` and friends — the blessed agent lane. Reads serve
/// the effective view (defaults with the file's deviations over them);
/// writes are validated before a byte moves, land sparse and canonical,
/// and reach the running instance through the ordinary reload.
func runConfigVerb(_ arguments: [String]) -> Never {
    /// nil means "there is a file and it did not read" — every caller
    /// refuses to write on nil, which is the point: an unreadable file
    /// must never be silently treated as an empty one, or the next write
    /// replaces the user's whole config with the single key it is setting.
    /// Only a genuinely absent file yields an empty tree.
    func userTree() -> [String: ConfigValue]? {
        guard FileManager.default.fileExists(atPath: Config.file.path) else { return [:] }
        guard let text = try? String(contentsOf: Config.file, encoding: .utf8) else { return nil }
        return try? Json.parse(text)
    }
    /// Reads serve the tree as `build` would see it: the parse-time
    /// migrations applied, so `config get` never hands back a value the
    /// current release would refuse to be given.
    func options(_ tree: [String: ConfigValue]) -> [String: ConfigValue] {
        var out = ConfigDefaults.normalized(tree)
        out.removeValue(forKey: "$schema")
        out.removeValue(forKey: "version")
        return out
    }
    func signalRunningInstance() {
        let pidPath = Paths.pidFile
        if let raw = try? String(contentsOf: pidPath, encoding: .utf8),
           let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           kill(pid, 0) == 0 {
            kill(pid, SIGUSR2)
            print("✓ applied to the running instance (pid \(pid))")
        }
    }

    guard let tree = userTree() else {
        print("✕ the config does not parse — run: lodestar check")
        exit(1)
    }

    switch arguments.first {
    case nil:
        print(Json.emit(Json.merged(defaults: ConfigDefaults.tree, overlay: options(tree))), terminator: "")
        exit(0)

    case "get":
        guard arguments.count == 2 else {
            print("usage: lodestar config get <dotted.path>")
            exit(64)
        }
        let path = ConfigSchema.path(for: arguments[1], in: Config.schema)
        let effective = Json.merged(defaults: ConfigDefaults.tree, overlay: options(tree))
        guard let value = effective.value(at: path) else {
            print("✕ nothing at \(arguments[1])")
            exit(1)
        }
        print(Json.emitFragment(value))
        exit(0)

    case "set", "unset":
        guard let current = userTree() else {
            print("✕ the config does not parse — fix it (lodestar check) before writing")
            exit(1)
        }
        // The mutation is kept as a transform so the write below can run
        // it against the tree Config.edit re-reads under its own lock:
        // writing the pre-read `updated` tree instead would silently
        // revert any key another process changed in between.
        let updated: [String: ConfigValue]
        let transform: ([String: ConfigValue]) -> [String: ConfigValue]
        if arguments.first == "set" {
            guard arguments.count == 3 else {
                print("usage: lodestar config set <dotted.path> <value>")
                exit(64)
            }
            let path = ConfigSchema.path(for: arguments[1], in: Config.schema)
            guard let next = Json.setting(current, path: path, to: Json.parseFragment(arguments[2])) else {
                print("✕ a value already sits on that path — unset it first")
                exit(1)
            }
            updated = next
            transform = { fresh in
                Json.setting(fresh, path: path, to: Json.parseFragment(arguments[2])) ?? fresh
            }
        } else {
            guard arguments.count == 2 else {
                print("usage: lodestar config unset <dotted.path>")
                exit(64)
            }
            let path = ConfigSchema.path(for: arguments[1], in: Config.schema)
            switch Json.removing(current, path: path) {
            case .removed(let next):
                updated = next
            case .absent:
                print("✓ \(arguments[1]) is already the default")
                exit(0)
            case .blocked(let prefix):
                // Not the same answer as "already the default": the key is
                // still in the file, and saying otherwise sent scripted
                // callers away with an exit code that meant success.
                print("✕ \(arguments[1]) is not reachable — a value sits at \(prefix)")
                exit(1)
            }
            transform = { fresh in
                if case .removed(let next) = Json.removing(fresh, path: path) { return next }
                return fresh
            }
        }
        // Refuse any write that introduces a problem the file didn't
        // already have; pre-existing complaints stay the user's business.
        let before = ConfigSchema.validate(options(current), against: Config.schema)
        let after = ConfigSchema.validate(options(updated), against: Config.schema)
        let introduced = after.filter { !before.contains($0) }
        guard introduced.isEmpty else {
            for problem in introduced { print("✕ \(problem)") }
            print("nothing written")
            exit(1)
        }
        do {
            try Config.edit { fresh in transform(fresh) }
        } catch {
            print("✕ could not write the config: \(error)")
            exit(1)
        }
        if arguments.first == "set" {
            print("✓ \(arguments[1]) = \(Json.emitFragment(Json.parseFragment(arguments[2])))")
        } else {
            print("✓ \(arguments[1]) → default")
        }
        signalRunningInstance()
        exit(0)

    default:
        print("unknown config command: \(arguments[0])")
        print("usage: lodestar config [get <path> | set <path> <value> | unset <path>]")
        exit(64)
    }
}

/// The graph's valid vocabulary: every app name the index can resolve,
/// exactly as it should be written in the config.
func runApps() -> Never {
    let appIndex = AppIndex()
    appIndex.refresh()
    for name in appIndex.entries.map(\.name).sorted(by: { $0.lowercased() < $1.lowercased() }) {
        print(name)
    }
    exit(0)
}

/// SIGUSR2 to the running instance — apply the config without the menu.
func runReload() -> Never {
    let pidPath = Paths.pidFile
    guard let raw = try? String(contentsOf: pidPath, encoding: .utf8),
          let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
          kill(pid, 0) == 0 else {
        print("✕ Lodestar is not running")
        exit(1)
    }
    let problems = collectConfigProblems()
    kill(pid, SIGUSR2)
    if problems.isEmpty {
        print("✓ reloaded (pid \(pid))")
        exit(0)
    }
    print("⚠ reloaded (pid \(pid)) with problems:")
    for problem in problems { print("• \(problem)") }
    exit(1)
}

/// `lodestar observations` — what Lodestar has noticed about how you reach
/// things, printed plainly, because a store you cannot read is a store you
/// cannot consent to. It records how you got places — timings, counts, app
/// names, and the hosts you opened — never a window title, a URL path, a
/// clipboard, or a typed query beyond its first two characters.
/// `engine` dumps the fitted models behind the findings, for eyes that
/// want the working shown.
func runObservations(clear: Bool, engine: Bool) -> Never {
    Log.stdoutEnabled = false
    let store = ObservationStore()
    if clear {
        store.clear()
        // A running instance holds its own copy; tell it, or it saves that copy
        // back over the deletion within seconds.
        store.requestClear()
        print("✓ observations cleared (\(ObservationStore.defaultFile.path))")
        exit(0)
    }
    store.load(compacting: false)
    let o = store.observations
    let events = store.log.readAll()
    let (config, _) = Config.load()

    guard o.updated != .distantPast else {
        print("no observations yet · \(ObservationStore.defaultFile.path)")
        print("set observations.enabled to false to keep it that way.")
        exit(0)
    }

    let bound = config.graph.leaves()
    // The saved breath paths, read without a StateStore: its load() takes
    // a backup on the way through, and a reporting process must never
    // write beside the running instance.
    let breathPaths: [String] = {
        guard let data = try? Data(contentsOf: StateStore.defaultFile),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return [] }
        return state.breaths.map(\.path)
    }()
    // The same context the app hands its coach, or the report would
    // disagree with the chip about what stands.
    let context = Advisor.Context(
        observations: o, events: events,
        leaves: bound.map { Advisor.Leaf(chain: $0.chain, label: $0.target.label,
                                         value: $0.target.configValue) },
        webRoutes: config.webRoutes,
        profileKeys: Dictionary(config.browserProfiles.map {
            ($0.value.reference, $0.value.reference)
        }, uniquingKeysWith: { first, _ in first }),
        meetingsEnabled: config.meetingsEnabled,
        breathPaths: breathPaths
    )

    if engine {
        runObservationsEngine(context)
    }

    let days = max(1, Int(Date().timeIntervalSince(o.since) / 86400))
    print("observations · \(days) day\(days == 1 ? "" : "s") · \(events.count) events"
        + " · nothing here leaves this machine")
    // The archive is part of what is kept, so it is part of what is shown.
    if let data = try? Data(contentsOf: store.rollupFile) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let archive = try? decoder.decode(Rollup.self, from: data),
           !archive.months.isEmpty {
            let keys = archive.months.keys.sorted()
            print("archive · \(keys.count) month\(keys.count == 1 ? "" : "s")"
                + " (\(keys.first!) … \(keys.last!)) · \(store.rollupFile.lastPathComponent)"
                + " · cleared by observations clear")
        }
    }
    print("")

    func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }
    func seconds(_ value: TimeInterval) -> String { String(format: "%.2fs", value) }

    if !bound.isEmpty {
        print("addresses")
        for leaf in bound.sorted(by: { $0.chain.joined() < $1.chain.joined() }) {
            let shown = "lode " + leaf.chain.map { $0.uppercased() }.joined(separator: " ")
            let record = o.addresses[Observations.key(leaf.chain)]
            var columns = [pad(shown, 16), pad(leaf.target.label, 18)]
            columns.append(pad("\(record?.completions ?? 0) uses", 10))
            if let fluency = o.fluency(leaf.chain, pos: 0) {
                columns.append(pad(seconds(fluency.median), 8))
            } else {
                columns.append(pad("", 8))
            }
            if let blind = o.blindRate(leaf.chain) {
                columns.append(pad("\(Int(blind * 100))% blind", 10))
            } else {
                columns.append(pad("", 10))
            }
            var notes: [String] = []
            if let record, record.abandons > 0 { notes.append("\(record.abandons) abandoned") }
            if let record, record.wrongKeys > 0 {
                var note = "\(record.wrongKeys) wrong keys"
                if let (letter, count) = record.confusion.max(by: { $0.value < $1.value }),
                   count > 1 {
                    note += " (mostly \(letter.uppercased()))"
                }
                notes.append(note)
            }
            print("  " + columns.joined() + notes.joined(separator: " · "))
        }
        print("")
    }

    let apps = o.apps.sorted { $0.value.reaches > $1.value.reaches }.prefix(15)
    if !apps.isEmpty {
        print("apps")
        for (name, record) in apps {
            var line = pad("  " + name, 26)
            line += pad("graph \(record.graph)", 12) + pad("launcher \(record.searcher)", 14)
            if let share = o.routeShare(name) {
                line += pad("\(Int(share * 100))% searched", 15)
            }
            if let launcher = o.launcherSeconds(name) {
                line += pad(seconds(launcher) + " a search", 16)
            } else if let typed = o.medianTyped(name) {
                line += pad("\(typed) chars", 10)
            }
            print(line)
        }
        print("")
    }

    let hosts = o.hosts.sorted { $0.value.count > $1.value.count }.prefix(8)
    if !hosts.isEmpty {
        print("hosts")
        for (host, record) in hosts {
            var line = pad("  " + host, 30) + pad("\(record.count) opens", 10)
            if let (profile, hits) = record.profiles.max(by: { $0.value < $1.value }) {
                line += "\(profile) \(hits)/\(record.count)"
            }
            print(line)
        }
        print("")
    }

    let pairs = Transitions.strongPairs(o.transitions).prefix(5)
    if !pairs.isEmpty {
        print("moves")
        for pair in pairs {
            print("  " + pad("\(pair.from) → \(pair.to)", 34)
                + String(format: "%.0f× · lift %.1f", pair.count, pair.lift))
        }
        print("")
    }

    // How focus moved: Lodestar's own routes against the system's roads.
    // The split the transition matrix could never make on its own.
    if let roads = o.focusRoads, !roads.isEmpty {
        let total = max(1, roads.values.reduce(0, +))
        let list = roads.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .map { "\($0.key) \($0.value * 100 / total)%" }
        print("roads · how focus moved · \(total) change\(total == 1 ? "" : "s")")
        print("  " + list.joined(separator: " · "))
        print("")
    }

    if !o.verbs.isEmpty {
        let list = o.verbs.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }
        print("verbs")
        print("  " + list.joined(separator: " · "))
        print("")
    }

    if !o.selects.isEmpty {
        print("select")
        for (name, record) in o.selects.sorted(by: { $0.value.completed + $0.value.abandoned
            > $1.value.completed + $1.value.abandoned }).prefix(10) {
            var line = pad("  " + name, 26)
            line += pad("\(record.completed) selected", 14)
            if record.abandoned > 0 { line += pad("\(record.abandoned) abandoned", 14) }
            let total = max(1, record.ocr + record.ax)
            line += pad("\(Int(Double(record.ocr) / Double(total) * 100))% pixels", 12)
            if let seconds = record.seconds.mean {
                line += String(format: "%.1fs a span", seconds)
            }
            print(line)
        }
        print("")
    }

    // The draft, as counts: how often each door opens, how it ends, how
    // much was said, and the two waits — to the first word, to the first
    // key. Never the text; there is none in the record to print.
    let cutoff = Date().addingTimeInterval(-28 * 86_400)
    let drafts = events.filter { $0.kind == .draft && $0.t >= cutoff && $0.action != "empty" }
    if !drafts.isEmpty {
        let days = max(1, Set(drafts.map { Calendar.current.startOfDay(for: $0.t) }).count)
        let spoke = drafts.filter { $0.source == "speak" }.count
        let pasted = drafts.filter { $0.action == "pasted" || $0.action == "replaced" }.count
        let copied = drafts.filter { $0.action == "copied" }.count
        let cancelled = drafts.filter { $0.action == "cancelled" }.count
        let words = drafts.reduce(0) { $0 + ($1.words ?? 0) }
        let typed = drafts.reduce(0) { $0 + ($1.typed ?? 0) }
        var line = pad("draft", 10)
        line += pad(String(format: "%.1f/day", Double(drafts.count) / Double(days)), 10)
        line += pad("\(spoke) spoken · \(drafts.count - spoke) edited", 24)
        line += pad("\(pasted) pasted", 12)
        if copied > 0 { line += pad("\(copied) copied", 11) }
        if cancelled > 0 { line += pad("\(cancelled) cancelled", 14) }
        print(line)
        var detail = pad("", 10)
        detail += pad(String(format: "%.0f words/day", Double(words) / Double(days)), 16)
        detail += pad("\(typed) typed", 12)
        let firstWords = drafts.compactMap(\.firstWord).sorted()
        if !firstWords.isEmpty {
            detail += pad(String(format: "%.1fs to the first word", firstWords[firstWords.count / 2]), 26)
        }
        let seconds = drafts.compactMap(\.seconds).sorted()
        if !seconds.isEmpty {
            detail += String(format: "%.0fs a draft", seconds[seconds.count / 2])
        }
        print(detail)
        print("")
    }

    // The hands' pulse, described and never judged: the mirror's whole
    // grammar. Four weeks, because a trend needs a baseline and a month
    // is the shortest span a rhythm shows in.
    if let health = Health.summary(events: events, days: 28) {
        print("health · last \(health.days) active day\(health.days == 1 ? "" : "s")"
            + " · counts and moments only, never which keys")
        var input = pad("  input", 10)
        let keysPerDay = Double(health.keys) / Double(max(1, health.days))
        input += pad(keysPerDay >= 1000
                     ? String(format: "%.1fk keys/day", keysPerDay / 1000)
                     : String(format: "%.0f keys/day", keysPerDay), 16)
        if let rate = health.correctionRate {
            input += pad(String(format: "%.1f%% corrections", rate * 100), 20)
        }
        if let pointer = health.pointerShare {
            input += String(format: "pointer share %d%%", Int(pointer * 100))
        }
        print(input)
        // The correction key by burst: a single is a typo, a run of five
        // or more is a sentence being retaken. Different budgets — only
        // the second is anything a product should try to claim.
        if health.backspaceRunKeys.reduce(0, +) > 0,
           let typo = health.typoShare, let revision = health.revisionShare {
            var runs = pad("  backspace", 10)
            runs += pad(String(format: "%.0f%% single", typo * 100), 16)
            runs += pad(String(format: "%.0f%% in runs of 2 to 4", max(0, 1 - typo - revision) * 100), 26)
            runs += String(format: "%.0f%% in runs of 5 or more · revision, not typo",
                           revision * 100)
            print(runs)
        }
        var rhythm = pad("  rhythm", 10)
        rhythm += pad(String(format: "%.1fh active/day",
                             Double(health.activeMinutes) / 60 / Double(max(1, health.days))), 18)
        rhythm += pad("longest stretch \(health.longestStretchMinutes)m", 24)
        if let mean = health.interKeyMean {
            rhythm += String(format: "inter-key %.0fms", mean * 1000)
        }
        print(rhythm)
        if let peak = health.hourMinutes.enumerated().max(by: { $0.element < $1.element }),
           peak.element > 0 {
            let late = health.hourMinutes[23] + health.hourMinutes[0]
                + health.hourMinutes[1] + health.hourMinutes[2]
            let total = max(1, health.activeMinutes)
            print(pad("  shape", 10)
                + pad(String(format: "peak %02d:00", peak.offset), 14)
                + "late night \(late * 100 / total)% (23:00 to 03:00)")
        }
        // The mouse by app: where the clicks go and what they land on,
        // by role class. Described, not judged — the pool's size is the
        // fact, and what to do about it is a later release's question.
        if let clicks = Health.clicks(events: events, days: 28), clicks.clicks > 0 {
            var line = pad("  clicks", 10)
            line += pad(String(format: "%.0f/day", Double(clicks.clicks) / Double(max(1, clicks.days))), 10)
            if let trips = clicks.tripShare {
                line += pad(String(format: "%d%% hand trips", Int(trips * 100)), 18)
            }
            line += clicks.ranked.prefix(3).map { app, record in
                let share = record.clicks * 100 / max(1, clicks.clicks)
                let roles = record.roles.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
                    .prefix(2)
                    .map { "\($0.key) \($0.value * 100 / max(1, record.clicks))" }
                    .joined(separator: " · ")
                return "\(app) \(share)%" + (roles.isEmpty ? "" : " (\(roles))")
            }.joined(separator: "  ")
            print(line)
        }
        print("")
    }

    // The product's own score: actual input cost against its computed
    // floor, per channel. A channel at 1.0 has nothing left to give;
    // everything above it is backlog. "measured" lines were timed by the
    // instrument; the others are counts priced by KLM constants at this
    // hand's own inter-key gap.
    let overheadHealth = Health.summary(events: events, days: 28)
    let overheadClicks = Health.clicks(events: events, days: 28)
    let overheadLatency = LatencyModel.fit(
        samples: LatencyModel.samples(from: context.events))
    let overhead = Overhead.compute(events: events, latency: overheadLatency,
                                    health: overheadHealth, clicks: overheadClicks)
    if !overhead.channels.isEmpty {
        func daily(_ secondsPerDay: Double) -> String {
            secondsPerDay >= 120
                ? String(format: "%.1fm/day", secondsPerDay / 60)
                : String(format: "%.0fs/day", secondsPerDay)
        }
        print("overhead · actual ÷ computed floor · 1.0 has nothing left to give")
        for channel in overhead.channels {
            var line = pad("  " + channel.name, 14)
            line += pad(String(format: "%.0f/day", channel.actsPerDay), 10)
            line += pad(daily(channel.actualSecondsPerDay), 12)
            line += pad("floor " + daily(channel.floorSecondsPerDay), 18)
            if let ratio = channel.ratio {
                line += pad(String(format: "%.1f×", ratio), 8)
            }
            line += channel.measured ? "measured" : "priced from counts"
            print(line)
        }
        if let overheadClicks {
            let pool = Overhead.pointingBacklog(clicks: overheadClicks)
            if !pool.isEmpty {
                print("  pointing pool · ranked by cost · what the keyboard could learn next")
                for entry in pool {
                    print(pad("    \(entry.app) · \(entry.role)", 34)
                        + pad(String(format: "%.0f/day", entry.clicksPerDay), 10)
                        + "≈" + daily(entry.secondsPerDay))
                }
            }
        }
        print("")
    }

    // The instrument observing itself: what its own warmups cost, so a
    // regression in the instrument surfaces the way one in the hand does.
    let warmups = events.filter { $0.kind == .latency }
    if !warmups.isEmpty {
        var bySurface: [String: [Double]] = [:]
        for event in warmups {
            guard let surface = event.verb, let s = event.seconds else { continue }
            bySurface[surface, default: []].append(s)
        }
        let line = bySurface.sorted { $0.key < $1.key }.compactMap { surface, samples -> String? in
            let sorted = samples.sorted()
            guard !sorted.isEmpty else { return nil }
            return String(format: "%@ %.2fs median (n=%d)", surface,
                          sorted[sorted.count / 2], sorted.count)
        }.joined(separator: " · ")
        if !line.isEmpty {
            print("latency")
            print("  " + line)
            print("")
        }
    }

    // The coach's ledger — everything it has said and what became of it —
    // then its pacing, so "am I missing chips, or is it quiet" is
    // answerable from here instead of by feel.
    let recommendations = Advisor.recommend(context)
    if !o.ledger.isEmpty || !recommendations.isEmpty {
        print("coach")
        for entry in o.ledger.sorted(by: { $0.lastOfferedWeek > $1.lastOfferedWeek })
            .prefix(10) {
            var line = pad("  \(entry.kind) \(entry.target)", 34) + pad(entry.status, 10)
            line += pad("\(entry.offers) offer\(entry.offers == 1 ? "" : "s")", 10)
            // Stood its whole minute and got no answer: the one thing that
            // separates passed over from never readable, so it is worth a
            // column of its own.
            let ignores = entry.ignores ?? 0
            line += pad(ignores > 0 ? "\(ignores) stood out" : "", 13)
            if entry.adoptedWeek != nil, entry.status != "accepted" {
                line += "adopted by hand"
            } else if entry.predictedSecondsPerWeek > 0 {
                line += String(format: "≈%.0fs/week promised", entry.predictedSecondsPerWeek)
            }
            print(line)
        }
        func relative(_ interval: TimeInterval) -> String {
            if interval < 3600 { return "\(max(1, Int(interval / 60)))m" }
            if interval < 86_400 { return "\(Int(interval / 3600))h" }
            return "\(Int(interval / 86_400))d"
        }
        var pacing: [String] = []
        if let spoke = o.ledger.map(\.lastOfferedAt).filter({ $0 != .distantPast }).max() {
            pacing.append("last spoke \(relative(Date().timeIntervalSince(spoke))) ago")
        } else {
            pacing.append("has not spoken yet")
        }
        if let standing = Coach.standingOffer(observations: o,
                                              recommendations: recommendations,
                                              now: Date()) {
            pacing.append("standing: \(Coach.chip(for: standing, observations: o).headline)")
            let wait = Coach.showingWait(observations: o, rec: standing, now: Date())
            pacing.append(wait > 0 ? "may show in \(relative(wait)) at the earliest"
                                   : "free to show at the next quiet boundary")
        } else if Coach.slotBusy(observations: o, now: Date()) {
            pacing.append("nothing standing · a habit is still being learned")
        } else {
            pacing.append("nothing standing · no finding has cleared the gates")
        }
        print("  " + pacing.joined(separator: " · "))
        print("")
    }

    // The engine's verdicts: each survives a posterior-probability gate and
    // false-discovery control across everything tested, so a line here has
    // earned its place. Silence stays the honest answer until then.
    if recommendations.isEmpty {
        print("nothing worth saying yet. Silence is the honest answer until the numbers are in.")
    } else {
        print("worth looking at")
        for rec in recommendations.prefix(12) {
            var line = "  " + rec.detail
            if rec.secondsPerWeek > 0 {
                line += String(format: "  (≈%.0fs/week, p %.2f)", rec.secondsPerWeek,
                               rec.probability)
            }
            print(line)
        }
    }
    print("")
    print(ObservationStore.defaultFile.path)
    exit(0)
}

/// `lodestar observations engine` — the fitted models, shown working. A
/// development surface: the product never shows this, the way a watch never
/// shows its escapement.
func runObservationsEngine(_ context: Advisor.Context) -> Never {
    let o = context.observations
    print("engine · \(context.events.count) events in the ring")
    print("")

    func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    if let latency = LatencyModel.fit(samples: LatencyModel.samples(from: context.events)) {
        print("latency model (log-seconds)")
        let names = ["intercept", "trigger", "same hand", "same finger", "row distance"]
        for (name, beta) in zip(names, latency.coefficients) {
            print("  " + pad(name, 14) + String(format: "%+.3f", beta))
        }
        print(String(format: "  residual sd    %.3f on %d samples", latency.residualSD,
                     latency.samples))
        print("  fluency residuals (shrunk; + is slower than the chain explains)")
        for (address, entry) in latency.fluency.sorted(by: { $0.value.residual > $1.value.residual }) {
            print("    " + pad(address, 10)
                + String(format: "%+.3f  (n=%d)", entry.residual, entry.n))
        }
        print("")
    } else {
        print("latency model: not enough samples yet")
        print("")
    }

    if let curve = LearningCurve.fit(observations: o) {
        print(String(format: "learning curves · pooled α %.2f · typical bill %.0fs",
                     curve.alpha, curve.typicalLearningCost()))
        for (address, fit) in curve.fits.sorted(by: { $0.key < $1.key }) {
            print("  " + pad(address, 10)
                + String(format: "asymptote %.2fs · remaining %.0fs · n=%d",
                         exp(fit.asymptote), fit.remainingSeconds(alpha: curve.alpha), fit.n))
        }
        print("")
    }

    if let mixture = RecallMixture.fit(observations: o) {
        print(String(format: "recall mixture · fast %.2fs±%.2f · slow %.2fs±%.2f · %d%% recall",
                     exp(mixture.fastMean), mixture.fastSD, exp(mixture.slowMean),
                     mixture.slowSD, Int(mixture.weight * 100)))
        for (address, pi) in mixture.ownership.sorted(by: { $0.value > $1.value }) {
            print("  " + pad(address, 10) + "owned \(Int(pi * 100))%")
        }
        print("")
    }

    let now = Date()
    let demands = o.apps.keys.compactMap { app -> (String, Demand)? in
        let counts = Demand.weeklyCounts(app: app, events: context.events, now: now)
        guard let demand = Demand.fit(weeklyCounts: counts) else { return nil }
        return (app, demand)
    }.sorted { $0.1.perWeek > $1.1.perWeek }
    if !demands.isEmpty {
        print("demand (reaches/week, fano > 2 is a project not a habit)")
        for (app, demand) in demands.prefix(12) {
            print("  " + pad(app, 24)
                + String(format: "%.1f ± %.1f · fano %.1f · %d weeks",
                         demand.perWeek, demand.se, demand.fano, demand.weeks))
        }
        print("")
    }

    let stationary = Transitions.stationary(o.transitions)
        .sorted { $0.value > $1.value }.prefix(8)
    if !stationary.isEmpty {
        print("attention at equilibrium")
        for (app, share) in stationary {
            print("  " + pad(app, 24) + "\(Int(share * 100))%")
        }
        print("")
    }
    let clusters = Transitions.clusters(o.transitions)
    if !clusters.isEmpty {
        print("working sets")
        for cluster in clusters.prefix(4) {
            print(String(format: "  %@  (weight %.0f)",
                         cluster.apps.joined(separator: " + "), cluster.weight))
        }
        print("")
    }

    // Which app comes next, every strategy scored in shadow over the real
    // focus stream — the table predicted warming picks its model from.
    let tuneBegan = Date()
    let tuning = NextApp.tune(events: context.events)
    let tuneSeconds = Date().timeIntervalSince(tuneBegan)
    let scoreBegan = Date()
    let nextApp = NextApp.evaluate(events: context.events, tuning: tuning)
    let scoreSeconds = Date().timeIntervalSince(scoreBegan)
    if let switches = nextApp.first?.switches {
        print("next app (hit rate of the top 1 · 2 · 3 predictions, over \(switches) switches)")
        for score in nextApp {
            print("  " + pad(score.strategy.rawValue, 10)
                + score.hits.map { String(format: "%3.0f%%", $0 * 100) }.joined(separator: "  "))
        }
        print(String(format: "  tuned: chain weight %.1f · recency decay %.2f · %@ · tuned in %.2fs, scored in %.2fs",
                     tuning.weight, tuning.decay,
                     tuning.secondOrder ? "second order" : "first order",
                     tuneSeconds, scoreSeconds))
        print("  warmer uses \(NextApp.best(nextApp).rawValue)")
        print("")
    }

    let scores = Shadow.evaluate(events: context.events)
    if !scores.isEmpty {
        print("shadow scores (mean log-density, one step ahead; higher is better)")
        for score in scores {
            print("  " + pad(score.model, 10)
                + String(format: "%+.3f over %d predictions", score.meanLogScore,
                         score.predictions))
        }
        let earned = Shadow.geometryEarnedInfluence(scores)
        print("  geometry model \(earned ? "has earned" : "has not yet earned") influence")
        print("")
    }

    let recommendations = Advisor.recommend(context)
    print("recommendations (post-gate: P(net benefit) ≥ 0.9, BH q=0.1)")
    if recommendations.isEmpty {
        print("  none survive the gates yet")
    }
    for rec in recommendations {
        print(String(format: "  [%@] %@", rec.kind.rawValue, rec.detail))
        print(String(format: "        ≈%.0fs/week · p %.2f", rec.secondsPerWeek,
                     rec.probability))
        for line in rec.evidence { print("        · " + line) }
    }
    print("")
    exit(0)
}
