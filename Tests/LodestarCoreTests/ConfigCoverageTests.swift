import StoicJSON
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
    struct Probe {
        let path: [String]
        let value: ConfigValue
        var context: [String: ConfigValue] = [:]
        let landed: (Config) -> Bool
    }

    static let probes: [Probe] = [
        Probe(path: ["lode", "trigger"], value: .string("left-command")) { $0.trigger == .leftCommand },
        Probe(path: ["lode", "tap"], value: .bool(false)) { !$0.lodeTap },
        Probe(path: ["app", "active-display"], value: .string("focus")) { $0.activeDisplayMode == .focus },
        Probe(path: ["app", "auto-update"], value: .bool(false)) { !$0.autoUpdate },
        Probe(path: ["app", "channel"], value: .string("preview")) { $0.channel == .preview },
        Probe(path: ["app", "sounds"], value: .bool(false)) { !$0.sounds },
        Probe(path: ["app", "show-menu-bar"], value: .bool(false)) { !$0.showMenuBar },
        Probe(path: ["app", "start-at-login"], value: .bool(false)) { !$0.startAtLogin },

        Probe(path: ["scroll", "smooth"], value: .bool(false)) { !$0.scrollSmooth },
        Probe(path: ["scroll", "speed"], value: .int(2500)) { $0.scrollSpeed == 2500 },
        Probe(path: ["scroll", "step"], value: .int(120)) { $0.scrollStep == 120 },
        Probe(path: ["select", "copy-on-complete"], value: .bool(true)) { $0.selectCopyOnComplete },
        Probe(path: ["appearance", "eye-comfort"], value: .bool(false)) { !$0.eyeComfort },

        Probe(path: ["clipboard", "enabled"], value: .bool(false)) { !$0.clipboardEnabled },
        Probe(path: ["clipboard", "max-size-mb"], value: .int(42)) { $0.clipboardMaxBytes == 42_000_000 },
        Probe(path: ["clipboard", "save-to"], value: .string("~/Pictures/Clips")) {
            $0.clipboardSaveFolder == "~/Pictures/Clips"
        },
        Probe(path: ["clipboard", "exclude-apps", "com.example.vault"], value: .bool(true)) {
            $0.clipboardExcludedApps.contains("com.example.vault")
        },
        Probe(path: ["clipboard", "exclude", "hunter2"], value: .bool(true)) {
            $0.clipboardExcludePatterns.contains("hunter2")
        },
        Probe(path: ["app", "units"], value: .string("metric")) {
            $0.units == "metric"
        },
        Probe(path: ["clipboard", "time-zones", "Asia/Tokyo"], value: .bool(true)) {
            $0.clipboardTimeZones == ["Asia/Tokyo"]
        },
        Probe(path: ["draft", "words", "Ghostty"], value: .bool(true)) {
            $0.draftWords.contains("Ghostty")
        },
        Probe(path: ["draft", "input"], value: .string("MacBook Pro Microphone")) {
            $0.draftInput == "MacBook Pro Microphone"
        },
        Probe(path: ["draft", "model"], value: .string("standard")) {
            $0.draftModel == "standard"
        },

        Probe(path: ["observations", "logbook"], value: .bool(false)) { !$0.logbookEnabled },
        Probe(path: ["observations", "logbook-mb"], value: .int(128)) { $0.logbookBytes == 128 << 20 },
        Probe(path: ["observations", "health-mb"], value: .int(2048)) { $0.healthBytes == 2048 << 20 },
        Probe(path: ["observations", "health"], value: .bool(false)) { !$0.observationsHealth },
        Probe(path: ["coach", "enabled"], value: .bool(false)) { !$0.coachEnabled },
        Probe(path: ["coach", "stand"], value: .bool(false)) { !$0.standEnabled },
        Probe(path: ["coach", "stand-after"], value: .int(45)) { $0.standAfterMinutes == 45 },
        Probe(path: ["health", "born"], value: .string("1990")) { $0.healthBorn == 1990 },
        Probe(path: ["health", "exact-keyboards"], value: .bool(true)) { $0.healthExactKeyboards },
        Probe(path: ["health", "hand"], value: .string("left")) { $0.healthHand == "left" },

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
        Probe(path: ["editor", "enabled"], value: .bool(true)) { $0.editorEnabled },
        Probe(path: ["editor", "model"], value: .string("full")) { $0.editorModel == "full" },
        Probe(path: ["editor", "language"], value: .string("en_GB")) { $0.editorLanguage == "en_GB" },
        Probe(path: ["editor", "skip-apps", "com.apple.mail"], value: .bool(true)) {
            $0.editorSkipApps.contains("com.apple.mail")
        },
        Probe(path: ["health", "keyboards", "7504:24926:782ec294", "enter"], value: .string("right thumb")) {
            $0.fingerMap.keyboards["7504:24926:782ec294"]?[.enter] == FingerMap.Placement(.right, .thumb)
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
        let declared = ConfigSchemaWalk.leafAddresses()
        let probed = Set(Self.probes.map { ConfigSchemaWalk.address(of: $0.path) })
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
                          "\(ConfigSchemaWalk.address(of: probe.path)) reported problems: \(problems)")
            XCTAssertTrue(probe.landed(config),
                          "\(ConfigSchemaWalk.address(of: probe.path)) is declared in the schema but never reaches Config")
        }
    }

    /// Every leaf says what it is: the one description the editor's hover,
    /// `lodestar schema` and the settings window's help all read.
    func testEverySchemaLeafIsDocumented() {
        for leaf in ConfigSchemaWalk.leaves() {
            XCTAssertFalse((leaf.doc ?? "").isEmpty, "\(leaf.address) has no description in the schema")
        }
    }

    /// The schema's reading of a document, before it is decoded.
    private func normalized(_ tree: [String: ConfigValue]) -> JSONValue {
        ConfigFile.schema.normalized(ConfigStore.json(tree))
    }

    /// A retired section is dropped silently by the normalization rather
    /// than reported as unknown: a file written before the retirement
    /// keeps parsing clean.
    func testRetiredSectionsAreDroppedSilently() {
        for retired in [["you", "name"], ["double-tap", "cmd"], ["hints", "letters"],
                        ["hints", "rescan-delay"], ["app", "auto-reload"], ["gestures", "tabs"],
                        ["gestures", "back-forward"], ["gestures", "cheat-sheet"],
                        ["appearance", "background"], ["appearance", "accent"], ["web", "clicks", "trace"],
                        ["select", "commit-on-unique"], ["guide", "fade"]] {
            var problems: [String] = []
            _ = Config.build(from: Self.tree(retired, .string("x")), problems: &problems)
            XCTAssertEqual(problems, [], "\(retired.joined(separator: ".")) was reported after its retirement")
            XCTAssertNil(normalized(Self.tree(retired, .string("x"))).value(at: JSONPath(retired.map { .key($0) })),
                         "\(retired.joined(separator: ".")) survived its retirement")
        }
        let hyper = normalized(Self.tree(["lode", "trigger"], .string("raw-hyper")))
        XCTAssertEqual(hyper.value(at: jsonPath("lode", "trigger"))?.string, "right-command",
                       "the old hyper trigger folds into the default")
    }

    /// 0.41 named the two records: a file that switched observations off
    /// keeps the logbook off, and stays valid.
    func testTheOldObservationsSwitchBecomesTheLogbook() {
        let migrated = normalized(Self.tree(["observations", "enabled"], .bool(false)))
        XCTAssertNil(migrated.value(at: jsonPath("observations", "enabled")))
        XCTAssertEqual(migrated.value(at: jsonPath("observations", "logbook"))?.bool, false)
        var problems: [String] = []
        let config = Config.build(from: Self.tree(["observations", "enabled"], .bool(false)), problems: &problems)
        XCTAssertEqual(problems, [])
        XCTAssertFalse(config.logbookEnabled)
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
        let migrated = normalized(root)
        XCTAssertNil(migrated.value(at: jsonPath("profiles")), "the registry is gone")
        XCTAssertEqual(migrated.value(at: jsonPath("web", "fallback"))?.string, "brave:Xonar")
        XCTAssertEqual(migrated.value(at: jsonPath("web", "routes", "x.com"))?.string, "brave:Xonar")
        XCTAssertEqual(migrated.value(at: jsonPath("web", "links", "gh", "profile"))?.string, "brave:Xonar")
        XCTAssertEqual(migrated.value(at: jsonPath("meetings", "calendars", "Work"))?.string, "brave:Xonar")
        XCTAssertEqual(migrated.value(at: jsonPath("graph", "b", "x"))?.string, "brave:Xonar")
        var problems: [String] = []
        let config = Config.build(from: root, problems: &problems)
        XCTAssertEqual(problems, [])
        XCTAssertEqual(config.webFallback, "brave:xonar")
    }

    /// A config already speaking the new form passes through untouched:
    /// the normalization is idempotent, and most-recent is never a name.
    func testMigrationLeavesModernReferencesAlone() {
        let root: [String: ConfigValue] = [
            "web": .table(["fallback": .string("most-recent"),
                           "routes": .table(["x.com": .string("brave:Xonar")])]),
        ]
        let migrated = normalized(root)
        XCTAssertEqual(migrated.value(at: jsonPath("web", "fallback"))?.string, "most-recent")
        XCTAssertEqual(migrated.value(at: jsonPath("web", "routes", "x.com"))?.string, "brave:Xonar")
    }

    // MARK: - Helpers

    private static func tree(_ path: [String], _ value: ConfigValue) -> [String: ConfigValue] {
        var node = value
        for key in path.dropFirst().reversed() { node = .table([key: node]) }
        return [path[0]: node]
    }
}
