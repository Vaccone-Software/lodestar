import Foundation
import StoicJSON
import StoicSettings
import XCTest
@testable import LodestarCore

/// The config file as a hand-edited Stoic settings store. What these hold is
/// the contract the file made before it was a store: the same bytes, a file
/// that does not parse never overwritten, the same lock, the same messages
/// (now with a line and column).
final class ConfigStoreTests: XCTestCase {
    private var directory: URL!
    private var file: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-configstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("lodestar.json")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func write(_ text: String) throws { try text.write(to: file, atomically: true, encoding: .utf8) }
    private var onDisk: String { (try? String(contentsOf: file, encoding: .utf8)) ?? "" }
    private func stamped(_ tree: [String: ConfigValue]) -> String {
        var tree = tree
        tree["$schema"] = .string("lodestar-schema.json")
        tree["version"] = .string(Lodestar.version)
        return Json.emit(tree)
    }

    /// A config of the real shape, as a person who uses most of Lodestar has
    /// it: every section the order names, a graph with a multi-letter key, a
    /// link with a quote and a URL in it, routes, key overrides, a fractional
    /// number, text that needs escaping, and a key nothing declares.
    private var realistic: [String: ConfigValue] {
        [
            "lode": .table(["trigger": .string("left-command"), "tap": .bool(false)]),
            "app": .table(["auto-update": .bool(false), "channel": .string("preview")]),
            "gestures": .table(["scroll": .bool(false), "hints": .bool(false)]),
            "web": .table([
                "search-url": .string("https://search.brave.com/search?q=%s&source=lodestar"),
                "links": .table([
                    "mail": .table(["url": .string("https://mail.google.com/mail/u/0/#inbox"), "profile": .string("brave:Work")]),
                    "quoted": .table(["url": .string("https://example.com/?q=\"a b\"&back=\\slash")]),
                ]),
                "routes": .table(["github.com": .string("brave:Work"), "news.ycombinator.com": .string("brave:Home")]),
            ]),
            "scroll": .table(["speed": .int(2200), "step": .double(0.4)]),
            "select": .table(["hold": .double(0.35)]),
            "meetings": .table(["enabled": .bool(true), "calendars": .table(["Work": .string("brave:Work")])]),
            "clipboard": .table(["max-size-mb": .int(900), "exclude-apps": .table(["com.1password.1password": .bool(true)])]),
            "editor": .table(["enabled": .bool(true)]),
            "observations": .table(["logbook": .bool(false)]),
            "coach": .table(["stand-after": .int(45)]),
            "keys": .table(["10": .string("§"), "50": .string("`")]),
            "graph": .table([
                "b": .table(["x": .string("brave:Work"), "y": .string("Xonar \u{1F680} café")]),
                "eo": .string("Outlook"),
                "g": .string("Ghostty"),
                "s": .string("Slack\ttab \"quoted\" back\\slash"),
            ]),
            "zz-unknown": .table(["note": .string("kept for validation to flag"), "a": .int(1)]),
        ]
    }

    // MARK: - The bytes

    /// An existing canonical file, as every earlier release wrote it, is read
    /// and rewritten byte for byte: a change and its reverse leave the file
    /// exactly as it was, and the bytes are what the old emitter wrote. A
    /// person's repository of dotfiles shows no churn from the upgrade.
    func testACanonicalFileRoundTripsByteForByte() throws {
        let original = stamped(realistic)
        try write(original)
        try Config.edit(in: file) { tree in
            Json.setting(tree, path: ["scroll", "speed"], to: .int(2400))!
        }
        XCTAssertNotEqual(onDisk, original)
        var changed = realistic
        changed["scroll"] = .table(["speed": .int(2400), "step": .double(0.4)])
        XCTAssertEqual(onDisk, stamped(changed), "one change, the bytes the old emitter wrote for it")
        try Config.edit(in: file) { tree in
            Json.setting(tree, path: ["scroll", "speed"], to: .int(2200))!
        }
        XCTAssertEqual(onDisk, original, "and back, byte for byte")
    }

    /// The order of the sections, pinned as bytes rather than derived from
    /// the old emitter: the header, then lode, app, gestures … graph in the
    /// order a person reads them, then what nothing declares; every nested
    /// table alphabetical; a two-space indent; a final newline.
    func testTheBytesAreThePinnedCanonicalFile() throws {
        try Config.write(tree: [
            "graph": .table(["g": .string("Ghostty"), "b": .table(["x": .string("brave:Work")])]),
            "scroll": .table(["speed": .int(2200)]),
            "zebra": .bool(true),
            "lode": .table(["trigger": .string("left-command")]),
            "web": .table(["routes": .table(["b.com": .string("brave:B"), "a.com": .string("brave:A")])]),
        ], to: file)
        XCTAssertEqual(onDisk, """
        {
          "$schema": "lodestar-schema.json",
          "version": "\(Lodestar.version)",
          "lode": {
            "trigger": "left-command"
          },
          "web": {
            "routes": {
              "a.com": "brave:A",
              "b.com": "brave:B"
            }
          },
          "scroll": {
            "speed": 2200
          },
          "graph": {
            "b": {
              "x": "brave:Work"
            },
            "g": "Ghostty"
          },
          "zebra": true
        }

        """)
    }

    /// The one documented difference in spelling: a control character is
    /// written as `\b` or `\f` where the old emitter wrote `\u0008`/`\u000c`.
    /// Both are JSON, both read back to the same string, and the two
    /// spellings are the only difference between the old bytes and the new.
    func testTheOnlySpellingDifferenceIsBackspaceAndFormFeed() throws {
        let tricky = "a\u{8}b\u{c}c\u{1}d\u{1f}e\u{7f}f\u{2028}g/h"
        try Config.edit(in: file) { tree in
            Json.setting(tree, path: ["graph", "s"], to: .string(tricky))!
        }
        let text = onDisk
        XCTAssertTrue(text.contains(#""a\bb\fc\u0001d\u001fe"#), text)
        let old = stamped(["graph": .table(["s": .string(tricky)])])
        XCTAssertEqual(text.replacingOccurrences(of: #"\b"#, with: #"\u0008"#)
                        .replacingOccurrences(of: #"\f"#, with: #"\u000c"#), old)
        XCTAssertEqual(try Json.parse(text).value(at: ["graph", "s"]), .string(tricky))
    }

    /// The first launch leaves a file to edit: the header, and nothing else.
    func testAFirstLaunchWritesTheHeaderAlone() {
        let (_, problems) = Config.load(from: file)
        XCTAssertEqual(problems, [])
        XCTAssertEqual(onDisk, "{\n  \"$schema\": \"lodestar-schema.json\",\n  \"version\": \"\(Lodestar.version)\"\n}\n")
        let mode = (try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) ?? -1
        XCTAssertEqual(mode, 0o600)
    }

    // MARK: - Two writers converge

    /// Two files that mean the same thing and are laid out differently (a
    /// hand edit: sections out of order, four spaces, `1800.0`, a trailing
    /// comma, the legacy `hyper`) become the same bytes after the same edit:
    /// the file does not churn between writers.
    func testDifferentlyLaidOutFilesConvergeOnTheSameBytes() throws {
        let messy = """
        {
            "graph": {"s": "Slack", "g": "Ghostty",},
            "hyper": {"trigger": "left-command"},
            "scroll": {"step": 60, "speed": 2200.0},
            "$schema": "elsewhere.json",
            "version": "0.1.0"
        }
        """
        let tidy = stamped([
            "lode": .table(["trigger": .string("left-command")]),
            "scroll": .table(["speed": .int(2200)]),
            "graph": .table(["g": .string("Ghostty"), "s": .string("Slack")]),
        ])
        let other = directory.appendingPathComponent("other.json")
        try write(messy)
        try tidy.write(to: other, atomically: true, encoding: .utf8)
        let edit: ([String: ConfigValue]) -> [String: ConfigValue] = {
            Json.setting($0, path: ["scroll", "speed"], to: .int(2400))!
        }
        try Config.edit(in: file, edit)
        try Config.edit(in: other, edit)
        XCTAssertEqual(onDisk, try String(contentsOf: other, encoding: .utf8))
        XCTAssertTrue(onDisk.hasPrefix("{\n  \"$schema\": \"lodestar-schema.json\",\n  \"version\": \"\(Lodestar.version)\",\n  \"lode\""),
                      "the header is the app's, whatever the file held")
        XCTAssertFalse(onDisk.contains("hyper"))
    }

    /// Two writers in two stores (the app, and a second process or a build
    /// that opened its own) each applying changes to the other's result: every
    /// change lands, and the bytes are the canonical bytes of what they hold.
    func testTwoStoresOnOneFileEachApplyToTheOthersResult() throws {
        _ = try ConfigStore.store(at: file) // the process's own
        let other = try ConfigStore.Store.open(at: file.path, schema: ConfigStore.schema,
                                               format: .handEdited, options: ConfigStore.options())
        for n in 0..<3 {
            try Config.edit(in: file) { Json.setting($0, path: ["graph", "a\(n)"], to: .string("A"))! }
            try other.blockingUpdate(waitingUpTo: .seconds(2)) { value in
                var ignored: [String] = []
                var tree = ConfigStore.tree(of: value, problems: &ignored)
                tree = Json.setting(tree, path: ["graph", "b\(n)"], to: .string("B"))!
                value = ConfigStore.canonical(tree)
            }
        }
        let tree = try Json.parse(onDisk)
        for n in 0..<3 {
            XCTAssertEqual(tree.value(at: ["graph", "a\(n)"]), .string("A"))
            XCTAssertEqual(tree.value(at: ["graph", "b\(n)"]), .string("B"))
        }
        XCTAssertEqual(onDisk, stamped(tree.filter { $0.key != "$schema" && $0.key != "version" }))
    }

    // MARK: - A file that does not parse is never overwritten

    private let withComment = "{\n  // mine\n  \"graph\": {\"s\": \"Slack\"}\n}"

    /// From Settings and every writer that goes through `Config.edit`.
    func testNoEditOrWriteGoesOverAFileThatDoesNotParse() throws {
        try write(withComment)
        XCTAssertThrowsError(try Config.edit(in: file) { Json.setting($0, path: ["scroll", "speed"], to: .int(1))! }) {
            guard case Config.EditError.unparsed(let detail) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(detail.hasPrefix("lodestar.json:2:3: comments are not allowed in the config"), detail)
        }
        XCTAssertThrowsError(try Config.write(tree: ["scroll": .table(["speed": .int(1)])], to: file))
        XCTAssertEqual(onDisk, withComment)
    }

    /// From the command line: `config get/set/unset` start from `userTree`,
    /// which is nil for a file that cannot be used, and refuse to write.
    func testTheCommandLineSeesNoTreeAndSoWritesNothing() throws {
        try write(withComment)
        XCTAssertNil(Config.userTree(from: file))
        try write("{}")
        XCTAssertEqual(Config.userTree(from: file)?.isEmpty, true)
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(Config.userTree(from: file)?.isEmpty, true, "no file is an empty config, not a broken one")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "reading never creates it")
    }

    /// A file that is not JSON at all, from `load`: said with its position,
    /// kept, and never replaced by the defaults.
    func testLoadSaysWhereAndLeavesTheFile() throws {
        try write("{\n  \"scroll\": {\n    \"speed\": 2200,,\n  }\n}")
        let before = onDisk
        let (config, problems) = Config.load(from: file)
        XCTAssertEqual(problems.count, 1, "\(problems)")
        XCTAssertTrue(problems[0].hasPrefix("config parse failed (lodestar.json:3:19: "), problems[0])
        XCTAssertTrue(problems[0].hasSuffix("); using defaults — lodestar.json left untouched"), problems[0])
        XCTAssertEqual(config.scrollSpeed, Config().scrollSpeed)
        XCTAssertEqual(onDisk, before)
    }

    /// A file with a top level that is not an object is as unreadable as text
    /// that is not JSON.
    func testATopLevelThatIsNotAnObjectIsAProblemAndIsKept() throws {
        try write("[1, 2]")
        let (_, problems) = Config.load(from: file)
        XCTAssertTrue(problems[0].hasPrefix("config parse failed (lodestar.json:1:1: the top level must be an object)"), problems[0])
        XCTAssertThrowsError(try Config.edit(in: file) { $0 })
        XCTAssertEqual(onDisk, "[1, 2]")
    }

    // MARK: - Reset

    func testResetKeepsTheBrokenFileAndWritesTheDefaults() throws {
        try write(withComment)
        let backup = directory.appendingPathComponent("lodestar.json.backup-now")
        let kept = try Config.reset(at: file, backingUpTo: backup)
        XCTAssertEqual(kept, backup)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), withComment, "the person's bytes, exactly")
        XCTAssertEqual(onDisk, "{\n  \"$schema\": \"lodestar-schema.json\",\n  \"version\": \"\(Lodestar.version)\"\n}\n")
        // And the store is usable again, with no problem left over.
        XCTAssertNoThrow(try Config.edit(in: file) { Json.setting($0, path: ["scroll", "speed"], to: .int(2400))! })
    }

    func testResetOfAGoodFileKeepsItToo() throws {
        try write(stamped(realistic))
        let backup = directory.appendingPathComponent("lodestar.json.backup-now")
        XCTAssertEqual(try Config.reset(at: file, backingUpTo: backup), backup)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), stamped(realistic))
        XCTAssertTrue(onDisk.contains("\"version\"") && !onDisk.contains("graph"))
    }

    func testResetOfNoFileMakesOneAndKeepsNothing() throws {
        let backup = directory.appendingPathComponent("lodestar.json.backup-now")
        XCTAssertNil(try Config.reset(at: file, backingUpTo: backup))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    /// A backup that is already there is never written over (it may be an
    /// earlier copy of somebody's work), and the file is as it was.
    func testResetRefusesToWriteOverAnEarlierBackup() throws {
        try write(withComment)
        let backup = directory.appendingPathComponent("lodestar.json.backup-now")
        try "earlier".write(to: backup, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Config.reset(at: file, backingUpTo: backup)) {
            guard case Config.ResetError.backupFailed = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(onDisk, withComment)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "earlier")
    }

    // MARK: - The lock

    /// The default wait is the old one, 2 s, on the same `<path>.lock`, so an
    /// old build holding it (it is a plain flock) keeps the new one out for
    /// exactly that long, and the file is untouched.
    func testAnOldBuildsLockIsWaitedOnForTwoSecondsThenBusy() throws {
        try write(stamped(["scroll": .table(["speed": .int(2400)])]))
        let before = try Data(contentsOf: file)
        let held = open(file.path + ".lock", O_RDWR | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(held, 0)
        XCTAssertEqual(flock(held, LOCK_EX | LOCK_NB), 0)
        defer { close(held) }
        var ran = false
        let started = Date()
        XCTAssertThrowsError(try Config.edit(in: file) { ran = true; return $0 }) {
            guard case Config.EditError.busy(let detail) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(detail, "waited 2 s for the lock on lodestar.json")
        }
        let waited = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(waited, 1.9)
        XCTAssertLessThan(waited, 3.5)
        XCTAssertFalse(ran)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    /// And the other way: while an edit is in flight, a raw `flock` (an old
    /// build's `Config.edit`) cannot take the lock the new one holds.
    func testTheNewBuildsLockKeepsAnOldBuildOut() throws {
        try write("{}")
        var refused = false
        try Config.edit(in: file) { tree in
            let other = open(file.path + ".lock", O_RDWR | O_CREAT, 0o600)
            defer { close(other) }
            refused = flock(other, LOCK_EX | LOCK_NB) != 0
            return Json.setting(tree, path: ["scroll", "speed"], to: .int(2400))!
        }
        XCTAssertTrue(refused)
    }

    /// An edit that finds the file changed since the store read it applies
    /// to what is there: nothing another writer did is lost.
    func testAnEditAppliesToWhatTheFileHoldsNow() throws {
        try write(stamped(["scroll": .table(["speed": .int(2400)])]))
        _ = Config.load(from: file) // the store has read it
        try write(stamped(["scroll": .table(["speed": .int(2400)]), "graph": .table(["s": .string("Slack")])]))
        try Config.edit(in: file) { Json.setting($0, path: ["clipboard", "max-size-mb"], to: .int(900))! }
        let tree = try Json.parse(onDisk)
        XCTAssertEqual(tree.value(at: ["graph", "s"]), .string("Slack"), "the other writer's key rides")
        XCTAssertEqual(tree.value(at: ["clipboard", "max-size-mb"]), .int(900))
    }
}

extension ConfigStoreTests {
    /// Numbers a config can hold are spelt as before; only the exponent forms
    /// of numbers no option can take (the widest range is 16384) differ:
    /// Stoic writes RFC 8785's shortest form where Swift's description used an
    /// exponent.
    func testNumbersAreSpeltAsBefore() throws {
        for value in [0.4, 0.35, 0.7, 2.5, 1800.0, 16384.0, 0.05, 1.0 / 3.0, 100.5] {
            try Config.edit(in: file) { Json.setting($0, path: ["scroll", "step"], to: .double(value))! }
            let now = onDisk
            let old = stamped(["scroll": .table(["step": .double(value)])])
            XCTAssertEqual(now, old, "\(value)")
        }
        // The two forms that differ, and that no option takes: 1e-05 and
        // 1.5e+20 before, 0.00001 and 150000000000000000000 now. Both read
        // back as the same number.
        try Config.edit(in: file) { Json.setting($0, path: ["scroll", "step"], to: .double(0.00001))! }
        XCTAssertTrue(onDisk.contains("\"step\": 0.00001\n"), onDisk)
        XCTAssertEqual(Json.emitFragment(.double(0.00001)), "1e-05")
        XCTAssertEqual(try Json.parse(onDisk).value(at: ["scroll", "step"])?.double, 0.00001)
        try Config.edit(in: file) { Json.setting($0, path: ["scroll", "step"], to: .double(1.5e20))! }
        XCTAssertTrue(onDisk.contains("\"step\": 150000000000000000000\n"), onDisk)
        XCTAssertEqual(try Json.parse(onDisk).value(at: ["scroll", "step"])?.double, 1.5e20)
    }
}
