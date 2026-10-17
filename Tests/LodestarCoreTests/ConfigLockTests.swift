import XCTest
@testable import LodestarCore

/// `Config.edit` holds a lock across its read and its write, so the CLI and
/// the app cannot each read the old tree and the second to write undo the
/// first.
final class ConfigLockTests: XCTestCase {
    private var directory: URL!
    private var file: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-configlock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("lodestar.json")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    func testConcurrentEditsAllLand() throws {
        try Config.edit(in: file) { $0 }
        let group = DispatchGroup()
        let failures = NSLock()
        var errors: [Error] = []
        for writer in 0..<4 {
            DispatchQueue.global().async(group: group) {
                for n in 0..<3 {
                    do {
                        try Config.edit(in: self.file, lockTimeout: 30) { tree in
                            var tree = tree
                            tree["k\(writer)-\(n)"] = .string("v")
                            return tree
                        }
                    } catch {
                        failures.lock(); errors.append(error); failures.unlock()
                    }
                }
            }
        }
        group.wait()
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        let tree = try Json.parse(String(contentsOf: file, encoding: .utf8))
        for writer in 0..<4 { for n in 0..<3 {
            XCTAssertNotNil(tree["k\(writer)-\(n)"], "k\(writer)-\(n) was lost to another writer")
        } }
    }

    func testAHeldLockIsReportedAfterTheBoundedWaitAndTheFileIsUntouched() throws {
        try Config.edit(in: file) { _ in ["a": .string("1")] }
        let before = try Data(contentsOf: file)
        // Another process holding the lock: flock on the same sidecar.
        let held = open(file.path + ".lock", O_RDWR | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(held, 0)
        XCTAssertEqual(flock(held, LOCK_EX | LOCK_NB), 0)
        defer { close(held) }
        var ran = false
        let started = Date()
        XCTAssertThrowsError(try Config.edit(in: file, lockTimeout: 0.1) { tree in ran = true; return tree }) { error in
            guard case Config.EditError.busy = error else { return XCTFail("expected .busy, got \(error)") }
            XCTAssertTrue("\(error)".contains("another process"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        XCTAssertFalse(ran, "the transform does not run without the lock")
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testTheLockIsReleasedAfterAnEditAndAfterAThrowingOne() throws {
        struct Nope: Error {}
        XCTAssertThrowsError(try Config.edit(in: file) { _ in throw Nope() })
        try Config.edit(in: file, lockTimeout: 0.1) { _ in ["a": .string("1")] }
        try Config.edit(in: file, lockTimeout: 0.1) { $0 }
    }

    func testANewConfigIsTheOwnersAloneAndAnOldOneKeepsItsMode() throws {
        try Config.write(tree: ["graph": .table(["s": .string("Slack")])], to: file)
        func mode() throws -> Int { (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) ?? -1 }
        XCTAssertEqual(try mode(), 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        try Config.write(tree: ["graph": .table(["s": .string("Mail")])], to: file)
        XCTAssertEqual(try mode(), 0o644, "a file its owner made readable stays readable")
    }

    func testTheWriteIsTheSameBytesAsBeforeAndLeavesNoTemporary() throws {
        try Config.write(tree: ["graph": .table(["s": .string("Slack")])], to: file)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(text, Json.emit(try Json.parse(text)), "canonical, plain text: no envelope")
        XCTAssertTrue(text.contains("\"$schema\""))
        XCTAssertTrue(text.contains("\"s\": \"Slack\""))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".tmp") })
    }
}
