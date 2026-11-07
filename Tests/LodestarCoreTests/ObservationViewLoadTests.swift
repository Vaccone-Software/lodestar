import StoicSealed
import StoicStore
import XCTest
@testable import LodestarCore

/// The view is read once at launch, off to one side of the event tap: what is
/// recorded before that read, and what a save does before it, must not cost
/// the history the file holds. Every store here lives in a directory of its
/// own, under a vault over an in-memory custody: no keychain, no real data.
final class ObservationViewLoadTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("observations.json") }
    private let day = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("obsview-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func completions(_ store: ObservationStore, _ letter: String) -> Int {
        store.observations.addresses[letter]?.completions ?? 0
    }

    /// A previous run: `g` completed twice, saved.
    private func history(vault: Vault) -> ObservationStore {
        let first = ObservationStore(file: file, vault: vault)
        first.chainCompleted(["g"], gaps: [0.2], peeked: false, at: day)
        first.chainCompleted(["g"], gaps: [0.2], peeked: false, at: day.addingTimeInterval(1))
        first.flush()
        return first
    }

    // MARK: A save before the view is read

    func testASaveBeforeTheViewIsReadDoesNotReplaceTheHistory() throws {
        let vault = SealedFixture.vault(directory, custody: InMemoryKeyCustody())
        _ = history(vault: vault)
        let sealed = try Data(contentsOf: file)

        // The next launch: a chain lands, and the save (the coalesced one
        // five seconds on, or shutdown's) runs before the load has read.
        let second = ObservationStore(file: file, vault: vault)
        second.expectLoad()
        second.chainCompleted(["h"], gaps: [0.2], peeked: false, at: day.addingTimeInterval(10))
        second.flush()
        XCTAssertEqual(try Data(contentsOf: file), sealed, "the view the load has not read is not replaced")

        second.load()
        XCTAssertEqual(completions(second, "g"), 2, "the history in the file")
        XCTAssertEqual(completions(second, "h"), 1, "and what landed before the load")
    }

    func testTheCoalescedSaveBeforeTheViewIsReadDoesNotReplaceTheHistory() throws {
        let vault = SealedFixture.vault(directory, custody: InMemoryKeyCustody())
        _ = history(vault: vault)
        let sealed = try Data(contentsOf: file)

        let second = ObservationStore(file: file, vault: vault)
        second.expectLoad()
        second.chainCompleted(["h"], gaps: [0.2], peeked: false, at: day.addingTimeInterval(10))
        // The real timer: saveSoon's five seconds, on the main queue.
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline, (try? Data(contentsOf: file)) == sealed {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertEqual(try Data(contentsOf: file), sealed, "the coalesced save wrote a view of this run's events alone")

        second.load()
        XCTAssertEqual(completions(second, "g"), 2)
        XCTAssertEqual(completions(second, "h"), 1)
    }

    func testAStoreWhoseLogbookWasClearedAtLaunchStillSaves() throws {
        let vault = SealedFixture.vault(directory, custody: InMemoryKeyCustody())
        _ = history(vault: vault)
        // main.swift clears the logbook on request and then never loads.
        let second = ObservationStore(file: file, vault: vault)
        second.clearLogbook()
        second.chainCompleted(["h"], gaps: [0.2], peeked: false, at: day.addingTimeInterval(10))
        second.flush()

        let third = ObservationStore(file: file, vault: vault)
        third.load()
        XCTAssertEqual(completions(third, "g"), 0, "the cleared history stays cleared")
        XCTAssertEqual(completions(third, "h"), 1, "a store that will never load saves")
    }

    // MARK: Events recorded before the view is read

    func testEventsRecordedBeforeTheLoadAreInTheViewAfterIt() {
        let vault = SealedFixture.vault(directory, custody: InMemoryKeyCustody())
        _ = history(vault: vault)

        let second = ObservationStore(file: file, vault: vault)
        second.expectLoad()
        second.chainCompleted(["h"], gaps: [0.2], peeked: false, at: day.addingTimeInterval(10))
        second.load()
        XCTAssertEqual(completions(second, "g"), 2)
        XCTAssertEqual(completions(second, "h"), 1, "recorded before the load: in the log and in the view")
        XCTAssertEqual(second.log.readAll().filter { $0.chain == ["h"] }.count, 1)
    }

    func testEventsRecordedBeforeTheLoadAreCountedOnceWhenTheViewIsReplayedFromTheLog() throws {
        let vault = SealedFixture.vault(directory, custody: InMemoryKeyCustody())
        _ = history(vault: vault)
        try FileManager.default.removeItem(at: file)

        let second = ObservationStore(file: file, vault: vault)
        second.expectLoad()
        second.chainCompleted(["h"], gaps: [0.2], peeked: false, at: day.addingTimeInterval(10))
        second.load()
        XCTAssertEqual(completions(second, "g"), 2, "rebuilt from the log")
        XCTAssertEqual(completions(second, "h"), 1, "the log already holds it: applied once")
    }

    func testEventsRecordedBeforeAPausedLoadAreInTheViewOnceTheKeyIsBack() {
        let custody = InMemoryKeyCustody()
        _ = history(vault: SealedFixture.vault(directory, custody: custody))

        let keychain = LockedCustody(copying: custody)
        let paused = Vault(custody: keychain, directory: directory)
        let second = ObservationStore(file: file, vault: paused)
        second.expectLoad()
        second.chainCompleted(["h"], gaps: [0.2], peeked: false, at: day.addingTimeInterval(10))
        second.load()
        keychain.unlock()
        XCTAssertTrue(paused.ring(.logbook).retry())
        second.resume()
        XCTAssertEqual(completions(second, "g"), 2)
        XCTAssertEqual(completions(second, "h"), 1, "recorded before the load that found the key away")
    }

    // MARK: What the rule must not cost

    func testAClearWhileTheViewIsUnreadLeavesNothingBlockedAndNothingBack() throws {
        let vault = SealedFixture.vault(directory, custody: InMemoryKeyCustody())
        _ = history(vault: vault)

        let second = ObservationStore(file: file, vault: vault)
        second.expectLoad()
        second.chainCompleted(["h"], gaps: [0.2], peeked: false, at: day.addingTimeInterval(10))
        second.clearLogbook()
        second.chainCompleted(["i"], gaps: [0.2], peeked: false, at: day.addingTimeInterval(20))
        second.flush()
        second.resume()
        XCTAssertEqual(completions(second, "g"), 0, "the cleared history did not come back")
        XCTAssertEqual(completions(second, "h"), 0, "nor what was held for it")

        let third = ObservationStore(file: file, vault: vault)
        third.load()
        XCTAssertEqual(completions(third, "g"), 0)
        XCTAssertEqual(completions(third, "h"), 0)
        XCTAssertEqual(completions(third, "i"), 1, "a clear ends the wait: what came after it is saved")
    }

    func testAClearWhileTheKeyIsAwayIsNotUndoneWhenItReturns() {
        let custody = InMemoryKeyCustody()
        _ = history(vault: SealedFixture.vault(directory, custody: custody))

        let keychain = LockedCustody(copying: custody)
        let paused = Vault(custody: keychain, directory: directory)
        let second = ObservationStore(file: file, vault: paused)
        second.expectLoad()
        second.load()
        second.clearLogbook()
        keychain.unlock()
        _ = paused.ring(.logbook).retry()
        second.resume()
        XCTAssertEqual(completions(second, "g"), 0, "the clear is not read back from a file it removed")
        second.chainCompleted(["i"], gaps: [0.2], peeked: false, at: day.addingTimeInterval(20))
        second.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "and the store saves")
    }

    func testAShutdownSaveWhileTheViewIsUnreadWritesNothingAndTheLogKeepsTheEvents() throws {
        let vault = SealedFixture.vault(directory, custody: InMemoryKeyCustody())
        _ = history(vault: vault)
        let sealed = try Data(contentsOf: file)

        let second = ObservationStore(file: file, vault: vault)
        second.expectLoad()
        second.chainCompleted(["h"], gaps: [0.2], peeked: false, at: day.addingTimeInterval(10))
        second.flush()
        XCTAssertEqual(try Data(contentsOf: file), sealed, "nothing written")
        XCTAssertEqual(second.log.readAll().filter { $0.chain == ["h"] }.count, 1, "and the event is in the log")

        let next = ObservationStore(file: file, vault: vault)
        next.expectLoad()
        next.load()
        XCTAssertEqual(completions(next, "g"), 2)
        XCTAssertEqual(next.log.readAll().filter { $0.chain == ["h"] }.count, 1)
    }

    func testEventsHeldAcrossALoadThatFoundTheKeyAwayJoinTheViewOnceOnResume() throws {
        let custody = InMemoryKeyCustody()
        _ = history(vault: SealedFixture.vault(directory, custody: custody))

        let keychain = LockedCustody(copying: custody)
        let paused = Vault(custody: keychain, directory: directory)
        let second = ObservationStore(file: file, vault: paused)
        second.expectLoad()
        second.chainCompleted(["h"], gaps: [0.2], peeked: false, at: day.addingTimeInterval(10))
        second.load()
        second.chainCompleted(["i"], gaps: [0.2], peeked: false, at: day.addingTimeInterval(11))
        keychain.unlock()
        XCTAssertTrue(paused.ring(.logbook).retry())
        second.resume()
        second.resume()
        XCTAssertEqual(completions(second, "g"), 2)
        XCTAssertEqual(completions(second, "h"), 1, "held before the load, applied once")
        XCTAssertEqual(completions(second, "i"), 1, "held after it, applied once")
        second.flush()

        let third = ObservationStore(file: file, vault: paused)
        third.load()
        XCTAssertEqual(completions(third, "g"), 2)
        XCTAssertEqual(completions(third, "h"), 1)
        XCTAssertEqual(completions(third, "i"), 1)
    }

    func testWhatWasHeldIsSavedOnceTheViewIsRead() throws {
        let vault = SealedFixture.vault(directory, custody: InMemoryKeyCustody())
        _ = history(vault: vault)
        let sealed = try Data(contentsOf: file)

        let second = ObservationStore(file: file, vault: vault)
        second.expectLoad()
        second.chainCompleted(["h"], gaps: [0.2], peeked: false, at: day.addingTimeInterval(10))
        second.load()
        // The real timer: the save the held event asked for, five seconds on.
        let deadline = Date().addingTimeInterval(9)
        while Date() < deadline, (try? Data(contentsOf: file)) == sealed {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertNotEqual(try Data(contentsOf: file), sealed, "the refused save is made again after the read")
        let third = ObservationStore(file: file, vault: vault)
        third.load()
        XCTAssertEqual(completions(third, "g"), 2)
        XCTAssertEqual(completions(third, "h"), 1)
    }
}
