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
        XCTAssertTrue(items[0].detail.hasPrefix("Added lode S · The coach"))
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
