import AppKit
import StoicSealed
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The live monitor records when it could not see: secure input sampled,
/// sleep heard, a quit closed by the next launch, a tap outage reported by
/// the engine. What lands in the health log is the kind and the edges.
final class HealthBlindnessTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-blind-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func store() -> ObservationStore {
        let store = ObservationStore(file: directory.appendingPathComponent("observations.json"), vault: SealedFixture.vault(directory.appendingPathComponent("observations.json").deletingLastPathComponent()),
                                     log: SealedFixture.eventLog(directory.appendingPathComponent("events.jsonl")))
        store.setHealthEnabled(true)
        return store
    }

    private func monitor(_ store: ObservationStore) -> HealthMonitor {
        let health = HealthMonitor(directory: directory, vault: SealedFixture.vault(directory))
        health.observations = store
        health.listensToTheMouse = false
        return health
    }

    /// Every blind span the store has, once the queue and main have run.
    private func spans(_ health: HealthMonitor, _ store: ObservationStore) -> [ObservationEvent] {
        _ = health.ledgerForTesting()
        let landed = expectation(description: "delivered")
        DispatchQueue.main.async { landed.fulfill() }
        wait(for: [landed], timeout: 2)
        return store.healthLog.readAll().filter { $0.kind == .blind }
    }

    func testSecureInputIsSampledIntoASpanWithItsResolution() {
        let store = store()
        let health = monitor(store)
        var secure = false
        health.secureInput = { secure }
        health.setEnabled(true)
        let t0 = Date()
        health.sampleSecureInput(now: t0)
        secure = true
        health.sampleSecureInput(now: t0.addingTimeInterval(2))
        health.sampleSecureInput(now: t0.addingTimeInterval(4))
        secure = false
        health.sampleSecureInput(now: t0.addingTimeInterval(6))
        let found = spans(health, store)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.blind?.blindKind, .secureInput)
        XCTAssertEqual(found.first?.t, t0, "from the last sample that saw it off")
        XCTAssertEqual(found.first?.blind?.end, t0.addingTimeInterval(6), "to the first that sees it off")
        XCTAssertEqual(found.first?.blind?.resolution, HealthMonitor.secureInputInterval)
        health.setEnabled(false)
    }

    /// A quit with secure input on: the next launch closes the span at the
    /// quit and writes the time away, from the ledger on disk.
    func testAQuitIsWrittenDownByTheNextLaunch() {
        let store = store()
        let first = monitor(store)
        first.secureInput = { true }
        first.setEnabled(true)
        first.sampleSecureInput()
        _ = first.ledgerForTesting()
        first.quitting()
        first.flush()

        let second = monitor(store)
        second.secureInput = { false }
        second.setEnabled(true)
        let found = spans(second, store)
        XCTAssertEqual(found.compactMap { $0.blind?.blindKind }, [.secureInput, .notRunning])
        XCTAssertEqual(found[0].blind?.end, found[1].t, "the open span ends at the quit, where the time away begins")
        XCTAssertNil(found[1].blind?.startBound, "a clean quit's moment was seen")
        second.setEnabled(false)
    }

    func testSleepAndWakeAreASpan() {
        let store = store()
        let health = monitor(store)
        health.secureInput = { false }
        health.setEnabled(true)
        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
        center.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
        XCTAssertEqual(spans(health, store).compactMap { $0.blind?.blindKind }, [.asleep])
        health.setEnabled(false)
    }

    /// With health off nothing is sampled and nothing is written; turned
    /// back on, the time it was off is one span.
    func testTheSwitchOffIsWrittenDownWhenItComesBackOn() {
        let store = store()
        let health = monitor(store)
        health.secureInput = { false }
        health.setEnabled(true)
        health.setEnabled(false)
        health.noteBlindBegan(.asleep)
        health.setEnabled(true)
        XCTAssertEqual(spans(health, store).compactMap { $0.blind?.blindKind }, [.healthOff])
        health.setEnabled(false)
    }

    /// The engine reports a tap outage from the last moment the tap was
    /// known to see to the moment it is back, the start marked a bound.
    func testATapOutageRunsFromTheLastEventTheTapSaw() {
        let stage = Stage()
        var outages: [(Date, Date)] = []
        stage.engine.onTapOutage = { outages.append(($0, $1)) }
        stage.press("a")
        let seen = stage.clock.now
        stage.clock.advance(by: 4)
        stage.tapDisabled()
        XCTAssertEqual(outages.count, 1)
        XCTAssertEqual(outages.first?.0, seen)
        XCTAssertEqual(outages.first?.1, stage.clock.now)
    }

    /// The keychain is locked at launch: the key cannot be asked for, so the
    /// presses are dropped, nothing is written and nothing sealed is read or
    /// replaced. When the key comes back the record says why it has a gap.
    func testAPausedKeyDropsPressesAndTheGapSaysWhy() throws {
        let custody = InMemoryKeyCustody()
        _ = SealedFixture.vault(directory, custody: custody)
        let first = monitor(store())
        first.setEnabled(true)
        first.quitting() // a clean stop, in a ledger sealed under the real key
        let blindFile = directory.appendingPathComponent("blind.json")
        let sealedLedger = try Data(contentsOf: blindFile)
        XCTAssertTrue(Sealing.isSealed(Array(sealedLedger.prefix(4))))

        let keychain = LockedCustody(copying: custody)
        let vault = SealedFixture.vault(directory, custody: keychain)
        let store = store()
        let second = monitor(store)
        second.setEnabled(true)
        second.notePress(KeyPress(down: Date(), hold: 0.09, hand: .left, kind: .letter, finger: .index))
        second.flush()
        XCTAssertEqual(try Data(contentsOf: blindFile), sealedLedger, "the sealed ledger was neither read nor replaced")
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("keys").path)) ?? []).isEmpty,
                      "no press reached a file")
        XCTAssertEqual(vault.ring(.health).availability, .paused(.custody(.unavailable(.locked))))

        keychain.unlock()
        XCTAssertTrue(vault.ring(.health).retry())
        second.resume()
        let found = spans(second, store)
        let kinds = found.compactMap { $0.blind?.blindKind }
        XCTAssertTrue(kinds.contains(.keyUnavailable), "the record says why: \(kinds)")
        XCTAssertTrue(kinds.contains(.notRunning), "and the earlier run's stop is closed, as it always was")
        let why = try XCTUnwrap(found.first { $0.blind?.blindKind == .keyUnavailable })
        XCTAssertGreaterThan(why.blind?.end ?? .distantPast, why.t)
        XCTAssertNotEqual(try Data(contentsOf: blindFile), sealedLedger, "the ledger is written again, under the key")
        second.setEnabled(false)
    }
}
