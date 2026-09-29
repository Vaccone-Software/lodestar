import XCTest
@testable import LodestarCore

/// Two writers on one log, the way an app and its successor share one at
/// an update: every line whole, none written over, and a writer whose file
/// the other rotated away follows it to the new one.
final class AppendingFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-append-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func line(_ writer: String, _ n: Int) -> Data {
        Data("12:00:00.000 INFO \(writer) line=\(n) padding=\(String(repeating: "x", count: 40))\n".utf8)
    }

    func testTwoWritersNeverWriteOverEachOther() throws {
        let url = directory.appendingPathComponent("lodestar.log")
        let a = AppendingFile(url: url, maxBytes: 50_000_000, keptRotations: 2)
        let b = AppendingFile(url: url, maxBytes: 50_000_000, keptRotations: 2)
        for n in 0..<500 {
            a.append(line("a", n))
            b.append(line("b", n))
        }
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1_000, "every line of both writers")
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("12:00:00.000 INFO ") }, "none torn")
        XCTAssertEqual(Set(lines).count, 1_000)
    }

    func testAWriterFollowsAFileTheOtherRotatedAway() throws {
        let url = directory.appendingPathComponent("lodestar.log")
        let a = AppendingFile(url: url, maxBytes: 1_000, keptRotations: 2)
        let b = AppendingFile(url: url, maxBytes: 50_000_000, keptRotations: 2)
        b.append(line("b", 0))                               // b opens the file
        for n in 0..<30 { a.append(line("a", n)) }           // a fills it and rotates it away
        b.append(line("b", 1))
        let live = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(live.contains("b line=1"), "b's next line is in the live file, not in .1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".1"))
    }

    func testRotationKeepsTheNumberAskedFor() throws {
        let url = directory.appendingPathComponent("lodestar.log")
        let a = AppendingFile(url: url, maxBytes: 500, keptRotations: 2)
        for n in 0..<200 { a.append(line("a", n)) }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(names, ["lodestar.log", "lodestar.log.1", "lodestar.log.2"])
    }
}
