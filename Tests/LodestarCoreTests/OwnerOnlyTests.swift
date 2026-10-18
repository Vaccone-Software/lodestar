import StoicStore
import XCTest
@testable import LodestarCore

/// A note waiting in the outbox is private, so every file a store makes
/// through `OwnerOnly.fileSystem` is 0o600 from its first byte, and what an
/// earlier build made open is closed by `OwnerOnly.tighten`.
final class OwnerOnlyTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-owneronly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func mode(_ name: String) throws -> Int {
        (try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent(name).path)[.posixPermissions] as? Int) ?? -1
    }

    func testTheStoresOwnFilesAreOwnerOnly() throws {
        let path = directory.appendingPathComponent("j").path
        let journal = try Journal.open(
            at: path, fileSystem: OwnerOnly.fileSystem, options: .init(crossProcessLock: true))
        try journal.append([1, 2, 3])
        try journal.compact(snapshot: [9])
        try journal.append([4])
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(names, ["j", "j.lock", "j.snapshot"], "the log, its lock and its snapshot")
        for name in names { XCTAssertEqual(try mode(name), 0o600, name) }
        try journal.close()
    }

    func testPlainStoicWouldHaveLeftThemReadable() throws {
        // The reason `OwnerOnly.fileSystem` is the default of every store, held
        // so a Stoic that changes its own default is noticed.
        let path = directory.appendingPathComponent("plain").path
        let journal = try Journal.open(at: path)
        try journal.append([1])
        XCTAssertEqual(try mode("plain"), 0o644)
        try journal.close()
    }

    func testFoldersTheStoresMakeAreOwnerOnly() throws {
        try OwnerOnly.fileSystem.createDirectory(directory.appendingPathComponent("a/b").path)
        XCTAssertEqual(try mode("a"), 0o700)
        XCTAssertEqual(try mode("a/b"), 0o700)
    }

    func testAFileThatAlreadyExistsIsTightenedByTheSweepAndNotByOpening() throws {
        let path = directory.appendingPathComponent("old").path
        let plain = try Journal.open(at: path)
        try plain.append([1])
        try plain.close()
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("sub/deeper"), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        let nested = directory.appendingPathComponent("sub/deeper/note")
        XCTAssertTrue(FileManager.default.createFile(atPath: nested.path, contents: Data([1]), attributes: [.posixPermissions: 0o644]))
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("link").path, withDestinationPath: nested.path)
        XCTAssertEqual(try mode("old"), 0o644)

        let journal = try Journal.open(at: path, fileSystem: OwnerOnly.fileSystem)
        XCTAssertEqual(try mode("old"), 0o644, "a mode is given to what is created; opening one that exists changes nothing")
        try journal.close()

        XCTAssertEqual(OwnerOnly.tighten(directory), 5, "the data folder itself, the file, the two folders and the note")
        XCTAssertEqual(try mode("old"), 0o600, "a queue an older build made open to the group is closed by the sweep")
        XCTAssertEqual(try mode("sub"), 0o700)
        XCTAssertEqual(try mode("sub/deeper"), 0o700)
        XCTAssertEqual(try mode("sub/deeper/note"), 0o600)
        XCTAssertEqual(OwnerOnly.tighten(directory), 0, "idempotent")
    }

    func testTheFeedbackQueueIsBehavioralAndKeptOutOfBackups() {
        XCTAssertTrue(Paths.isBehavioral("feedback-outbox"))
        XCTAssertEqual(Paths.feedbackOutbox.lastPathComponent, "feedback-outbox")
        XCTAssertEqual(Paths.feedbackOutbox.deletingLastPathComponent().path, Paths.data.path)
    }
}
