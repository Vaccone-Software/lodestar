import StoicSealed
import StoicStore
import XCTest
@testable import LodestarCore

/// The sealed records in use: a paused key reads, writes, deletes and migrates
/// nothing; a second process reads what the first appends; the export gives
/// the old plaintext back; clearing the health record leaves nothing of it.
final class SealedRecordTests: XCTestCase {
    private var directory: URL!
    private let utc = TimeZone(identifier: "UTC")!
    private let fs = PosixFileSystem()

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sealedrecord-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        SealedFailures.reset()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private var keys: URL { directory.appendingPathComponent("keys", isDirectory: true) }

    private func press(_ seconds: Double) -> KeyPress {
        KeyPress(down: Date(timeIntervalSince1970: 1_700_000_000 + seconds), hold: 0.09, hand: .left, kind: .letter,
                 shift: false, chord: false, gesture: false, lens: false, repeated: false, keyboardType: 40)
    }

    private var day: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return DayFile.day(of: press(0).down, calendar: calendar)
    }

    private func store(_ vault: Vault) -> KeyStore {
        KeyStore(directory: keys, installID: "i", timeZone: utc, appVersion: "9.9.9", ring: vault.ring(.health))
    }

    private func event(_ t: Double, verb: String = "graph") -> ObservationEvent {
        var event = ObservationEvent(t: Date(timeIntervalSince1970: t), kind: .verb)
        event.verb = verb
        return event
    }

    private func snapshotOfDirectory() throws -> [String: Data] {
        var out: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(atPath: directory.path)
        while let name = enumerator?.nextObject() as? String {
            var isDirectory: ObjCBool = false
            let path = directory.appendingPathComponent(name).path
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
                out[name] = try Data(contentsOf: URL(fileURLWithPath: path))
            }
        }
        return out
    }

    // MARK: A paused key

    func testAPausedKeyStoreDropsPressesWritesNothingAndMigratesNothing() throws {
        let custody = InMemoryKeyCustody()
        let healthy = SealedFixture.vault(directory, custody: custody)
        let first = store(healthy)
        first.append(press(0))
        first.flushSync()
        first.close()
        // And a plaintext day an earlier build left.
        let other = DayFile.url(prefix: "keys", day: "2023-11-01", in: keys)
        try Data(DayFile.encode(first.header(for: "2023-11-01", roster: []))).write(to: other)
        let before = try snapshotOfDirectory()

        let paused = Vault(custody: LockedCustody(copying: custody), directory: directory)
        let second = store(paused)
        second.append(press(10))
        second.append(press(11))
        second.flushSync()
        XCTAssertEqual(second.dropped, 2)
        let migration = second.migrateLegacy()
        XCTAssertTrue(migration.paused)
        XCTAssertEqual(migration.remaining, 1)
        XCTAssertEqual(migration.files, 0)
        XCTAssertEqual(try snapshotOfDirectory(), before, "not a byte written, moved or deleted")
        XCTAssertEqual(KeyStore.read(day: day, in: keys, ring: paused.ring(.health)).status.unavailable, true,
                       "a read says the key is unavailable: not that the day is empty")
        XCTAssertEqual(KeyStore.presses(day: day, in: keys, ring: paused.ring(.health)), [])
    }

    func testAPausedLogHoldsItsEventsForTheKey() throws {
        let custody = InMemoryKeyCustody()
        let keychain = LockedCustody(copying: custody)
        let vault = Vault(custody: keychain, directory: directory)
        let log = EventLog(file: directory.appendingPathComponent("events.jsonl"), ring: vault.ring(.logbook))
        log.append(event(1))
        log.flush()
        XCTAssertEqual(try snapshotOfDirectory(), [:], "nothing written while paused")
        XCTAssertEqual(log.readAll().count, 1, "but held, and visible to a reader of this run")
        log.compact(now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(try snapshotOfDirectory(), [:])
        keychain.unlock()
        XCTAssertTrue(vault.ring(.logbook).retry())
        log.flush()
        XCTAssertEqual(log.readAll().map(\.verb), ["graph"])
        XCTAssertFalse(try snapshotOfDirectory().isEmpty)
    }

    func testAPausedStoreNeverWritesAFreshViewOverASealedOne() throws {
        let custody = InMemoryKeyCustody()
        let healthy = SealedFixture.vault(directory, custody: custody)
        let file = directory.appendingPathComponent("observations.json")
        let first = ObservationStore(file: file, vault: healthy)
        first.chainCompleted(["g"], gaps: [0.2], peeked: false, at: Date())
        first.flush()
        let sealed = try Data(contentsOf: file)
        XCTAssertTrue(Sealing.isSealed(Array(sealed.prefix(4))))

        let keychain = LockedCustody(copying: custody)
        let paused = Vault(custody: keychain, directory: directory)
        let second = ObservationStore(file: file, vault: paused)
        second.load()
        second.chainCompleted(["g"], gaps: [0.2], peeked: false, at: Date())
        second.flush()
        XCTAssertEqual(try Data(contentsOf: file), sealed, "the sealed view is untouched")
        XCTAssertEqual(second.observations.addresses["g"]?.completions, 1, "only this run's, until the key is back")

        keychain.unlock()
        XCTAssertTrue(paused.ring(.logbook).retry())
        second.resume()
        XCTAssertEqual(second.observations.addresses["g"]?.completions, 2, "the history, and what was recorded meanwhile")
        second.flush()
        XCTAssertNotEqual(try Data(contentsOf: file), sealed)
    }

    func testAShardThatDoesNotOpenIsNeverRetired() throws {
        let vault = SealedFixture.vault(directory, custody: InMemoryKeyCustody())
        let file = directory.appendingPathComponent("events.jsonl")
        let log = EventLog(file: file, ring: vault.ring(.logbook))
        _ = vault.ring(.logbook).keyring() // the ring exists: its key is not what is missing
        let june = log.shardFile(for: "2026-06")
        // A shard sealed under a key this ring does not hold.
        let stranger = try Keyring.open(name: "elsewhere", custody: InMemoryKeyCustody(), ifMissing: .create).keyring
        let journal = try SealedJournal.open(at: LineStore.journalPath(forPlaintext: june), context: LineStore.context(forPlaintext: june),
                                             keyring: stranger, fileSystem: fs, options: LineCodec.options)
        try journal.append(LineCodec.batchRecord(Array(#"{"kind":"pulse","t":1781000000}"#.utf8) + [0x0A]))
        try journal.close()
        log.append(event(1_790_000_000))
        log.flush()
        log.behavioralBound = 1
        log.compact(now: Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertTrue(FileManager.default.fileExists(atPath: LineStore.journalPath(forPlaintext: june)),
                      "unreadable is not garbage: the shard stays")
        XCTAssertGreaterThan(SealedFailures.tally.unknownKey, 0, "and the failure is counted, not swallowed")
        XCTAssertFalse(LineStore.read(plaintext: june, ring: vault.ring(.logbook), fileSystem: fs).whole)
    }

    // MARK: A second process

    func testAReaderSeesAWriterAppendingAndChangesNothing() throws {
        let custody = InMemoryKeyCustody()
        let writerVault = SealedFixture.vault(directory, custody: custody)
        let file = directory.appendingPathComponent("events.jsonl")
        let log = EventLog(file: file, ring: writerVault.ring(.logbook))
        log.append(event(1))
        log.flush()
        // The reader is another process: its own vault, its own ring object.
        let readerRing = Vault(custody: custody, directory: directory).ring(.logbook)
        let done = Flag()
        DispatchQueue.global().async {
            for i in 2...60 {
                log.append(self.event(Double(i)))
                log.flush()
            }
            done.raise()
        }
        var last = 0
        var finished = false
        while !finished {
            let seen = LineStore.read(plaintext: file, ring: readerRing, fileSystem: fs)
            XCTAssertTrue(seen.whole)
            let count = LineStore.lines(seen.bytes).count
            XCTAssertGreaterThanOrEqual(count, last, "a prefix of what was appended, growing")
            last = count
            finished = done.raised
        }
        XCTAssertEqual(EventLog.read(file: file, ring: readerRing).count, 60, "the writer lost nothing to the reader")
        XCTAssertEqual(SealedFailures.tally.total, 0)
    }

    func testAReaderWhoseRingIsOlderReloadsOnceAndReads() throws {
        let custody = InMemoryKeyCustody()
        let writerVault = SealedFixture.vault(directory, custody: custody)
        let file = directory.appendingPathComponent("events.jsonl")
        let log = EventLog(file: file, ring: writerVault.ring(.logbook))
        log.append(event(1))
        log.flush()
        let readerRing = Vault(custody: custody, directory: directory).ring(.logbook)
        XCTAssertNotNil(readerRing.existing(), "the reader opened its ring before the rotation")
        try XCTUnwrap(writerVault.ring(.logbook).keyring()).rotate()
        log.append(event(2))
        log.flush()
        XCTAssertEqual(EventLog.read(file: file, ring: readerRing).map(\.t.timeIntervalSince1970), [1, 2],
                       "an unknown key id reloads the ring once and reads again")
        XCTAssertEqual(SealedFailures.tally.total, 0)
    }

    // MARK: Export

    func testExportGivesBackThePlaintextFormats() throws {
        let vault = SealedFixture.vault(directory, custody: InMemoryKeyCustody())
        let store = store(vault)
        store.append(press(0), roster: ["a"])
        store.flushSync()
        store.append(press(1), roster: ["a", "b"])
        store.flushSync()
        store.append(press(86_400 * 2))
        store.flushSync() // closes the first day: one snapshot of deflated segments
        store.close()
        let health = SealedFixture.eventLog(directory.appendingPathComponent("health-events.jsonl"), ring: .health)
        health.append(event(100, verb: "pulse-ish"))
        health.flush()
        let era = SealedValueFile(url: directory.appendingPathComponent("era.json"), ring: vault.ring(.health))
        XCTAssertEqual(era.write(Array(#"{"fingerprint":"x"}"#.utf8)), .written)

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        let report = try RecordExport.export(logbook: false, from: directory, to: out, vault: vault)
        XCTAssertTrue(report.ok, "\(report.problems)")
        let names = report.written.map(\.path).sorted()
        XCTAssertEqual(names, ["blind.json"].filter { _ in false } + [
            "era.json", "health-events.jsonl",
            "keys/keys-\(day).1.bin.z", "keys/keys-\(day).bin.z", "keys/keys-2023-11-16.bin",
        ].sorted())
        // The documented recipe reads the closed day: raw DEFLATE.
        let packed = try Data(contentsOf: out.appendingPathComponent("keys/keys-\(day).bin.z"))
        let plain = try (packed as NSData).decompressed(using: .zlib) as Data
        let header = try XCTUnwrap(DayFile.readHeader(plain))
        XCTAssertEqual(header.roster, ["a"])
        XCTAssertEqual(plain.count, header.bodyOffset + KeyStore.recordSize)
        let open = try Data(contentsOf: out.appendingPathComponent("keys/keys-2023-11-16.bin"))
        XCTAssertEqual(try KeyStore.read(url: out.appendingPathComponent("keys/keys-2023-11-16.bin")).presses.count, 1)
        XCTAssertEqual(open.count, KeyStore.headerSize + KeyStore.recordSize)
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("era.json"), encoding: .utf8), #"{"fingerprint":"x"}"#)
        XCTAssertTrue(try String(contentsOf: out.appendingPathComponent("health-events.jsonl"), encoding: .utf8).contains("pulse-ish"))
        for file in report.written {
            let mode = try FileManager.default.attributesOfItem(atPath: out.appendingPathComponent(file.path).path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o600, file.path)
        }
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: out.path)[.posixPermissions] as? Int, 0o700)
        // Never into a folder that has something in it.
        XCTAssertThrowsError(try RecordExport.export(logbook: false, from: directory, to: out, vault: vault))
    }

    func testExportOfAPausedRecordSaysSoAndWritesNoEmptyFiles() throws {
        let custody = InMemoryKeyCustody()
        let healthy = SealedFixture.vault(directory, custody: custody)
        let store = store(healthy)
        store.append(press(0))
        store.flushSync()
        store.close()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        let report = try RecordExport.export(logbook: false, from: directory, to: out,
                                             vault: Vault(custody: LockedCustody(copying: custody), directory: directory))
        XCTAssertFalse(report.ok)
        XCTAssertTrue(report.written.isEmpty)
        XCTAssertTrue(report.problems.joined().contains("key is unavailable"))
    }

    // MARK: Clearing the health record

    func testClearingHealthLeavesNothingOfItAndDestroysItsKey() throws {
        let custody = InMemoryKeyCustody()
        let vault = SealedFixture.vault(directory, custody: custody)
        let observations = ObservationStore(file: directory.appendingPathComponent("observations.json"), vault: vault)
        let k = store(vault)
        k.append(press(0))
        k.flushSync()
        let pointer = PointerStore(directory: directory.appendingPathComponent("pointer"), installID: "i", timeZone: utc, ring: vault.ring(.health))
        pointer.append(.click(at: press(0).down, button: 0, source: .human, device: .mouse, index: 1, stage: 0, pressure: 0))
        pointer.flushSync()
        var pulse = ObservationEvent(t: Date(timeIntervalSince1970: 1_700_000_000), kind: .pulse)
        pulse.keys = 50
        observations.healthPulse(pulse)
        observations.chainCompleted(["g"], gaps: [0.2], peeked: false, at: Date(timeIntervalSince1970: 1_700_000_000))
        observations.flush()
        let aside = directory.appendingPathComponent("health-unreadable-2026-01-01/keys")
        try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
        try Data([1]).write(to: aside.appendingPathComponent("keys-x.sj"))
        for (name, bytes) in [("era.json", "{}"), ("blind.json", "{}"), ("install-id", "abc"), (".health-split", "")] {
            if name == "era.json" || name == "blind.json" {
                XCTAssertEqual(SealedValueFile(url: directory.appendingPathComponent(name), ring: vault.ring(.health)).write(Array(bytes.utf8)), .written)
            } else {
                try Data(bytes.utf8).write(to: directory.appendingPathComponent(name))
            }
        }
        let archive = SealedValueFile(url: directory.appendingPathComponent("health-2026-06.jsonl.z.sealed"), ring: vault.ring(.health))
        XCTAssertEqual(archive.write([1, 2, 3]), .written)
        // A rollup whose month holds health summaries beside the logbook's own.
        var month = Rollup.Month(firstEvent: Date(timeIntervalSince1970: 1_700_000_000), lastEvent: Date(timeIntervalSince1970: 1_700_000_100))
        month.health.keys = 999
        month.versions = ["1.0"]
        month.blindSpans = ["asleep": 3]
        month.verbs = ["graph": 4]
        var week = Rollup.WeekHealth()
        week.keys = 5
        week.switches = 7
        month.weeks = ["2700": week]
        var archiveOfMonths = Rollup()
        archiveOfMonths.months = ["2023-11": month]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let rollups = observations.rollupFile
        XCTAssertEqual(SealedValueFile(url: rollups, ring: vault.ring(.logbook)).write(Array(try encoder.encode(archiveOfMonths))), .written)

        observations.clearHealth()

        for name in ["keys", "pointer", "era.json", "blind.json", "install-id", ".health-split", "health-events.sj",
                     "health-2026-06.jsonl.z.sealed", "health-unreadable-2026-01-01"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path), name)
        }
        XCTAssertNil(custody.contents(of: "lodestar.ring.health"), "the health key is destroyed")
        XCTAssertNotNil(custody.contents(of: "lodestar.ring.logbook"), "the logbook's is not")
        XCTAssertEqual(observations.log.readAll().count, 1, "the logbook stands")
        let kept = try XCTUnwrap(Rollup.load(file: rollups, ring: vault.ring(.logbook)).archive?.months["2023-11"])
        XCTAssertTrue(kept.health.isEmpty)
        XCTAssertEqual(kept.versions, [])
        XCTAssertEqual(kept.blindSpans, [:])
        XCTAssertEqual(kept.weeks["2700"]?.keys, 0)
        XCTAssertEqual(kept.weeks["2700"]?.switches, 7, "what the logbook contributed stays")
        XCTAssertEqual(kept.verbs, ["graph": 4])
        // And the record can begin again: a new key, a new day.
        let again = store(vault)
        again.append(press(5))
        again.flushSync()
        XCTAssertEqual(KeyStore.presses(day: day, in: keys, ring: vault.ring(.health)).count, 1)
        XCTAssertNotNil(custody.contents(of: "lodestar.ring.health"))
    }

    // MARK: Modes and size

    func testSealedFilesAreOwnerOnlyAndTheFoldersToo() throws {
        let vault = SealedFixture.vault(directory, custody: InMemoryKeyCustody())
        let store = store(vault)
        store.append(press(0))
        store.flushSync()
        store.append(press(86_400 * 2))
        store.flushSync()
        store.close()
        func mode(_ url: URL) -> Int? { try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int }
        XCTAssertEqual(mode(keys), 0o700)
        for name in try FileManager.default.contentsOfDirectory(atPath: keys.path) {
            XCTAssertEqual(mode(keys.appendingPathComponent(name)), 0o600, name)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: keys.path).contains { $0.hasSuffix(".snapshot") })
    }

    func testTheSizeAccountingCountsTheSealedFiles() throws {
        let vault = SealedFixture.vault(directory, custody: InMemoryKeyCustody())
        let store = store(vault)
        for i in 0..<50 { store.append(press(Double(i))) }
        store.flushSync()
        store.append(press(86_400 * 2))
        store.flushSync()
        store.close()
        let log = SealedFixture.eventLog(directory.appendingPathComponent("health-events.jsonl"), ring: .health)
        log.append(event(1))
        log.flush()
        var expected: Int64 = 0
        for name in try FileManager.default.contentsOfDirectory(atPath: keys.path) {
            expected += Int64(try Data(contentsOf: keys.appendingPathComponent(name)).count)
        }
        expected += Int64(try Data(contentsOf: directory.appendingPathComponent("health-events.sj")).count)
        XCTAssertEqual(Retention.healthUsage(in: directory).bytes, expected)
        let ring = SealedFixture.eventLog(directory.appendingPathComponent("events.jsonl"))
        ring.append(event(2))
        ring.flush()
        XCTAssertGreaterThan(Retention.behavioralUsage(in: directory).bytes, 0)
        XCTAssertEqual(Retention.behavioralUsage(in: directory).bytes,
                       Int64(try Data(contentsOf: directory.appendingPathComponent("events.sj")).count))
    }

    func testTheStatusSaysWhatIsSealedAndWhatIsMigrating() throws {
        let vault = SealedFixture.vault(directory, custody: InMemoryKeyCustody())
        let store = store(vault)
        store.append(press(0))
        store.flushSync()
        store.close()
        try Data(DayFile.encode(store.header(for: "2023-11-01", roster: []))).write(
            to: DayFile.url(prefix: "keys", day: "2023-11-01", in: keys))
        let report = RecordStatus.health(vault: vault, directory: directory)
        XCTAssertEqual(report.key, .ready)
        XCTAssertEqual(report.days, 1)
        XCTAssertEqual(report.plaintextFiles, 1)
        XCTAssertEqual(report.unreadable, 0)
        XCTAssertEqual(RecordStatus.healthLines(report), ["health record: sealed, 1 day; migrating 1 files"])
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func raise() { lock.lock(); value = true; lock.unlock() }
    var raised: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
