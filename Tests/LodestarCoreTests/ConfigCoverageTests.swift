import XCTest
@testable import LodestarCore

/// The structural guard over `Config.build`.
///
/// `double-tap` shipped with a schema, a default, documentation, a
/// consumer and a fully tested detector — and no parser. Every binding
/// validated, wrote, printed back through `lodestar config`, and did
/// nothing, because nothing connected the section to `Config.doubleTaps`.
/// No test caught it: the detector's own tests injected their bindings by
/// hand, so the missing link was invisible.
///
/// This suite closes that hole from both ends. `testEverySchemaLeafIsCovered`
/// fails when a leaf is added to the schema without a case here, so a new
/// option cannot be shipped unwired. `testEverySchemaLeafReachesConfig`
/// then proves each case actually lands in a `Config` field.
final class ConfigCoverageTests: XCTestCase {
    /// A non-default value for one schema leaf, and the proof it arrived.
    /// Some leaves only validate against others — a web route names a
    /// profile that has to exist — so a probe may carry the context its
    /// leaf needs to be legal.
    private struct Probe {
        let path: [String]
        let value: ConfigValue
        var context: [String: ConfigValue] = [:]
        let landed: (Config) -> Bool
    }

    /// Metadata `build` is right to ignore: both are stamped by `write`
    /// and carry nothing the running app reads.
    private static let metadata: Set<String> = ["$schema", "version"]

    private static let probes: [Probe] = [
        Probe(path: ["lode", "trigger"], value: .string("left-command")) { $0.trigger == .leftCommand },
        Probe(path: ["app", "active-display"], value: .string("focus")) { $0.activeDisplayMode == .focus },
        Probe(path: ["app", "auto-update"], value: .bool(false)) { !$0.autoUpdate },
        Probe(path: ["app", "show-menu-bar"], value: .bool(false)) { !$0.showMenuBar },
        Probe(path: ["app", "start-at-login"], value: .bool(false)) { !$0.startAtLogin },

        Probe(path: ["scroll", "smooth"], value: .bool(false)) { !$0.scrollSmooth },
        Probe(path: ["scroll", "speed"], value: .int(2500)) { $0.scrollSpeed == 2500 },
        Probe(path: ["scroll", "step"], value: .int(120)) { $0.scrollStep == 120 },
        Probe(path: ["select", "copy-on-complete"], value: .bool(true)) { $0.selectCopyOnComplete },

        Probe(path: ["clipboard", "enabled"], value: .bool(false)) { !$0.clipboardEnabled },
        Probe(path: ["clipboard", "max-size-mb"], value: .int(42)) { $0.clipboardMaxBytes == 42_000_000 },
        Probe(path: ["clipboard", "exclude-apps", "com.example.vault"], value: .bool(true)) {
            $0.clipboardExcludedApps.contains("com.example.vault")
        },
        Probe(path: ["clipboard", "exclude", "hunter2"], value: .bool(true)) {
            $0.clipboardExcludePatterns.contains("hunter2")
        },

        Probe(path: ["observations", "enabled"], value: .bool(false)) { !$0.observationsEnabled },
        Probe(path: ["observations", "health"], value: .bool(false)) { !$0.observationsHealth },
        Probe(path: ["guide", "fade"], value: .bool(false)) { !$0.guideFade },
        Probe(path: ["coach", "enabled"], value: .bool(false)) { !$0.coachEnabled },

        Probe(path: ["keys", "50"], value: .string("-")) { $0.keyOverrides[50] == "-" },
        Probe(path: ["graph", "s"], value: .string("Slack")) {
            if case .leaf(.app("Slack")) = $0.graph.resolve(["s"]) { return true }
            return false
        },

        Probe(path: ["web", "fallback"], value: .string("brave:Work")) {
            $0.webFallback == "brave:work"
        },
        Probe(path: ["web", "search-url"], value: .string("https://example.com/?q=%s")) {
            $0.webSearchURL == "https://example.com/?q=%s"
        },
        Probe(path: ["web", "routes", "example.com"], value: .string("brave:Work")) {
            $0.webRoutes["example.com"] == "brave:work"
        },

        Probe(path: ["meetings", "enabled"], value: .bool(true)) { $0.meetingsEnabled },
        Probe(path: ["meetings", "lead-minutes"], value: .int(10)) { $0.meetingsLeadMinutes == 10 },
        Probe(path: ["meetings", "calendars", "Work"], value: .string("brave:Work")) {
            $0.meetingsCalendars["Work"] == "brave:work"
        },
        Probe(path: ["web", "links", "gh", "url"], value: .string("https://github.com")) {
            $0.webLinks.contains { $0.name == "gh" && $0.url == "https://github.com" }
        },
        // A link's profile is a reference; the link needs its url beside it.
        Probe(path: ["web", "links", "gh", "profile"], value: .string("brave:Work"),
              context: ["web": .table(["links": .table(["gh": .table([
                  "url": .string("https://github.com"),
              ])])])]) {
            $0.webLinks.contains { $0.name == "gh" && $0.profileKey == "brave:work" }
        },
        // Routing clicks with nowhere to send the unrouted ones is refused,
        // so this leaf can only be probed with its sibling present.
        Probe(path: ["web", "clicks", "enabled"], value: .bool(true),
              context: ["web": .table(["clicks": .table(["browser": .string("com.brave.Browser")])])]) {
            $0.webHandleClicks
        },
        Probe(path: ["web", "clicks", "browser"], value: .string("com.brave.Browser")) {
            $0.webClickBrowser == "com.brave.Browser"
        },
    ] + Gestures.roster.map { verb in
        Probe(path: ["gestures", verb.name], value: .bool(false)) { config in
            !verb.keys.isEmpty && verb.keys.allSatisfy(config.disabledGestures.contains)
        }
    }

    // MARK: - Coverage

    /// Every addressable leaf in the schema has a probe. A new config
    /// option that nobody wired into `build` fails here.
    func testEverySchemaLeafIsCovered() {
        let declared = Self.leafPaths(of: Config.schema, at: [])
            .subtracting(Self.metadata)
        let probed = Set(Self.probes.map { Self.address($0.path) })
        XCTAssertEqual(declared.subtracting(probed), [],
                       "schema leaves with no probe — wire them into Config.build, then add a case here")
        XCTAssertEqual(probed.subtracting(declared), [],
                       "probes for leaves the schema no longer declares")
    }

    /// Each probe's value actually reaches a `Config` field. This is the
    /// half that would have caught `double-tap`.
    func testEverySchemaLeafReachesConfig() {
        for probe in Self.probes {
            var problems: [String] = []
            let root = Json.merged(defaults: probe.context,
                                   overlay: Self.tree(probe.path, probe.value))
            let config = Config.build(from: root, problems: &problems)
            XCTAssertTrue(problems.isEmpty,
                          "\(Self.address(probe.path)) reported problems: \(problems)")
            XCTAssertTrue(probe.landed(config),
                          "\(Self.address(probe.path)) is declared in the schema but never reaches Config")
        }
    }

    /// A retired section is dropped silently by the migration rather
    /// than reported as unknown: a file written before the retirement
    /// keeps parsing clean.
    func testRetiredSectionsAreDroppedSilently() {
        for retired in [["you", "name"], ["double-tap", "cmd"], ["hints", "letters"],
                        ["hints", "rescan-delay"], ["app", "auto-reload"]] {
            let root = ConfigDefaults.normalized(Self.tree(retired, .string("x")))
            XCTAssertNil(root.value(at: [retired[0]])?.table?[retired[1]],
                         "\(retired.joined(separator: ".")) survived its retirement")
        }
        let hyper = ConfigDefaults.normalized(
            Self.tree(["lode", "trigger"], .string("raw-hyper")))
        XCTAssertEqual(hyper.value(at: ["lode", "trigger"])?.string, "right-command",
                       "the old hyper trigger folds into the default")
    }

    /// The 0.22 registry retirement: every reference written through the
    /// old profiles table is rewritten to `browser:Name` — the display
    /// name's own casing — and the section itself is dropped.
    func testProfileRegistryMigratesReferencesThenDrops() {
        let root: [String: ConfigValue] = [
            "profiles": .table(["brave": .table(["work": .string("Xonar")])]),
            "web": .table([
                "fallback": .string("work"),
                "routes": .table(["x.com": .string("work")]),
                "links": .table(["gh": .table(["url": .string("github.com"),
                                               "profile": .string("work")])]),
            ]),
            "meetings": .table(["calendars": .table(["Work": .string("work")])]),
            "graph": .table(["b": .table(["x": .string("brave:work")])]),
        ]
        let migrated = ConfigDefaults.normalized(root)
        XCTAssertNil(migrated["profiles"], "the registry is gone")
        XCTAssertEqual(migrated.value(at: ["web", "fallback"])?.string, "brave:Xonar")
        XCTAssertEqual(migrated.value(at: ["web", "routes", "x.com"])?.string, "brave:Xonar")
        XCTAssertEqual(migrated.value(at: ["web", "links", "gh", "profile"])?.string, "brave:Xonar")
        XCTAssertEqual(migrated.value(at: ["meetings", "calendars", "Work"])?.string, "brave:Xonar")
        XCTAssertEqual(migrated.value(at: ["graph", "b", "x"])?.string, "brave:Xonar")
    }

    /// A config already speaking the new form passes through untouched:
    /// the migration is idempotent, and most-recent is never a name.
    func testMigrationLeavesModernReferencesAlone() {
        let root: [String: ConfigValue] = [
            "web": .table(["fallback": .string("most-recent"),
                           "routes": .table(["x.com": .string("brave:Xonar")])]),
        ]
        let migrated = ConfigDefaults.normalized(root)
        XCTAssertEqual(migrated.value(at: ["web", "fallback"])?.string, "most-recent")
        XCTAssertEqual(migrated.value(at: ["web", "routes", "x.com"])?.string, "brave:Xonar")
    }

    // MARK: - Helpers

    /// A probe's path as the schema addresses it. Free-table and graph
    /// keys are user-chosen, so the schema declares the slot rather than
    /// the key: a probe for `web.routes.example.com` covers the declared
    /// leaf `web.routes.<key>`.
    private static func address(_ path: [String]) -> String {
        var node = Config.schema
        var out: [String] = []
        for segment in path {
            switch node {
            case .table(let children, _):
                out.append(segment)
                guard let next = children[segment] else { return out.joined(separator: ".") }
                node = next
            case .freeTable(let value, _):
                out.append("<key>")
                node = value
            case .graph:
                // Nested graph letters are all user-chosen, all the way down.
                out.append("<key>")
            case .string, .boolean, .number:
                out.append(segment)
            }
        }
        return out.joined(separator: ".")
    }

    /// Every addressable leaf, with user-chosen keys written `<key>`.
    ///
    /// This must descend THROUGH a free table into its value, or the
    /// guard has a hole exactly where the schema is richest: stopping at
    /// `web.links.<key>` would let `web.links.<key>.profile` be added,
    /// or silently stop being parsed, with nothing failing here.
    private static func leafPaths(of node: SchemaNode, at path: [String]) -> Set<String> {
        switch node {
        case .table(let children, _):
            return children.reduce(into: Set<String>()) { out, entry in
                out.formUnion(leafPaths(of: entry.value, at: path + [entry.key]))
            }
        case .freeTable(let value, _):
            return leafPaths(of: value, at: path + ["<key>"])
        case .graph:
            // Letters all the way down; one slot stands for the whole trie.
            return [(path + ["<key>"]).joined(separator: ".")]
        case .string, .boolean, .number:
            return [path.joined(separator: ".")]
        }
    }

    private static func tree(_ path: [String], _ value: ConfigValue) -> [String: ConfigValue] {
        var node = value
        for key in path.dropFirst().reversed() { node = .table([key: node]) }
        return [path[0]: node]
    }
}
