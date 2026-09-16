import XCTest
@testable import LodestarCore

/// The raw record: what goes in comes out, in press order, from an open
/// day or a closed one, and a torn tail costs one record and nothing
/// else.
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

    func testRoundTripKeepsEveryFieldToTheMicrosecond() {
        let store = KeyStore(directory: directory, installID: "test-install", timeZone: utc)
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

    func testHeaderNamesTheFormatAndTheInstall() throws {
        let store = KeyStore(directory: directory, installID: "abcdefgh-rest", timeZone: utc)
        store.append(press(0))
        store.flushSync()
        let day = KeyStore.day(of: press(0).down, calendar: calendar())
        let data = try Data(contentsOf: KeyStore.url(for: day, in: directory))
        XCTAssertEqual(Array(data.prefix(4)), Array("LDK1".utf8))
        XCTAssertEqual(data.count, KeyStore.headerSize + KeyStore.recordSize)
        // magic 4, version 2, record size 2, tz 4, day start 8, then the install.
        XCTAssertEqual(String(bytes: data[20..<28], encoding: .utf8), "abcdefgh")
    }

    func testATornTailIsIgnoredByLength() throws {
        let store = KeyStore(directory: directory, installID: "t", timeZone: utc)
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
        let store = KeyStore(directory: directory, installID: "t", timeZone: utc)
        let yesterday = press(0)
        let today = press(86_400)
        store.append(yesterday)
        store.flushSync()
        let firstDay = KeyStore.day(of: yesterday.down, calendar: calendar())
        XCTAssertTrue(FileManager.default.fileExists(atPath: KeyStore.url(for: firstDay, in: directory).path))
        store.append(today)
        store.flushSync()
        XCTAssertFalse(FileManager.default.fileExists(atPath: KeyStore.url(for: firstDay, in: directory).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: KeyStore.url(for: firstDay, in: directory, compressed: true).path))
        XCTAssertEqual(KeyStore.days(in: directory), [firstDay, KeyStore.day(of: today.down, calendar: calendar())])
        let back = KeyStore.presses(day: firstDay, in: directory)
        XCTAssertEqual(back.count, 1)
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
        let store = KeyStore(directory: directory, installID: "t", timeZone: utc)
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
