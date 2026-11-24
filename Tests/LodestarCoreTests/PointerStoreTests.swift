import StoicSealed
import StoicStore
import XCTest
@testable import LodestarCore

/// The pointer's raw record: every kind of record round-trips, a reach
/// carries its reports inline and a torn tail loses only that reach,
/// and the header names the pointing devices.
final class PointerStoreTests: XCTestCase {
    private var directory: URL!
    private var vault: Vault!
    private var ring: Vault.Ring { vault.ring(.health) }
    private let utc = TimeZone(identifier: "UTC")!
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pointerstore-\(UUID().uuidString)", isDirectory: true)
        vault = SealedFixture.vault(directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store() -> PointerStore {
        PointerStore(directory: directory, installID: "test-install", timeZone: utc, appVersion: "1.2.3", ring: ring)
    }

    private var day: String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        return DayFile.day(of: base, calendar: cal)
    }

    /// The plaintext day file an earlier build wrote, with its tail cut by
    /// `tear` bytes: what a crash in the middle of a reach left behind.
    private func legacyFile(_ records: [PointerStore.Record], tear: Int = 0) throws -> URL {
        let header = store().header(for: day, roster: [])
        var data = DayFile.encode(header)
        for record in records { data.append(contentsOf: PointerStore.encode(record)) }
        data.removeLast(tear)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = DayFile.url(prefix: "pointer", day: day, in: directory)
        try data.write(to: url)
        return url
    }

    private var tornPair: [PointerStore.Record] {
        [.click(at: base, button: 0, source: .human, device: .mouse, index: 1, stage: 0, pressure: 0),
         .reach(start: base.addingTimeInterval(1), screen: 0,
                samples: (0..<50).map { _ in PointerStore.Sample(dt: 0.008, dx: 1, dy: 1) },
                end: base.addingTimeInterval(1.4))]
    }

    func testMotionAndWheelRunsRoundTripBesideTheReaches() throws {
        let store = store()
        let samples = [PointerStore.Sample(dt: 0, dx: 3, dy: -2), PointerStore.Sample(dt: 0.0083, dx: -1, dy: 0)]
        let records: [PointerStore.Record] = [
            .motion(start: base, screen: 2, samples: samples, end: base.addingTimeInterval(0.0083), held: false),
            .motion(start: base.addingTimeInterval(1), screen: 0, samples: samples,
                    end: base.addingTimeInterval(1.0083), held: true),
            .wheel(start: base.addingTimeInterval(2), samples: samples, end: base.addingTimeInterval(2.0083),
                   precise: true, momentum: false, device: .trackpad, index: 1),
            .wheel(start: base.addingTimeInterval(3), samples: [PointerStore.Sample(dt: 0, dx: 0, dy: -40)],
                   end: base.addingTimeInterval(3), precise: true, momentum: true, device: .trackpad, index: 1),
            .reach(start: base.addingTimeInterval(4), screen: 0, samples: samples, end: base.addingTimeInterval(4.1)),
        ]
        for record in records { store.append(record, roster: ["pad"]) }
        store.flushSync()
        let back = PointerStore.records(day: day, in: directory, ring: ring)
        XCTAssertEqual(back.count, records.count)
        guard case .motion(_, let screen, let got, _, let held) = back[0] else { return XCTFail("motion") }
        XCTAssertEqual(screen, 2)
        XCTAssertEqual(got.map(\.dx), [3, -1])
        XCTAssertFalse(held)
        guard case .motion(_, _, _, _, true) = back[1] else { return XCTFail("a drag's run is held") }
        guard case .wheel(_, let wheel, _, true, false, .trackpad, 1) = back[2] else { return XCTFail("wheel") }
        XCTAssertEqual(wheel.map(\.dy), [-2, 0])
        guard case .wheel(_, _, _, _, true, _, _) = back[3] else { return XCTFail("momentum is its own run") }
        guard case .reach = back[4] else { return XCTFail("the reach after the runs still reads") }
        // Every sampled kind walks whole, so a day takes more rows after it.
        var bytes: [UInt8] = []
        for record in records { bytes.append(contentsOf: PointerStore.encode(record)) }
        XCTAssertEqual(PointerStore.wholeLength(bytes), bytes.count)
        XCTAssertLessThan(PointerStore.wholeLength(Array(bytes.dropLast(3))), bytes.count - 3, "a torn tail is not whole")
    }

    func testEveryRecordKindRoundTrips() throws {
        let store = store()
        let samples = [PointerStore.Sample(dt: 0.008, dx: 3, dy: -2),
                       PointerStore.Sample(dt: 0.0081, dx: -120, dy: 7),
                       PointerStore.Sample(dt: 0.5, dx: 0, dy: 1)]
        let reach = PointerStore.Record.reach(start: base, screen: 1, samples: samples,
                                              end: base.addingTimeInterval(0.7))
        let click = PointerStore.Record.click(at: base.addingTimeInterval(0.7), button: 1, source: .human,
                                              device: .trackpad, index: 1, stage: 2, pressure: 0.734)
        let release = PointerStore.Record.release(at: base.addingTimeInterval(0.9), button: 1, press: 0.183)
        let scroll = PointerStore.Record.scroll(start: base.addingTimeInterval(2), seconds: 1.25,
                                                precise: true, momentum: true, device: .mouse, index: 2)
        let posted = PointerStore.Record.click(at: base.addingTimeInterval(3), button: 0, source: .lodestar,
                                               device: .unknown, index: 0, stage: 0, pressure: 0)
        for record in [reach, click, release, scroll, posted] { store.append(record, roster: ["pad", "mouse"]) }
        store.flushSync()
        let back = PointerStore.records(day: day, in: directory, ring: ring)
        XCTAssertEqual(back.count, 5)
        guard case .reach(let start, let screen, let got, let end) = back[0] else { return XCTFail("reach") }
        XCTAssertEqual(start.timeIntervalSince1970, base.timeIntervalSince1970, accuracy: 1e-6)
        XCTAssertEqual(screen, 1)
        XCTAssertEqual(got.count, 3)
        for (a, b) in zip(got, samples) {
            XCTAssertEqual(a.dt, b.dt, accuracy: 1e-4, "tenths of a millisecond")
            XCTAssertEqual(a.dx, b.dx)
            XCTAssertEqual(a.dy, b.dy)
        }
        XCTAssertEqual(end.timeIntervalSince(base), 0.7, accuracy: 1e-6)
        guard case .click(_, let button, let source, let device, let index, let stage, let pressure) = back[1]
        else { return XCTFail("click") }
        XCTAssertEqual(button, 1)
        XCTAssertEqual(source, .human)
        XCTAssertEqual(device, .trackpad)
        XCTAssertEqual(index, 1)
        XCTAssertEqual(stage, 2)
        XCTAssertEqual(pressure, 0.734, accuracy: 1e-3)
        guard case .release(_, _, let press) = back[2] else { return XCTFail("release") }
        XCTAssertEqual(press, 0.183, accuracy: 1e-6)
        guard case .scroll(_, let seconds, let precise, let momentum, let on, let which) = back[3]
        else { return XCTFail("scroll") }
        XCTAssertEqual(seconds, 1.25, accuracy: 1e-3)
        XCTAssertTrue(precise)
        XCTAssertTrue(momentum)
        XCTAssertEqual(on, .mouse)
        XCTAssertEqual(which, 2)
        guard case .click(_, _, let who, _, _, _, _) = back[4] else { return XCTFail("posted") }
        XCTAssertEqual(who, .lodestar)
        let header = try XCTUnwrap(PointerStore.read(day: day, in: directory, ring: ring).segments.first).header
        XCTAssertEqual(header.magic, Array("LDP1".utf8))
        XCTAssertEqual(header.roster, ["pad", "mouse"])
        XCTAssertEqual(header.appVersion, "1.2.3")
    }

    /// A plaintext file an earlier build left, torn mid-reach, reads as it
    /// always did (the reach is lost, the click is not), and sealing it
    /// carries every byte, torn tail included, so nothing is cut that was there.
    func testATornReachLosesOnlyItself() throws {
        let url = try legacyFile(tornPair, tear: 40)
        let plain = try PointerStore.read(url: url).records
        XCTAssertEqual(plain.count, 1)
        guard case .click = plain[0] else { return XCTFail("the whole click survives") }
        let store = store()
        XCTAssertEqual(store.migrateLegacy().files, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let back = PointerStore.records(day: day, in: directory, ring: ring)
        XCTAssertEqual(back.count, 1)
        guard case .click = back[0] else { return XCTFail("the whole click survives sealed") }
        let bytes = DayStore.read(prefix: "pointer", purpose: DayStore.purpose, day: day, in: directory, ring: ring,
                                  fileSystem: PosixFileSystem()).segments[0]
        XCTAssertEqual(bytes.count, DayFile.encode(store.header(for: day, roster: [])).count
                       + PointerStore.recordSize + (PointerStore.recordSize + 50 * PointerStore.sampleSize + PointerStore.recordSize) - 40,
                       "the torn bytes are kept, byte for byte")
    }

    /// A reach is as long as its samples, so a healthy day's body is
    /// rarely a multiple of the record size. The torn-tail check once took
    /// every such file for torn and opened a new segment at each flush:
    /// thousands of files, each append listing them all. Whole reaches keep
    /// one segment, flush after flush.
    func testWholeReachesKeepOneSegmentAcrossFlushes() {
        let store = store()
        for i in 0..<5 {
            let at = base.addingTimeInterval(Double(i))
            store.append(.reach(start: at, screen: 0,
                                samples: (0..<(3 + i)).map { _ in PointerStore.Sample(dt: 0.008, dx: 1, dy: 1) },
                                end: at.addingTimeInterval(0.1)))
            store.append(.click(at: at.addingTimeInterval(0.1), button: 0, source: .human, device: .mouse,
                                index: 1, stage: 0, pressure: 0))
            store.flushSync()
        }
        XCTAssertEqual(PointerStore.read(day: day, in: directory, ring: ring).segments.count, 1)
        XCTAssertEqual(PointerStore.records(day: day, in: directory, ring: ring).count, 10)
    }

    /// And a reach cut inside its samples does close its segment: what
    /// comes after is written to a new one and reads whole.
    func testAClickAfterATornReachOpensANewSegment() throws {
        let url = try legacyFile(Array(tornPair.suffix(1)), tear: 40)
        let store = store()
        XCTAssertEqual(store.migrateLegacy().files, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        store.append(.click(at: base.addingTimeInterval(1), button: 2, source: .human, device: .mouse,
                            index: 1, stage: 0, pressure: 0))
        store.flushSync()
        XCTAssertEqual(PointerStore.read(day: day, in: directory, ring: ring).segments.count, 2)
        let back = PointerStore.records(day: day, in: directory, ring: ring)
        guard case .click(_, let button, _, _, _, _, _)? = back.last else { return XCTFail("the click reads whole") }
        XCTAssertEqual(button, 2)
    }

    func testWholeLengthStopsWhereDecodeStops() {
        let reach = PointerStore.encode(.reach(start: base, screen: 0,
                                               samples: [PointerStore.Sample(dt: 0.008, dx: 1, dy: 1)],
                                               end: base))
        let click = PointerStore.encode(.click(at: base, button: 0, source: .human, device: .mouse,
                                               index: 1, stage: 0, pressure: 0))
        let body = reach + click
        XCTAssertEqual(PointerStore.wholeLength(body), body.count)
        XCTAssertEqual(PointerStore.wholeLength(Array(body.dropLast(3))), reach.count, "a torn click")
        XCTAssertEqual(PointerStore.wholeLength(Array(reach.dropLast(5))), reach.count - 16,
                       "a torn trailer leaves the reach without it")
        XCTAssertEqual(PointerStore.wholeLength(Array(reach.prefix(20))), 0, "a reach torn in its samples")
    }

    func testARosterChangeOpensANewSegmentAndOlderDaysDeflate() throws {
        let store = store()
        store.append(.click(at: base, button: 0, source: .human, device: .trackpad, index: 1, stage: 0, pressure: 0),
                     roster: ["pad"])
        store.flushSync()
        store.append(.click(at: base.addingTimeInterval(1), button: 0, source: .human, device: .mouse, index: 2,
                            stage: 0, pressure: 0), roster: ["pad", "mouse"])
        store.flushSync()
        XCTAssertEqual(PointerStore.read(day: day, in: directory, ring: ring).segments.map(\.header.roster),
                       [["pad"], ["pad", "mouse"]])
        store.append(.click(at: base.addingTimeInterval(86_400), button: 0, source: .human, device: .mouse,
                            index: 2, stage: 0, pressure: 0), roster: ["pad", "mouse"])
        store.flushSync()
        XCTAssertEqual(PointerStore.days(in: directory).count, 2)
        XCTAssertEqual(PointerStore.records(day: day, in: directory, ring: ring).count, 2, "both deflated segments read")
        let journal = directory.appendingPathComponent(DayStore.journalName(prefix: "pointer", day: day))
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path + ".snapshot"))
        XCTAssertEqual(DayStore.read(prefix: "pointer", purpose: DayStore.purpose, day: day, in: directory, ring: ring,
                                     fileSystem: PosixFileSystem()).closed.count, 2)
    }

    func testAReachMotionYieldsItsSamples() {
        var motion = ReachMotion()
        motion.add(dx: 2, dy: 0, at: base)
        motion.add(dx: 4, dy: -1, at: base.addingTimeInterval(0.008))
        motion.add(dx: 1, dy: 3, at: base.addingTimeInterval(0.020))
        let samples = motion.samples
        XCTAssertEqual(samples.map(\.dx), [2, 4, 1])
        XCTAssertEqual(samples.map(\.dy), [0, -1, 3])
        XCTAssertEqual(samples[0].dt, 0, accuracy: 1e-6)
        XCTAssertEqual(samples[1].dt, 0.008, accuracy: 1e-6)
        XCTAssertEqual(samples[2].dt, 0.012, accuracy: 1e-6)
        XCTAssertEqual(motion.origin, base)
    }
}
