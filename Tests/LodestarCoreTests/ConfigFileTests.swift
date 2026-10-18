import Foundation
import StoicJSON
import StoicSchema
import XCTest
@testable import LodestarCore

/// `ConfigFile.schema` as the one declaration of the file: its defaults, its
/// layout (the bytes every earlier release wrote), how it reads the old
/// spellings, what it keeps of what it does not understand, and how an edit
/// is refused.
final class ConfigFileTests: XCTestCase {
    private var directory: URL!
    private var file: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-configfile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("lodestar.json")
    }


    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func write(_ text: String) throws { try text.write(to: file, atomically: true, encoding: .utf8) }
    private var onDisk: String { (try? String(contentsOf: file, encoding: .utf8)) ?? "" }
    /// The file the app writes: the header, then `body` (members, each line
    /// indented two spaces, the last with no comma), then the close.
    private func written(_ body: String = "") -> String {
        "{\n  \"$schema\": \"lodestar-schema.json\",\n  \"version\": \"\(Lodestar.version)\"" + (body.isEmpty ? "\n" : ",\n" + body) + "}\n"
    }


    // MARK: - Byte for byte

    /// Every option of the file, set to a value that is not its default, in
    /// the one tree. Built from the coverage probes, so it names every leaf the
    /// schema declares.
    private func everything() -> [String: ConfigValue] {
        var tree: [String: ConfigValue] = [:]
        for probe in ConfigCoverageTests.probes {
            var node = probe.value
            for key in probe.path.dropFirst().reversed() { node = .table([key: node]) }
            tree = Json.merged(defaults: Json.merged(defaults: tree, overlay: probe.context),
                               overlay: [probe.path[0]: node])
        }
        return tree
    }


    /// A config of the real shape that sets every option (as the old emitter
    /// writes it, header first) is read with no problem, and a change and its
    /// reverse leave the file exactly as it was: no churn for the person whose
    /// file an earlier release wrote.
    func testAFullConfigFileRoundTripsByteForByte() throws {
        var stamped = everything()
        stamped["$schema"] = .string("lodestar-schema.json")
        stamped["version"] = .string(Lodestar.version)
        let original = Json.emit(stamped)
        try write(original)
        XCTAssertEqual(Config.load(from: file).1, [], "every option in it is one the schema reads")
        try Config.edit(in: file) { Json.setting($0, path: ["scroll", "speed"], to: .int(2501))! }
        XCTAssertNotEqual(onDisk, original)
        try Config.edit(in: file) { Json.setting($0, path: ["scroll", "speed"], to: .int(2500))! }
        XCTAssertEqual(onDisk, original)
    }


    /// The same for a file that sets nothing the defaults do not already say,
    /// said anyway: the next write is sparse, and only the change is left.
    func testExplicitDefaultsAreNotWrittenBack() throws {
        var stamped = ConfigFile.defaultTree
        stamped["$schema"] = .string("lodestar-schema.json")
        stamped["version"] = .string("0.1.0")
        try write(Json.emit(stamped))
        try Config.edit(in: file) { Json.setting($0, path: ["scroll", "speed"], to: .int(2200))! }
        XCTAssertEqual(onDisk, written("  \"scroll\": {\n    \"speed\": 2200\n  }\n"))
    }


    /// Nothing but the header, for a config that is all defaults.
    func testAllDefaultsWriteOnlyTheHeader() throws {
        let (_, problems) = Config.load(from: file)
        XCTAssertEqual(problems, [])
        XCTAssertEqual(onDisk, written())
        // And an edit that sets a default is no edit.
        let before = onDisk
        try Config.edit(in: file) { Json.setting($0, path: ["scroll", "speed"], to: .int(1800))! }
        XCTAssertEqual(onDisk, before)
    }


    /// What the schema does not declare is kept and written after what it
    /// does: the one place the layout differs from the emitter's, which
    /// mixed such keys in alphabetically.
    func testUndeclaredKeysAreKeptAndWrittenAfterTheDeclaredOnes() throws {
        try write("""
        {
          "aardvark": 1,
          "scroll": {"speed": 2200, "inertia": 0.5},
          "lode": {"trigger": "left-command"}
        }
        """)
        try Config.edit(in: file) { Json.setting($0, path: ["scroll", "smooth"], to: .bool(false))! }
        XCTAssertEqual(onDisk, written("""
          "lode": {
            "trigger": "left-command"
          },
          "scroll": {
            "smooth": false,
            "speed": 2200,
            "inertia": 0.5
          },
          "aardvark": 1

        """))
    }


    // MARK: - What is kept of what is not understood

    /// A value the schema refused is the person's still: it is read as the
    /// default, said at the load, and every write that leaves it alone puts it
    /// back.
    func testARepairedValueIsKeptThroughAnUnrelatedWrite() throws {
        try write(#"{"lode": {"trigger": "nonsense"}, "scroll": {"speed": "fast"}}"#)
        let (config, problems) = Config.load(from: file)
        XCTAssertEqual(config.trigger, .rightCommand)
        XCTAssertEqual(config.scrollSpeed, 1800)
        XCTAssertEqual(problems.count, 2, "\(problems)")
        XCTAssertTrue(problems.contains { $0.hasPrefix("lode.trigger: ") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.hasPrefix("scroll.speed: ") }, "\(problems)")
        try Config.edit(in: file) { Json.setting($0, path: ["coach", "stand"], to: .bool(false))! }
        let tree = try Json.parse(onDisk)
        XCTAssertEqual(tree.value(at: ["lode", "trigger"]), .string("nonsense"))
        XCTAssertEqual(tree.value(at: ["scroll", "speed"]), .string("fast"))
        XCTAssertEqual(tree.value(at: ["coach", "stand"]), .bool(false))
    }


    /// The renamed and the retired are not carried: the next write has the new
    /// names only.
    func testAnOldSpellingIsWrittenNewAndRetiredKeysAreGone() throws {
        try write("""
        {
          "hyper": {"trigger": "left-command"},
          "gestures": {"searcher": false, "tabs": true},
          "hints": {"rescan-delay": 0.8},
          "app": {"auto-reload": true}
        }
        """)
        XCTAssertEqual(Config.load(from: file).1, [], "read clean")
        try Config.edit(in: file) { Json.setting($0, path: ["coach", "stand"], to: .bool(false))! }
        XCTAssertEqual(onDisk, written("""
          "lode": {
            "trigger": "left-command"
          },
          "gestures": {
            "launcher": false
          },
          "coach": {
            "stand": false
          }

        """))
    }


    /// A null is nothing, as an earlier release's default file wrote it, and a
    /// write does not carry it.
    func testNullsAreSilentAndNotWrittenBack() throws {
        try write(#"{"web": {"links": null, "routes": null}, "scroll": null, "meetings": {"enabled": null}}"#)
        XCTAssertEqual(Config.load(from: file).1, [])
        try Config.edit(in: file) { Json.setting($0, path: ["coach", "stand"], to: .bool(false))! }
        XCTAssertFalse(onDisk.contains("null"), onDisk)
    }


    // MARK: - Editing

    /// An edit that makes the file say what the schema refuses writes nothing.
    func testAnEditTheSchemaRefusesWritesNothing() throws {
        try write(#"{"scroll": {"speed": 2200}}"#)
        let before = onDisk
        XCTAssertThrowsError(try Config.edit(in: file) { Json.setting($0, path: ["lode", "trigger"], to: .string("nonsense"))! }) {
            guard case Config.EditError.invalid(let detail) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(detail.hasPrefix("lode.trigger: "), detail)
        }
        XCTAssertThrowsError(try Config.edit(in: file) { Json.setting($0, path: ["scroll", "smooth"], to: .int(3))! })
        XCTAssertEqual(onDisk, before)
    }


    /// A number out of range, written by the app, is the bound it is nearest.
    func testAnOutOfRangeEditIsClamped() throws {
        try Config.edit(in: file) { Json.setting($0, path: ["scroll", "speed"], to: .int(99_999))! }
        XCTAssertEqual(try Json.parse(onDisk).value(at: ["scroll", "speed"]), .int(4000))
    }


    // MARK: - What the person is told

    /// A bad entry in a table is one problem at the entry, the entry is left
    /// out, and the others stand.
    func testABadRouteCostsThatRouteAlone() throws {
        let tree = try Json.parse(#"{"web": {"routes": {"a.com": "brave:A", "b.com": 5, "c.com": "brave:C"}}}"#)
        var problems: [String] = []
        let config = Config.build(from: tree, problems: &problems)
        XCTAssertEqual(config.webRoutes, ["a.com": "brave:a", "c.com": "brave:c"])
        XCTAssertEqual(problems.count, 1, "\(problems)")
        XCTAssertTrue(problems[0].hasPrefix("web.routes.b.com: dropped the entry `b.com`"), problems[0])
    }


    func testTheFlashShowsTheFirstProblemInTheOrderOfTheFile() throws {
        try write("{\n  \"scroll\": {\"smooth\": 1},\n  \"coach\": {\"stnad\": true},\n  \"app\": {\"channel\": \"beta\"}\n}")
        let (_, problems) = Config.load(from: file)
        XCTAssertEqual(problems.count, 3, "\(problems)")
        XCTAssertTrue(problems[0].hasPrefix("scroll.smooth: "), "\(problems)")
        XCTAssertTrue(problems[1].hasPrefix("coach.stnad: "), "\(problems)")
        XCTAssertTrue(problems[2].hasPrefix("app.channel: "), "\(problems)")
    }
    /// A bad entry in a table costs that entry (the problem says where), and
    /// the entries beside it stand.
    func testABadEntryCostsThatEntryAlone() throws {
        let tree = try Json.parse(#"{"clipboard": {"exclude-apps": {"com.a": true, "com.b": "yes", "com.c": true}}}"#)
        var problems: [String] = []
        let config = Config.build(from: tree, problems: &problems)
        XCTAssertEqual(config.clipboardExcludedApps, ["com.a", "com.c"])
        XCTAssertEqual(problems.count, 1, "\(problems)")
        XCTAssertTrue(problems[0].hasPrefix("clipboard.exclude-apps.com.b: "), problems[0])
    }

    /// The entry it dropped is the person's, and a write that does not touch
    /// the table should put it back, as it does a value it repaired. Stoic's
    /// `lossyDictionary` does not carry what it dropped back into the file yet,
    /// so for now the entry goes with the next write; when Stoic carries it,
    /// this expectation fails and goes.
    func testAnEntryTheTableDroppedIsKeptThroughAnUnrelatedWrite() throws {
        try write(#"{"clipboard": {"exclude-apps": {"com.a": true, "com.b": "yes"}}}"#)
        _ = Config.load(from: file)
        try Config.edit(in: file) { Json.setting($0, path: ["coach", "stand"], to: .bool(false))! }
        let tree = try Json.parse(onDisk)
        XCTAssertEqual(tree.value(at: ["clipboard", "exclude-apps", "com.a"]), .bool(true), "the good entry stays")
        XCTExpectFailure("Stoic does not carry the entries a lossyDictionary dropped") {
            XCTAssertEqual(tree.value(at: ["clipboard", "exclude-apps", "com.b"]), .string("yes"))
        }
    }

    /// A number out of range is the bound it is nearest, in the running app
    /// and, from the next write, in the file.
    func testAClampedNumberIsWrittenAsTheBound() throws {
        try write(#"{"scroll": {"speed": 99999}, "clipboard": {"max-size-mb": 5}}"#)
        let (config, problems) = Config.load(from: file)
        XCTAssertEqual(config.scrollSpeed, 4000)
        XCTAssertEqual(config.clipboardMaxBytes, 10_000_000)
        XCTAssertEqual(problems.count, 2, "\(problems)")
        XCTAssertTrue(problems.allSatisfy { $0.contains("out of range") && $0.contains("clamped to") }, "\(problems)")
        try Config.edit(in: file) { Json.setting($0, path: ["coach", "stand"], to: .bool(false))! }
        let tree = try Json.parse(onDisk)
        XCTAssertEqual(tree.value(at: ["scroll", "speed"]), .int(4000))
        XCTAssertEqual(tree.value(at: ["clipboard", "max-size-mb"]), .int(10))
    }

    /// The doctrine of the earlier readers: an option the app cannot take
    /// (an empty model name is "the one this Mac suits", not an error).
    func testTheEmptyChoicesAreChoices() throws {
        let tree = try Json.parse(#"{"app": {"units": ""}, "draft": {"model": ""}, "editor": {"model": "", "language": ""}}"#)
        XCTAssertEqual(ConfigFile.problems(in: tree), [])
    }
}
