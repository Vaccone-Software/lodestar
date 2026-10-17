import StoicStore
import XCTest
@testable import LodestarCore

/// Stoic's file system creates files 0o644; a note waiting in the outbox is
/// private, so every file the store makes through this one is 0o600.
final class OwnerOnlyFileSystemTests: XCTestCase {
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
            at: path, fileSystem: OwnerOnlyFileSystem(), options: .init(crossProcessLock: true))
        try journal.append([1, 2, 3])
        try journal.compact(snapshot: [9])
        try journal.append([4])
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(names, ["j", "j.lock", "j.snapshot"], "the log, its lock and its snapshot")
        for name in names { XCTAssertEqual(try mode(name), 0o600, name) }
        try journal.close()
    }

    func testPlainStoicWouldHaveLeftThemReadable() throws {
        // The reason this type exists, held so a Stoic that fixes it is noticed.
        let path = directory.appendingPathComponent("plain").path
        let journal = try Journal.open(at: path)
        try journal.append([1])
        XCTAssertEqual(try mode("plain"), 0o644)
        try journal.close()
    }

    func testAFileThatAlreadyExistsIsTightened() throws {
        let path = directory.appendingPathComponent("old").path
        let plain = try Journal.open(at: path)
        try plain.append([1])
        try plain.close()
        XCTAssertEqual(try mode("old"), 0o644)
        let journal = try Journal.open(at: path, fileSystem: OwnerOnlyFileSystem())
        XCTAssertEqual(try mode("old"), 0o600, "a queue an older build made open to the group is closed on the next open")
        try journal.close()
    }

    func testAskingForMoreThanTheOwnerGetsNothingMore() throws {
        let fs = OwnerOnlyFileSystem()
        let path = directory.appendingPathComponent("x").path
        let file = try fs.open(path, mode: .createExclusive)
        try fs.setPermissions(file, to: 0o755)
        try fs.close(file)
        XCTAssertEqual(try mode("x"), 0o600)
    }

    func testTheFeedbackQueueIsBehavioralAndKeptOutOfBackups() {
        XCTAssertTrue(Paths.isBehavioral("feedback-outbox"))
        XCTAssertEqual(Paths.feedbackOutbox.lastPathComponent, "feedback-outbox")
        XCTAssertEqual(Paths.feedbackOutbox.deletingLastPathComponent().path, Paths.data.path)
    }
}
