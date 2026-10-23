import Foundation
import XCTest
@testable import lodestar
import LodestarCore
import LodestarEars

/// What Settings says about the dictation model. A tier whose load failed
/// is not "in use": the draft hears with Apple's recognizer, and the row
/// says so, until a later load of that same ear works.
final class EarHostStatusTests: XCTestCase {
    func testTheRowNamesTheTierUntilALoadFails() {
        let host = EarHost()
        host.stageForTesting(tier: .apple, named: "apple")
        XCTAssertEqual(host.status, "", "Apple, chosen, has nothing to add")
        host.stageForTesting(tier: .apple, named: "")
        XCTAssertEqual(host.status, "Not on this Mac yet")
        host.stageForTesting(tier: .apple, named: "apple", loadFailed: true)
        XCTAssertEqual(host.status, "", "Apple has no second model to fail")

        for tier in [EarTier.standard, .full, .max] {
            host.stageForTesting(tier: tier, named: tier.rawValue)
            XCTAssertEqual(host.status, "\(tier.name) in use")
            host.stageForTesting(tier: tier, named: tier.rawValue, loadFailed: true)
            XCTAssertEqual(host.status, "\(tier.name) failed to load, so Apple's recognizer is being used")
        }
    }

    func testALoadFailureIsSaidAheadOfADownload() {
        let fetching = "Gemma 4 E2B · downloading 0.1 of 3.5 GB"
        XCTAssertEqual(
            EarHost.statusLine(tier: .full, named: "full", fetching: fetching, loadFailed: true),
            "Full failed to load, so Apple's recognizer is being used",
            "a cleanup model on its way must not hide a failed ear")
        XCTAssertEqual(
            EarHost.statusLine(tier: .full, named: "full", fetching: fetching, loadFailed: false),
            fetching)
        XCTAssertEqual(
            EarHost.statusLine(tier: .standard, named: "standard", fetching: nil, loadFailed: false),
            "Standard in use")
    }

    func testSettingsShowsTheFailureOnTheDictationRow() {
        let failure = EarHost.statusLine(tier: .standard, named: "standard", fetching: nil, loadFailed: true)
        var machine = SettingsModel.MachineState()
        machine.earStatus = failure
        let row = SettingsModel.catalog(config: Config(), machine: machine)
            .first { $0.name == "Speak" }!
            .rows.first { $0.path == "draft.model" }!
        XCTAssertEqual(row.title, "Model")
        XCTAssertTrue(row.detail?.hasPrefix(failure + ". ") == true,
                      "the failure is the first thing the dictation row says")
    }

    func testAFailedLoadStaysUntilALaterLoadWorks() async {
        let host = EarHost()
        let ear = EarThatLoads()
        ear.fail = true
        host.stageForTesting(tier: .standard, named: "standard", ear: ear)
        XCTAssertEqual(host.status, "Standard in use")

        let failed = expectation(description: "the failure reaches the row")
        host.statusChanged = { failed.fulfill() }
        host.warm()
        await fulfillment(of: [failed], timeout: 2)
        let failedStatus = await MainActor.run { host.status }
        XCTAssertEqual(failedStatus, "Standard failed to load, so Apple's recognizer is being used")
        XCTAssertFalse(ear.isLoaded)

        ear.fail = false
        let cleared = expectation(description: "a later load clears it")
        host.statusChanged = { cleared.fulfill() }
        host.warm()
        await fulfillment(of: [cleared], timeout: 2)
        let clearedStatus = await MainActor.run { host.status }
        XCTAssertEqual(clearedStatus, "Standard in use")
        XCTAssertTrue(ear.isLoaded)
    }

    /// A load still in flight when the tier is replaced belongs to the ear
    /// that was replaced. Its failure must not land on the new one.
    func testAStaleLoadDoesNotMarkTheEarThatReplacedIt() async {
        let host = EarHost()
        let first = EarThatLoads()
        first.hold = true
        first.fail = true
        let held = expectation(description: "the first load is in flight")
        first.onHold = { held.fulfill() }
        host.stageForTesting(tier: .standard, named: "standard", ear: first)
        host.warm()
        await fulfillment(of: [held], timeout: 2)

        let second = EarThatLoads()
        host.stageForTesting(tier: .full, named: "full", ear: second)
        let settled = expectation(description: "the stale load was recorded")
        host.statusChanged = { settled.fulfill() }
        first.release()
        await fulfillment(of: [settled], timeout: 2)

        let status = await MainActor.run { host.status }
        XCTAssertEqual(status, "Full in use")
        XCTAssertFalse(first.isLoaded)
        XCTAssertFalse(second.isLoaded)
    }
}

/// A settling ear whose load fails or waits, so a test can settle the host
/// around it.
private final class EarThatLoads: SettlingEar, @unchecked Sendable {
    let name = "script"
    var fail = false
    var hold = false
    var onHold: () -> Void = {}
    private let lock = NSLock()
    private var loaded = false
    private var waiter: CheckedContinuation<Void, Never>?

    var isLoaded: Bool { lock.withLock { loaded } }

    func load() async throws {
        if hold {
            await withCheckedContinuation { continuation in
                lock.withLock { waiter = continuation }
                // After this closure returns the load is suspended, so the
                // signal runs on a later turn of the main queue.
                DispatchQueue.main.async { self.onHold() }
            }
        }
        if fail { throw EarLoadFailure() }
        lock.withLock { loaded = true }
    }

    func release() {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            hold = false
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume()
    }

    func unload() { lock.withLock { loaded = false } }

    func transcribe(_ samples: [Float], context: [String]) async throws -> Heard { Heard("") }
}

private struct EarLoadFailure: Error {}
