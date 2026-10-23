import CryptoKit
import Foundation
import XCTest
@testable import LodestarCore

/// The zip the updater unpacks, and the paths it is willing to write.
/// The fixtures are real archives: deflate with a data descriptor and an
/// extra field, the shape `ditto -c -k` writes, plus the paths a zip slip
/// uses. A bad name fails before the destination is replaced.
final class UpdateArchiveTests: XCTestCase {
    private var directory: URL!
    private var destination: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        destination = directory.appendingPathComponent("staged", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: "/tmp/lodestar-updater-not-written"))
    }

    func testTheDigestIsRequiredAndCheckedBeforeAnythingIsUnpacked() throws {
        let data = try XCTUnwrap(Data(base64Encoded: Fixture.good))
        let zip = directory.appendingPathComponent("download.zip")
        try data.write(to: zip)
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertTrue(UpdateArchive.matches(file: zip, digest: "sha256:\(hex)"))
        XCTAssertTrue(UpdateArchive.matches(file: zip, digest: "sha256:\(hex.uppercased())"))
        XCTAssertFalse(UpdateArchive.matches(file: zip, digest: nil))
        XCTAssertFalse(UpdateArchive.matches(file: zip, digest: "sha256:" + String(repeating: "00", count: 32)))
        XCTAssertFalse(UpdateArchive.matches(file: directory.appendingPathComponent("missing.zip"), digest: "sha256:\(hex)"))
        for digest in [nil as String?, "md5:" + String(repeating: "ab", count: 16), "sha256:" + String(repeating: "a", count: 63), "sha256:", ""] {
            XCTAssertFalse(UpdateArchive.isSHA256(digest), String(describing: digest))
        }
    }

    func testAGoodArchiveLandsOnlyInsideAFreshDirectory() throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appendingPathComponent("old.txt"))
        let neighbor = directory.appendingPathComponent("neighbor.txt")
        try Data("stay".utf8).write(to: neighbor)

        try UpdateArchive.extract(try zip("good", Fixture.good), replacing: destination)

        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("lodestar.app/Contents/Info.plist")), "version-ok")
        let binary = destination.appendingPathComponent("lodestar.app/Contents/MacOS/lodestar")
        XCTAssertEqual(try String(contentsOf: binary), "#!/bin/sh\n")
        let mode = try FileManager.default.attributesOfItem(atPath: binary.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((mode?.intValue ?? 0) & 0o111, 0o111, "the executable bit survives")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath:
            destination.appendingPathComponent("lodestar.app/Contents/MacOS/tool").path), "lodestar")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("lodestar.app/Contents/._Info.plist").path),
                       "Finder metadata is not a file in the bundle")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("old.txt").path),
                       "the staging directory is replaced, not merged into")
        XCTAssertEqual(try String(contentsOf: neighbor), "stay")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("staged.incoming").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("staged.outgoing").path))
    }

    func testPathsThatLeaveTheDirectoryAreRefusedUnwritten() throws {
        let outside = "/tmp/lodestar-updater-not-written"
        let cases: [(String, String, String)] = [
            ("escape", Fixture.escape, "../escaped.txt"),
            ("nested", Fixture.nested, "lodestar.app/../../escaped.txt"),
            ("dotslash", Fixture.dotslash, "lodestar.app/./../../escaped.txt"),
            ("absolute", Fixture.absolute, outside),
            ("symlink", Fixture.symlink, "lodestar.app/link"),
            ("symlink-rel", Fixture.symlinkRel, "link"),
            ("empty", Fixture.emptyComponent, "lodestar.app//Info.plist"),
            ("backslash", Fixture.backslash, "..\\..\\escaped.txt"),
        ]
        for (name, base64, path) in cases {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let sentinel = destination.appendingPathComponent("sentinel")
            try Data("keep".utf8).write(to: sentinel)
            XCTAssertThrowsError(try UpdateArchive.extract(try zip(name, base64), replacing: destination)) { error in
                XCTAssertEqual(error as? UpdateArchive.ExtractError, .unsafePath(path), name)
            }
            XCTAssertEqual(try String(contentsOf: sentinel), "keep", name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("escaped.txt").path), name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: outside), name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("lodestar-updater-not-written").path), name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("staged.incoming").path), name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("staged.outgoing").path), name)
            try FileManager.default.removeItem(at: destination)
        }
    }

    func testNamesThatWouldLeaveStaging() {
        XCTAssertEqual(UpdateArchive.safeComponents("lodestar.app/Contents/Info.plist"),
                       ["lodestar.app", "Contents", "Info.plist"])
        XCTAssertEqual(UpdateArchive.safeComponents("lodestar.app/"), ["lodestar.app"])
        for name in ["../escaped.txt", "/tmp/x", "lodestar.app/../../x", "lodestar.app/./../x",
                     "lodestar.app//x", "~/.ssh/authorized_keys", "..\\..\\x", "a/../b", ""] {
            XCTAssertNil(UpdateArchive.safeComponents(name), name)
        }
    }

    func testAZipThatIsNotAZipIsNotUnpacked() throws {
        let junk = directory.appendingPathComponent("junk.zip")
        try Data("not a zip".utf8).write(to: junk)
        XCTAssertThrowsError(try UpdateArchive.extract(junk, replacing: destination)) { error in
            XCTAssertEqual(error as? UpdateArchive.ExtractError, .notAZip)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

        let chopped = directory.appendingPathComponent("chopped.zip")
        var data = try XCTUnwrap(Data(base64Encoded: Fixture.good))
        data.removeLast(40)
        try data.write(to: chopped)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: destination.appendingPathComponent("sentinel"))
        XCTAssertThrowsError(try UpdateArchive.extract(chopped, replacing: destination)) { error in
            XCTAssertTrue(error is UpdateArchive.ExtractError)
        }
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("sentinel")), "keep")
    }

    private func zip(_ name: String, _ base64: String) throws -> URL {
        let data = try XCTUnwrap(Data(base64Encoded: base64), name)
        let url = directory.appendingPathComponent("\(name).zip")
        try data.write(to: url)
        return url
    }
}

private enum Fixture {
    /// Deflate with a data descriptor and an extra field, a stored
    /// executable, an internal symlink, a directory, and a `._` sidecar.
    static let good = "UEsDBBQAAAAAAAAAAAAAAAAAAAAAAAAAAAANAAAAbG9kZXN0YXIuYXBwL1BLAwQUAAAAAAAAAAAAAAAAAAAAAAAAAAAAFgAAAGxvZGVzdGFyLmFwcC9Db250ZW50cy9QSwMEFAAIAAgAAAAAAAAAAAAAAAAAAAAAACAAEABsb2Rlc3Rhci5hcHAvQ29udGVudHMvSW5mby5wbGlzdFVYCAARIjNEVWZ3iJmId2YrSy0qzszP083PBgBQSwcILCEs2gwAAAAKAAAAUEsDBBQAAAAAAAAAAAAAAAAAAAAAAAAAAAAcAAAAbG9kZXN0YXIuYXBwL0NvbnRlbnRzL01hY09TL1BLAwQUAAAAAAAAAAAAHZ37BAoAAAAKAAAAJAAAAGxvZGVzdGFyLmFwcC9Db250ZW50cy9NYWNPUy9sb2Rlc3RhciMhL2Jpbi9zaApQSwMEFAAAAAAAAAAAAEup20QLAAAACwAAACIAAABsb2Rlc3Rhci5hcHAvQ29udGVudHMvLl9JbmZvLnBsaXN0QVBQTEVET1VCTEVQSwMEFAAAAAAAAAAAAOhmsLUIAAAACAAAACAAAABsb2Rlc3Rhci5hcHAvQ29udGVudHMvTWFjT1MvdG9vbGxvZGVzdGFyUEsBAhQDFAAAAAAAAAAAAAAAAAAAAAAAAAAAAA0AAAAAAAAAAAAAAO1BAAAAAGxvZGVzdGFyLmFwcC9QSwECFAMUAAAAAAAAAAAAAAAAAAAAAAAAAAAAFgAAAAAAAAAAAAAA7UErAAAAbG9kZXN0YXIuYXBwL0NvbnRlbnRzL1BLAQIUAxQACAAIAAAAAAAsISzaDAAAAAoAAAAgAAwAAAAAAAAAAACkgV8AAABsb2Rlc3Rhci5hcHAvQ29udGVudHMvSW5mby5wbGlzdFVYCAARIjNEVWZ3iFBLAQIUAxQAAAAAAAAAAAAAAAAAAAAAAAAAAAAcAAAAAAAAAAAAAADtQckAAABsb2Rlc3Rhci5hcHAvQ29udGVudHMvTWFjT1MvUEsBAhQDFAAAAAAAAAAAAB2d+wQKAAAACgAAACQAAAAAAAAAAAAAAO2BAwEAAGxvZGVzdGFyLmFwcC9Db250ZW50cy9NYWNPUy9sb2Rlc3RhclBLAQIUAxQAAAAAAAAAAABLqdtECwAAAAsAAAAiAAAAAAAAAAAAAACkgU8BAABsb2Rlc3Rhci5hcHAvQ29udGVudHMvLl9JbmZvLnBsaXN0UEsBAhQDFAAAAAAAAAAAAOhmsLUIAAAACAAAACAAAAAAAAAAAAAAAP+hmgEAAGxvZGVzdGFyLmFwcC9Db250ZW50cy9NYWNPUy90b29sUEsFBgAAAAAHAAcAEwIAAOABAAAAAA=="
    static let escape = "UEsDBBQAAAAAAAAAAABH3dx5AgAAAAIAAAAgAAAAbG9kZXN0YXIuYXBwL0NvbnRlbnRzL0luZm8ucGxpc3Rva1BLAwQUAAAAAAAAAAAAflME2QUAAAAFAAAADgAAAC4uL2VzY2FwZWQudHh0cHduZWRQSwECFAMUAAAAAAAAAAAAR93ceQIAAAACAAAAIAAAAAAAAAAAAAAApIEAAAAAbG9kZXN0YXIuYXBwL0NvbnRlbnRzL0luZm8ucGxpc3RQSwECFAMUAAAAAAAAAAAAflME2QUAAAAFAAAADgAAAAAAAAAAAAAApIFAAAAALi4vZXNjYXBlZC50eHRQSwUGAAAAAAIAAgCKAAAAcQAAAAAA"
    static let nested = "UEsDBBQAAAAAAAAAAAB+UwTZBQAAAAUAAAAeAAAAbG9kZXN0YXIuYXBwLy4uLy4uL2VzY2FwZWQudHh0cHduZWRQSwECFAMUAAAAAAAAAAAAflME2QUAAAAFAAAAHgAAAAAAAAAAAAAApIEAAAAAbG9kZXN0YXIuYXBwLy4uLy4uL2VzY2FwZWQudHh0UEsFBgAAAAABAAEATAAAAEEAAAAAAA=="
    static let absolute = "UEsDBBQAAAAAAAAAAAB+UwTZBQAAAAUAAAAhAAAAL3RtcC9sb2Rlc3Rhci11cGRhdGVyLW5vdC13cml0dGVucHduZWRQSwECFAMUAAAAAAAAAAAAflME2QUAAAAFAAAAIQAAAAAAAAAAAAAApIEAAAAAL3RtcC9sb2Rlc3Rhci11cGRhdGVyLW5vdC13cml0dGVuUEsFBgAAAAABAAEATwAAAEQAAAAAAA=="
    static let dotslash = "UEsDBBQAAAAAAAAAAAB+UwTZBQAAAAUAAAAgAAAAbG9kZXN0YXIuYXBwLy4vLi4vLi4vZXNjYXBlZC50eHRwd25lZFBLAQIUAxQAAAAAAAAAAAB+UwTZBQAAAAUAAAAgAAAAAAAAAAAAAACkgQAAAABsb2Rlc3Rhci5hcHAvLi8uLi8uLi9lc2NhcGVkLnR4dFBLBQYAAAAAAQABAE4AAABDAAAAAAA="
    static let symlink = "UEsDBBQAAAAAAAAAAADpPyPhIQAAACEAAAARAAAAbG9kZXN0YXIuYXBwL2xpbmsvdG1wL2xvZGVzdGFyLXVwZGF0ZXItbm90LXdyaXR0ZW5QSwECFAMUAAAAAAAAAAAA6T8j4SEAAAAhAAAAEQAAAAAAAAAAAAAA/6EAAAAAbG9kZXN0YXIuYXBwL2xpbmtQSwUGAAAAAAEAAQA/AAAAUAAAAAAA"
    static let symlinkRel = "UEsDBBQAAAAAAAAAAACPVqSQHwAAAB8AAAAEAAAAbGluay4uL2xvZGVzdGFyLXVwZGF0ZXItbm90LXdyaXR0ZW5QSwECFAMUAAAAAAAAAAAAj1akkB8AAAAfAAAABAAAAAAAAAAAAAAA/6EAAAAAbGlua1BLBQYAAAAAAQABADIAAABBAAAAAAA="
    static let emptyComponent = "UEsDBBQAAAAAAAAAAACDFtyMAQAAAAEAAAAYAAAAbG9kZXN0YXIuYXBwLy9JbmZvLnBsaXN0eFBLAQIUAxQAAAAAAAAAAACDFtyMAQAAAAEAAAAYAAAAAAAAAAAAAACkgQAAAABsb2Rlc3Rhci5hcHAvL0luZm8ucGxpc3RQSwUGAAAAAAEAAQBGAAAANwAAAAAA"
    static let backslash = "UEsDBBQAAAAAAAAAAAB+UwTZBQAAAAUAAAARAAAALi5cLi5cZXNjYXBlZC50eHRwd25lZFBLAQIUAxQAAAAAAAAAAAB+UwTZBQAAAAUAAAARAAAAAAAAAAAAAACkgQAAAAAuLlwuLlxlc2NhcGVkLnR4dFBLBQYAAAAAAQABAD8AAAA0AAAAAAA="
}
