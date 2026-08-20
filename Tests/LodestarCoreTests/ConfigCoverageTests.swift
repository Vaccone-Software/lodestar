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

    /// The registry `web.fallback` and `web.routes` are checked against.
    private static let braveWork: [String: ConfigValue] =
        ["profiles": .table(["brave": .table(["work": .string("Work")])])]

    /// Metadata `build` is right to ignore: both are stamped by `write`
    /// and carry nothing the running app reads.
    private static let metadata: Set<String> = ["$schema", "version"]

    private static let probes: [Probe] = [
        Probe(path: ["lode", "trigger"], value: .string("raw-hyper")) { $0.trigger == .rawHyper },
        Probe(path: ["app", "active-display"], value: .string("focus")) { $0.activeDisplayMode == .focus },
        Probe(path: ["app", "auto-reload"], value: .bool(true)) { $0.autoReload },
        Probe(path: ["app", "auto-update"], value: .bool(false)) { !$0.autoUpdate },
        Probe(path: ["app", "show-menu-bar"], value: .bool(false)) { !$0.showMenuBar },
        Probe(path: ["app", "start-at-login"], value: .bool(false)) { !$0.startAtLogin },

        Probe(path: ["scroll", "smooth"], value: .bool(false)) { !$0.scrollSmooth },
        Probe(path: ["scroll", "speed"], value: .int(2500)) { $0.scrollSpeed == 2500 },
        Probe(path: ["scroll", "step"], value: .int(120)) { $0.scrollStep == 120 },

        Probe(path: ["hints", "letters"], value: .string("qwer")) { $0.hintLetters == "qwer" },
        Probe(path: ["hints", "rescan-delay"], value: .double(1.5)) { $0.hintRescanDelay == 1.5 },

        Probe(path: ["clipboard", "enabled"], value: .bool(false)) { !$0.clipboardEnabled },
        Probe(path: ["clipboard", "max-size-mb"], value: .int(42)) { $0.clipboardMaxBytes == 42_000_000 },
        Probe(path: ["clipboard", "exclude-apps", "com.example.vault"], value: .bool(true)) {
            $0.clipboardExcludedApps.contains("com.example.vault")
        },
        Probe(path: ["clipboard", "exclude", "hunter2"], value: .bool(true)) {
            $0.clipboardExcludePatterns.contains("hunter2")
        },

        Probe(path: ["observations", "enabled"], value: .bool(false)) { !$0.observationsEnabled },
        Probe(path: ["coach", "enabled"], value: .bool(false)) { !$0.coachEnabled },
        Probe(path: ["you", "name"], value: .string("Ada")) { $0.yourName == "Ada" },

        // The regression this suite exists for.
        Probe(path: ["double-tap", "cmd"], value: .string("scroll")) {
            $0.doubleTaps[.cmd] == .scroll
        },

        Probe(path: ["keys", "50"], value: .string("-")) { $0.keyOverrides[50] == "-" },
        Probe(path: ["graph", "s"], value: .string("Slack")) {
            if case .leaf(.app("Slack")) = $0.graph.resolve(["s"]) { return true }
            return false
        },

        Probe(path: ["profiles", "brave", "work"], value: .string("Work")) {
            $0.browserProfiles["work"]?.browser == .brave
        },
        Probe(path: ["profiles", "chrome", "work"], value: .string("Work")) {
            $0.browserProfiles["work"]?.browser == .chrome
        },
        Probe(path: ["profiles", "edge", "work"], value: .string("Work")) {
            $0.browserProfiles["work"]?.browser == .edge
        },

        Probe(path: ["web", "fallback"], value: .string("work"), context: braveWork) {
            $0.webFallback == "work"
        },
        Probe(path: ["web", "search-url"], value: .string("https://example.com/?q=%s")) {
            $0.webSearchURL == "https://example.com/?q=%s"
        },
        Probe(path: ["web", "routes", "example.com"], value: .string("work"), context: braveWork) {
            $0.webRoutes["example.com"] == "work"
        },

        Probe(path: ["meetings", "enabled"], value: .bool(true)) { $0.meetingsEnabled },
        Probe(path: ["meetings", "lead-minutes"], value: .int(10)) { $0.meetingsLeadMinutes == 10 },
        Probe(path: ["meetings", "calendars", "Work"], value: .string("work"), context: braveWork) {
            $0.meetingsCalendars["Work"] == "work"
        },
        Probe(path: ["web", "links", "gh", "url"], value: .string("https://github.com")) {
            $0.webLinks.contains { $0.name == "gh" && $0.url == "https://github.com" }
        },
        // A link's profile names a registry entry, so it needs one present.
        Probe(path: ["web", "links", "gh", "profile"], value: .string("work"),
              context: Json.merged(defaults: braveWork,
                                   overlay: ["web": .table(["links": .table(["gh": .table([
                                       "url": .string("https://github.com"),
                                   ])])])])) {
            $0.webLinks.contains { $0.name == "gh" && $0.profileKey == "work" }
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
        Probe(path: ["web", "clicks", "trace"], value: .bool(true)) { $0.webTraceClicks },
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

    /// A value the schema forbids is refused rather than absorbed.
    func testUnknownDoubleTapNamesAndVerbsAreReported() {
        var problems: [String] = []
        _ = Config.build(from: Self.tree(["double-tap", "banana"], .string("scroll")), problems: &problems)
        XCTAssertTrue(problems.contains { $0.contains("double-tap.banana") }, "\(problems)")

        problems = []
        let config = Config.build(from: Self.tree(["double-tap", "cmd"], .string("teleport")),
                                  problems: &problems)
        XCTAssertTrue(problems.contains { $0.contains("double-tap.cmd") }, "\(problems)")
        XCTAssertNil(config.doubleTaps[.cmd])
    }

    func testSidedDoubleTapBindingIsAccepted() {
        var problems: [String] = []
        let config = Config.build(from: Self.tree(["double-tap", "right-cmd"], .string("hints")),
                                  problems: &problems)
        XCTAssertTrue(problems.isEmpty, "\(problems)")
        XCTAssertEqual(config.doubleTaps[.rightCmd], .hints)
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
