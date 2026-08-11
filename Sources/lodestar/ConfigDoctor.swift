import AppKit
import Foundation
import LodestarCore

/// The checks that go beyond parsing: ground truth against the browser,
/// semantic warnings, schema emission. Shared by startup, Reload Config,
/// and `lodestar --check`.
enum ConfigDoctor {
    /// Registry entries the browser doesn't actually have. A browser with
    /// no readable Local State (not installed, never launched) validates
    /// nothing — absence of ground truth is not a verdict.
    static func groundTruthProblems(_ config: Config) -> [String] {
        var problems: [String] = []
        let byBrowser = Dictionary(grouping: config.browserProfiles, by: \.value.browser)
        for (browser, entries) in byBrowser.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let known = ChromiumProfiles.knownDisplayNames(for: browser)
            guard !known.isEmpty else { continue }
            problems += entries
                .filter { !known.contains($0.value.display.lowercased()) }
                .map { "profiles.\(browser.rawValue).\($0.key): \(browser.label) has no profile named '\($0.value.display)'" }
                .sorted()
        }
        return problems
    }

    /// Typo'd app names and dead registry weight.
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

        var referenced = Set<String>()
        for (_, target) in graphTargets(config.graph, prefix: "") {
            if case .browserProfile(let key, _) = target { referenced.insert(key) }
        }
        for link in config.webLinks {
            if let key = link.profileKey { referenced.insert(key) }
        }
        referenced.formUnion(config.webRoutes.values)
        if config.webFallback != "most-recent" { referenced.insert(config.webFallback) }
        for (key, profile) in config.browserProfiles.sorted(by: { $0.key < $1.key })
        where !referenced.contains(key) {
            warnings.append("profiles.\(profile.browser.rawValue).\(key) is declared but never referenced")
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

    let pidPath = Log.directory.appendingPathComponent("lodestar.pid")
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
    lines.append("state: \(store.state.marks.count) marks, \(store.state.breaths.count) breaths, \(store.state.parked.count) parked, version \(store.state.version.map(String.init) ?? "unversioned")")
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
    if fm.fileExists(atPath: Config.file.path) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = Config.directory.appendingPathComponent("lodestar.yaml.backup-\(stamp)")
        do {
            try fm.copyItem(at: Config.file, to: backup)
            print("backed up current config → \(backup.lastPathComponent)")
        } catch {
            print("✕ could not back up the current config (\(error.localizedDescription)) — aborting, nothing changed")
            exit(1)
        }
    }
    do {
        try Config.defaultYaml.write(to: Config.file, atomically: true, encoding: .utf8)
    } catch {
        print("✕ could not write the default config: \(error.localizedDescription)")
        exit(1)
    }
    print("✓ fresh default config written — \(Config.file.path)")
    let pidPath = Log.directory.appendingPathComponent("lodestar.pid")
    if let raw = try? String(contentsOf: pidPath, encoding: .utf8),
       let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
       kill(pid, 0) == 0 {
        kill(pid, SIGUSR2)
        print("✓ reloaded the running instance (pid \(pid))")
    }
    exit(0)
}

/// Remove lodestar from the machine: agent, PATH link, app bundle. User
/// data (config, marks, breaths) stays unless --purge; --dry-run prints
/// the plan and touches nothing. A clean exit is part of professionalism.
func runUninstall(dryRun: Bool, purge: Bool) -> Never {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let agentPlist = home.appendingPathComponent("Library/LaunchAgents/com.vaccone.lodestar.plist")
    let appBundle = home.appendingPathComponent("Applications/lodestar.app")
    let links = ["/opt/homebrew/bin/lodestar", "/usr/local/bin/lodestar"]
    let dataDir = Log.directory

    var plan: [(String, () -> Void)] = []
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
        plan.append(("remove \(dataDir.path) — config, marks, breaths, logs", { try? fm.removeItem(at: dataDir) }))
    }

    if dryRun {
        print("uninstall would:")
        for (step, _) in plan { print("  • \(step)") }
        if !purge { print("  (keeping \(dataDir.path) — add --purge to remove your config and marks)") }
        exit(0)
    }
    for (step, action) in plan {
        print("• \(step)")
        action()
    }
    if !purge {
        print("kept \(dataDir.path) — your config, marks, and breaths survive a reinstall")
        print("(remove it later with: lodestar uninstall --purge, or rm -rf)")
    }
    print("✓ Lodestar uninstalled. The Accessibility entry can be removed in System Settings → Privacy & Security.")
    exit(0)
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
    let pidPath = Log.directory.appendingPathComponent("lodestar.pid")
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
