import Foundation
import StoicJSON
import StoicSettings
import XCTest
@testable import LodestarCore

/// The config while the app runs: an edit made outside arrives once, a save
/// that does not parse keeps the last good config and says where, the app's
/// own writes are not applied a second time, and the explicit reload always
/// applies.
final class ConfigWatcherTests: XCTestCase {
    private var directory: URL!
    private var file: URL!
    private var watcher: ConfigWatcher?
    private var arrivals = 0

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-configwatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("lodestar.json")
        arrivals = 0
    }

    override func tearDown() {
        watcher?.stop()
        watcher = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func start(debounce: Duration = .milliseconds(40), _ arrived: @escaping () -> Void = {}) throws -> ConfigStore.Store {
        let store = try ConfigStore.store(at: file)
        // What the app does with an arrival: applies what the store holds, and
        // tells the watcher what it applied.
        let watcher = ConfigWatcher(store: store, debounce: debounce) { [unowned self] in
            self.arrivals += 1
            let problem = store.fileProblem
            self.watcher?.didApply(ConfigStore.Snapshot(value: store.value, problem: problem))
            arrived()
        }
        try watcher.start()
        self.watcher = watcher
        return store
    }

    /// Pumps the main queue (where the watcher tells) until `condition` holds.
    private func wait(_ what: String, seconds: Double = 5, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    /// Lets the main queue and the watcher's debounce run, to see that
    /// nothing more arrives.
    private func settle(_ seconds: Double = 0.5) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }

    private func save(_ text: String) throws { try text.write(to: file, atomically: true, encoding: .utf8) } // a rename
    private func json(_ speed: Int) -> String { "{\n  \"scroll\": {\n    \"speed\": \(speed)\n  }\n}\n" }
    private func speed(_ store: ConfigStore.Store) -> Int? {
        Int(store.value.scroll.speed)
    }

    // MARK: - An edit made outside

    /// An editor that saves by renaming a new file over the old one: seen,
    /// reloaded off the main thread, told once.
    func testASaveByRenameReloadsAndArrivesOnce() throws {
        try save(json(2200))
        let store = try start()
        XCTAssertEqual(speed(store), 2200)
        try save(json(2400))
        wait("the reload") { arrivals == 1 }
        XCTAssertEqual(speed(store), 2400)
        settle()
        XCTAssertEqual(arrivals, 1, "one save, one arrival")
    }

    /// Several writes in a burst are one reload.
    func testABurstIsOneArrival() throws {
        try save(json(2200))
        let store = try start(debounce: .milliseconds(150))
        for value in [2300, 2400, 2500] { try save(json(value)); settle(0.02) }
        wait("the reload") { arrivals >= 1 }
        settle(0.5)
        XCTAssertEqual(arrivals, 1)
        XCTAssertEqual(speed(store), 2500)
    }

    /// A file that is not there yet is picked up when it is created.
    func testAFileCreatedLaterIsPickedUp() throws {
        let store = try start()
        XCTAssertEqual(speed(store), 1800, "the defaults, until there is a file")
        try save(json(2400))
        wait("the create") { arrivals == 1 }
        XCTAssertEqual(speed(store), 2400)
    }

    /// A save that does not parse: the last good config stays, the problem is
    /// the line and column, the file is untouched, and the arrival says so
    /// once. The save that fixes it arrives too, and the problem clears.
    func testAnUnparsableSaveKeepsTheLastGoodConfig() throws {
        try save(json(2200))
        let store = try start()
        let broken = "{\n  \"scroll\": {\n    \"speed\": 2400\n    // a note\n  }\n}\n"
        try save(broken)
        wait("the problem") { arrivals == 1 }
        XCTAssertEqual(speed(store), 2200, "the last good value")
        guard let problem = store.fileProblem, let at = ConfigStore.location(of: problem) else {
            return XCTFail("no problem: \(String(describing: store.fileProblem))")
        }
        XCTAssertEqual(at.line, 4)
        XCTAssertEqual(at.column, 5)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), broken, "the file is as the person left it")

        let loaded = Config.loadSnapshot(from: file, reload: false)
        XCTAssertEqual(loaded.config.scrollSpeed, 2200, "the config in force is the last good one")
        XCTAssertEqual(loaded.problems.count, 1)
        XCTAssertTrue(loaded.problems[0].hasPrefix("config parse failed (lodestar.json:4:5: "), loaded.problems[0])
        XCTAssertTrue(loaded.problems[0].hasSuffix("); keeping the last good config — lodestar.json left untouched"), loaded.problems[0])
        XCTAssertNotNil(loaded.snapshot?.problem)

        // The same bytes saved again say nothing more.
        try save(broken)
        settle()
        XCTAssertEqual(arrivals, 1)

        try save(json(2600))
        wait("the fix") { arrivals == 2 }
        XCTAssertNil(store.fileProblem)
        XCTAssertEqual(speed(store), 2600)
    }

    /// The fix that leaves the value as it was (the person removes the note
    /// and the rest is what it was) changes no value, so no change is
    /// announced: the clearing of the problem is itself an arrival.
    func testAFixThatLeavesTheValueAsItWasStillArrives() throws {
        try save(json(2200))
        let store = try start()
        try save("{ not json")
        wait("the problem") { arrivals == 1 }
        try save(json(2200))
        wait("the fix") { arrivals == 2 }
        XCTAssertNil(store.fileProblem)
    }

    // MARK: - The app's own writes

    /// An edit through `Config.edit` is the app's: the store finds the bytes
    /// it wrote when the watcher reports them, and nothing arrives.
    func testOwnWritesAreNotAppliedTwice() throws {
        try save(json(2200))
        let store = try start()
        try Config.edit(in: file) { Json.setting($0, path: ["scroll", "speed"], to: .int(2500))! }
        try Config.edit(in: file) { Json.setting($0, path: ["graph", "s"], to: .string("Slack"))! }
        settle(0.7)
        XCTAssertEqual(arrivals, 0)
        XCTAssertEqual(speed(store), 2500)
        // And the next edit from outside still arrives: the silence above was
        // not the watcher being off.
        try save(json(2600))
        wait("the outside edit") { arrivals == 1 }
    }

    /// An edit made while ours is in flight: the store applies ours to what
    /// the file now holds, which is two changes (the file's, then ours), and
    /// the file's is the one that arrives.
    func testAnEditThatFindsTheFileMovedArrivesOnceForTheFilesChange() throws {
        try save(json(2200))
        let store = try start(debounce: .seconds(30)) // the watch is out of it: the update finds the edit
        try save("{\n  \"graph\": {\n    \"s\": \"Slack\"\n  },\n  \"scroll\": {\n    \"speed\": 2200\n  }\n}\n")
        try Config.edit(in: file) { Json.setting($0, path: ["scroll", "speed"], to: .int(2500))! }
        wait("the file's change") { arrivals == 1 }
        settle(0.2)
        XCTAssertEqual(arrivals, 1)
        let tree = ConfigStore.tree(of: store.value)
        XCTAssertEqual(tree.value(at: ["graph", "s"]), .string("Slack"))
        XCTAssertEqual(tree.value(at: ["scroll", "speed"]), .int(2500))
    }

    // MARK: - What has been applied

    /// An arrival the app has already applied (an explicit reload got there
    /// first) is not told again; one it has not is.
    func testAnArrivalTheAppAlreadyAppliedIsNotToldAgain() throws {
        try save(json(2200))
        let store = try start(debounce: .milliseconds(40))
        try save(json(2400))
        // The explicit reload gets there first, and the app applies what it read.
        try store.reload()
        let applied = ConfigStore.Snapshot(value: store.value, problem: store.fileProblem)
        watcher?.didApply(applied)
        settle(0.5)
        XCTAssertEqual(arrivals, 0, "the store's change was applied already")
        try save(json(2600))
        wait("the next edit") { arrivals == 1 }
    }

    func testTheLedgerKnowsWhatWasApplied() {
        let ledger = ConfigApplyLedger()
        func at(_ speed: Double) -> ConfigStore.Snapshot {
            var file = ConfigFile()
            file.scroll.speed = speed
            return ConfigStore.Snapshot(value: file, problem: nil)
        }
        let a = at(1000), b = at(2000)
        XCTAssertTrue(ledger.needsApply(a), "nothing applied yet")
        ledger.didApply(a)
        XCTAssertFalse(ledger.needsApply(a))
        XCTAssertTrue(ledger.needsApply(b))
        // A one-key write that sets what it holds in memory has applied it.
        ledger.ownUpdate(SettingsChange(old: a.value, new: b.value, cause: .update))
        XCTAssertFalse(ledger.needsApply(b))
        // A writer that reloaded has applied something newer: left alone.
        let c = at(3000)
        ledger.didApply(c)
        ledger.ownUpdate(SettingsChange(old: a.value, new: b.value, cause: .update))
        XCTAssertFalse(ledger.needsApply(c))
        XCTAssertTrue(ledger.needsApply(b))
    }

    // MARK: - The explicit reload

    /// SIGUSR2 and the menu: the file is re-read, then `apply` runs, whether
    /// or not the file changed and whether or not it parses.
    func testTheExplicitReloadAlwaysApplies() throws {
        try save(json(2200))
        let store = try ConfigStore.store(at: file)
        var applied: [Int?] = []
        func reload() {
            var done = false
            ConfigWatcher.reloadThenApply(store) { applied.append(self.speed(store)); done = true }
            wait("the apply") { done }
        }
        reload()                       // nothing changed
        XCTAssertEqual(applied, [2200])
        try save(json(2400))
        reload()                       // changed, and no watcher is running: the reload reads it
        XCTAssertEqual(applied, [2200, 2400])
        try save("{ broken")
        reload()                       // does not parse: applies, on the last good value
        XCTAssertEqual(applied, [2200, 2400, 2400])
        XCTAssertNotNil(store.fileProblem)
        var done = false
        ConfigWatcher.reloadThenApply(nil) { done = true }   // no store at all
        wait("the apply") { done }
    }
}
