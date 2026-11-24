import XCTest
@testable import LodestarCore

/// What the clipboard keeps is the owner's alone, from the first byte.
final class PrivateFileTests: XCTestCase {
    private var directory: URL!
    private var previousMask: mode_t = 0

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-private-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The loosest umask there is: the mode must come from the file's
        // own request, not from what the process happens to subtract.
        previousMask = umask(0)
    }

    override func tearDown() {
        umask(previousMask)
        try? FileManager.default.removeItem(at: directory)
    }

    private func mode(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int) ?? -1
    }

    func testANewFileIsTheOwnersAlone() throws {
        let url = directory.appendingPathComponent("a.plain")
        try PrivateFile.write(Data("secret".utf8), to: url)
        XCTAssertEqual(mode(url), 0o600)
        XCTAssertEqual(try Data(contentsOf: url), Data("secret".utf8))
    }

    func testAFileAnOlderBuildLeftReadableIsTightenedWhenItIsWrittenOver() throws {
        let url = directory.appendingPathComponent("a.plain")
        try Data("old and much longer".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try PrivateFile.write(Data("new".utf8), to: url)
        XCTAssertEqual(mode(url), 0o600)
        XCTAssertEqual(try Data(contentsOf: url), Data("new".utf8), "truncated, not overlaid")
    }

    func testAnAtomicWriteIsPrivateAndLeavesNoTemporaryFile() throws {
        let url = directory.appendingPathComponent("a.plain")
        try Data("old".utf8).write(to: url)
        try PrivateFile.write(Data("new".utf8), to: url, atomically: true)
        XCTAssertEqual(mode(url), 0o600)
        XCTAssertEqual(try Data(contentsOf: url), Data("new".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["a.plain"])
    }

    func testBigAndEmptyBytesRoundTrip() throws {
        let big = Data((0..<5_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let url = directory.appendingPathComponent("big")
        try PrivateFile.write(big, to: url)
        XCTAssertEqual(try Data(contentsOf: url), big)
        let empty = directory.appendingPathComponent("empty")
        try PrivateFile.write(Data(), to: empty)
        XCTAssertEqual(try Data(contentsOf: empty), Data())
        XCTAssertEqual(mode(empty), 0o600)
    }

    func testAFailureIsThrownAndLeavesNothingBehind() {
        let missing = directory.appendingPathComponent("no-such-folder/a.plain")
        XCTAssertThrowsError(try PrivateFile.write(Data("x".utf8), to: missing))
        XCTAssertThrowsError(try PrivateFile.write(Data("x".utf8), to: missing, atomically: true))
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? ["?"], [])
    }

    func testALinkIsNeverFollowed() throws {
        let target = directory.appendingPathComponent("target")
        try Data("untouched".utf8).write(to: target)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try PrivateFile.write(Data("through the link".utf8), to: link))
        XCTAssertEqual(try Data(contentsOf: target), Data("untouched".utf8))
        // An atomic write replaces the link itself, and leaves what it
        // pointed at alone.
        try PrivateFile.write(Data("replaced".utf8), to: link, atomically: true)
        XCTAssertEqual(try Data(contentsOf: target), Data("untouched".utf8))
        XCTAssertEqual(try Data(contentsOf: link), Data("replaced".utf8))
    }

    func testRestrictingTightensAFileAndNothingElse() throws {
        let file = directory.appendingPathComponent("f")
        try Data("x".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertTrue(PrivateFile.restrict(existing: file.path))
        XCTAssertEqual(mode(file), 0o600)
        XCTAssertFalse(PrivateFile.restrict(existing: file.path), "already private: nothing to do")

        let target = directory.appendingPathComponent("target")
        try Data("x".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertFalse(PrivateFile.restrict(existing: link.path))
        XCTAssertEqual(mode(target), 0o644, "what a link points at is not ours to change")
        XCTAssertFalse(PrivateFile.restrict(existing: directory.path), "nor is a directory")
        XCTAssertFalse(PrivateFile.restrict(existing: directory.appendingPathComponent("absent").path))
    }
}
