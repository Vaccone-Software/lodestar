import XCTest
@testable import LodestarCore

/// What the two launch-time readers of the logbook hold, measured where it
/// can be: in a process that has run nothing else.
///
/// A peak is one number for the life of a process, and a test process has
/// run a hundred other tests, which is why these run `probe memory-seed` and
/// `probe memory-rollup` (`Sources/probe/Memory.swift`): each writes a sealed
/// synthetic logbook of its own in a child, reads it, and says the footprint
/// before and the highest it was while reading. Nothing a neighbouring test
/// does can move either number, and the probe removes its folder.
final class LaunchMemoryTests: XCTestCase {
    private struct Reading: Decodable {
        let mode: String
        let path: String
        let events: Int
        let baseline: Int
        let peak: Int
        let stride: Int
        let switches: Int?
        let archived: Int?
        let held: Int?

        /// What the read held at its highest, above what the process held before it.
        var megabytes: Double { Double(peak - baseline) / 1_048_576 }
    }

    /// Where `swift build --build-tests` leaves the probe: beside the bundle.
    private var probe: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("probe")
    }

    /// Run the probe with `arguments`, and read its last line of standard output.
    /// A probe that does not finish in `seconds` is ended, with its folder.
    private func measure(_ arguments: [String], seconds: TimeInterval = 240) throws -> Reading {
        let tool = probe
        guard FileManager.default.isExecutableFile(atPath: tool.path) else {
            XCTFail("the probe is not built beside the tests (\(tool.path)): swift build --build-tests builds it")
            throw CocoaError(.fileNoSuchFile)
        }
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        let pid = process.processIdentifier
        // The pipe is read to its end while the probe runs, so a full pipe is never what it waits on.
        var data = Data()
        let reader = DispatchQueue(label: "launch-memory-reader")
        let read = DispatchSemaphore(value: 0)
        reader.async {
            data = output.fileHandleForReading.readDataToEndOfFile()
            read.signal()
        }
        if finished.wait(timeout: .now() + seconds) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 10)
            try? FileManager.default.removeItem(
                at: FileManager.default.temporaryDirectory.appendingPathComponent("lodestar-memprobe-\(pid)"))
            XCTFail("the probe did not finish in \(Int(seconds)) s: \(arguments)")
            throw CocoaError(.fileReadUnknown)
        }
        _ = read.wait(timeout: .now() + 10)
        XCTAssertEqual(process.terminationStatus, 0, "the probe failed: \(arguments)")
        let text = String(decoding: data, as: UTF8.self)
        let line = try XCTUnwrap(text.split(separator: "\n").last { $0.hasPrefix("RESULT ") }, "no result in: \(text)")
        return try JSONDecoder().decode(Reading.self, from: Data(line.dropFirst("RESULT ".count).utf8))
    }

    private func assertCleanStart(_ reading: Reading, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(reading.baseline, 100 << 20,
                          "a probe that starts big cannot say what the read added", file: file, line: line)
        XCTAssertLessThanOrEqual(reading.stride, 1_024, "the probe measures the event as it is", file: file, line: line)
    }

    /// The boot seed (ninety days of a ring of 220,000 events) used to hold
    /// every event of the window decoded, about 2.6 GB with events of 3,056
    /// bytes. It reads a shard at a time into a time and an app: what it holds
    /// is about a shard's bytes through the sealed reader, measured at 80 MB;
    /// 150 MB is a bound with room that a read of whole events does not fit in.
    func testTheBootSeedHoldsAShardNotTheRing() throws {
        let reading = try measure(["memory-seed", "--events", "220000"])
        assertCleanStart(reading)
        XCTAssertEqual(reading.path, "stream")
        XCTAssertGreaterThan(reading.switches ?? 0, 1_000, "the seed ran: it scored the switches")
        XCTAssertLessThan(reading.megabytes, 150, "the boot seed held \(Int(reading.megabytes)) MB")
    }

    /// The monthly roll (13 months of 200,000 events over both logs) used to
    /// decode every event of both logs and sort a copy: 4.3 GB at 350,000
    /// events of 3,056 bytes. It holds a month's lines at a time, however
    /// many months there are: measured at 50 MB at 350,000 events, and 100 MB
    /// leaves room for the largest month of a heavier hand, where the whole
    /// read grows with the whole ring.
    func testTheRollHoldsAMonthNotTheRing() throws {
        let reading = try measure(["memory-rollup", "--events", "200000"])
        assertCleanStart(reading)
        XCTAssertEqual(reading.path, "stream")
        XCTAssertGreaterThanOrEqual(reading.archived ?? 0, 12, "the roll ran: it archived the months")
        XCTAssertLessThan(reading.megabytes, 100, "the roll held \(Int(reading.megabytes)) MB")
    }

    /// The coach's refresh reads ninety days of the ring as events and holds
    /// them all, so what it costs is what an event costs: about 3.1 GB at
    /// 220,000 events of 3,056 bytes, 430 to 510 MB now (the events are 936
    /// and the read is one array, not a join and a filter of copies of it). A
    /// read that went back to the old event or the old chain of copies is
    /// well past 800 MB.
    func testTheCoachsRefreshHoldsTheEventsAtTheirSmallSize() throws {
        let reading = try measure(["memory-coach", "--events", "220000"])
        assertCleanStart(reading)
        XCTAssertEqual(reading.held, 220_000, "every event of the window is held, as the coach needs them")
        XCTAssertLessThan(reading.megabytes, 800, "the coach's read held \(Int(reading.megabytes)) MB")
    }

    /// The control: the same probe, on the whole read the seed used to take
    /// (still there for a report that wants every event), reads as large. A
    /// probe that read everything as small would pass the two tests above
    /// whatever the code did.
    func testTheProbeReadsTheWholeReadAsLarge() throws {
        let reading = try measure(["memory-seed", "--events", "220000", "--legacy"])
        assertCleanStart(reading)
        XCTAssertEqual(reading.path, "legacy")
        XCTAssertGreaterThan(reading.megabytes, 300, "the whole read held only \(Int(reading.megabytes)) MB")
    }
}
