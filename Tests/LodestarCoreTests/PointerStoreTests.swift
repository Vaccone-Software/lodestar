import XCTest
@testable import LodestarCore

/// The pointer's raw record: every kind of record round-trips, a reach
/// carries its reports inline and a torn tail loses only that reach,
/// and the header names the pointing devices.
final class PointerStoreTests: XCTestCase {
    private var directory: URL!
    private let utc = TimeZone(identifier: "UTC")!
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pointerstore-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store() -> PointerStore {
        PointerStore(directory: directory, installID: "test-install", timeZone: utc, appVersion: "1.2.3")
    }

    private var day: String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        return DayFile.day(of: base, calendar: cal)
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
        let back = PointerStore.records(day: day, in: directory)
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
        let (header, _) = try PointerStore.read(url: DayFile.url(prefix: "pointer", day: day, in: directory))
        XCTAssertEqual(header.magic, Array("LDP1".utf8))
        XCTAssertEqual(header.roster, ["pad", "mouse"])
        XCTAssertEqual(header.appVersion, "1.2.3")
    }

    func testATornReachLosesOnlyItself() throws {
        let store = store()
        store.append(.click(at: base, button: 0, source: .human, device: .mouse, index: 1, stage: 0, pressure: 0))
        store.append(.reach(start: base.addingTimeInterval(1), screen: 0,
                            samples: (0..<50).map { _ in PointerStore.Sample(dt: 0.008, dx: 1, dy: 1) },
                            end: base.addingTimeInterval(1.4)))
        store.flushSync()
        let url = DayFile.url(prefix: "pointer", day: day, in: directory)
        var data = try Data(contentsOf: url)
        data.removeLast(40) // mid-samples
        try data.write(to: url)
        let back = PointerStore.records(day: day, in: directory)
        XCTAssertEqual(back.count, 1)
        guard case .click = back[0] else { return XCTFail("the whole click survives") }
    }

    func testARosterChangeOpensANewSegmentAndOlderDaysDeflate() {
        let store = store()
        store.append(.click(at: base, button: 0, source: .human, device: .trackpad, index: 1, stage: 0, pressure: 0),
                     roster: ["pad"])
        store.flushSync()
        store.append(.click(at: base.addingTimeInterval(1), button: 0, source: .human, device: .mouse, index: 2,
                            stage: 0, pressure: 0), roster: ["pad", "mouse"])
        store.flushSync()
        XCTAssertEqual(DayFile.segments(prefix: "pointer", in: directory).map(\.index), [0, 1])
        store.append(.click(at: base.addingTimeInterval(86_400), button: 0, source: .human, device: .mouse,
                            index: 2, stage: 0, pressure: 0), roster: ["pad", "mouse"])
        store.flushSync()
        XCTAssertEqual(PointerStore.days(in: directory).count, 2)
        XCTAssertEqual(PointerStore.records(day: day, in: directory).count, 2, "both deflated segments read")
        XCTAssertEqual(DayFile.segments(prefix: "pointer", in: directory).filter { $0.day == day }.map(\.compressed),
                       [true, true])
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
