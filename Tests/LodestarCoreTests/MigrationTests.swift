import StoicSealed
import StoicStore
import XCTest
@testable import LodestarCore

/// The plaintext an earlier build left becomes sealed without a byte lost:
/// each file is taken in, read back and compared, and only then removed; an
/// interruption at any step leaves the plaintext, or both (finished by the
/// next run, never repeated), never neither; and what an older build writes
/// afterwards is merged, not overwritten.
final class MigrationTests: XCTestCase {
    private var directory: URL!
    private var vault: Vault!
    private var ring: Vault.Ring { vault.ring(.health) }
    private let utc = TimeZone(identifier: "UTC")!
    private let fs = PosixFileSystem()
    private let base = 1_700_000_000.0

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        vault = SealedFixture.vault(directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private var keysDirectory: URL { directory.appendingPathComponent("keys", isDirectory: true) }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }

    private var day: String { DayFile.day(of: Date(timeIntervalSince1970: base), calendar: calendar) }

    private func press(_ seconds: Double, hand: Keys.Hand = .left) -> KeyPress {
        KeyPress(down: Date(timeIntervalSince1970: base + seconds), hold: 0.09, hand: hand, kind: .letter,
                 shift: false, chord: false, gesture: false, lens: false, repeated: false, keyboardType: 40)
    }

    private func store(version: String = "9.9.9") -> KeyStore {
        KeyStore(directory: keysDirectory, installID: "legacy-install", timeZone: utc, appVersion: version, ring: ring)
    }

    /// The bytes of a plaintext segment as an older build wrote them.
    private func legacy(_ presses: [KeyPress], roster: [String] = [], version: String = "1.0.0", tail: [UInt8] = []) -> [UInt8] {
        var data = DayFile.encode(store(version: version).header(for: day, roster: roster))
        for press in presses { data.append(contentsOf: KeyStore.encode(press)) }
        return [UInt8](data) + tail
    }

    @discardableResult
    private func writeLegacy(_ bytes: [UInt8], segment: Int, compressed: Bool = false, day: String? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: keysDirectory, withIntermediateDirectories: true)
        let url = DayFile.url(prefix: "keys", day: day ?? self.day, segment: segment, in: keysDirectory, compressed: compressed)
        let stored = compressed ? try XCTUnwrap(DayCodec.deflate(bytes)) : bytes
        try Data(stored).write(to: url)
        return url
    }

    private func plaintextFiles() -> [DayFile.Segment] { DayFile.segments(prefix: "keys", in: keysDirectory) }

    // MARK: A day, file by file

    func testEveryKindOfDayFileIsSealedVerifiedAndRemoved() throws {
        let first = legacy([press(0), press(1)], roster: ["a"])
        let second = legacy([press(2, hand: .right)], roster: ["a", "b"], version: "1.1.0", tail: [1, 2, 3, 4, 5])
        let third = legacy([press(3), press(4)], roster: ["a", "b"], version: "1.2.0")
        try writeLegacy(first, segment: 0)
        try writeLegacy(second, segment: 1)
        try writeLegacy(third, segment: 2, compressed: true)
        let decodedBefore = try plaintextFiles().map { try KeyStore.read(url: $0.url).presses }
        XCTAssertEqual(decodedBefore.map(\.count), [2, 1, 2])

        let outcome = store().migrateLegacy()
        XCTAssertEqual(outcome.files, 3)
        XCTAssertEqual(outcome.remaining, 0)
        XCTAssertEqual(outcome.bytes, Int64(first.count + second.count + (try XCTUnwrap(DayCodec.deflate(third))).count))
        XCTAssertTrue(plaintextFiles().isEmpty, "the plaintext is gone")

        let sealed = KeyStore.read(day: day, in: keysDirectory, ring: ring)
        XCTAssertTrue(sealed.status.clean)
        XCTAssertEqual(sealed.segments.map(\.presses), decodedBefore, "decoded content identical, segment by segment")
        XCTAssertEqual(sealed.segments.map(\.header.roster), [["a"], ["a", "b"], ["a", "b"]])
        let raw = DayStore.read(prefix: "keys", purpose: DayStore.purpose, day: day, in: keysDirectory, ring: ring, fileSystem: fs)
        XCTAssertEqual(raw.segments, [first, second, third], "the torn tail is carried too: byte for byte")
        // Nothing on disk is the plaintext.
        for name in try FileManager.default.contentsOfDirectory(atPath: keysDirectory.path) {
            let bytes = try Data(contentsOf: keysDirectory.appendingPathComponent(name))
            XCTAssertNil(bytes.range(of: Data("LDK1".utf8)), "\(name) holds no plaintext header")
        }
    }

    func testAMigratedDayThatIsNotTodayIsFoldedIntoOneSnapshot() throws {
        try writeLegacy(legacy([press(0)]), segment: 0)
        try writeLegacy(legacy([press(1)], roster: ["a"]), segment: 1)
        _ = store().migrateLegacy()
        let journal = keysDirectory.appendingPathComponent(DayStore.journalName(prefix: "keys", day: day)).path
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal + ".snapshot"))
        XCTAssertEqual(KeyStore.presses(day: day, in: keysDirectory, ring: ring).count, 2)
    }

    func testMigrationIsIdempotent() throws {
        let bytes = legacy([press(0), press(1)])
        try writeLegacy(bytes, segment: 0)
        let store = store()
        XCTAssertEqual(store.migrateLegacy().files, 1)
        let again = store.migrateLegacy()
        XCTAssertEqual(again, RecordMigration())
        XCTAssertEqual(DayStore.read(prefix: "keys", purpose: DayStore.purpose, day: day, in: keysDirectory, ring: ring,
                                     fileSystem: fs).segments, [bytes])
    }

    /// The crash between "sealed" and "plaintext removed" leaves both. The
    /// next run finds the digest and removes; it never appends the day twice.
    func testAFileAlreadyTakenInIsOnlyRemoved() throws {
        let bytes = legacy([press(0), press(1)])
        try writeLegacy(bytes, segment: 0)
        let store = store()
        _ = store.migrateLegacy()
        try writeLegacy(bytes, segment: 0) // the plaintext the crash left behind
        // Read before the next run: the day is not doubled.
        XCTAssertEqual(KeyStore.presses(day: day, in: keysDirectory, ring: ring).count, 2)
        let outcome = store.migrateLegacy()
        XCTAssertEqual(outcome.files, 1)
        XCTAssertTrue(plaintextFiles().isEmpty)
        XCTAssertEqual(KeyStore.presses(day: day, in: keysDirectory, ring: ring).count, 2)
        XCTAssertEqual(DayStore.read(prefix: "keys", purpose: DayStore.purpose, day: day, in: keysDirectory, ring: ring,
                                     fileSystem: fs).segments, [bytes])
    }

    // MARK: Mixed and downgraded builds

    func testPlaintextAnOlderBuildWritesAfterwardsIsMergedNotOverwritten() throws {
        let sealedFirst = legacy([press(0), press(1)])
        try writeLegacy(sealedFirst, segment: 0)
        let store = store()
        _ = store.migrateLegacy()
        // A build from before sealing runs again today: it ignores the journal and starts its own file.
        let newer = legacy([press(10), press(11), press(12)], version: "0.49.0")
        try writeLegacy(newer, segment: 0)
        XCTAssertEqual(KeyStore.presses(day: day, in: keysDirectory, ring: ring).count, 5,
                       "readers accept both forms for the same day")
        let outcome = store.migrateLegacy()
        XCTAssertEqual(outcome.files, 1)
        XCTAssertTrue(plaintextFiles().isEmpty)
        let raw = DayStore.read(prefix: "keys", purpose: DayStore.purpose, day: day, in: keysDirectory, ring: ring, fileSystem: fs)
        XCTAssertEqual(raw.segments, [sealedFirst, newer], "appended in order, neither overwritten")
        XCTAssertEqual(KeyStore.presses(day: day, in: keysDirectory, ring: ring).count, 5)
    }

    func testRowsWrittenAfterAnImportOpenTheirOwnSegment() throws {
        try writeLegacy(legacy([press(0)]), segment: 0)
        let store = store()
        _ = store.migrateLegacy()
        store.append(press(2))
        store.flushSync()
        XCTAssertEqual(KeyStore.segments(day: day, in: keysDirectory, ring: ring).map(\.presses.count), [1, 1])
    }

    // MARK: Crashes

    private func simWrite(_ sim: SimulatedFileSystem, _ path: String, _ bytes: [UInt8]) throws {
        let file = try sim.open(path, mode: .createExclusive)
        try sim.write(file, bytes, at: 0)
        try sim.fullSync(file)
        try sim.close(file)
        try sim.syncDirectory(SealedPath.directory(of: path))
    }

    func testACrashAtEveryStepOfADayMigrationLosesNothingAndRepeatsNothing() throws {
        let first = legacy([press(0), press(1)], roster: ["a"])
        let second = legacy([press(2)], roster: ["a", "b"], tail: [9, 9])
        let sim = SimulatedFileSystem()
        let folder = URL(fileURLWithPath: "/data/keys")
        try sim.createDirectory(folder.path)
        try simWrite(sim, folder.appendingPathComponent("keys-\(day).bin").path, first)
        try simWrite(sim, folder.appendingPathComponent("keys-\(day).1.bin").path, second)
        sim.settle()
        let custody = InMemoryKeyCustody()
        let simVault = Vault(custody: custody, directory: URL(fileURLWithPath: "/data"), fileSystem: sim)
        let ring = simVault.ring(.health)
        XCTAssertNotNil(ring.keyring())

        func writer(_ fileSystem: SimulatedFileSystem) -> DayWriter {
            DayWriter(prefix: "keys", purpose: DayStore.purpose, directory: folder, ring: ring, fileSystem: fileSystem)
        }
        func read(_ fileSystem: SimulatedFileSystem) -> [[UInt8]] {
            DayStore.read(prefix: "keys", purpose: DayStore.purpose, day: day, in: folder, ring: ring, fileSystem: fileSystem).segments
        }
        let start = sim.operationCount
        let run = writer(sim)
        let outcome = run.migrate()
        run.closeAll()
        XCTAssertEqual(outcome.files, 2)
        let end = sim.operationCount
        XCTAssertGreaterThan(end - start, 5)

        var images = 0
        for count in start...end {
            for image in sim.crashImages(afterOperation: count, samples: 6) {
                let world = image.fileSystem
                // Whatever the crash left, the day reads whole and once.
                XCTAssertEqual(read(world), [first, second], "after \(count): \(image.description)")
                // The next run finishes it.
                let recovery = writer(world)
                let finished = recovery.migrate()
                recovery.closeAll()
                XCTAssertEqual(finished.remaining, 0, image.description)
                XCTAssertTrue(DayFile.segments(prefix: "keys", in: folder, fileSystem: world).isEmpty,
                              "no plaintext left: \(image.description)")
                XCTAssertEqual(read(world), [first, second], "after recovery: \(image.description)")
                images += 1
            }
        }
        XCTAssertGreaterThan(images, 20)
    }

    // MARK: An event log

    private func lines(_ events: [String]) -> [UInt8] { Array((events.joined(separator: "\n") + "\n").utf8) }

    private func logLines(_ log: EventLog) -> String { SealedFixture.text(of: log.file) }

    func testAPlaintextRingIsTakenInLineForLineIncludingWhatItCannotDecode() throws {
        let august = 1_786_000_000.0
        let known = #"{"kind":"verb","t":\#(august),"verb":"graph"}"#
        let unknownKind = #"{"kind":"assist","t":\#(august),"job":"guard"}"#
        let unknownField = #"{"kind":"verb","t":\#(august + 1),"verb":"x","novel":7}"#
        let garbage = "not json at all"
        let body = lines([known, unknownKind, unknownField, garbage])
        let file = directory.appendingPathComponent("events.jsonl")
        try Data(body).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

        let log = SealedFixture.eventLog(file)
        let outcome = log.migrateLegacy()
        XCTAssertEqual(outcome.files, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(logLines(log), String(decoding: body, as: UTF8.self), "every line, byte for byte, in order")
        XCTAssertEqual(log.readAll().count, 2, "the reader skips what it cannot decode, as it always did")
        let mode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("events.sj").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(log.migrateLegacy(), RecordMigration(), "idempotent")
    }

    func testAnUnterminatedLastLineIsKeptAsALineOfItsOwn() throws {
        let file = directory.appendingPathComponent("events.jsonl")
        try Data(#"{"kind":"verb","t":1,"verb":"a"}"#.utf8).write(to: file) // torn: no newline
        let log = SealedFixture.eventLog(file)
        XCTAssertEqual(log.migrateLegacy().files, 1)
        var event = ObservationEvent(t: Date(timeIntervalSince1970: 2), kind: .verb)
        event.verb = "b"
        log.append(event)
        log.flush()
        XCTAssertEqual(log.readAll().map(\.verb), ["a", "b"], "a later line is never glued to the torn one")
    }

    func testPlaintextAnOlderBuildWritesToTheRingIsMerged() throws {
        let file = directory.appendingPathComponent("events.jsonl")
        let log = SealedFixture.eventLog(file)
        var sealedEvent = ObservationEvent(t: Date(timeIntervalSince1970: 100), kind: .verb)
        sealedEvent.verb = "sealed"
        log.append(sealedEvent)
        log.flush()
        try Data(lines([#"{"kind":"verb","t":200,"verb":"older-build"}"#])).write(to: file)
        XCTAssertEqual(log.readAll().map(\.verb), ["sealed", "older-build"], "both forms read")
        XCTAssertEqual(log.migrateLegacy().files, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(log.readAll().map(\.verb), ["sealed", "older-build"])
        XCTAssertEqual(log.migrateLegacy(), RecordMigration())
    }

    func testALogAlreadyTakenInIsOnlyRemoved() throws {
        let file = directory.appendingPathComponent("events.jsonl")
        let body = lines([#"{"kind":"verb","t":100,"verb":"a"}"#, #"{"kind":"verb","t":101,"verb":"b"}"#])
        try Data(body).write(to: file)
        let log = SealedFixture.eventLog(file)
        _ = log.migrateLegacy()
        try Data(body).write(to: file) // the crash's leftover
        XCTAssertEqual(log.readAll().count, 2, "not doubled while both exist")
        XCTAssertEqual(log.migrateLegacy().files, 1)
        XCTAssertEqual(log.readAll().count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAMigratedDigestSurvivesACompaction() throws {
        let file = directory.appendingPathComponent("events.jsonl")
        let body = lines([#"{"kind":"verb","t":1785000000,"verb":"july"}"#, #"{"kind":"verb","t":1790000000,"verb":"sept"}"#])
        try Data(body).write(to: file)
        let log = SealedFixture.eventLog(file)
        _ = log.migrateLegacy()
        log.compact(now: Date(timeIntervalSince1970: 1_790_100_000)) // folds July into its shard, snapshots the live file
        try Data(body).write(to: file) // the leftover of a crash that preceded the compaction
        XCTAssertEqual(log.migrateLegacy().files, 1)
        XCTAssertEqual(log.readAll().map(\.verb), ["july", "sept"], "taken in once, however many compactions came between")
    }

    func testACrashAtEveryStepOfALogMigrationLosesNothingAndRepeatsNothing() throws {
        let body = lines([#"{"kind":"verb","t":100,"verb":"a"}"#, #"{"kind":"assist","t":101}"#, #"{"kind":"verb","t":102,"verb":"c"}"#])
        let sim = SimulatedFileSystem()
        try sim.createDirectory("/data")
        let url = URL(fileURLWithPath: "/data/events.jsonl")
        try simWrite(sim, url.path, body)
        sim.settle()
        let simVault = Vault(custody: InMemoryKeyCustody(), directory: URL(fileURLWithPath: "/data"), fileSystem: sim)
        let ring = simVault.ring(.logbook)
        XCTAssertNotNil(ring.keyring())

        func text(_ world: SimulatedFileSystem) -> [UInt8] { [UInt8](LineStore.read(plaintext: url, ring: ring, fileSystem: world).bytes) }
        let start = sim.operationCount
        let run = LineJournal(plaintext: url, ring: ring, fileSystem: sim)
        XCTAssertEqual(try run.migratePlaintext(decodedCount: { LineStore.lines($0).count }), body.count)
        run.close()
        let end = sim.operationCount

        var images = 0
        for count in start...end {
            for image in sim.crashImages(afterOperation: count, samples: 6) {
                let world = image.fileSystem
                XCTAssertEqual(text(world), body, "after \(count): \(image.description)")
                let recovery = LineJournal(plaintext: url, ring: ring, fileSystem: world)
                _ = try recovery.migratePlaintext(decodedCount: { LineStore.lines($0).count })
                recovery.close()
                XCTAssertFalse((try? world.exists(url.path)) ?? true, "no plaintext left: \(image.description)")
                XCTAssertEqual(text(world), body, "after recovery: \(image.description)")
                images += 1
            }
        }
        XCTAssertGreaterThan(images, 15)
    }

    // MARK: A whole file

    func testAWholeFileIsSealedInPlaceVerifiedAndTightened() throws {
        let file = directory.appendingPathComponent("era.json")
        let plain = Array(#"{"fingerprint":"x","at":0}"#.utf8)
        try Data(plain).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let sealed = SealedValueFile(url: file, ring: ring)
        XCTAssertEqual(sealed.read().bytes, plain, "a plaintext file reads as it is, until it is sealed")
        XCTAssertEqual(sealed.migrate(), .sealed(bytes: plain.count))
        XCTAssertTrue(Sealing.isSealed(Array(try Data(contentsOf: file).prefix(4))))
        XCTAssertEqual(sealed.read(), .value(plain, sealed: true))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(sealed.migrate(), .nothing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".sealing"))
    }

    func testACrashAtEveryStepOfAWholeFileMigrationNeverLosesTheFile() throws {
        let plain = Array(#"{"version":1,"months":{}}"#.utf8)
        let sim = SimulatedFileSystem()
        try sim.createDirectory("/data")
        let path = "/data/rollups.json"
        try simWrite(sim, path, plain)
        sim.settle()
        let simVault = Vault(custody: InMemoryKeyCustody(), directory: URL(fileURLWithPath: "/data"), fileSystem: sim)
        let ring = simVault.ring(.logbook)
        _ = ring.keyring()
        func file(_ world: SimulatedFileSystem) -> SealedValueFile {
            SealedValueFile(url: URL(fileURLWithPath: path), ring: ring, fileSystem: world)
        }
        let start = sim.operationCount
        XCTAssertEqual(file(sim).migrate(), .sealed(bytes: plain.count))
        let end = sim.operationCount
        var images = 0
        for count in start...end {
            for image in sim.crashImages(afterOperation: count, samples: 6) {
                let world = image.fileSystem
                XCTAssertEqual(file(world).read().bytes, plain, "after \(count): \(image.description)")
                XCTAssertNotEqual(file(world).migrate(), .paused)
                XCTAssertEqual(file(world).read(), .value(plain, sealed: true), image.description)
                for leftover in [path + ".sealing", path + ".sealing.tmp"] {
                    XCTAssertFalse((try? world.exists(leftover)) ?? true, "\(leftover) after recovery: \(image.description)")
                }
                images += 1
            }
        }
        XCTAssertGreaterThan(images, 5)
    }

    func testAnArchiveMonthIsSealedAndAnOldBuildsCopyIsMergedByItsLines() throws {
        let month = "2026-06"
        let plainFile = directory.appendingPathComponent("health-\(month).jsonl.z")
        let first = Data(lines([#"{"kind":"pulse","t":1780000000,"keys":3}"#]))
        try (first as NSData).compressed(using: .zlib).write(to: plainFile)
        let log = SealedFixture.eventLog(directory.appendingPathComponent("health-events.jsonl"), ring: .health)
        XCTAssertEqual(log.migrateArchives().files, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plainFile.path))
        let sealedFile = log.sealedHealthArchiveFile(for: month)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sealedFile.path))
        XCTAssertEqual(EventLog.healthArchive(month: month, beside: log.file, ring: ring).map(\.keys), [3])
        // The leftover of a crash (same lines): removed, not doubled.
        try (first as NSData).compressed(using: .zlib).write(to: plainFile)
        XCTAssertEqual(EventLog.healthArchive(month: month, beside: log.file, ring: ring).count, 1)
        XCTAssertEqual(log.migrateArchives().files, 1)
        XCTAssertEqual(EventLog.healthArchive(month: month, beside: log.file, ring: ring).count, 1)
        // Different lines written by an older build: appended.
        let more = Data(lines([#"{"kind":"pulse","t":1780000100,"keys":4}"#]))
        try (more as NSData).compressed(using: .zlib).write(to: plainFile)
        XCTAssertEqual(log.migrateArchives().files, 1)
        XCTAssertEqual(EventLog.healthArchive(month: month, beside: log.file, ring: ring).map(\.keys), [3, 4])
    }
}
