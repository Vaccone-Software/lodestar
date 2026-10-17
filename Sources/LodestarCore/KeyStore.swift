import Foundation
import StoicStore

/// The raw record: one fixed-width row per press, one file per local day,
/// kept for as long as the disk allows.
///
/// Everything else the health instrument writes is a summary — moments,
/// histograms, windows — and a summary answers the questions it was
/// designed for. This is the layer beneath: the press and release stamps
/// themselves, with no key's identity (though hand, finger and kind leave
/// typed text partly recoverable; see `KeyPress`), so that a question
/// nobody has asked yet can still be put to this year's typing in five
/// years. Every window statistic is
/// recomputable from here; nothing here is recomputable from anything.
///
/// The format is deliberately dull. A `DayFile` header — the format, the
/// install, the build that wrote it, the keyboards attached — then
/// 24-byte little-endian records: microseconds since the Unix epoch for
/// the press, microseconds held (all ones when the release was never
/// seen), then hand, kind, flags and keyboard type as single bytes, the
/// finger, the modifiers, how many keys a modifier's own press covered,
/// which roster keyboard sent it, and whether the lid was closed. A
/// day is appended to as the day goes; when the build or the roster
/// changes mid-day a new segment opens, so a header never describes rows
/// it did not see; and every segment is compressed once a later day opens
/// — the Compression framework's zlib, which is raw DEFLATE (Python reads
/// it with `zlib.decompress(data, -15)`). Version-1 segments (16-byte
/// rows, 32-byte header) still read, with the new columns at their
/// defaults.
///
/// **At rest a day is sealed**: one `SealedJournal` per day
/// (`keys-YYYY-MM-DD.sj`, see `DayStore` for the bytes), whose records
/// are those segments, so what the disk holds is ciphertext and a flush
/// is one authenticated, durable append. The plaintext layout above is
/// what `lodestar health export` writes, and what older builds left
/// behind, which migration seals and removes.
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
    /// The health ring the days are sealed under.
    public let ring: Vault.Ring
    private let fileSystem: any FileSystem
    private let writer: DayWriter
    private var droppedPresses = 0
    /// Presses dropped because the health key was unavailable (the record
    /// is paused for the launch; see `Vault`).
    public var dropped: Int {
        lock.lock(); defer { lock.unlock() }
        return droppedPresses
    }

    private func drop(_ count: Int) {
        lock.lock(); droppedPresses += count; lock.unlock()
    }
    /// The install's name, asked for the first time a day journal is opened:
    /// an instrument that is off must not write even the file that names
    /// it.
    public var installID: String {
        lock.lock(); defer { lock.unlock() }
        if let resolvedInstall { return resolvedInstall }
        let id = resolveInstall()
        resolvedInstall = id
        return id
    }
    private let resolveInstall: () -> String
    private var resolvedInstall: String?
    public let appVersion: String
    private let calendar: Calendar
    private let queue = DispatchQueue(label: "lodestar.keys", qos: .utility)
    private var buffer: [(press: KeyPress, roster: [String])] = []
    private let lock = NSLock()

    public init(directory: URL, installID: @autoclosure @escaping () -> String,
                timeZone: TimeZone = .current, appVersion: String = Lodestar.version,
                ring: Vault.Ring, fileSystem: any FileSystem = OwnerOnlyFileSystem()) {
        self.directory = directory
        self.ring = ring
        self.fileSystem = fileSystem
        self.writer = DayWriter(prefix: Self.prefix, purpose: DayStore.purpose, directory: directory,
                                ring: ring, fileSystem: fileSystem)
        self.resolveInstall = installID
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

    /// Drop what is buffered and not yet written, and the install's name:
    /// the record was just deleted, and neither may land after it.
    public func discardBuffered() {
        lock.lock()
        buffer.removeAll()
        resolvedInstall = nil
        lock.unlock()
        queue.sync {}
    }

    /// Write and wait — shutdown, and the tests.
    public func flushSync() {
        flush()
        queue.sync {}
    }

    private func write(_ pending: [(press: KeyPress, roster: [String])]) {
        // The key first: with the record paused nothing is written, not even
        // the file that names the install.
        guard ring.keyring() != nil else {
            drop(pending.count)
            return
        }
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
        var byDay: [String: [DayWriter.Run]] = [:]
        for run in runs {
            var records = [UInt8]()
            for row in run.rows { records.append(contentsOf: Self.encode(row)) }
            byDay[run.day, default: []].append(.init(header: header(for: run.day, roster: run.roster), rows: records))
        }
        var newest = ""
        for day in byDay.keys.sorted() {
            switch writer.append(day: day, runs: byDay[day] ?? []) {
            case .written: newest = max(newest, day)
            case .paused: drop(runs.filter { $0.day == day }.reduce(0) { $0 + $1.rows.count })
            case .failed: break
            }
        }
        if !newest.isEmpty { writer.closeDays(before: newest) }
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

    /// What a read of a day found besides rows: whether the key could not be
    /// asked, and how many sealed values or files would not open.
    public struct DayStatus: Equatable {
        public var unavailable = false
        public var failures = 0
        public var clean: Bool { !unavailable && failures == 0 }
    }

    /// The days with a journal or a plaintext file, oldest first.
    public static func days(in directory: URL, fileSystem: any FileSystem = PosixFileSystem()) -> [String] {
        DayStore.days(prefix: prefix, in: directory, fileSystem: fileSystem)
    }

    /// One day's presses, in press order, across every segment that holds
    /// part of it. `ring` is the key to open a sealed day with; nil reads
    /// the plaintext remnants only.
    public static func presses(day: String, in directory: URL, ring: Vault.Ring?,
                               fileSystem: any FileSystem = PosixFileSystem()) -> [KeyPress] {
        read(day: day, in: directory, ring: ring, fileSystem: fileSystem).segments
            .flatMap { $0.presses }.sorted { $0.down < $1.down }
    }

    /// One day's segments with their headers — the roster a `keyboard`
    /// index refers to is the header of the segment the row sits in.
    public static func segments(day: String, in directory: URL, ring: Vault.Ring?,
                                fileSystem: any FileSystem = PosixFileSystem())
        -> [(header: DayFile.Header, presses: [KeyPress])] {
        read(day: day, in: directory, ring: ring, fileSystem: fileSystem).segments
    }

    /// The segments and how the read went: a sealed day that did not open
    /// says so here, and is never an empty one.
    public static func read(day: String, in directory: URL, ring: Vault.Ring?,
                            fileSystem: any FileSystem = PosixFileSystem())
        -> (segments: [(header: DayFile.Header, presses: [KeyPress])], status: DayStatus) {
        let contents = DayStore.read(prefix: prefix, purpose: DayStore.purpose, day: day, in: directory,
                                     ring: ring, fileSystem: fileSystem)
        let segments = contents.segments.compactMap { decode(segment: $0) }
        return (segments, DayStatus(unavailable: contents.unavailable, failures: contents.failures))
    }

    /// One plaintext segment file, as an older build wrote it.
    public static func read(url: URL) throws -> (header: DayFile.Header, presses: [KeyPress]) {
        let (header, body) = try DayFile.read(url: url)
        return (header, rows(header: header, body: body))
    }

    /// A segment's bytes (header, then rows) as presses.
    public static func decode(segment bytes: [UInt8]) -> (header: DayFile.Header, presses: [KeyPress])? {
        guard let header = DayFile.readHeader(Data(bytes)), bytes.count >= header.bodyOffset else { return nil }
        return (header, rows(header: header, body: Array(bytes.dropFirst(header.bodyOffset))))
    }

    private static func rows(header: DayFile.Header, body: [UInt8]) -> [KeyPress] {
        guard header.magic == magic else { return [] }
        let size = Int(header.recordSize)
        guard size >= legacyRecordSize else { return [] }
        let count = body.count / size
        var out: [KeyPress] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            out.append(decode(Array(body[(i * size)..<((i + 1) * size)])))
        }
        return out.sorted { $0.down < $1.down }
    }

    // MARK: - Migrating

    /// Seal and remove the plaintext day files an earlier build left, on the
    /// store's own queue (no flush interleaves). Resumable; see
    /// `DayWriter.migrate`.
    public func migrateLegacy() -> RecordMigration {
        queue.sync {
            let outcome = writer.migrate(decodedCount: { Self.decode(segment: $0)?.presses.count ?? -1 })
            writer.closeDays(before: Self.day(of: Date(), calendar: calendar))
            return outcome
        }
    }

    /// Close the journals this store holds open: shutdown, and a test that
    /// wants the file system to itself.
    public func close() {
        queue.sync { writer.closeAll() }
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

    /// The plaintext file an earlier build kept the day in (segment 0).
    public static func url(for day: String, in directory: URL, compressed: Bool = false) -> URL {
        DayFile.url(prefix: prefix, day: day, in: directory, compressed: compressed)
    }
}
