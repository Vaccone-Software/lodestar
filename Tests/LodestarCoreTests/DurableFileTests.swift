import StoicStore
import XCTest
@testable import LodestarCore

/// The two durable ways onto disk: a whole-file replace that is synced and
/// says so when it fails, and an `O_APPEND` append that never replaces what
/// it could not open.
final class DurableFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-durable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        DurableFile.forgetFailures()
    }

    override func tearDown() {
        // A test leaves files read-only on purpose.
        if let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for name in names {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                       ofItemAtPath: directory.appendingPathComponent(name).path)
            }
        }
        try? FileManager.default.removeItem(at: directory)
        Log.listener = nil
    }

    private func permissions(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
    }

    // MARK: - write

    func testAWriteIsExactlyTheBytesGivenWithNoEnvelopeAndNoTemporaryLeft() throws {
        let url = directory.appendingPathComponent("a.json")
        try DurableFile.write(Data("{\"a\": 1}\n".utf8), to: url)
        XCTAssertEqual(try Data(contentsOf: url), Data("{\"a\": 1}\n".utf8), "readers see the same bytes as before")
        try DurableFile.write(Data("{\"a\": 2}\n".utf8), to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{\"a\": 2}\n")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["a.json"])
    }

    func testANewFileTakesTheModeAskedForAndAnOldOneKeepsItsOwn() throws {
        let url = directory.appendingPathComponent("private.json")
        try DurableFile.write(Data("x".utf8), to: url, newFileMode: 0o600)
        XCTAssertEqual(try permissions(url), 0o600)
        let open = directory.appendingPathComponent("open.json")
        try Data("x".utf8).write(to: open)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: open.path)
        try DurableFile.write(Data("y".utf8), to: open, newFileMode: 0o600)
        XCTAssertEqual(try permissions(open), 0o640, "a replacement is as private as what it replaces")
    }

    func testAFailedSaveIsLoggedOnceAndSaysFalse() {
        let url = directory.appendingPathComponent("missing-dir/a.json")
        var lines: [String] = []
        Log.listener = { lines.append($0) }
        XCTAssertFalse(DurableFile.save(Data("x".utf8), to: url, as: "unit"))
        XCTAssertFalse(DurableFile.save(Data("x".utf8), to: url, as: "unit"))
        let reported = lines.filter { $0.contains("unit: could not write a.json") }
        XCTAssertEqual(reported.count, 1, "a full disk is one line, not one per save")
        XCTAssertTrue(reported[0].contains("ERR"))
    }

    func testASaveThatWorksClearsTheFailureSoTheNextOneIsNewsAgain() throws {
        let url = directory.appendingPathComponent("sub/a.json")
        var lines: [String] = []
        Log.listener = { lines.append($0) }
        XCTAssertFalse(DurableFile.save(Data("x".utf8), to: url, as: "unit"))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(DurableFile.save(Data("x".utf8), to: url, as: "unit"))
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        XCTAssertFalse(DurableFile.save(Data("x".utf8), to: url, as: "unit"))
        XCTAssertEqual(lines.filter { $0.contains("could not write a.json") }.count, 2)
    }

    // MARK: - durability unknown

    /// A disk whose directory sync fails after the rename: the file is the
    /// new one, only its survival of a power cut is in doubt.
    private func unsyncedDisk() throws -> SimulatedFileSystem {
        let disk = SimulatedFileSystem()
        try disk.createDirectory("/d")
        disk.settle()
        disk.inject(EIO, on: .syncDirectory)
        return disk
    }

    func testAWriteWhoseDirectorySyncFailedIsMadeAndWarnedAbout() throws {
        let disk = try unsyncedDisk()
        var lines: [String] = []
        Log.listener = { lines.append($0) }
        try DurableFile.write(Data("new".utf8), to: URL(fileURLWithPath: "/d/a.json"), fileSystem: disk)
        XCTAssertEqual(disk.contents(of: "/d/a.json"), Array("new".utf8), "readers see the bytes")
        let warned = lines.filter { $0.contains("a.json: in place, but not known to be durable") }
        XCTAssertEqual(warned.count, 1)
        XCTAssertTrue(warned[0].contains("WARN"))
    }

    func testASaveWhoseDirectorySyncFailedSucceeds() throws {
        let disk = try unsyncedDisk()
        var lines: [String] = []
        Log.listener = { lines.append($0) }
        let url = URL(fileURLWithPath: "/d/a.json")
        XCTAssertTrue(DurableFile.save(Data("new".utf8), to: url, as: "unit", fileSystem: disk))
        XCTAssertEqual(disk.contents(of: "/d/a.json"), Array("new".utf8))
        XCTAssertFalse(lines.contains { $0.contains("ERR") }, "not a failure: \(lines)")
    }

    func testUnknownDurabilityIsWarnedOncePerNameUntilACleanCall() throws {
        var lines: [String] = []
        Log.listener = { lines.append($0) }
        let unknown = StoreError(kind: .durabilityUnknown, operation: "fsync", errnoValue: EIO)
        func attempt(_ name: String, failing: Bool) throws {
            try DurableFile.acceptingUnknownDurability(of: name) { if failing { throw unknown } }
        }
        try attempt("model", failing: true)
        try attempt("model", failing: true)
        try attempt("other", failing: true)
        XCTAssertEqual(lines.count, 2, "a flapping disk is one line per file, not one per save")
        try attempt("model", failing: false)
        try attempt("model", failing: true)
        XCTAssertEqual(lines.count, 3, "after a clean call the next one is news again")
    }

    func testEveryOtherFailureStillThrows() {
        for kind in [StoreError.Kind.diskFull, .readOnly, .ioFailure, .corrupt, .other] {
            let error = StoreError(kind: kind, operation: "write")
            XCTAssertThrowsError(try DurableFile.acceptingUnknownDurability(of: "x") { throw error }, "\(kind)") {
                XCTAssertEqual(($0 as? StoreError)?.kind, kind)
            }
        }
        struct Boom: Error {}
        XCTAssertThrowsError(try DurableFile.acceptingUnknownDurability(of: "x") { throw Boom() }) {
            XCTAssertTrue($0 is Boom)
        }
    }

    // MARK: - append

    func testAppendCreatesThenAddsAndKeepsTheBytesIdentical() throws {
        let url = directory.appendingPathComponent("log.jsonl")
        try DurableFile.append(Data("one\n".utf8), to: url)
        try DurableFile.append(Data("two\n".utf8), to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "one\ntwo\n")
        XCTAssertEqual(try permissions(url), 0o600)
    }

    func testAnAppendThatCannotOpenThrowsAndLeavesTheFileAlone() throws {
        let url = directory.appendingPathComponent("history.jsonl")
        try Data("precious\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        XCTAssertThrowsError(try DurableFile.append(Data("new\n".utf8), to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "precious\n")
    }

    func testTwoAppendersNeverWriteOverEachOther() throws {
        let url = directory.appendingPathComponent("two.jsonl")
        let group = DispatchGroup()
        for writer in ["a", "b"] {
            DispatchQueue.global().async(group: group) {
                for n in 0..<100 { try? DurableFile.append(Data("\(writer)\(n)\n".utf8), to: url) }
            }
        }
        group.wait()
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 200)
        XCTAssertEqual(Set(lines).count, 200)
    }

    // MARK: - The three that used to fall back to replacing the file

    private func entry(_ n: Int) -> ConfigHistory.Entry {
        ConfigHistory.Entry(group: n, index: 0, at: Date(timeIntervalSince1970: 1_790_000_000 + Double(n)),
                            path: ["k"], old: nil, new: .string("v\(n)"), source: "test")
    }

    func testConfigHistoryAppendsAndNeverReplacesAHistoryItCouldNotOpen() throws {
        let url = directory.appendingPathComponent("config-history.jsonl")
        ConfigHistory.append([entry(1)], to: url)
        ConfigHistory.append([entry(2)], to: url)
        XCTAssertEqual(ConfigHistory.read(from: url).map(\.group), [1, 2])
        let before = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        ConfigHistory.append([entry(3)], to: url)
        XCTAssertEqual(try Data(contentsOf: url), before, "the old fallback wrote a new file holding only entry 3")
    }

    func testDictationJournalAppendsWholeLinesAndSurvivesAFileItCannotOpen() throws {
        let journal = DictationJournal(folder: directory, days: 14)
        let now = Date()
        func dictate(_ text: String) {
            journal.begin(app: "Ghostty", at: now)
            journal.note("fix", before: "a", after: "b", at: now)
            journal.finish("pasted", text: text, at: now)
        }
        dictate("first")
        dictate("second")
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: directory.path).first)
        let url = directory.appendingPathComponent(file)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count, 2)
        let before = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        dictate("third") // must neither raise nor replace the file
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testADayFileSegmentIsContinuedAndNotReplacedWhenItCannotBeOpened() throws {
        let header = DayFile.Header(magic: Array("LDT1".utf8), version: 1, recordSize: 4, tzOffset: 0,
                                    dayStart: 0, install: "inst", appVersion: "1.0", roster: [], bodyOffset: 64)
        let records = Data([1, 2, 3, 4])
        let segment = DayFile.append(records, prefix: "unit", day: "2026-10-14", header: header, in: directory)
        DayFile.append(records, prefix: "unit", day: "2026-10-14", header: header, in: directory)
        let url = DayFile.url(prefix: "unit", day: "2026-10-14", segment: segment, in: directory)
        let whole = try Data(contentsOf: url)
        XCTAssertEqual(whole.count, 64 + 8, "one header, two records")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        DayFile.append(records, prefix: "unit", day: "2026-10-14", header: header, in: directory)
        XCTAssertEqual(try Data(contentsOf: url), whole, "the old fallback wrote headerless records over the day")
    }
}
