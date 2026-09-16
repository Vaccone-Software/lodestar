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
/// The format is deliberately dull. A 32-byte header, then 16-byte
/// little-endian records: microseconds since the Unix epoch for the
/// press, microseconds held (all ones when the release was never seen),
/// then hand, kind, flags and keyboard type as single bytes. A day's file
/// is appended to as the day goes and compressed once a later day opens —
/// the Compression framework's zlib, which is raw DEFLATE (Python reads it
/// with `zlib.decompress(data, -15)`). A torn tail is ignored by length,
/// so a crash mid-write costs at most one record.
///
/// The day begins at four in the morning, as it does everywhere else in
/// the instrument, so an evening that runs past midnight stays one day.
public final class KeyStore {
    public static let version: UInt16 = 1
    public static let recordSize = 16
    public static let headerSize = 32
    public static let magic: [UInt8] = Array("LDK1".utf8)
    public static let dayStartHour = 4
    public static let unknownHold = UInt32.max
    /// Records buffered before a write is scheduled.
    public static let flushThreshold = 256
    public static let subdirectory = "keys"

    public let directory: URL
    public let installID: String
    private let calendar: Calendar
    private let queue = DispatchQueue(label: "lodestar.keys", qos: .utility)
    private var buffer: [KeyPress] = []
    private let lock = NSLock()

    public init(directory: URL, installID: String, timeZone: TimeZone = .current) {
        self.directory = directory
        self.installID = installID
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    // MARK: - Writing

    /// Any thread. Buffered; a keystroke never waits on the disk.
    public func append(_ press: KeyPress) {
        lock.lock()
        buffer.append(press)
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

    private func write(_ presses: [KeyPress]) {
        let grouped = Dictionary(grouping: presses) { Self.day(of: $0.down, calendar: calendar) }
        let days = grouped.keys.sorted()
        for day in days {
            let rows = grouped[day]!.sorted { $0.down < $1.down }
            let url = Self.url(for: day, in: directory)
            var data = Data()
            if !FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                data.append(header(for: day))
            }
            for row in rows { data.append(contentsOf: Self.encode(row)) }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
        if let newest = days.last { compressDays(before: newest) }
    }

    private func header(for day: String) -> Data {
        var data = Data(Self.magic)
        data.append(le(Self.version))
        data.append(le(UInt16(Self.recordSize)))
        let start = Self.dayStart(of: day, calendar: calendar) ?? Date()
        data.append(le(Int32(calendar.timeZone.secondsFromGMT(for: start))))
        data.append(le(UInt64(max(0, start.timeIntervalSince1970 * 1e6))))
        var id = Array(installID.utf8.prefix(8))
        id.append(contentsOf: [UInt8](repeating: 0, count: 8 - id.count))
        data.append(contentsOf: id)
        data.append(contentsOf: [UInt8](repeating: 0, count: Self.headerSize - data.count))
        return data
    }

    /// Every open day older than `current` closes: read whole, deflated,
    /// written beside, and only then removed.
    private func compressDays(before current: String) {
        for day in Self.days(in: directory, compressed: false) where day < current {
            let raw = Self.url(for: day, in: directory)
            let packed = Self.url(for: day, in: directory, compressed: true)
            guard let data = try? Data(contentsOf: raw),
                  let deflated = try? (data as NSData).compressed(using: .zlib) as Data,
                  (try? deflated.write(to: packed, options: .atomic)) != nil else { continue }
            try? FileManager.default.removeItem(at: raw)
        }
    }

    // MARK: - Reading

    /// The days with a file, oldest first.
    public static func days(in directory: URL, compressed: Bool? = nil) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var days: Set<String> = []
        for name in names {
            guard name.hasPrefix("keys-") else { continue }
            if name.hasSuffix(".bin.z"), compressed != false {
                days.insert(String(name.dropFirst(5).dropLast(6)))
            } else if name.hasSuffix(".bin"), compressed != true {
                days.insert(String(name.dropFirst(5).dropLast(4)))
            }
        }
        return days.sorted()
    }

    /// One day's presses, in press order, from whichever file holds it.
    public static func presses(day: String, in directory: URL) -> [KeyPress] {
        let packed = url(for: day, in: directory, compressed: true)
        if FileManager.default.fileExists(atPath: packed.path) {
            return (try? read(url: packed)) ?? []
        }
        return (try? read(url: url(for: day, in: directory))) ?? []
    }

    public static func read(url: URL) throws -> [KeyPress] {
        var data = try Data(contentsOf: url)
        if url.pathExtension == "z" {
            data = try (data as NSData).decompressed(using: .zlib) as Data
        }
        guard data.count >= headerSize, Array(data.prefix(4)) == magic else { return [] }
        let body = data.dropFirst(headerSize)
        let count = body.count / recordSize
        var out: [KeyPress] = []
        out.reserveCapacity(count)
        let bytes = [UInt8](body)
        for i in 0..<count {
            let slice = Array(bytes[(i * recordSize)..<((i + 1) * recordSize)])
            out.append(decode(slice))
        }
        return out.sorted { $0.down < $1.down }
    }

    // MARK: - Encoding

    static func encode(_ press: KeyPress) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(recordSize)
        let micros = UInt64(max(0, press.down.timeIntervalSince1970 * 1e6))
        out.append(contentsOf: le(micros))
        let hold: UInt32 = press.hold.map { UInt32(min(Double(UInt32.max - 1), max(0, $0 * 1e6))) } ?? unknownHold
        out.append(contentsOf: le(hold))
        out.append(press.hand.rawValue)
        out.append(press.kind.rawValue)
        var flags: UInt8 = 0
        if press.shift { flags |= 1 }
        if press.chord { flags |= 2 }
        if press.gesture { flags |= 4 }
        if press.lens { flags |= 8 }
        if press.repeated { flags |= 16 }
        out.append(flags)
        out.append(UInt8(min(255, max(0, press.keyboardType))))
        return out
    }

    static func decode(_ bytes: [UInt8]) -> KeyPress {
        let micros = readLE(bytes, 0, UInt64.self)
        let hold = readLE(bytes, 8, UInt32.self)
        let flags = bytes[14]
        return KeyPress(
            down: Date(timeIntervalSince1970: Double(micros) / 1e6),
            hold: hold == unknownHold ? nil : Double(hold) / 1e6,
            hand: Keys.Hand(rawValue: bytes[12]) ?? .other,
            kind: Keys.Kind(rawValue: bytes[13]) ?? .other,
            shift: flags & 1 != 0, chord: flags & 2 != 0, gesture: flags & 4 != 0,
            lens: flags & 8 != 0, repeated: flags & 16 != 0,
            keyboardType: Int(bytes[15]))
    }

    private static func readLE<T: FixedWidthInteger>(_ bytes: [UInt8], _ offset: Int, _: T.Type) -> T {
        var value: T = 0
        for i in 0..<MemoryLayout<T>.size {
            value |= T(bytes[offset + i]) << (8 * i)
        }
        return value
    }

    private func le<T: FixedWidthInteger>(_ value: T) -> Data { Data(Self.le(value)) }

    private static func le<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    // MARK: - Days

    /// The local day a moment belongs to, beginning at four in the
    /// morning.
    public static func day(of date: Date, calendar: Calendar) -> String {
        let shifted = date.addingTimeInterval(-Double(dayStartHour) * 3600)
        let parts = calendar.dateComponents([.year, .month, .day], from: shifted)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public static func dayStart(of day: String, calendar: Calendar) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        components.hour = dayStartHour
        return calendar.date(from: components)
    }

    public static func url(for day: String, in directory: URL, compressed: Bool = false) -> URL {
        directory.appendingPathComponent("keys-\(day).bin" + (compressed ? ".z" : ""))
    }
}
