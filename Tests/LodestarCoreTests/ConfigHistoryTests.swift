import Foundation
import XCTest
@testable import LodestarCore

/// Every change to the config, whoever wrote it, with the way back.
final class ConfigHistoryTests: XCTestCase {
    func testChangesAreLeavesNotStamps() {
        let before: [String: ConfigValue] = [
            "version": .string("0.40.0"),
            "scroll": .table(["speed": .int(1800)]),
            "draft": .table(["words": .table(["Kindora": .bool(true)])]),
        ]
        let after: [String: ConfigValue] = [
            "version": .string("0.41.0"),
            "scroll": .table(["speed": .int(1200)]),
            "draft": .table(["words": .table(["Kindora": .bool(true), "Xonar": .bool(true)])]),
        ]
        let changes = ConfigHistory.changes(from: before, to: after)
        XCTAssertEqual(changes.map(\.path), [["draft", "words", "Xonar"], ["scroll", "speed"]])
        XCTAssertNil(changes[0].old)
        XCTAssertEqual(changes[1].old, .int(1800))
        XCTAssertEqual(changes[1].new, .int(1200))
    }

    func testApplyingWritesBackOrRemoves() {
        let tree: [String: ConfigValue] = ["scroll": .table(["speed": .int(1200)])]
        let restored = ConfigHistory.applying(.int(1800), at: ["scroll", "speed"], to: tree)
        XCTAssertEqual(restored.value(at: ["scroll", "speed"]), .int(1800))
        let removed = ConfigHistory.applying(nil, at: ["scroll", "speed"], to: tree)
        XCTAssertNil(removed.value(at: ["scroll", "speed"]))
        let made = ConfigHistory.applying(.bool(true), at: ["draft", "words", "Kindora"], to: [:])
        XCTAssertEqual(made.value(at: ["draft", "words", "Kindora"]), .bool(true), "tables made on the way")
    }

    func testTheFileRoundTripsAndKeepsItsBound() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        ConfigHistory.append([
            ConfigHistory.Entry(group: 1, index: 0, at: at, path: ["scroll", "speed"], old: .int(1800), new: .int(1200), source: "Settings"),
            ConfigHistory.Entry(group: 1, index: 1, at: at, path: ["draft", "words", "Kindora"], old: nil, new: .bool(true), source: "Settings"),
        ], to: file)
        let read = ConfigHistory.read(from: file)
        XCTAssertEqual(read.count, 2)
        XCTAssertEqual(read[0].old, .int(1800))
        XCTAssertNil(read[1].old)
        XCTAssertEqual(read[1].id, "1-1")
        for group in 2...(ConfigHistory.keep * 2 + 1) {
            ConfigHistory.append([ConfigHistory.Entry(group: group, index: 0, at: at, path: ["a"], old: nil,
                                                      new: .int(group), source: "The file")], to: file)
        }
        XCTAssertLessThanOrEqual(ConfigHistory.read(from: file).count, ConfigHistory.keep * 2)
    }

    func testTheHistoryPageSaysWhatChangedInWords() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let items = SettingsModel.historyItems([
            ConfigHistory.Entry(group: 1, index: 0, at: now, path: ["scroll", "speed"], old: .int(1800), new: .int(1200), source: "Settings"),
            ConfigHistory.Entry(group: 2, index: 0, at: now, path: ["draft", "words", "Kindora"], old: nil, new: .bool(true), source: "The editor"),
            ConfigHistory.Entry(group: 3, index: 0, at: now, path: ["graph", "s"], old: nil, new: .string("Slack"), source: "The coach"),
        ], now: now)
        XCTAssertEqual(items.map(\.title), ["Letters", "Words", "Scroll speed"], "newest first")
        XCTAssertTrue(items[0].detail.hasPrefix("Added lode s · The coach"))
        XCTAssertTrue(items[1].detail.hasPrefix("Added Kindora · The editor"))
        XCTAssertTrue(items[2].detail.hasPrefix("1800 → 1200 · Settings"))
        XCTAssertTrue(items.allSatisfy(\.today))
        let page = SettingsModel.pages(config: Config(), machine: { var m = SettingsModel.MachineState(); m.history = items; return m }())
            .first { $0.name == SettingsModel.historyPage }!
        XCTAssertEqual(page.rows.compactMap(\.action?.id), items.map { "undo:\($0.id)" })
    }

    func testAModelAnswerIsHeldToRowsThatExist() {
        let sections = SettingsModel.catalog(config: Config(), machine: .init())
        let choices = SettingsModel.askChoices(sections)
        XCTAssertEqual(Set(choices).count, choices.count, "every name is unique")
        let hit = SettingsModel.hit(forName: "Operate › Scroll speed", in: sections)
        XCTAssertEqual(hit?.address, "5 d")
        XCTAssertNil(SettingsModel.hit(forName: "Operate › Nonsense", in: sections))
        XCTAssertTrue(SettingsModel.askCatalog(sections).contains("Keep, about clipboard"))
    }
}

// MARK: - From the store's stream

/// The history is written from the store's changes: what changed, and who.
final class ConfigHistoryRecorderTests: XCTestCase {
    private var directory: URL!
    private var file: URL!
    private var history: URL!
    private var recorder: ConfigHistoryRecorder?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-confighistory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("lodestar.json")
        history = directory.appendingPathComponent("config-history.jsonl")
    }

    override func tearDown() {
        recorder?.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    private func record() throws -> ConfigStore.Store {
        let store = try ConfigStore.store(at: file)
        let recorder = ConfigHistoryRecorder(store: store, file: history)
        recorder.start()
        self.recorder = recorder
        return store
    }

    /// Waits for the recorder, which reads the stream a moment after the write.
    private func entries(count: Int, file: URL? = nil) -> [ConfigHistory.Entry] {
        let deadline = Date().addingTimeInterval(5)
        var read = ConfigHistory.read(from: history)
        while read.count < count, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
            read = ConfigHistory.read(from: history)
        }
        return read
    }

    private func set(_ path: [String], _ value: ConfigValue, source: String? = nil) throws {
        try Config.edit(in: file, source: source) { Json.setting($0, path: path, to: value)! }
    }

    // MARK: Attribution

    /// Each way the config changes is written down with its own source.
    func testEverySourceIsAttributedToItsOwnWrite() throws {
        let store = try record()
        try set(["scroll", "speed"], .int(2200), source: "Settings")
        try set(["scroll", "speed"], .int(2400))                             // nobody named it
        try set(["graph", "s"], .string("Slack"), source: "The coach")
        try set(["draft", "words", "Kindora"], .bool(true), source: "The editor")
        try set(["scroll", "speed"], .int(2200), source: "Undo")
        try set(["scroll", "speed"], .int(2400), source: "Redo")
        // From outside: a hand edit saved by rename, found by the reload.
        try """
        {"scroll": {"speed": 2400}, "graph": {"s": "Slack"}, "draft": {"words": {"Kindora": true}}, "web": {"search-url": "https://x.example/?q=%s"}}
        """.write(to: file, atomically: true, encoding: .utf8)
        try store.reload()
        let read = entries(count: 7)
        XCTAssertEqual(read.map(\.source), ["Settings", "Lodestar", "The coach", "The editor", "Undo", "Redo", "The file"])
        // A section that was not in the file is added whole, as it always was:
        // one change at the section, holding what it holds.
        XCTAssertEqual(read.map(\.path), [["scroll"], ["scroll", "speed"], ["graph"], ["draft"],
                                         ["scroll", "speed"], ["scroll", "speed"], ["web"]])
        XCTAssertEqual(read[0].old, nil, "1800 is the default, so the section was not in the file")
        XCTAssertEqual(read[0].new, .table(["speed": .int(2200)]))
        XCTAssertEqual(read[1].old, .int(2200))
        XCTAssertEqual(read[1].new, .int(2400))
        XCTAssertEqual(read.map(\.group).count, Set(read.map(\.group)).count, "one group each")
    }

    /// The writer is the one that wrote, even when the writes come at once:
    /// ten edits in a row, ten different sources, each on its own entry.
    func testARunOfWritesKeepsEachOnesSource() throws {
        try #"{"graph": {"seed": "X"}}"#.write(to: file, atomically: true, encoding: .utf8)
        _ = try record()
        for n in 0..<10 {
            try set(["graph", "k\(n)"], .string("A"), source: "writer-\(n)")
        }
        let read = entries(count: 10)
        XCTAssertEqual(read.map(\.source), (0..<10).map { "writer-\($0)" })
        XCTAssertEqual(read.map(\.path), (0..<10).map { ["graph", "k\($0)"] })
        XCTAssertEqual(Set(read.map(\.group)).count, 10, "ten groups, even inside one millisecond")
    }

    /// An edit that changes nothing, one that is refused, and one whose
    /// transform throws leave no entry, and no stale name for the next write.
    func testNothingIsRecordedForAnEditThatChangesNothingOrFails() throws {
        _ = try record()
        try set(["graph", "s"], .string("Slack"), source: "Settings")
        _ = entries(count: 1)
        try set(["graph", "s"], .string("Slack"), source: "Nobody")           // the same value
        struct Nope: Error {}
        XCTAssertThrowsError(try Config.edit(in: file, source: "Nobody") { _ in throw Nope() })
        try "{ broken".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try set(["graph", "t"], .string("Mail"), source: "Nobody"))
        try """
        {"graph": {"s": "Slack"}}
        """.write(to: file, atomically: true, encoding: .utf8)
        try set(["graph", "t"], .string("Mail"), source: "Lodestar")
        let read = entries(count: 2)
        Thread.sleep(forTimeInterval: 0.2)
        let after = ConfigHistory.read(from: history)
        XCTAssertEqual(after.map(\.source), ["Settings", "Lodestar"], "\(after)")
        XCTAssertEqual(read.count, 2)
    }

    /// An update that finds the file moved is two changes: the file's edit,
    /// attributed to the file, then ours, attributed to us.
    func testAnUpdateThatFindsTheFileMovedRecordsBoth() throws {
        let store = try record()
        try set(["graph", "s"], .string("Slack"), source: "Settings")
        _ = entries(count: 1)
        _ = store
        try """
        {"graph": {"s": "Slack", "m": "Mail"}}
        """.write(to: file, atomically: true, encoding: .utf8)
        try set(["scroll", "speed"], .int(2400), source: "Settings") // reads the file again under its lock
        let read = entries(count: 3)
        XCTAssertEqual(read.dropFirst().map(\.source), ["The file", "Settings"])
        XCTAssertEqual(read.dropFirst().map(\.path), [["graph", "m"], ["scroll"]])
    }

    /// What a hand edit that the config cannot hold does to the history:
    /// nothing, as before (a list is not a value of this config).
    func testAListIsNotAChangeOfThisConfig() throws {
        let store = try record()
        try set(["graph", "s"], .string("Slack"), source: "Settings")
        _ = entries(count: 1)
        try """
        {"graph": {"s": "Slack", "t": ["Mail"]}}
        """.write(to: file, atomically: true, encoding: .utf8)
        try store.reload()
        try set(["scroll", "speed"], .int(2400), source: "Settings")
        let read = entries(count: 2)
        XCTAssertEqual(read.map(\.path), [["graph"], ["scroll"]])
    }

    /// The app is told, on the main queue, what was recorded and for whom (a
    /// change from Settings ends the redo chain).
    func testTheAppIsToldOnTheMainQueueWhatWasRecorded() throws {
        let store = try ConfigStore.store(at: file)
        var told: [(String, Int, Bool)] = []
        let recorder = ConfigHistoryRecorder(store: store, file: history, onRecorded: { recorded in
            told.append((recorded.source, recorded.entries.count, Thread.isMainThread))
        })
        recorder.start()
        self.recorder = recorder
        try set(["scroll", "speed"], .int(2200), source: "Settings")
        let deadline = Date().addingTimeInterval(5)
        while told.isEmpty, Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(told.count, 1)
        XCTAssertEqual(told.first?.0, "Settings")
        XCTAssertEqual(told.first?.1, 1)
        XCTAssertEqual(told.first?.2, true)
    }

    // MARK: Undo and redo

    /// The group an undo takes back, written back as one edit, and the redo
    /// that makes it again: the file's bytes are what they were before the
    /// change, and after it, and the history says who did each.
    func testUndoAndRedoRoundTrip() throws {
        _ = try record()
        try set(["graph", "g"], .string("Ghostty"), source: "Settings")
        let start = try Data(contentsOf: file)
        try Config.edit(in: file, source: "Settings") { tree in
            var tree = Json.setting(tree, path: ["scroll", "speed"], to: .int(2200))!
            tree = Json.setting(tree, path: ["draft", "words", "Kindora"], to: .bool(true))!
            return tree
        }
        let afterEdit = try Data(contentsOf: file)
        var read = entries(count: 3)
        let group = read.last!.group
        let edited = read.filter { $0.group == group }
        XCTAssertEqual(edited.count, 2, "two leaves, one group")

        // ⌘Z: the group's old values, written back last to first.
        try Config.edit(in: file, source: "Undo") { ConfigHistory.restoring(edited, to: .old, in: $0) }
        XCTAssertEqual(try Data(contentsOf: file), start, "the file is as it was, byte for byte")

        // ⇧⌘Z: the new values, first to last.
        try Config.edit(in: file, source: "Redo") { ConfigHistory.restoring(edited, to: .new, in: $0) }
        XCTAssertEqual(try Data(contentsOf: file), afterEdit)

        read = entries(count: 7)
        XCTAssertEqual(read.map(\.source), ["Settings", "Settings", "Settings", "Undo", "Undo", "Redo", "Redo"])
        XCTAssertEqual(Set(read.filter { $0.source == "Undo" }.map(\.group)).count, 1, "the undo is one group")
    }

    // MARK: The file

    /// Lines an earlier release wrote still read, and the new ones are the
    /// same shape: `t, g, p, s, o, n`.
    func testEntriesFromBeforeStillReadAndNewOnesHaveTheSameShape() throws {
        let old = """
        {"g":1790000000000,"n":"2200","o":"1800","p":["scroll","speed"],"s":"Settings","t":1790000000.5}
        {"g":1790000000000,"n":"true","p":["draft","words","Kindora"],"s":"The editor","t":1790000000.5}
        {"g":1790000001000,"n":"\\"Slack\\"","p":["graph","s"],"s":"The file","t":1790000001}
        """
        try (old + "\n").write(to: history, atomically: true, encoding: .utf8)
        var read = ConfigHistory.read(from: history)
        XCTAssertEqual(read.count, 3)
        XCTAssertEqual(read[0].old, .int(1800))
        XCTAssertNil(read[1].old)
        XCTAssertEqual(read[2].new, .string("Slack"))
        try #"{"scroll": {"speed": 2200}}"#.write(to: file, atomically: true, encoding: .utf8)
        _ = try record()
        try set(["scroll", "speed"], .int(2400), source: "Settings")
        read = entries(count: 4)
        let line = try String(contentsOf: history, encoding: .utf8).split(separator: "\n").last!
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        XCTAssertEqual(Set(object.keys), ["t", "g", "p", "s", "o", "n"])
        XCTAssertEqual(object["o"] as? String, "2200")
        XCTAssertEqual(object["p"] as? [String], ["scroll", "speed"])
        XCTAssertEqual(object["s"] as? String, "Settings")
        XCTAssertEqual(object["n"] as? String, "2400")
        XCTAssertTrue((object["g"] as? Int ?? 0) > 1790000001000, "a new group is after the old ones")
    }

    // MARK: The difference and the write-back, by Stoic

    func testANumberThatIsTheSameNumberIsNotAChange() {
        let changes = ConfigHistory.changes(from: ["scroll": .table(["speed": .int(1800)])],
                                            to: ["scroll": .table(["speed": .double(1800)])])
        XCTAssertTrue(changes.isEmpty)
    }

    func testAChangeOfKindAndAWholeSectionAreOneChangeEach() {
        let changes = ConfigHistory.changes(
            from: ["a": .string("x"), "web": .table(["links": .table(["m": .table(["url": .string("u")])])])],
            to: ["a": .table(["b": .bool(true)]), "web": .table([:])])
        XCTAssertEqual(changes.map(\.path), [["a"], ["web", "links"]])
        XCTAssertEqual(changes[0].new, .table(["b": .bool(true)]))
        XCTAssertEqual(changes[1].old, .table(["m": .table(["url": .string("u")])]))
        XCTAssertNil(changes[1].new)
    }

    /// A value in the way of a section is replaced by it: undoing an edit
    /// never fails over what the file holds now.
    func testApplyingOverAScalarInTheWayMakesTheSection() {
        let restored = ConfigHistory.applying(.bool(true), at: ["draft", "words", "Kindora"],
                                              to: ["draft": .string("oops")])
        XCTAssertEqual(restored.value(at: ["draft", "words", "Kindora"]), .bool(true))
        XCTAssertEqual(ConfigHistory.applying(nil, at: ["draft", "words", "Kindora"], to: [:]).value(at: ["draft"]), nil,
                       "removing what is not there makes nothing")
    }
}
