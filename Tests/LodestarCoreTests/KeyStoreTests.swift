import StoicSealed
import StoicStore
import XCTest
@testable import LodestarCore

/// The raw record: what goes in comes out, in press order, from an open
/// day or a closed one, across the segments a day may have grown, and a
/// torn tail costs one record and nothing else. A first-format file
/// still reads.
final class KeyStoreTests: XCTestCase {
    private var directory: URL!
    private var vault: Vault!
    private var ring: Vault.Ring { vault.ring(.health) }
    private let utc = TimeZone(identifier: "UTC")!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keystore-\(UUID().uuidString)", isDirectory: true)
        vault = SealedFixture.vault(directory)
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
        KeyStore(directory: directory, installID: "test-install", timeZone: utc, appVersion: version, ring: ring)
    }

    func testRoundTripKeepsEveryFieldToTheMicrosecond() {
        let store = store()
        let presses = [press(0.5), press(0.25, hand: .right, kind: .space), press(1.0, hold: nil, kind: .backspace)]
        for p in presses { store.append(p) }
        store.flushSync()
        let day = KeyStore.day(of: presses[0].down, calendar: calendar())
        let back = KeyStore.presses(day: day, in: directory, ring: ring)
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
        letter.armed = true
        var modifier = press(0.5, hold: 1.7, kind: .modifier)
        modifier.modifiers = .control
        modifier.struck = 3
        modifier.finger = .pinky
        store.append(letter, roster: ["a", "b"])
        store.append(modifier, roster: ["a", "b"])
        store.flushSync()
        let day = KeyStore.day(of: letter.down, calendar: calendar())
        let back = KeyStore.presses(day: day, in: directory, ring: ring)
        XCTAssertEqual(back.count, 2)
        XCTAssertEqual(back[0].finger, .ring)
        XCTAssertEqual(back[0].modifiers, [.shift, .command])
        XCTAssertEqual(back[0].keyboard, 2)
        XCTAssertTrue(back[0].lid)
        XCTAssertTrue(back[0].armed, "a key under a tapped lode says so")
        XCTAssertFalse(back[1].armed)
        XCTAssertEqual(back[0].struck, 0)
        XCTAssertEqual(back[1].kind, .modifier)
        XCTAssertEqual(back[1].modifiers, .control)
        XCTAssertEqual(back[1].struck, 3)
        XCTAssertEqual(back[1].hold!, 1.7, accuracy: 1e-6)
        XCTAssertFalse(back[1].lid)
        let segments = KeyStore.segments(day: day, in: directory, ring: ring)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].header.roster, ["a", "b"])
    }

    func testHeaderNamesTheFormatTheInstallAndTheBuild() throws {
        let store = KeyStore(directory: directory, installID: "abcdefgh-rest", timeZone: utc, appVersion: "9.8.7", ring: ring)
        store.append(press(0))
        store.flushSync()
        let day = KeyStore.day(of: press(0).down, calendar: calendar())
        let segment = try XCTUnwrap(KeyStore.read(day: day, in: directory, ring: ring).segments.first)
        XCTAssertEqual(segment.header.magic, Array("LDK1".utf8))
        XCTAssertEqual(segment.header.version, 2)
        XCTAssertEqual(segment.header.recordSize, UInt16(KeyStore.recordSize))
        XCTAssertEqual(segment.header.install, "abcdefgh")
        XCTAssertEqual(segment.header.appVersion, "9.8.7")
        XCTAssertEqual(segment.header.bodyOffset, KeyStore.headerSize)
        XCTAssertEqual(segment.header.roster, [])
        // The bytes of the sealed segment are what the plaintext file was:
        // header, then one 24-byte row.
        let contents = DayStore.read(prefix: "keys", purpose: DayStore.purpose, day: day, in: directory, ring: ring,
                                     fileSystem: PosixFileSystem())
        XCTAssertEqual(contents.segments.first?.count, KeyStore.headerSize + KeyStore.recordSize)
        XCTAssertEqual(Array(contents.segments[0].prefix(4)), Array("LDK1".utf8))
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
        // As the plaintext file an earlier build left, before migration...
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
        // ...and as a sealed segment, after it.
        let store = store()
        XCTAssertEqual(store.migrateLegacy().files, 1)
        let sealed = KeyStore.read(day: day, in: directory, ring: ring)
        XCTAssertEqual(sealed.segments.count, 1)
        XCTAssertEqual(sealed.segments[0].header.version, 1)
        XCTAssertEqual(sealed.segments[0].presses.count, 1)
        XCTAssertEqual(sealed.segments[0].presses[0].finger, .unknown)
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
        let segments = KeyStore.segments(day: day, in: directory, ring: ring)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].header.roster, ["kb-a"])
        XCTAssertEqual(segments[0].presses.count, 1)
        XCTAssertEqual(segments[1].header.roster, ["kb-a", "kb-b"])
        XCTAssertEqual(segments[1].presses.count, 3, "the same roster appends to the open segment")
        XCTAssertEqual(KeyStore.presses(day: day, in: directory, ring: ring).map { $0.down.timeIntervalSince1970 - 1_700_000_000 },
                       [0, 1, 2, 3])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(DayStore.journalName(prefix: "keys", day: day)).path),
                      "a day is one journal, however many segments it holds")
        XCTAssertTrue(DayFile.segments(prefix: "keys", in: directory).isEmpty, "and no plaintext file is written")
    }

    func testABuildChangeOpensANewSegment() {
        let earlier = store("1.0.0")
        earlier.append(press(0))
        earlier.flushSync()
        let later = store("1.1.0")
        later.append(press(1))
        later.flushSync()
        let day = KeyStore.day(of: press(0).down, calendar: calendar())
        let segments = KeyStore.segments(day: day, in: directory, ring: ring)
        XCTAssertEqual(segments.map(\.header.appVersion), ["1.0.0", "1.1.0"])
        XCTAssertEqual(KeyStore.presses(day: day, in: directory, ring: ring).count, 2)
    }

    /// A write torn by a crash leaves bytes at the end of the journal; they
    /// are the journal's to cut, and the presses before them read back.
    func testATornTailIsIgnoredByLength() throws {
        let store = store()
        store.append(press(0))
        store.append(press(1))
        store.flushSync()
        let day = KeyStore.day(of: press(0).down, calendar: calendar())
        let url = directory.appendingPathComponent(DayStore.journalName(prefix: "keys", day: day))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([1, 2, 3, 4, 5]))
        try handle.close()
        XCTAssertEqual(KeyStore.presses(day: day, in: directory, ring: ring).count, 2)
    }

    /// Appending after a torn tail used to shift every later record: a
    /// press written behind five stray bytes read back as garbage. The
    /// torn segment is closed as it stands and the next press opens one.
    /// A press written after a crash that tore the journal's tail is not
    /// shifted: the writer reopens the journal, which cuts the torn bytes,
    /// and the press lands whole after the ones before.
    func testAPressAfterATornTailOpensANewSegment() throws {
        let first = store()
        first.append(press(0))
        first.flushSync()
        first.close()
        let day = KeyStore.day(of: press(0).down, calendar: calendar())
        let url = directory.appendingPathComponent(DayStore.journalName(prefix: "keys", day: day))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([1, 2, 3, 4, 5]))
        try handle.close()

        let second = store()
        second.append(press(2, hand: .right, kind: .space))
        second.flushSync()
        let back = KeyStore.presses(day: day, in: directory, ring: ring)
        XCTAssertEqual(back.count, 2)
        XCTAssertEqual(back[1].down.timeIntervalSince1970, 1_700_000_002, accuracy: 1e-6)
        XCTAssertEqual(back[1].hand, .right)
        XCTAssertEqual(back[1].kind, .space)
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
        let journal = directory.appendingPathComponent(DayStore.journalName(prefix: "keys", day: firstDay))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path + ".snapshot"), "an open day has no snapshot")
        store.append(today)
        store.flushSync()
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path + ".snapshot"),
                      "a later day closes it: one snapshot of deflated segments")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: journal.path)[.size] as? Int) ?? -1, 0,
                       "and the log is empty")
        XCTAssertEqual(KeyStore.days(in: directory), [firstDay, KeyStore.day(of: today.down, calendar: calendar())])
        let back = KeyStore.presses(day: firstDay, in: directory, ring: ring)
        XCTAssertEqual(back.count, 2, "both of yesterday's segments read back deflated")
        XCTAssertEqual(back[0].hold!, 0.09, accuracy: 1e-6)
        XCTAssertEqual(KeyStore.segments(day: firstDay, in: directory, ring: ring).map(\.header.roster), [["a"], ["a", "b"]])
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
        XCTAssertEqual(KeyStore.presses(day: days[0], in: directory, ring: ring).count, 2000)
    }

    private func calendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        return cal
    }
}
