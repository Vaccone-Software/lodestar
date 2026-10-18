import Foundation
import StoicJSON
import StoicSchema
import XCTest
@testable import LodestarCore

/// `ConfigFile.schema` as the one declaration of the file: its defaults, its
/// layout (the order every earlier release wrote), how it reads the old
/// spellings, and the gestures it generates from the roster.
final class ConfigFileSchemaTests: XCTestCase {
    // MARK: - The defaults

    /// Every default, as the tree of defaults every earlier release carried in
    /// its `ConfigDefaults`, written out again: the field initialisers of
    /// `ConfigFile` are today's defaults exactly. (`health.exact-keyboards` is
    /// the one addition: it was false by `Config`'s own declaration and is
    /// now said here, so `lodestar config` lists it.)
    func testTheDefaultsAreTodaysDefaults() {
        var expected: [String: ConfigValue] = [
            "lode": .table(["trigger": .string("right-command"), "tap": .bool(true)]),
            "gestures": .table(Dictionary(uniqueKeysWithValues: Gestures.roster.map { ($0.name, ConfigValue.bool(true)) })),
            "app": .table([
                "auto-update": .bool(true), "channel": .string("stable"), "sounds": .bool(true),
                "start-at-login": .bool(true), "show-menu-bar": .bool(true),
                "active-display": .string("pointer"), "units": .string(""),
            ]),
            "graph": .table([:]),
            "web": .table([
                "fallback": .string("most-recent"),
                "search-url": .string("https://search.brave.com/search?q=%s"),
                "links": .table([:]), "routes": .table([:]),
                "clicks": .table(["enabled": .bool(false), "browser": .string("")]),
            ]),
            "scroll": .table(["smooth": .bool(true), "speed": .int(1800), "step": .int(60)]),
            "select": .table(["copy-on-complete": .bool(false)]),
            "appearance": .table(["accent": .string("system")]),
            "draft": .table(["input": .string(""), "model": .string(""), "words": .table([:])]),
            "clipboard": .table([
                "enabled": .bool(true), "max-size-mb": .int(500), "save-to": .string("~/Downloads"),
                "exclude-apps": .table([:]), "exclude": .table([:]), "time-zones": .table([:]),
            ]),
            "observations": .table([
                "logbook": .bool(true), "logbook-mb": .int(256), "health": .bool(true), "health-mb": .int(1024),
            ]),
            "editor": .table([
                "enabled": .bool(false), "model": .string(""), "language": .string(""), "skip-apps": .table([:]),
            ]),
            "meetings": .table(["enabled": .bool(false), "lead-minutes": .int(5), "calendars": .table([:])]),
            "coach": .table(["enabled": .bool(true), "stand": .bool(true), "stand-after": .int(30)]),
            "health": .table(["keyboards": .table([:])]),
            "keys": .table([:]),
        ]
        expected["health"] = .table(["keyboards": .table([:]), "exact-keyboards": .bool(false)])
        XCTAssertEqual(ConfigFile.defaultTree, expected)
    }


    /// A value the person can only give has no default, and so nothing to
    /// reset to.
    func testAFactOnlyThePersonCanGiveHasNoDefault() {
        XCTAssertNil(ConfigFile.defaultTree.value(at: ["health", "born"]))
        XCTAssertNil(ConfigFile.defaultTree.value(at: ["health", "hand"]))
    }


    func testAllDefaultsEncodeToNothingAndDecodeBack() {
        XCTAssertEqual(ConfigFile.schema.encode(ConfigFile(), style: .sparse), .object(JSONObject()))
        let decoded = ConfigFile.schema.decode(.object(JSONObject()), options: .strict)
        XCTAssertEqual(decoded.value, ConfigFile())
        XCTAssertEqual(decoded.issues, [])
    }


    // MARK: - The layout

    /// The sections, in the order a person reads the file; the three the
    /// emitter never listed come last, alphabetically.
    func testTheSectionsAreDeclaredInTheOrderOfTheFile() {
        let root = ConfigSchemaWalk.objects().first { $0.path.isEmpty }!.object
        XCTAssertEqual(root.fields.map(\.key), ConfigStore.sectionOrder + ["appearance", "draft", "health"])
    }


    /// Every section's fields are alphabetical: what the emitter wrote, and
    /// what the schema's declared order must be for a file to come back byte
    /// for byte.
    func testEverySectionDeclaresItsFieldsAlphabetically() {
        let sections = ConfigSchemaWalk.objects().filter { !$0.path.isEmpty }
        XCTAssertGreaterThan(sections.count, 15)
        for (path, object) in sections {
            let keys = object.fields.map(\.key)
            XCTAssertEqual(keys, keys.sorted(), "\(path.joined(separator: ".")) is not alphabetical")
        }
    }


    // MARK: - The old spellings

    /// Every old spelling the file has ever had, each with the others beside
    /// it: reading is idempotent, as a normalization that runs on every read
    /// must be.
    func testNormalizationIsIdempotentOverEveryOldSpelling() throws {
        let fixtures = [
            #"{"hyper": {"trigger": "raw-hyper"}}"#,
            #"{"hyper": {"trigger": "left-command"}, "lode": {"tap": false}}"#,
            #"{"gestures": {"searcher": false, "launcher": true, "menu-search": false, "commands": true}}"#,
            #"{"gestures": {"searcher": false, "menu-search": false, "back-forward": true, "cheat-sheet": true, "tabs": true}}"#,
            #"{"observations": {"enabled": false}}"#,
            #"{"observations": {"enabled": false, "logbook": true}}"#,
            #"{"appearance": {"background": "lodestone", "accent": "orange"}}"#,
            #"{"web": {"clicks": {"trace": true, "enabled": true}}, "app": {"auto-reload": false}}"#,
            #"{"you": {"name": "x"}, "double-tap": {"cmd": "x"}, "hints": {"letters": "abc"}, "guide": {"fade": false}}"#,
            #"{"select": {"commit-on-unique": false, "copy-on-complete": true}}"#,
            #"{"lode": {"trigger": "raw-hyper"}}"#,
            #"{"profiles": {"brave": {"work": "Xonar"}, "chrome": {"work": "Pro"}}, "web": {"fallback": "work", "routes": {"a.com": "work", "b.com": "chrome:work"}, "links": {"gh": {"url": "x", "profile": "work"}}}, "meetings": {"calendars": {"W": "work"}}, "graph": {"b": {"x": "brave:work", "y": "chrome:work", "z": "brave:other"}, "e": "Excel"}}"#,
            #"{"profiles": 5, "web": {"fallback": "work"}}"#,
            #"{"profiles": {"brave": {"work": "Xonar"}}, "web": {"fallback": "most-recent"}}"#,
            #"{"web": {"links": null, "routes": null}, "scroll": null, "graph": {"a": null}}"#,
            #"{"hyper": null, "gestures": null}"#,
            #"{"hyper": 5, "gestures": {"searcher": 1}, "web": 3, "graph": "Slack"}"#,
            #"{"hyper": {"trigger": "raw-hyper"}, "gestures": {"searcher": false, "back-forward": 1}, "observations": {"enabled": false}, "profiles": {"brave": {"work": "Xonar"}}, "web": {"fallback": "work"}, "you": 1, "hints": 1, "guide": 1}"#,
            "{}",
        ]
        for text in fixtures {
            let once = ConfigFile.schema.normalized(try JSONDocument(parsing: text, options: .strict).value)
            XCTAssertEqual(ConfigFile.schema.normalized(once), once, text)
        }
    }


    /// The new name wins where both are there, and the old one is dropped.
    func testTheNewNameWinsWhereBothAreThere() throws {
        func normalized(_ text: String) throws -> JSONValue {
            ConfigFile.schema.normalized(try JSONDocument(parsing: text, options: .strict).value)
        }
        let lode = try normalized(#"{"hyper": {"trigger": "left-command"}, "lode": {"trigger": "right-command"}}"#)
        XCTAssertEqual(lode.value(at: jsonPath("lode", "trigger"))?.string, "right-command")
        XCTAssertNil(lode.value(at: jsonPath("hyper")))
        let gestures = try normalized(#"{"gestures": {"searcher": false, "launcher": true, "menu-search": false, "commands": true}}"#)
        XCTAssertEqual(gestures.value(at: jsonPath("gestures", "launcher"))?.bool, true)
        XCTAssertEqual(gestures.value(at: jsonPath("gestures", "commands"))?.bool, true)
        XCTAssertNil(gestures.value(at: jsonPath("gestures", "searcher")))
        let records = try normalized(#"{"observations": {"enabled": false, "logbook": true}}"#)
        XCTAssertEqual(records.value(at: jsonPath("observations", "logbook"))?.bool, true)
    }


    /// A reference the registry never held is already a name, and a
    /// reference to another browser's profile is not translated through this
    /// browser's table.
    func testTheRegistryTranslatesOnlyWhatItHeld() throws {
        let text = #"""
        {"profiles": {"brave": {"work": "Xonar"}},
         "graph": {"x": "brave:work", "y": "chrome:work", "z": "brave:Other", "w": "Slack"},
         "web": {"routes": {"a.com": "work", "b.com": "brave:Home"}}}
        """#
        let out = ConfigFile.schema.normalized(try JSONDocument(parsing: text, options: .strict).value)
        XCTAssertEqual(out.value(at: jsonPath("graph", "x"))?.string, "brave:Xonar")
        XCTAssertEqual(out.value(at: jsonPath("graph", "y"))?.string, "chrome:work")
        XCTAssertEqual(out.value(at: jsonPath("graph", "z"))?.string, "brave:Other")
        XCTAssertEqual(out.value(at: jsonPath("graph", "w"))?.string, "Slack")
        XCTAssertEqual(out.value(at: jsonPath("web", "routes", "a.com"))?.string, "brave:Xonar")
        XCTAssertEqual(out.value(at: jsonPath("web", "routes", "b.com"))?.string, "brave:Home")
    }


    // MARK: - Gestures

    func testAGestureNamedWrongIsFlaggedWithTheNearestVerb() {
        let findings = ConfigFile.problems(in: ["gestures": .table(["scrol": .bool(false), "hint": .bool(false)])])
        XCTAssertEqual(findings.sorted(), [
            "gestures.hint: unknown key `hint` (did you mean 'hints'?)",
            "gestures.scrol: unknown key `scrol` (did you mean 'scroll'?)",
        ])
    }


    func testOnlyTheVerbsThatAreOffAreWritten() throws {
        var file = ConfigFile()
        XCTAssertTrue(file.gestures["scroll"])
        file.gestures["scroll"] = false
        file.gestures["hints"] = false
        XCTAssertEqual(file.gestures.disabledKeys, ["`", ";"])
        XCTAssertEqual(ConfigFile.schema.encode(file, style: .sparse),
                       ["gestures": ["hints": false, "scroll": false]])
        file.gestures["scroll"] = true
        XCTAssertEqual(file.gestures.off, ["hints"])
    }


    /// What `lodestar config set` holds against an edit: a problem it would
    /// introduce, not one the file already had.
    func testOnlyANewProblemRefusesAnEdit() throws {
        let current = try Json.parse(#"{"scroll": {"speed": 2200}, "lode": {"trigger": "nonsense"}}"#)
        func introduced(_ path: [String], _ value: ConfigValue) -> [String] {
            let updated = Json.setting(current, path: path, to: value)!
            let before = ConfigFile.problems(in: current)
            return ConfigFile.problems(in: updated).filter { !before.contains($0) }
        }
        XCTAssertEqual(introduced(["scroll", "speed"], .int(2400)), [], "the problem that was there is not the edit's")
        XCTAssertEqual(introduced(["scroll", "speed"], .int(99_999)).count, 1)
        XCTAssertEqual(introduced(["scroll", "speeed"], .int(2400)),
                       ["scroll.speeed: unknown key `speeed` (did you mean 'speed'?)"])
        XCTAssertEqual(introduced(["scroll", "smooth"], .string("yes")).count, 1)
        XCTAssertEqual(introduced(["app", "channel"], .string("beta")).count, 1)
        XCTAssertEqual(introduced(["web", "routes", "github.com"], .int(5)).count, 1)
        XCTAssertEqual(introduced(["web", "routes", "github.com"], .string("brave:Work")), [])
    }


    func testAProblemAtTheTopSaysSo() {
        let issue = Issue(path: .root, code: .typeMismatch)
        XCTAssertTrue(ConfigFile.sentence(for: issue).hasPrefix("top level: "))
    }

    private func problems(_ json: String) throws -> [String] {
        ConfigFile.problems(in: try Json.parse(json))
    }

    func testCleanConfigHasNoFindings() throws {
        XCTAssertEqual(try problems("""
        {
          "lode": {"trigger": "right-command"},
          "scroll": {"smooth": true, "speed": 1800},
          "graph": {"s": "Slack", "e": {"o": "Outlook"}},
          "web": {"routes": {"acme": "brave:Work"}}
        }
        """), [])
    }

    func testUnknownKeyWithTypoHint() throws {
        XCTAssertEqual(try problems(#"{"scroll": {"smoothe": true}}"#),
                       ["scroll.smoothe: unknown key `smoothe` (did you mean 'smooth'?)"])
    }

    func testUnknownTopLevelSection() throws {
        XCTAssertEqual(try problems(#"{"scrol": {"speed": 100}}"#),
                       ["scrol: unknown key `scrol` (did you mean 'scroll'?)"])
        XCTAssertEqual(try problems(#"{"mystery": {"speed": 100}}"#), ["mystery: unknown key `mystery`"])
    }

    func testTypeMismatch() throws {
        let findings = try problems(#"{"scroll": {"smooth": 12}}"#)
        XCTAssertEqual(findings.count, 1)
        XCTAssertTrue(findings[0].hasPrefix("scroll.smooth: "), "\(findings)")
        XCTAssertTrue(findings[0].contains("boolean"), "\(findings)")
    }

    func testEnumViolationOffersTheNearestCase() throws {
        let findings = try problems(#"{"lode": {"trigger": "right-comand"}}"#)
        XCTAssertEqual(findings.count, 1)
        XCTAssertTrue(findings[0].hasPrefix("lode.trigger: "), "\(findings)")
        XCTAssertTrue(findings[0].contains("right-command"), "\(findings)")
        XCTAssertTrue(findings[0].contains("did you mean 'right-command'?"), "\(findings)")
    }

    /// An out-of-range number is clamped, and the person is told what it
    /// became.
    func testRangeViolationSaysWhatItBecame() throws {
        let findings = try problems(#"{"scroll": {"speed": 9000}}"#)
        XCTAssertEqual(findings.count, 1)
        XCTAssertTrue(findings[0].hasPrefix("scroll.speed: 9000 is out of range"), "\(findings)")
        XCTAssertTrue(findings[0].contains("200 and 4000"), "\(findings)")
        XCTAssertTrue(findings[0].hasSuffix("clamped to 4000"), "\(findings)")
    }

    func testGraphAcceptsNestingAndStrings() throws {
        XCTAssertEqual(try problems(#"{"graph": {"a": {"b": {"c": "Deep App"}}}}"#), [])
    }

    func testFreeTableAcceptsAnyKeys() throws {
        XCTAssertEqual(try problems(#"{"web": {"routes": {"anything.at.all": "brave:Work"}}}"#), [])
    }

    /// One bad entry costs that entry, said where it is, and not the table.
    func testABadEntryIsDroppedAndSaidAndItsNeighboursStay() throws {
        let tree = try Json.parse(#"{"clipboard": {"exclude-apps": {"com.a": true, "com.b": "yes", "com.c": true}}}"#)
        let findings = ConfigFile.problems(in: tree)
        XCTAssertEqual(findings.count, 1, "\(findings)")
        XCTAssertTrue(findings[0].hasPrefix("clipboard.exclude-apps.com.b: "), "\(findings)")
    }

    /// A null is "nothing here", as the default file of an earlier release
    /// wrote it: silent, and it reads as the default.
    func testANullIsSilent() throws {
        XCTAssertEqual(try problems(#"{"web": {"links": null, "routes": null}, "scroll": null, "keys": null}"#), [])
        XCTAssertEqual(try problems(#"{"scroll": {"speed": null}}"#), [])
    }

    // MARK: - Dotted addresses

    private func path(_ address: String) -> [String]? { ConfigFile.path(forAddress: address) }

    /// Ordinary paths keep splitting on every dot.
    func testFixedPathsSplitOnEveryDot() {
        XCTAssertEqual(path("scroll.speed"), ["scroll", "speed"])
        XCTAssertEqual(path("lode.trigger"), ["lode", "trigger"])
        XCTAssertEqual(path("graph"), ["graph"])
    }

    /// A free table's keys are the user's, so their dots are theirs too.
    /// `web.routes.github.com` is one route, not a section named `github`.
    func testFreeTableKeysKeepTheirDots() {
        XCTAssertEqual(path("web.routes.github.com"), ["web", "routes", "github.com"])
        XCTAssertEqual(path("web.routes.acme"), ["web", "routes", "acme"])
        XCTAssertEqual(path("web.routes.a.b.c.d"), ["web", "routes", "a.b.c.d"])
        XCTAssertEqual(path("clipboard.exclude-apps.com.1password.1password"),
                       ["clipboard", "exclude-apps", "com.1password.1password"])
    }

    /// Graph letters never contain a dot, so the chain keeps splitting.
    func testGraphChainsSplitPerLetter() {
        XCTAssertEqual(path("graph.e.o"), ["graph", "e", "o"])
    }

    /// A free table whose values are tables still addresses its fields —
    /// even when the user's key has dots in it.
    func testFreeTableOfTablesAddressesFieldsPastADottedKey() {
        XCTAssertEqual(path("web.links.gh.url"), ["web", "links", "gh", "url"])
        XCTAssertEqual(path("web.links.my.site.url"), ["web", "links", "my.site", "url"])
        XCTAssertEqual(path("web.links.gh"), ["web", "links", "gh"])
    }

    /// An unknown section is addressed literally so the schema can report it,
    /// rather than being silently reshaped here.
    func testUnknownSectionsAreLeftAlone() {
        XCTAssertEqual(path("nope.at.all"), ["nope", "at", "all"])
        XCTAssertNil(path("web..routes"), "an empty segment names no key")
    }

    // MARK: - The JSON Schema an editor reads

    private var document: JSONValue { ConfigFile.jsonSchema() }

    func testTheSchemaIsDraft07WithEveryOptionDescribed() {
        XCTAssertEqual(document.value(at: jsonPath("$schema"))?.string, "http://json-schema.org/draft-07/schema#")
        let properties = document.value(at: jsonPath("properties"))?.object
        XCTAssertEqual(properties?.keys.prefix(13).map { $0 },
                       ["lode", "app", "gestures", "web", "scroll", "select", "meetings", "clipboard", "editor",
                        "observations", "coach", "keys", "graph"])
        XCTAssertEqual(document.value(at: jsonPath("properties", "scroll", "properties", "speed", "minimum"))?.number?.lexeme, "200")
        XCTAssertEqual(document.value(at: jsonPath("properties", "scroll", "properties", "speed", "maximum"))?.number?.lexeme, "4000")
        XCTAssertNotNil(document.value(at: jsonPath("properties", "scroll", "properties", "speed", "description")))
    }

    /// Every object is closed, so an editor flags a typo whatever the app
    /// does with it, and the header the app writes is not itself flagged.
    func testObjectsAreClosedAndTheHeaderIsAdmitted() {
        XCTAssertEqual(document.value(at: jsonPath("additionalProperties"))?.bool, false)
        XCTAssertEqual(document.value(at: jsonPath("properties", "scroll", "additionalProperties"))?.bool, false)
        XCTAssertEqual(document.value(at: jsonPath("properties", "$schema", "type"))?.string, "string")
        XCTAssertEqual(document.value(at: jsonPath("properties", "version", "type"))?.string, "string")
    }

    /// A section holding only a null means all-defaults, which the app accepts
    /// and the editor must not flag.
    func testSectionsAcceptNull() {
        for section in ["lode", "app", "gestures", "web", "scroll", "clipboard", "health"] {
            let types = document.value(at: jsonPath("properties", section, "type"))?.array?.compactMap(\.string)
            XCTAssertEqual(types, ["object", "null"], "section \(section)")
        }
    }

    /// The gestures are enumerated: a typo in a verb's name is underlined.
    func testGesturesAreEnumeratedByName() {
        let properties = document.value(at: jsonPath("properties", "gestures", "properties"))?.object
        XCTAssertEqual(Set(properties?.keys ?? []), Set(Gestures.roster.map(\.name)))
    }

    /// The graph is held as JSON, so its shape is said here: an app name or a
    /// block of them, to any depth.
    func testTheGraphIsAnAppNameOrABlock() {
        XCTAssertEqual(document.value(at: jsonPath("properties", "graph", "type"))?.array?.compactMap(\.string),
                       ["object", "null"])
        XCTAssertEqual(document.value(at: jsonPath("properties", "graph", "additionalProperties", "$ref"))?.string,
                       "#/definitions/graphNode")
        let kinds = document.value(at: jsonPath("definitions", "graphNode", "oneOf"))?.array?
            .compactMap { $0.value(at: jsonPath("type"))?.string }
        XCTAssertEqual(kinds, ["string", "object"])
    }

    func testTheTextIsStableJson() throws {
        let text = ConfigFile.jsonSchemaText()
        XCTAssertEqual(text, ConfigFile.jsonSchemaText())
        XCTAssertEqual(try JSONDocument(parsing: text, options: .strict).value, document)
    }

    /// A spelling that is not the declared key is an unknown key, not a
    /// forgiven one: `auto_update` did nothing before and does nothing now,
    /// and the problem says what was meant.
    func testAKeyIsReadExactlyAsDeclared() {
        XCTAssertEqual(ConfigFile.problems(in: ["app": .table(["auto_update": .bool(false)])]),
                       ["app.auto_update: unknown key `auto_update` (did you mean 'auto-update'?)"])
        XCTAssertEqual(ConfigFile.problems(in: ["Scroll": .table([:])]),
                       ["Scroll: unknown key `Scroll` (did you mean 'scroll'?)"])
    }

    /// A choice spelt nearly right is offered the nearest, as an enumeration
    /// is, and a repaired section does not describe its default.
    func testAChoiceIsOfferedTheNearestAndARepairedSectionSaysNothingOfItsDefault() {
        XCTAssertEqual(ConfigFile.problems(in: ["editor": .table(["model": .string("ful")])]), [
            "editor.model: \"ful\" is not allowed, expected one of \"\", \"spelling\", \"minimal\", \"standard\", \"full\"; used the default \"\" (did you mean 'full'?)",
        ])
        XCTAssertEqual(ConfigFile.problems(in: ["health": .table(["hand": .string("lefft")])]), [
            "health.hand: \"lefft\" is not allowed, expected one of \"left\", \"right\", \"either\"; used the default (did you mean 'left'?)",
        ])
        XCTAssertEqual(ConfigFile.problems(in: ["web": .string("x")]),
                       ["web: expected an object, found string \"x\"; used the default"])
    }
}
