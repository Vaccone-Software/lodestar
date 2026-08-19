import XCTest
@testable import LodestarCore

final class IntentQueueTests: XCTestCase {
    private func window(_ id: CGWindowID, app: String) -> WindowModel.Window {
        WindowModel.Window(id: id, element: AXUIElementCreateApplication(1), pid: 1,
                           appName: app, bundleID: nil, title: "", frame: .zero,
                           isMinimized: false, isAlive: true, lastFocused: nil, deadAt: nil)
    }

    func testClaimConsumesFirstMatch() {
        var queue = IntentQueue()
        var landed: [CGWindowID] = []
        queue.expect(.init(matches: { $0.appName == "Slack" },
                           action: { landed.append($0.id) },
                           expires: .distantFuture))
        XCTAssertNil(queue.claim(window(1, app: "Brave")))
        queue.claim(window(2, app: "Slack"))?(window(2, app: "Slack"))
        XCTAssertEqual(landed, [2])
        XCTAssertNil(queue.claim(window(3, app: "Slack")), "consumed")
    }

    func testExpiredIntentsNeverFire() {
        var queue = IntentQueue()
        queue.expect(.init(matches: { _ in true }, action: { _ in XCTFail("expired") },
                           expires: Date(timeIntervalSinceNow: -1)))
        XCTAssertNil(queue.claim(window(1, app: "Any")))
    }
}

final class StateStoreTests: XCTestCase {
    private var directory: URL!
    private var file: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("state.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeBreath(_ path: String) -> BreathRecord {
        BreathRecord(path: path, orientation: "horizontal", members: [])
    }

    func testRoundTripStampsVersion() {
        let store = StateStore(file: file)
        store.setBreath(makeBreath("q"))

        let reloaded = StateStore(file: file)
        reloaded.load()
        XCTAssertEqual(reloaded.state.breaths.map(\.path), ["q"])
        XCTAssertEqual(reloaded.state.version, Lodestar.stateVersion)
        XCTAssertNil(reloaded.bootWarning)
    }

    // MARK: - The migration chain

    /// The chain has never carried a real step: `steps` is empty and
    /// `stateVersion` has been 1 since it was introduced, so in production
    /// this has only ever run as a no-op. These exercise it at length, which
    /// matters because the first time it does real work it will do it to
    /// every saved layout on every machine at once.
    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func object(_ data: Data) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testEveryStepRunsInOrder() {
        var trail: [Int] = []
        let steps: [Int: (inout [String: Any]) -> Void] = [
            1: { o in trail.append(1); o["one"] = true },
            2: { o in trail.append(2); o["two"] = true },
            3: { o in trail.append(3); o["three"] = true },
        ]
        let out = object(StateMigrations.lift(json(["version": 1]), through: steps, to: 4))
        XCTAssertEqual(trail, [1, 2, 3])
        XCTAssertEqual(out["version"] as? Int, 4)
        XCTAssertEqual(out["one"] as? Bool, true)
        XCTAssertEqual(out["three"] as? Bool, true)
    }

    /// A version with no registered step is a version that needed no change.
    /// It must not stall the chain — the later steps still have to run.
    func testAGapInTheTableDoesNotStallTheChain() {
        var ran: [Int] = []
        let steps: [Int: (inout [String: Any]) -> Void] = [
            1: { _ in ran.append(1) },
            // no step for 2
            3: { _ in ran.append(3) },
        ]
        let out = object(StateMigrations.lift(json(["version": 1]), through: steps, to: 4))
        XCTAssertEqual(ran, [1, 3])
        XCTAssertEqual(out["version"] as? Int, 4)
    }

    /// A file with no version at all is version zero, and starts from the top.
    func testAnUnversionedObjectStartsAtZero() {
        var ran: [Int] = []
        let steps: [Int: (inout [String: Any]) -> Void] = [0: { _ in ran.append(0) }]
        let out = object(StateMigrations.lift(json(["breaths": []]), through: steps, to: 1))
        XCTAssertEqual(ran, [0])
        XCTAssertEqual(out["version"] as? Int, 1)
    }

    func testAlreadyCurrentIsUntouched() {
        var ran = false
        let steps: [Int: (inout [String: Any]) -> Void] = [1: { _ in ran = true }]
        let input = json(["version": 2, "keep": "me"])
        XCTAssertEqual(StateMigrations.lift(input, through: steps, to: 2), input)
        XCTAssertFalse(ran)
    }

    /// A state file written by a *newer* Lodestar, opened by an older one.
    /// There is nothing sensible to do but leave it alone and let the decode
    /// speak; running the chain forward over it would corrupt it.
    func testAFileFromTheFutureIsLeftAlone() {
        let input = json(["version": 9, "breaths": []])
        XCTAssertEqual(StateMigrations.lift(input, through: [:], to: 2), input)
    }

    func testUnreadableDataIsReturnedUnchanged() {
        let garbage = Data("not json at all".utf8)
        XCTAssertEqual(StateMigrations.lift(garbage, through: [:], to: 3), garbage)
    }

    /// The public entry point is the same chain with the real table.
    func testThePublicLiftStampsTheCurrentVersion() {
        let out = object(StateMigrations.lift(json(["breaths": []])))
        XCTAssertEqual(out["version"] as? Int, Lodestar.stateVersion)
    }

    func testUnversionedFileLiftsCleanly() {
        // A pre-versioning state file: no version field at all. (Non-string
        // dictionary keys encode as flat arrays in JSON — parked is [].)
        let v0 = #"{"marks":[],"breaths":[],"parked":[]}"#
        try! v0.data(using: .utf8)!.write(to: file)
        let store = StateStore(file: file)
        store.load()
        XCTAssertNil(store.bootWarning)
        store.save()
        let raw = try! JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        XCTAssertEqual(raw["version"] as? Int, Lodestar.stateVersion)
    }

    /// Marks retired in 0.9.14: a file still carrying them loads without
    /// complaint, and the next save writes the key away.
    func testRetiredMarksKeyDecodesAwayQuietly() {
        let legacy = #"{"version":1,"marks":[{"path":"q","windowID":1,"appName":"App","title":"T","frame":{"origin":{"x":0,"y":0},"size":{"width":1,"height":1}}}],"breaths":[],"parked":[]}"#
        try! legacy.data(using: .utf8)!.write(to: file)
        let store = StateStore(file: file)
        store.load()
        XCTAssertNil(store.bootWarning, "a legacy marks key is not corruption")
        store.save()
        let raw = try! JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        XCTAssertNil(raw["marks"], "the retired key does not survive a save")
    }

    func testCorruptionRestoresFromBackup() {
        let store = StateStore(file: file)
        store.setBreath(makeBreath("q"))
        store.load() // a good load writes the .bak generation

        try! "{ definitely not json".data(using: .utf8)!.write(to: file)
        let recovered = StateStore(file: file)
        recovered.load()

        XCTAssertEqual(recovered.state.breaths.map(\.path), ["q"], "backup carried the breaths")
        XCTAssertNotNil(recovered.bootWarning)
        let quarantined = try! FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains("corrupt") }
        XCTAssertEqual(quarantined.count, 1, "the evidence is kept")
    }

    func testCorruptionWithoutBackupStartsFreshLoudly() {
        try! "nope".data(using: .utf8)!.write(to: file)
        let store = StateStore(file: file)
        store.load()
        XCTAssertTrue(store.state.breaths.isEmpty)
        XCTAssertNotNil(store.bootWarning)
    }

    func testBreathCRUDAndLatest() {
        let store = StateStore(file: file)
        store.setBreath(BreathRecord(path: "w", orientation: "horizontal", members: []))
        XCTAssertEqual(store.state.latestBreath, "w")
        XCTAssertTrue(store.deleteBreath(at: "w"))
        XCTAssertNil(store.state.latestBreath)
        XCTAssertFalse(store.deleteBreath(at: "w"))
    }
}
