import StoicSealed
import StoicStore
import XCTest
@testable import LodestarCore

/// The state file is sealed at rest, under the `state` ring, and every state
/// of the key means what the vault says it means: a key that cannot be asked
/// for is paused (nothing read, written, removed; the app runs on memory),
/// a key that is gone moves the sealed files aside, and what an earlier build
/// left in the clear is taken in only after its sealed form has been read back.
final class StateSealingTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("state.json") }
    private var sealed: URL { SealedFixture.sealedState(file) }
    private var backup: URL { sealed.appendingPathExtension("bak") }
    private var plainBackup: URL { file.appendingPathExtension("bak") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-statesealed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    // MARK: Fixtures

    private func breath(_ path: String, title: String = "a window") -> BreathRecord {
        BreathRecord(path: path, orientation: "horizontal", members: [
            BreathMember(windowID: 7, bundleID: "com.example.app", appName: "App", title: title,
                         frame: CGRect(x: 1, y: 2, width: 300, height: 200)),
        ])
    }

    private func names() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    }

    private func mode(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    /// What a build older than the sealing wrote: the state in the clear.
    private func writePlain(_ state: PersistedState, to url: URL? = nil) throws {
        var state = state
        state.version = Lodestar.stateVersion
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url ?? file)
    }

    private func decoded(_ url: URL) throws -> PersistedState {
        try JSONDecoder().decode(PersistedState.self, from: Data(try XCTUnwrap(SealedFixture.openedState(url))))
    }

    /// A state whose every field says something, to see none is dropped.
    private func richState() -> PersistedState {
        let json = """
        {"version":1,"breaths":[{"path":"a","orientation":"horizontal","members":[]}],"latestBreath":"a",
         "parked":[5,[[1,2],[3,4]]],"parkedSession":"1700000000",
         "usage":{"com.example.app":{"count":3,"last":700000000}},"walkStep":4,"walkCompletedVersion":"0.50.0",
         "walkDoor":"write","editorConsentAt":700000000,"meetingSpent":["m1","m2"],
         "coachStandingSince":{"bind:x":700000000},"curriculum":{"launcher":{"offers":1,"completedAt":700000000}}}
        """
        return try! JSONDecoder().decode(PersistedState.self, from: Data(json.utf8))
    }

    // MARK: Sealed at rest

    func testASaveIsSealedAndNothingIsLeftInTheClear() throws {
        let store = SealedFixture.stateStore(file)
        store.setBreath(breath("q", title: "Quarterly report for Acme — confidential"))
        let bytes = try Data(contentsOf: sealed)
        XCTAssertTrue(Sealing.isSealed([UInt8](bytes.prefix(4))), "the file is a sealed value")
        XCTAssertNil(bytes.range(of: Data("Acme".utf8)), "the title is not in the file")
        XCTAssertNil(bytes.range(of: Data("breaths".utf8)), "nor is the shape of the state")
        XCTAssertTrue(names().isSubset(of: ["state.sealed", "state.sealed.bak"]), "only sealed names: \(names())")
        XCTAssertTrue(names().contains("state.sealed"))
        XCTAssertEqual(try decoded(sealed).breaths.map(\.path), ["q"])
    }

    func testBothFilesAreOwnerOnlyAndLeftOutOfBackups() throws {
        let store = SealedFixture.stateStore(file)
        store.setBreath(breath("q"))
        store.load()   // the boot that makes the backup
        XCTAssertEqual(mode(sealed), 0o600)
        XCTAssertEqual(mode(backup), 0o600)
        for url in [sealed, backup] {
            let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(values.isExcludedFromBackup, true, url.lastPathComponent)
        }
        XCTAssertTrue(Paths.isBehavioral("state.sealed"))
        XCTAssertTrue(Paths.isBehavioral("state.sealed.bak"))
        XCTAssertTrue(Paths.isBehavioral("state.sealed.corrupt-2026-10-18T10-00-00Z"))
        XCTAssertTrue(Paths.isBehavioral("state-unreadable-2026-10-18"))
    }

    func testEveryFieldSurvivesASealedRoundTrip() throws {
        try writePlain(richState())
        _ = SealedFixture.stateStore(file)           // taken in, sealed
        let store = SealedFixture.stateStore(file)   // read sealed
        store.save()                                 // and written sealed again
        let again = SealedFixture.stateStore(file)
        XCTAssertEqual(again.state.breaths.map(\.path), ["a"])
        XCTAssertEqual(again.state.latestBreath, "a")
        XCTAssertEqual(again.state.parked[5], CGRect(x: 1, y: 2, width: 3, height: 4))
        XCTAssertEqual(again.state.parkedSession, "1700000000")
        XCTAssertEqual(again.state.usage?["com.example.app"]?.count, 3)
        XCTAssertEqual(again.walkStep, 4)
        XCTAssertEqual(again.walkCompletedVersion, "0.50.0")
        XCTAssertEqual(again.walkDoor, .write)
        XCTAssertTrue(again.editorConsented)
        XCTAssertEqual(again.meetingSpent, ["m1", "m2"])
        XCTAssertNotNil(again.state.coachStandingSince?["bind:x"])
        XCTAssertNotNil(again.curriculumRecords[.launcher]?.completedAt)
    }

    func testTheStateRingIsItsOwnSoClearingTheLogbookCannotCostTheBreaths() throws {
        let vault = SealedFixture.vault(directory)
        let store = SealedFixture.stateStore(file)
        store.setBreath(breath("q"))
        XCTAssertNotNil(vault.ring(.logbook).keyring())
        XCTAssertTrue(vault.ring(.logbook).destroy())
        XCTAssertEqual(SealedFixture.stateStore(file).state.breaths.map(\.path), ["q"])
    }

    func testTheFileOnlyOpensAsTheStateItIs() throws {
        let store = SealedFixture.stateStore(file)
        store.setBreath(breath("q"))
        // The same bytes under another name do not open as the state.
        let other = directory.appendingPathComponent("era.json")
        try FileManager.default.copyItem(at: sealed, to: other)
        let ring = SealedFixture.vault(directory).ring(.state)
        XCTAssertNil(SealedValueFile(url: other, name: "era.json", ring: ring).read().bytes)
    }

    // MARK: Taking in what an earlier build wrote

    func testPlaintextFromAnEarlierBuildIsSealedVerifiedAndRemoved() throws {
        var old = richState()
        old.breaths.append(breath("w", title: "Secret plans"))
        try writePlain(old)
        try writePlain(old, to: plainBackup)

        let store = SealedFixture.stateStore(file)

        XCTAssertEqual(store.state.breaths.map(\.path), ["a", "w"])
        XCTAssertNil(store.bootWarning, "an ordinary upgrade says nothing")
        XCTAssertEqual(names(), ["state.sealed", "state.sealed.bak"], "the plaintext and its plaintext backup are gone")
        XCTAssertEqual(try decoded(sealed).breaths.map(\.path), ["a", "w"])
        XCTAssertEqual(try decoded(backup).breaths.map(\.path), ["a", "w"], "the backup is a sealed copy of the same state")
        XCTAssertNil(try Data(contentsOf: sealed).range(of: Data("Secret".utf8)))
        XCTAssertEqual(SealedFixture.stateStore(file).state.walkStep, 4, "and the next launch reads the sealed file")
    }

    func testAnUnversionedPlaintextIsLiftedOnTheWayIn() throws {
        try Data(#"{"breaths":[{"path":"q","orientation":"horizontal","members":[]}],"parked":[]}"#.utf8).write(to: file)
        let store = SealedFixture.stateStore(file)
        XCTAssertEqual(store.state.breaths.map(\.path), ["q"])
        XCTAssertEqual(try decoded(sealed).version, Lodestar.stateVersion)
    }

    /// The plaintext is only removed after the sealed form is back in hand: a
    /// key that cannot be made leaves it exactly where it was.
    func testAKeyThatCannotBeMadeLeavesThePlaintextUntouched() throws {
        try writePlain(richState())
        let before = try Data(contentsOf: file)
        let custody = InMemoryKeyCustody()
        custody.failNext(with: .unavailable(.accessDenied), on: .store)
        let store = SealedFixture.stateStore(file, vault: SealedFixture.vault(directory, custody: custody))
        guard case .paused = store.condition else { return XCTFail("\(store.condition)") }
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(names(), ["state.json"], "nothing sealed was left half made")
    }

    /// A ring in the custody that is not a ring pauses the store, and the plaintext stays.
    func testADamagedRingLeavesThePlaintextWhereItIs() throws {
        try writePlain(richState())
        let custody = InMemoryKeyCustody(["lodestar.ring.state": [1, 2, 3]])
        let store = SealedFixture.stateStore(file, vault: SealedFixture.vault(directory, custody: custody))
        guard case .paused = store.condition else { return XCTFail("\(store.condition)") }
        XCTAssertEqual(names(), ["state.json"])
        XCTAssertEqual(custody.contents(of: "lodestar.ring.state"), [1, 2, 3], "and the ring was left as it was")
    }

    func testCrashAfterSealingBeforeRemovalIsFinishedWithoutDoubling() throws {
        var old = richState()
        old.usage = ["com.example.app": UsageRecord(count: 3, last: Date(timeIntervalSince1970: 1_700_000_000))]
        try writePlain(old)
        _ = SealedFixture.stateStore(file)
        // The crash: sealed is there, and so is the plaintext, as before.
        try writePlain(old)
        let store = SealedFixture.stateStore(file)
        XCTAssertEqual(store.state.usage?["com.example.app"]?.count, 3, "a count is not added to itself")
        XCTAssertEqual(store.state.breaths.map(\.path), ["a"], "nor a breath listed twice")
        XCTAssertEqual(names(), ["state.sealed", "state.sealed.bak"])
    }

    func testAPlaintextThatDoesNotDecodeIsSetAsideNeverDeleted() throws {
        try Data("{ not json".utf8).write(to: file)
        let store = SealedFixture.stateStore(file)
        XCTAssertTrue(store.state.breaths.isEmpty)
        XCTAssertNotNil(store.bootWarning)
        let kept = names().filter { $0.hasPrefix("state.json.corrupt-") }.sorted()
        XCTAssertEqual(kept.count, 1, "the evidence is kept: \(names())")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(kept[0]), encoding: .utf8), "{ not json")
    }

    func testAPlaintextBackupSavesAPlaintextThatDoesNotDecode() throws {
        try Data("{ not json".utf8).write(to: file)
        try writePlain(richState(), to: plainBackup)
        let store = SealedFixture.stateStore(file)
        XCTAssertEqual(store.state.breaths.map(\.path), ["a"])
        XCTAssertTrue(try XCTUnwrap(store.bootWarning).contains("restored from backup"))
        XCTAssertTrue(names().contains { $0.hasPrefix("state.json.corrupt-") })
        XCTAssertFalse(names().contains("state.json.bak"), "taken in, then removed")
    }

    // MARK: A build older than the sealing runs again (a downgrade)

    func testWhatAnOlderBuildWroteIsMergedInAndTheSealedStateKeepsWhatItHad() throws {
        try writePlain(richState())
        let store = SealedFixture.stateStore(file)
        store.setBreath(breath("b", title: "old b"))
        // The older build finds no state of its own, starts empty and records some.
        var older = PersistedState()
        older.breaths = [breath("b", title: "new b"), breath("c")]
        older.latestBreath = "c"
        older.usage = ["com.example.app": UsageRecord(count: 5, last: Date(timeIntervalSince1970: 1_800_000_000)),
                       "com.other": UsageRecord(count: 1, last: Date(timeIntervalSince1970: 1_800_000_000))]
        older.meetingSpent = ["m3"]
        try writePlain(older)
        try writePlain(older, to: plainBackup)

        let merged = SealedFixture.stateStore(file)

        XCTAssertEqual(merged.state.breaths.map(\.path), ["a", "b", "c"])
        XCTAssertEqual(merged.state.breaths.first { $0.path == "b" }?.members.first?.title, "new b",
                       "the older build began from nothing: what it holds is the later answer")
        XCTAssertEqual(merged.state.latestBreath, "c")
        XCTAssertEqual(merged.state.usage?["com.example.app"]?.count, 5)
        XCTAssertEqual(merged.state.usage?["com.other"]?.count, 1)
        XCTAssertEqual(merged.meetingSpent, ["m1", "m2", "m3"])
        XCTAssertEqual(merged.walkStep, 4, "what only the sealed state knew stays")
        XCTAssertEqual(merged.walkCompletedVersion, "0.50.0")
        XCTAssertEqual(names(), ["state.sealed", "state.sealed.bak"], "the plaintext is gone, as it is when sealed")
        XCTAssertEqual(try decoded(sealed).breaths.map(\.path), ["a", "b", "c"], "and the merge is what is sealed")
    }

    func testMergingIsIdempotentAndNeverLosesWhatEitherSideKnew() {
        let base = richState()
        var newer = PersistedState()
        newer.breaths = [breath("z")]
        newer.walkStep = 9
        newer.curriculum = ["launcher": Curriculum.Record(offers: 2, lastOfferedAt: nil, completedAt: nil),
                            "web": Curriculum.Record(offers: 1)]
        let once = base.merging(newer: newer)
        let twice = once.merging(newer: newer)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(once), try encoder.encode(twice))
        XCTAssertEqual(once.breaths.map(\.path), ["a", "z"])
        XCTAssertEqual(once.walkStep, 9)
        XCTAssertNotNil(once.curriculum?["launcher"]?.completedAt, "a lesson that was completed stays completed")
        XCTAssertEqual(once.curriculum?["web"]?.offers, 1)
        XCTAssertEqual(once.parked[5], CGRect(x: 1, y: 2, width: 3, height: 4), "an empty map does not erase the parked windows")
        XCTAssertEqual(once.latestBreath, "a")
        XCTAssertEqual(once.editorConsentAt, base.editorConsentAt)
    }

    // MARK: The keychain cannot be asked

    private func sealedState(custody: InMemoryKeyCustody, breaths: [String]) throws -> Data {
        let seed = SealedFixture.stateStore(file, vault: SealedFixture.vault(directory, custody: custody))
        for path in breaths { seed.setBreath(breath(path)) }
        seed.load()
        return try Data(contentsOf: sealed)
    }

    func testAPausedStateRunsOnMemoryAndNeverWritesOverTheSealedFile() throws {
        let custody = InMemoryKeyCustody()
        let before = try sealedState(custody: custody, breaths: ["a", "z"])
        let listing = names()
        let locked = LockedCustody(copying: custody)
        let store = StateStore(file: file, vault: Vault(custody: locked, directory: directory))

        store.load()

        guard case .paused(let why) = store.condition else { return XCTFail("\(store.condition)") }
        XCTAssertTrue(why.contains("locked"), why)
        XCTAssertFalse(store.isKnown)
        XCTAssertTrue(store.state.breaths.isEmpty, "nothing was read")
        XCTAssertTrue(try XCTUnwrap(store.bootWarning).contains("unavailable"))

        store.setBreath(breath("b"))
        store.setParked([9: CGRect(x: 0, y: 0, width: 1, height: 1)])
        store.touchUsage("com.example.app")
        store.setMeetingSpent(["m"])
        store.save()
        XCTAssertEqual(try Data(contentsOf: sealed), before, "the sealed file is as it was, byte for byte")
        XCTAssertEqual(names(), listing, "and nothing was written beside it, in the clear or otherwise")
        XCTAssertEqual(store.state.breaths.map(\.path), ["b"], "what changed is held in memory")
    }

    func testAPausedStateLeavesPlaintextAloneToo() throws {
        try writePlain(richState())
        let before = try Data(contentsOf: file)
        let custody = InMemoryKeyCustody()
        custody.failNext(with: .unavailable(.locked), on: .load)
        let store = SealedFixture.stateStore(file, vault: SealedFixture.vault(directory, custody: custody))
        guard case .paused = store.condition else { return XCTFail("\(store.condition)") }
        store.setBreath(breath("b"))
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(names(), ["state.json"])
    }

    func testWhenTheKeychainAnswersTheStateIsReadAndWhatChangedIsMergedNotLost() throws {
        let custody = InMemoryKeyCustody()
        _ = try sealedState(custody: custody, breaths: ["a", "z"])
        let locked = LockedCustody(copying: custody)
        let store = StateStore(file: file, vault: Vault(custody: locked, directory: directory))
        store.load()
        store.setBreath(breath("b"))
        _ = store.deleteBreath(at: "z")          // z is on disk, unread: it must not come back
        store.setWalkStep(3)

        let settled = expectation(description: "the keychain answered")
        store.onSettled = { settled.fulfill() }
        locked.unlock()
        store.retryIfPaused()
        wait(for: [settled], timeout: 5)

        XCTAssertEqual(store.condition, .ready)
        XCTAssertTrue(store.isKnown)
        XCTAssertEqual(store.state.breaths.map(\.path).sorted(), ["a", "b"], "disk and memory, minus what was deleted")
        XCTAssertEqual(store.walkStep, 3)
        XCTAssertNil(store.bootWarning, "the pause is over")
        XCTAssertEqual(try decoded(sealed).breaths.map(\.path).sorted(), ["a", "b"], "and it is written")
    }

    func testARefusalIsNotRetriedUntilTheNextLaunch() throws {
        let custody = InMemoryKeyCustody()
        _ = try sealedState(custody: custody, breaths: ["a"])
        custody.failNext(with: .unavailable(.accessDenied), on: .load)
        let store = StateStore(file: file, vault: Vault(custody: custody, directory: directory))
        store.load()
        guard case .paused = store.condition else { return XCTFail("\(store.condition)") }
        store.retryIfPaused()
        XCTAssertEqual(store.state.breaths.count, 0)
        guard case .paused = store.condition else { return XCTFail("a refusal stays refused: \(store.condition)") }
    }

    // MARK: The key is gone

    func testAKeyThatIsGoneMovesTheSealedFilesAsideNeverDeletesThemAndStartsFresh() throws {
        let custody = InMemoryKeyCustody()
        _ = try sealedState(custody: custody, breaths: ["a"])
        let before = try Data(contentsOf: sealed)
        // The custody has lost the ring: a restore without the keychain.
        let empty = InMemoryKeyCustody()
        let store = SealedFixture.stateStore(file, vault: SealedFixture.vault(directory, custody: empty))

        XCTAssertEqual(store.condition, .ready)
        XCTAssertTrue(store.state.breaths.isEmpty, "the unreadable state is not read")
        XCTAssertTrue(try XCTUnwrap(store.bootWarning).contains("state-unreadable"), "the person is told where it is")
        let folder = try XCTUnwrap(names().first { $0.hasPrefix("state-unreadable-") })
        let kept = directory.appendingPathComponent(folder)
        XCTAssertEqual(try Data(contentsOf: kept.appendingPathComponent("state.sealed")), before, "moved, byte for byte")
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.appendingPathComponent("state.sealed.bak").path))
        XCTAssertFalse(names().contains("state.sealed"), "the live name is free for the new state")

        store.setBreath(breath("fresh"))
        XCTAssertEqual(SealedFixture.stateStore(file, vault: SealedFixture.vault(directory, custody: empty)).state.breaths.map(\.path),
                       ["fresh"], "a new ring was made and the new state is sealed under it")
        XCTAssertEqual(try Data(contentsOf: kept.appendingPathComponent("state.sealed")), before, "still untouched")
    }

    func testAKeyThatIsGoneBesideAPlaintextStateTakesThePlaintextIn() throws {
        let custody = InMemoryKeyCustody()
        _ = try sealedState(custody: custody, breaths: ["a"])
        try writePlain(richState())
        let empty = InMemoryKeyCustody()
        let store = SealedFixture.stateStore(file, vault: SealedFixture.vault(directory, custody: empty))
        XCTAssertEqual(store.state.breaths.map(\.path), ["a"], "from the plaintext, the only readable copy")
        XCTAssertNotNil(store.bootWarning)
        XCTAssertFalse(names().contains("state.json"))
    }

    // MARK: Damage

    func testATamperedSealedFileIsKeptAsEvidenceAndTheBackupIsUsed() throws {
        let store = SealedFixture.stateStore(file)
        store.setBreath(breath("q"))
        store.load()
        var bytes = try Data(contentsOf: sealed)
        bytes[bytes.count - 3] ^= 0xFF
        try bytes.write(to: sealed)

        let again = SealedFixture.stateStore(file)

        XCTAssertEqual(again.state.breaths.map(\.path), ["q"])
        XCTAssertTrue(try XCTUnwrap(again.bootWarning).contains("restored from backup"))
        let evidence = try XCTUnwrap(names().first { $0.hasPrefix("state.sealed.corrupt-") })
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(evidence)), bytes, "the damaged file, as it was")
    }

    func testAMissingStateBesideItsBackupIsRestoredNotStartedEmpty() throws {
        let store = SealedFixture.stateStore(file)
        store.setBreath(breath("q"))
        store.load()
        try FileManager.default.removeItem(at: sealed)
        let again = SealedFixture.stateStore(file)
        XCTAssertEqual(again.state.breaths.map(\.path), ["q"])
        XCTAssertNotNil(again.bootWarning)
    }

    // MARK: Opening in the background

    func testTheBackgroundOpenIsAdoptedByTheBootsWait() throws {
        _ = try sealedState(custody: InMemoryKeyCustody(), breaths: ["a"])
        let store = StateStore(file: file, vault: SealedFixture.vault(directory))
        var settled = 0
        store.onSettled = { settled += 1 }
        XCTAssertEqual(store.condition, .loading)
        store.openInBackground()
        XCTAssertTrue(store.waitForOpen(upTo: 5))
        XCTAssertEqual(store.state.breaths.map(\.path), ["a"])
        XCTAssertEqual(settled, 1)
        // The completion that follows on the main queue finds nothing left to adopt.
        let drained = expectation(description: "main drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
        XCTAssertEqual(settled, 1, "adopted once")
    }

    func testAKeychainThatIsSlowIsNotWaitedForAndWhatChangedMeanwhileIsMerged() throws {
        let custody = InMemoryKeyCustody()
        _ = try sealedState(custody: custody, breaths: ["a"])
        let gate = GatedCustody(custody)
        let store = StateStore(file: file, vault: Vault(custody: gate, directory: directory))
        store.openInBackground()
        let started = Date()
        XCTAssertFalse(store.waitForOpen(upTo: 0.1), "the prompt is still up")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(store.condition, .loading)
        XCTAssertFalse(store.isKnown)

        store.setBreath(breath("b"))   // held, not lost, and nothing is written yet
        let settled = expectation(description: "answered")
        store.onSettled = { settled.fulfill() }
        gate.open()
        wait(for: [settled], timeout: 5)
        XCTAssertEqual(store.state.breaths.map(\.path).sorted(), ["a", "b"])
        XCTAssertEqual(try decoded(sealed).breaths.map(\.path).sorted(), ["a", "b"])
    }

    // MARK: Readers that must change nothing

    func testAReaderSeesTheSealedStateAndChangesNothing() throws {
        let custody = InMemoryKeyCustody()
        let before = try sealedState(custody: custody, breaths: ["a", "b"])
        let listing = names()
        let reader = Vault(custody: custody, directory: directory)
        guard case .state(let state, let isSealed) = StateStore.read(file: file, vault: reader) else { return XCTFail() }
        XCTAssertEqual(state.breaths.map(\.path), ["a", "b"])
        XCTAssertTrue(isSealed)
        XCTAssertEqual(try Data(contentsOf: sealed), before)
        XCTAssertEqual(names(), listing)
    }

    func testAReaderOfAnUnsealedStateReadsItAndSealsNothing() throws {
        try writePlain(richState())
        let custody = InMemoryKeyCustody()
        guard case .state(let state, let isSealed) = StateStore.read(file: file, vault: Vault(custody: custody, directory: directory))
        else { return XCTFail() }
        XCTAssertEqual(state.breaths.map(\.path), ["a"])
        XCTAssertFalse(isSealed)
        XCTAssertEqual(names(), ["state.json"])
        XCTAssertTrue(custody.names.isEmpty, "a reader makes no key")
    }

    func testAReaderIsToldWhenTheKeyCannotBeAskedForAndNeverGivenAnEmptyState() throws {
        let custody = InMemoryKeyCustody()
        _ = try sealedState(custody: custody, breaths: ["a"])
        let locked = LockedCustody(copying: custody)
        guard case .unavailable = StateStore.read(file: file, vault: Vault(custody: locked, directory: directory)) else {
            return XCTFail()
        }
        let nothing = directory.appendingPathComponent("elsewhere/state.json")
        guard case .absent = StateStore.read(file: nothing, vault: Vault(custody: custody, directory: directory)) else {
            return XCTFail()
        }
    }

    /// A `state.json` left in the config folder by a build from before the
    /// folders were split is moved to the data folder, as ever, unless the
    /// state is sealed there: it would be merged in over everything newer.
    func testAPreSplitStateFileIsNotMovedBesideASealedState() throws {
        Paths.prepare()
        let old = Paths.config.appendingPathComponent("state.json")
        let sealedHome = Paths.data.appendingPathComponent("state.sealed")
        let landed = Paths.data.appendingPathComponent("state.json")
        let fm = FileManager.default
        defer { for url in [old, sealedHome, landed] { try? fm.removeItem(at: url) } }
        for url in [old, sealedHome, landed] { try? fm.removeItem(at: url) }

        try Data("{}".utf8).write(to: old)
        Paths.migrateIfNeeded()
        XCTAssertTrue(fm.fileExists(atPath: landed.path), "with no sealed state, the move is what it always was")
        XCTAssertFalse(fm.fileExists(atPath: old.path))

        try? fm.removeItem(at: landed)
        try Data("sealed".utf8).write(to: sealedHome)
        try Data("{}".utf8).write(to: old)
        Paths.migrateIfNeeded()
        XCTAssertFalse(fm.fileExists(atPath: landed.path), "beside a sealed state it is left where it is")
        XCTAssertTrue(fm.fileExists(atPath: old.path))
    }

    // MARK: The files, by name

    func testTheRecordFilesNameTheStateInBothForms() throws {
        let store = SealedFixture.stateStore(file)
        store.setBreath(breath("q"))
        store.load()
        try Data("{}".utf8).write(to: file)
        try Data("{}".utf8).write(to: plainBackup)
        XCTAssertEqual(RecordFiles.sealed(of: .state, in: directory.path, fileSystem: PosixFileSystem()),
                       ["state.sealed", "state.sealed.bak"])
        XCTAssertEqual(RecordFiles.plaintext(of: .state, in: directory.path, fileSystem: PosixFileSystem()),
                       ["state.json", "state.json.bak"])
        XCTAssertEqual(SealedFixture.sealedState(StateStore.defaultFile).lastPathComponent, RecordFiles.stateSealedName)
        XCTAssertEqual(RecordFiles.sealed(of: .logbook, in: directory.path, fileSystem: PosixFileSystem()), [],
                       "the state is not the logbook's")
    }

    func testDiagnoseSaysWhatItShould() throws {
        let custody = InMemoryKeyCustody()
        let vault = SealedFixture.vault(directory, custody: custody)
        try writePlain(richState())
        var report = RecordStatus.state(vault: vault, directory: directory)
        XCTAssertEqual(report.plaintextFiles, 1)
        XCTAssertTrue(RecordStatus.stateLines(report).joined().contains("not sealed yet"))
        _ = SealedFixture.stateStore(file, vault: vault)
        report = RecordStatus.state(vault: vault, directory: directory)
        XCTAssertEqual(report.key, .ready)
        XCTAssertEqual(report.sealedFiles, 2)
        XCTAssertEqual(report.plaintextFiles, 0)
        XCTAssertTrue(RecordStatus.stateLines(report).joined().contains("sealed under its own key"))
        let locked = Vault(custody: LockedCustody(copying: custody), directory: directory)
        XCTAssertTrue(RecordStatus.stateLines(RecordStatus.state(vault: locked, directory: directory)).joined().contains("PAUSED"))
    }
}

/// A keychain that waits (as one with a prompt up does) until `open()`.
final class GatedCustody: KeyCustody, @unchecked Sendable {
    private let base: InMemoryKeyCustody
    private let gate = DispatchSemaphore(value: 0)

    init(_ base: InMemoryKeyCustody) { self.base = base }

    func open() { gate.signal() }

    func load(name: String) throws(CustodyError) -> [UInt8]? {
        gate.wait()
        gate.signal()
        return try base.load(name: name)
    }

    func store(_ bytes: [UInt8], name: String) throws(CustodyError) { try base.store(bytes, name: name) }
    func delete(name: String) throws(CustodyError) { try base.delete(name: name) }
}
