import XCTest
@testable import LodestarCore

final class AdoptionLedgerTests: XCTestCase {
    func testSettleRestoresWhenLayoutStayedEmpty() {
        var ledger = AdoptionLedger()
        ledger.recordAdoption(of: 99, on: 1, displacing: [10, 20])
        let settlement = ledger.settle(destroyed: 99,
                                       layoutNowEmpty: { $0 == 1 },
                                       isAlive: { _ in true })
        XCTAssertEqual(settlement?.display, 1)
        XCTAssertEqual(settlement?.restore, [10, 20])
    }

    func testSettleSkipsWhenWorldMovedOn() {
        var ledger = AdoptionLedger()
        ledger.recordAdoption(of: 99, on: 1, displacing: [10])
        XCTAssertNil(ledger.settle(destroyed: 99,
                                   layoutNowEmpty: { _ in false },
                                   isAlive: { _ in true }))
    }

    func testSettleSkipsDeadMembersAndEmptyDisplacements() {
        var ledger = AdoptionLedger()
        ledger.recordAdoption(of: 99, on: 1, displacing: [10])
        XCTAssertNil(ledger.settle(destroyed: 99,
                                   layoutNowEmpty: { _ in true },
                                   isAlive: { _ in false }))

        ledger.recordAdoption(of: 98, on: 1, displacing: [])
        XCTAssertNil(ledger.settle(destroyed: 98,
                                   layoutNowEmpty: { _ in true },
                                   isAlive: { _ in true }))
    }

    func testRecordsConsumeOnce() {
        var ledger = AdoptionLedger()
        ledger.recordAdoption(of: 99, on: 1, displacing: [10])
        XCTAssertNotNil(ledger.settle(destroyed: 99, layoutNowEmpty: { _ in true }, isAlive: { _ in true }))
        XCTAssertNil(ledger.settle(destroyed: 99, layoutNowEmpty: { _ in true }, isAlive: { _ in true }))
    }

    func testStackedAdoptionsUnwindIndependently() {
        var ledger = AdoptionLedger()
        ledger.recordAdoption(of: 98, on: 1, displacing: [10])
        ledger.recordAdoption(of: 99, on: 1, displacing: [98])
        XCTAssertEqual(ledger.settle(destroyed: 99, layoutNowEmpty: { _ in true }, isAlive: { _ in true })?.restore, [98])
        XCTAssertEqual(ledger.settle(destroyed: 98, layoutNowEmpty: { _ in true }, isAlive: { _ in true })?.restore, [10])
    }
}

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

    private func makeMark(_ path: String) -> MarkRecord {
        MarkRecord(path: path, windowID: 1, bundleID: nil, appName: "App",
                   title: "T", frame: .zero)
    }

    func testRoundTripStampsVersion() {
        let store = StateStore(file: file)
        store.setMark(makeMark("q"))

        let reloaded = StateStore(file: file)
        reloaded.load()
        XCTAssertEqual(reloaded.state.marks.map(\.path), ["q"])
        XCTAssertEqual(reloaded.state.version, Lodestar.stateVersion)
        XCTAssertNil(reloaded.bootWarning)
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

    func testCorruptionRestoresFromBackup() {
        let store = StateStore(file: file)
        store.setMark(makeMark("q"))
        store.load() // a good load writes the .bak generation

        try! "{ definitely not json".data(using: .utf8)!.write(to: file)
        let recovered = StateStore(file: file)
        recovered.load()

        XCTAssertEqual(recovered.state.marks.map(\.path), ["q"], "backup carried the marks")
        XCTAssertNotNil(recovered.bootWarning)
        let quarantined = try! FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains("corrupt") }
        XCTAssertEqual(quarantined.count, 1, "the evidence is kept")
    }

    func testCorruptionWithoutBackupStartsFreshLoudly() {
        try! "nope".data(using: .utf8)!.write(to: file)
        let store = StateStore(file: file)
        store.load()
        XCTAssertTrue(store.state.marks.isEmpty)
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
