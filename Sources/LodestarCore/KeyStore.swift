import Foundation

/// The raw record: one fixed-width row per press, one file per local day,
/// kept for as long as the disk allows.
///
/// Everything else the health instrument writes is a summary — moments,
/// histograms, windows — and a summary answers the questions it was
/// designed for. This is the layer beneath: the press and release stamps
/// themselves, unkeyed, so that a question nobody has asked yet can still
/// be put to this year's typing in five years. Every window statistic is
/// recomputable from here; nothing here is recomputable from anything.
///
/// The format is deliberately dull. A `DayFile` header — the format, the
/// install, the build that wrote it, the keyboards attached — then
/// 24-byte little-endian records: microseconds since the Unix epoch for
/// the press, microseconds held (all ones when the release was never
/// seen), then hand, kind, flags and keyboard type as single bytes, the
/// finger, the modifiers, how many keys a modifier's own press covered,
/// which roster keyboard sent it, and whether the lid was closed. A
/// day's file is appended to as the day goes; when the build or the
/// roster changes mid-day a new segment opens beside it, so a header
/// never describes rows it did not see; and every segment is compressed
/// once a later day opens — the Compression framework's zlib, which is
/// raw DEFLATE (Python reads it with `zlib.decompress(data, -15)`). A
/// torn tail is ignored by length, so a crash mid-write costs at most
/// one record. Version-1 files (16-byte rows, 32-byte header) still
/// read, with the new columns at their defaults.
///
/// The day begins at four in the morning, as it does everywhere else in
/// the instrument, so an evening that runs past midnight stays one day.
public final class KeyStore {
    public static let version: UInt16 = 2
    public static let recordSize = 24
    public static let legacyRecordSize = 16
    /// The header's size with no roster — a roster pads it further.
    public static let headerSize = DayFile.fixedHeaderSize
    public static let magic: [UInt8] = Array("LDK1".utf8)
    public static let dayStartHour = DayFile.dayStartHour
    public static let unknownHold = UInt32.max
    /// Records buffered before a write is scheduled.
    public static let flushThreshold = 256
    public static let subdirectory = "keys"
    static let prefix = "keys"

    public let directory: URL
    public let installID: String
    public let appVersion: String
    private let calendar: Calendar
    private let queue = DispatchQueue(label: "lodestar.keys", qos: .utility)
    private var buffer: [(press: KeyPress, roster: [String])] = []
    private let lock = NSLock()

    public init(directory: URL, installID: String, timeZone: TimeZone = .current,
                appVersion: String = Lodestar.version) {
        self.directory = directory
        self.installID = installID
        self.appVersion = appVersion
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    // MARK: - Writing

    /// Any thread. Buffered; a keystroke never waits on the disk. The
    /// roster is the keyboards attached as the press was recorded — the
    /// header of the segment it lands in names them, and `press.keyboard`
    /// indexes into that list.
    public func append(_ press: KeyPress, roster: [String] = []) {
        lock.lock()
        buffer.append((press, roster))
        let due = buffer.count >= Self.flushThreshold
        lock.unlock()
        if due { flush() }
    }

    /// Write what is buffered, on the store's own queue.
    public func flush() {
        lock.lock()
        let pending = buffer
        buffer.removeAll()
        lock.unlock()
        guard !pending.isEmpty else { return }
        queue.async { [self] in write(pending) }
    }

    /// Write and wait — shutdown, and the tests.
    public func flushSync() {
        flush()
        queue.sync {}
    }

    private func write(_ pending: [(press: KeyPress, roster: [String])]) {
        // Runs of one day and one roster, in arrival order: each run goes
        // to the segment whose header matches, or opens the next.
        var runs: [(day: String, roster: [String], rows: [KeyPress])] = []
        for entry in pending.sorted(by: { $0.press.down < $1.press.down }) {
            let day = Self.day(of: entry.press.down, calendar: calendar)
            if let last = runs.last, last.day == day, last.roster == entry.roster {
                runs[runs.count - 1].rows.append(entry.press)
            } else {
                runs.append((day, entry.roster, [entry.press]))
            }
        }
        var newest = ""
        for run in runs {
            var records = Data()
            for row in run.rows { records.append(contentsOf: Self.encode(row)) }
            DayFile.append(records, prefix: Self.prefix, day: run.day,
                           header: header(for: run.day, roster: run.roster), in: directory)
            newest = max(newest, run.day)
        }
        if !newest.isEmpty { DayFile.compress(prefix: Self.prefix, before: newest, in: directory) }
    }

    func header(for day: String, roster: [String]) -> DayFile.Header {
        let start = Self.dayStart(of: day, calendar: calendar) ?? Date()
        return DayFile.Header(
            magic: Self.magic, version: Self.version, recordSize: UInt16(Self.recordSize),
            tzOffset: Int32(calendar.timeZone.secondsFromGMT(for: start)),
            dayStart: UInt64(max(0, start.timeIntervalSince1970 * 1e6)),
            install: installID, appVersion: appVersion, roster: roster,
            bodyOffset: 0)
    }

    // MARK: - Reading

    /// The days with a file, oldest first.
    public static func days(in directory: URL, compressed: Bool? = nil) -> [String] {
        DayFile.days(prefix: prefix, in: directory, compressed: compressed)
    }

    /// One day's presses, in press order, across every segment that
    /// holds part of it.
    public static func presses(day: String, in directory: URL) -> [KeyPress] {
        segments(day: day, in: directory).flatMap { $0.presses }.sorted { $0.down < $1.down }
    }

    /// One day's segments with their headers — the roster a `keyboard`
    /// index refers to is the header of the segment the row sits in.
    public static func segments(day: String, in directory: URL)
        -> [(header: DayFile.Header, presses: [KeyPress])] {
        DayFile.segments(prefix: prefix, in: directory)
            .filter { $0.day == day }
            .compactMap { segment in
                guard let (header, presses) = try? read(url: segment.url) else { return nil }
                return (header, presses)
            }
    }

    public static func read(url: URL) throws -> (header: DayFile.Header, presses: [KeyPress]) {
        let (header, body) = try DayFile.read(url: url)
        guard header.magic == magic else { return (header, []) }
        let size = Int(header.recordSize)
        guard size >= legacyRecordSize else { return (header, []) }
        let count = body.count / size
        var out: [KeyPress] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            out.append(decode(Array(body[(i * size)..<((i + 1) * size)])))
        }
        return (header, out.sorted { $0.down < $1.down })
    }

    // MARK: - Encoding

    static func encode(_ press: KeyPress) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(recordSize)
        let micros = UInt64(max(0, press.down.timeIntervalSince1970 * 1e6))
        out.append(contentsOf: DayFile.leBytes(micros))
        let hold: UInt32 = press.hold.map { UInt32(min(Double(UInt32.max - 1), max(0, $0 * 1e6))) } ?? unknownHold
        out.append(contentsOf: DayFile.leBytes(hold))
        out.append(press.hand.rawValue)
        out.append(press.kind.rawValue)
        var flags: UInt8 = 0
        if press.shift { flags |= 1 }
        if press.chord { flags |= 2 }
        if press.gesture { flags |= 4 }
        if press.lens { flags |= 8 }
        if press.repeated { flags |= 16 }
        if press.armed { flags |= 32 }
        out.append(flags)
        out.append(UInt8(min(255, max(0, press.keyboardType))))
        out.append(press.finger.rawValue)
        out.append(press.modifiers.rawValue)
        out.append(contentsOf: DayFile.leBytes(UInt16(min(65_535, max(0, press.struck)))))
        out.append(UInt8(min(255, max(0, press.keyboard))))
        out.append(press.lid ? 1 : 0)
        out.append(contentsOf: [0, 0])
        return out
    }

    /// A row of either width: the first sixteen bytes are the same in
    /// both, and a legacy row stops there.
    static func decode(_ bytes: [UInt8]) -> KeyPress {
        let micros = DayFile.readLE(bytes, 0, UInt64.self)
        let hold = DayFile.readLE(bytes, 8, UInt32.self)
        let flags = bytes[14]
        var press = KeyPress(
            down: Date(timeIntervalSince1970: Double(micros) / 1e6),
            hold: hold == unknownHold ? nil : Double(hold) / 1e6,
            hand: Keys.Hand(rawValue: bytes[12]) ?? .other,
            kind: Keys.Kind(rawValue: bytes[13]) ?? .other,
            shift: flags & 1 != 0, chord: flags & 2 != 0, gesture: flags & 4 != 0,
            lens: flags & 8 != 0, repeated: flags & 16 != 0,
            keyboardType: Int(bytes[15]), armed: flags & 32 != 0)
        guard bytes.count >= recordSize else { return press }
        press.finger = Keys.Finger(rawValue: bytes[16]) ?? .unknown
        press.modifiers = Keys.Modifiers(rawValue: bytes[17])
        press.struck = Int(DayFile.readLE(bytes, 18, UInt16.self))
        press.keyboard = Int(bytes[20])
        press.lid = bytes[21] & 1 != 0
        return press
    }

    // MARK: - Days

    /// The local day a moment belongs to, beginning at four in the
    /// morning.
    public static func day(of date: Date, calendar: Calendar) -> String {
        DayFile.day(of: date, calendar: calendar)
    }

    public static func dayStart(of day: String, calendar: Calendar) -> Date? {
        DayFile.dayStart(of: day, calendar: calendar)
    }

    public static func url(for day: String, in directory: URL, compressed: Bool = false) -> URL {
        DayFile.url(prefix: prefix, day: day, in: directory, compressed: compressed)
    }
}
