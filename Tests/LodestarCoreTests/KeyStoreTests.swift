import XCTest
@testable import LodestarCore

/// The raw record: what goes in comes out, in press order, from an open
/// day or a closed one, across the segments a day may have grown, and a
/// torn tail costs one record and nothing else. A first-format file
/// still reads.
final class KeyStoreTests: XCTestCase {
    private var directory: URL!
    private let utc = TimeZone(identifier: "UTC")!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keystore-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func press(_ seconds: Double, hold: Double? = 0.09, hand: Keys.Hand = .left,
                       kind: Keys.Kind = .letter, base: Double = 1_700_000_000) -> KeyPress {
        KeyPress(down: Date(timeIntervalSince1970: base + seconds), hold: hold, hand: hand, kind: kind,
                 shift: hold == nil, chord: false, gesture: false,
                 lens: false, repeated: false, keyboardType: 40)
    }

    private func store(_ version: String = Lodestar.version) -> KeyStore {
        KeyStore(directory: directory, installID: "test-install", timeZone: utc, appVersion: version)
    }

    func testRoundTripKeepsEveryFieldToTheMicrosecond() {
        let store = store()
        let presses = [press(0.5), press(0.25, hand: .right, kind: .space), press(1.0, hold: nil, kind: .backspace)]
        for p in presses { store.append(p) }
        store.flushSync()
        let day = KeyStore.day(of: presses[0].down, calendar: calendar())
        let back = KeyStore.presses(day: day, in: directory)
        XCTAssertEqual(back.count, 3)
        // Sorted by press time, whatever order they were written in.
        XCTAssertEqual(back.map { $0.down.timeIntervalSince1970 }, [0.25, 0.5, 1.0].map { 1_700_000_000 + $0 })
        XCTAssertEqual(back[1].hold!, 0.09, accuracy: 1e-6)
        XCTAssertNil(back[2].hold)
        XCTAssertEqual(back[0].hand, .right)
        XCTAssertEqual(back[0].kind, .space)
        XCTAssertEqual(back[2].kind, .backspace)
        XCTAssertEqual(back[1].keyboardType, 40)
        XCTAssertTrue(back[2].shift)
        XCTAssertFalse(back[1].shift)
    }

    func testTheNewColumnsRoundTrip() {
        let store = store()
        var letter = press(0)
        letter.finger = .ring
        letter.modifiers = [.shift, .command]
        letter.keyboard = 2
        letter.lid = true
        var modifier = press(0.5, hold: 1.7, kind: .modifier)
        modifier.modifiers = .control
        modifier.struck = 3
        modifier.finger = .pinky
        store.append(letter, roster: ["a", "b"])
        store.append(modifier, roster: ["a", "b"])
        store.flushSync()
        let day = KeyStore.day(of: letter.down, calendar: calendar())
        let back = KeyStore.presses(day: day, in: directory)
        XCTAssertEqual(back.count, 2)
        XCTAssertEqual(back[0].finger, .ring)
        XCTAssertEqual(back[0].modifiers, [.shift, .command])
        XCTAssertEqual(back[0].keyboard, 2)
        XCTAssertTrue(back[0].lid)
        XCTAssertEqual(back[0].struck, 0)
        XCTAssertEqual(back[1].kind, .modifier)
        XCTAssertEqual(back[1].modifiers, .control)
        XCTAssertEqual(back[1].struck, 3)
        XCTAssertEqual(back[1].hold!, 1.7, accuracy: 1e-6)
        XCTAssertFalse(back[1].lid)
        let segments = KeyStore.segments(day: day, in: directory)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].header.roster, ["a", "b"])
    }

    func testHeaderNamesTheFormatTheInstallAndTheBuild() throws {
        let store = KeyStore(directory: directory, installID: "abcdefgh-rest", timeZone: utc, appVersion: "9.8.7")
        store.append(press(0))
        store.flushSync()
        let day = KeyStore.day(of: press(0).down, calendar: calendar())
        let data = try Data(contentsOf: KeyStore.url(for: day, in: directory))
        XCTAssertEqual(Array(data.prefix(4)), Array("LDK1".utf8))
        XCTAssertEqual(data.count, KeyStore.headerSize + KeyStore.recordSize)
        // magic 4, version 2, record size 2, tz 4, day start 8, then the install.
        XCTAssertEqual(data[4], 2)
        XCTAssertEqual(data[6], UInt8(KeyStore.recordSize))
        XCTAssertEqual(String(bytes: data[20..<28], encoding: .utf8), "abcdefgh")
        let header = try XCTUnwrap(DayFile.readHeader(data))
        XCTAssertEqual(header.appVersion, "9.8.7")
        XCTAssertEqual(header.bodyOffset, KeyStore.headerSize)
        XCTAssertEqual(header.roster, [])
    }

    /// The first format: a 32-byte header and 16-byte rows. It reads,
    /// with the columns it never had at their defaults.
    func testAVersionOneFileStillReads() throws {
        var data = Data("LDK1".utf8)
        func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] {
            (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) }
        }
        data.append(contentsOf: le(UInt16(1)))
        data.append(contentsOf: le(UInt16(16)))
        data.append(contentsOf: le(Int32(0)))
        data.append(contentsOf: le(UInt64(1_700_000_000_000_000)))
        data.append(contentsOf: Array("oldinst".utf8) + [0])
        data.append(contentsOf: [UInt8](repeating: 0, count: 32 - data.count))
        var row = press(0.5, hand: .right)
        row.finger = .index // must not survive: a v1 row has no such byte
        data.append(contentsOf: KeyStore.encode(row).prefix(16))
        let day = KeyStore.day(of: row.down, calendar: calendar())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: KeyStore.url(for: day, in: directory))
        let (header, back) = try KeyStore.read(url: KeyStore.url(for: day, in: directory))
        XCTAssertEqual(header.version, 1)
        XCTAssertEqual(header.bodyOffset, 32)
        XCTAssertEqual(header.install, "oldinst")
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].hand, .right)
        XCTAssertEqual(back[0].hold!, 0.09, accuracy: 1e-6)
        XCTAssertEqual(back[0].finger, .unknown)
        XCTAssertEqual(back[0].modifiers, [])
        XCTAssertEqual(back[0].keyboard, 0)
    }

    /// A header must never describe rows it did not see: a roster or a
    /// build that changes mid-day opens the next segment beside the day.
    func testARosterChangeOpensANewSegment() {
        let store = store()
        store.append(press(0), roster: ["kb-a"])
        store.flushSync()
        store.append(press(1), roster: ["kb-a", "kb-b"])
        store.append(press(2), roster: ["kb-a", "kb-b"])
        store.flushSync()
        store.append(press(3), roster: ["kb-a", "kb-b"])
        store.flushSync()
        let day = KeyStore.day(of: press(0).down, calendar: calendar())
        let segments = KeyStore.segments(day: day, in: directory)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].header.roster, ["kb-a"])
        XCTAssertEqual(segments[0].presses.count, 1)
        XCTAssertEqual(segments[1].header.roster, ["kb-a", "kb-b"])
        XCTAssertEqual(segments[1].presses.count, 3, "the same roster appends to the open segment")
        XCTAssertEqual(KeyStore.presses(day: day, in: directory).map { $0.down.timeIntervalSince1970 - 1_700_000_000 },
                       [0, 1, 2, 3])
        XCTAssertTrue(FileManager.default.fileExists(atPath: KeyStore.url(for: day, in: directory).path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: DayFile.url(prefix: "keys", day: day, segment: 1, in: directory).path))
    }

    func testABuildChangeOpensANewSegment() {
        let earlier = store("1.0.0")
        earlier.append(press(0))
        earlier.flushSync()
        let later = store("1.1.0")
        later.append(press(1))
        later.flushSync()
        let day = KeyStore.day(of: press(0).down, calendar: calendar())
        let segments = KeyStore.segments(day: day, in: directory)
        XCTAssertEqual(segments.map(\.header.appVersion), ["1.0.0", "1.1.0"])
        XCTAssertEqual(KeyStore.presses(day: day, in: directory).count, 2)
    }

    func testATornTailIsIgnoredByLength() throws {
        let store = store()
        store.append(press(0))
        store.append(press(1))
        store.flushSync()
        let day = KeyStore.day(of: press(0).down, calendar: calendar())
        let url = KeyStore.url(for: day, in: directory)
        var data = try Data(contentsOf: url)
        data.append(contentsOf: [1, 2, 3, 4, 5])
        try data.write(to: url)
        XCTAssertEqual(KeyStore.presses(day: day, in: directory).count, 2)
    }

    func testAnOlderDayIsCompressedWhenANewerOneOpens() throws {
        let store = store()
        let yesterday = press(0)
        let today = press(86_400)
        store.append(yesterday, roster: ["a"])
        store.flushSync()
        store.append(press(1), roster: ["a", "b"]) // a second segment of yesterday
        store.flushSync()
        let firstDay = KeyStore.day(of: yesterday.down, calendar: calendar())
        XCTAssertTrue(FileManager.default.fileExists(atPath: KeyStore.url(for: firstDay, in: directory).path))
        store.append(today)
        store.flushSync()
        XCTAssertFalse(FileManager.default.fileExists(atPath: KeyStore.url(for: firstDay, in: directory).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: KeyStore.url(for: firstDay, in: directory, compressed: true).path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: DayFile.url(prefix: "keys", day: firstDay, segment: 1, in: directory, compressed: true).path))
        XCTAssertEqual(KeyStore.days(in: directory), [firstDay, KeyStore.day(of: today.down, calendar: calendar())])
        let back = KeyStore.presses(day: firstDay, in: directory)
        XCTAssertEqual(back.count, 2, "both of yesterday's segments read back deflated")
        XCTAssertEqual(back[0].hold!, 0.09, accuracy: 1e-6)
    }

    func testTheDayBeginsAtFourInTheMorning() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        // 2023-11-14 22:13:20 UTC
        let evening = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(KeyStore.day(of: evening, calendar: cal), "2023-11-14")
        // 03:59 the next morning is still the 14th; 04:00 is the 15th.
        let threeFiftyNine = cal.date(from: DateComponents(year: 2023, month: 11, day: 15, hour: 3, minute: 59))!
        XCTAssertEqual(KeyStore.day(of: threeFiftyNine, calendar: cal), "2023-11-14")
        let four = cal.date(from: DateComponents(year: 2023, month: 11, day: 15, hour: 4))!
        XCTAssertEqual(KeyStore.day(of: four, calendar: cal), "2023-11-15")
    }

    func testAKeystrokeNeverWaitsOnTheDisk() {
        let store = store()
        let started = Date()
        for i in 0..<2000 { store.append(press(Double(i) * 0.1)) }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 0.5)
        store.flushSync()
        let days = KeyStore.days(in: directory)
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(KeyStore.presses(day: days[0], in: directory).count, 2000)
    }

    private func calendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        return cal
    }
}
