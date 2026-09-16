import Foundation

/// What the raw stores share: one file per local day, the day beginning
/// at four in the morning; a header that names the format, the install,
/// the build that wrote it and the devices that were attached; a fresh
/// *segment* whenever any of that would change mid-day, so a header
/// never lies about half its file; and older days deflated once a later
/// day opens.
///
/// The header is 64 bytes, then the roster as UTF-8 ids joined by commas
/// and padded to a sixteen-byte boundary, then the records. Bytes 28–29
/// say where the records start; a file whose bytes 28–31 are zero is the
/// first format's 32-byte header (no build, no roster), and reads as
/// such. Little-endian throughout.
public enum DayFile {
    public static let dayStartHour = 4
    public static let fixedHeaderSize = 64
    public static let legacyHeaderSize = 32

    public struct Header: Equatable {
        public var magic: [UInt8]
        public var version: UInt16
        public var recordSize: UInt16
        public var tzOffset: Int32
        /// Microseconds since the Unix epoch at the day's start.
        public var dayStart: UInt64
        public var install: String
        /// The build that wrote the segment; empty in a legacy header.
        public var appVersion: String
        /// The devices attached while the segment was written, by roster id.
        public var roster: [String]
        /// Where the records begin.
        public var bodyOffset: Int

        /// The parts a change of which opens a new segment.
        public var fingerprint: String {
            "\(version)/\(recordSize)/\(appVersion)/\(roster.joined(separator: ","))"
        }
    }

    // MARK: - Header

    public static func encode(_ header: Header) -> Data {
        var data = Data(header.magic.prefix(4))
        while data.count < 4 { data.append(0) }
        data.append(le(header.version))
        data.append(le(header.recordSize))
        data.append(le(header.tzOffset))
        data.append(le(header.dayStart))
        data.append(fixed(header.install, 8))
        let roster = Data(header.roster.joined(separator: ",").utf8)
        let padded = (roster.count + 15) / 16 * 16
        let bodyOffset = fixedHeaderSize + padded
        data.append(le(UInt16(bodyOffset)))
        data.append(le(UInt16(0)))
        data.append(fixed(header.appVersion, 12))
        data.append(le(UInt32(roster.count)))
        data.append(contentsOf: [UInt8](repeating: 0, count: fixedHeaderSize - data.count))
        data.append(roster)
        data.append(contentsOf: [UInt8](repeating: 0, count: padded - roster.count))
        return data
    }

    /// The header at the front of `data`, or nil when there is none.
    public static func readHeader(_ data: Data) -> Header? {
        guard data.count >= legacyHeaderSize else { return nil }
        let bytes = [UInt8](data.prefix(fixedHeaderSize))
        let magic = Array(bytes[0..<4])
        let version = readLE(bytes, 4, UInt16.self)
        let recordSize = readLE(bytes, 6, UInt16.self)
        let tz = readLE(bytes, 8, Int32.self)
        let dayStart = readLE(bytes, 12, UInt64.self)
        let install = string(bytes, 20, 8)
        let bodyOffset = Int(readLE(bytes, 28, UInt16.self))
        if bodyOffset == 0 {
            return Header(magic: magic, version: version, recordSize: recordSize, tzOffset: tz,
                          dayStart: dayStart, install: install, appVersion: "", roster: [],
                          bodyOffset: legacyHeaderSize)
        }
        guard data.count >= fixedHeaderSize, bodyOffset >= fixedHeaderSize, data.count >= bodyOffset
        else { return nil }
        let appVersion = string(bytes, 32, 12)
        let rosterLength = Int(readLE(bytes, 44, UInt32.self))
        guard fixedHeaderSize + rosterLength <= bodyOffset else { return nil }
        let rosterBytes = data.subdata(in: fixedHeaderSize..<(fixedHeaderSize + rosterLength))
        let roster = String(decoding: rosterBytes, as: UTF8.self)
            .split(separator: ",").map(String.init)
        return Header(magic: magic, version: version, recordSize: recordSize, tzOffset: tz,
                      dayStart: dayStart, install: install, appVersion: appVersion,
                      roster: roster, bodyOffset: bodyOffset)
    }

    /// Header and records of one file, inflated when it was deflated.
    public static func read(url: URL) throws -> (header: Header, body: [UInt8]) {
        var data = try Data(contentsOf: url)
        if url.pathExtension == "z" {
            data = try (data as NSData).decompressed(using: .zlib) as Data
        }
        guard let header = readHeader(data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (header, [UInt8](data.dropFirst(header.bodyOffset)))
    }

    // MARK: - Files

    /// `prefix-DAY.bin`, `prefix-DAY.1.bin`, … and `.z` once deflated.
    public static func url(prefix: String, day: String, segment: Int = 0,
                           in directory: URL, compressed: Bool = false) -> URL {
        let name = segment == 0 ? "\(prefix)-\(day).bin" : "\(prefix)-\(day).\(segment).bin"
        return directory.appendingPathComponent(name + (compressed ? ".z" : ""))
    }

    public struct Segment: Equatable {
        public var day: String
        public var index: Int
        public var compressed: Bool
        public var url: URL
    }

    /// Every segment in the directory, by day then index.
    public static func segments(prefix: String, in directory: URL) -> [Segment] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var out: [Segment] = []
        for name in names {
            guard name.hasPrefix("\(prefix)-") else { continue }
            var rest = String(name.dropFirst(prefix.count + 1))
            var compressed = false
            if rest.hasSuffix(".bin.z") {
                compressed = true
                rest = String(rest.dropLast(6))
            } else if rest.hasSuffix(".bin") {
                rest = String(rest.dropLast(4))
            } else { continue }
            let parts = rest.split(separator: ".", maxSplits: 1).map(String.init)
            guard let day = parts.first, day.count == 10 else { continue }
            let index = parts.count == 2 ? (Int(parts[1]) ?? -1) : 0
            guard index >= 0 else { continue }
            out.append(Segment(day: day, index: index, compressed: compressed,
                               url: directory.appendingPathComponent(name)))
        }
        return out.sorted { ($0.day, $0.index) < ($1.day, $1.index) }
    }

    /// The days with a file, oldest first.
    public static func days(prefix: String, in directory: URL, compressed: Bool? = nil) -> [String] {
        var days: Set<String> = []
        for segment in segments(prefix: prefix, in: directory) {
            if let compressed, segment.compressed != compressed { continue }
            days.insert(segment.day)
        }
        return days.sorted()
    }

    /// Every open segment of a day older than `current` closes: read
    /// whole, deflated, written beside, and only then removed.
    public static func compress(prefix: String, before current: String, in directory: URL) {
        for segment in segments(prefix: prefix, in: directory)
        where !segment.compressed && segment.day < current {
            let packed = url(prefix: prefix, day: segment.day, segment: segment.index,
                             in: directory, compressed: true)
            guard let data = try? Data(contentsOf: segment.url),
                  let deflated = try? (data as NSData).compressed(using: .zlib) as Data,
                  (try? deflated.write(to: packed, options: .atomic)) != nil else { continue }
            try? FileManager.default.removeItem(at: segment.url)
        }
    }

    /// Append records to the day's open segment, or open a new one when
    /// the header the store would write differs from the one on disk.
    /// Returns the segment written to.
    @discardableResult
    static func append(_ records: Data, prefix: String, day: String, header: Header,
                       in directory: URL) -> Int {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let open = segments(prefix: prefix, in: directory)
            .filter { $0.day == day }
        let last = open.last
        var index = 0
        var needsHeader = true
        if let last {
            if !last.compressed, let existing = try? Data(contentsOf: last.url),
               let onDisk = readHeader(existing), onDisk.fingerprint == header.fingerprint {
                index = last.index
                needsHeader = false
            } else {
                index = last.index + 1
            }
        }
        let target = url(prefix: prefix, day: day, segment: index, in: directory)
        var data = Data()
        if needsHeader { data.append(encode(header)) }
        data.append(records)
        if !needsHeader, let handle = try? FileHandle(forWritingTo: target) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: target)
        }
        return index
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

    // MARK: - Bytes

    static func le<T: FixedWidthInteger>(_ value: T) -> Data { Data(leBytes(value)) }

    static func leBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    static func readLE<T: FixedWidthInteger>(_ bytes: [UInt8], _ offset: Int, _: T.Type) -> T {
        var value: T = 0
        for i in 0..<MemoryLayout<T>.size where offset + i < bytes.count {
            value |= T(bytes[offset + i]) << (8 * i)
        }
        return value
    }

    static func fixed(_ text: String, _ width: Int) -> Data {
        var bytes = Array(text.utf8.prefix(width))
        bytes.append(contentsOf: [UInt8](repeating: 0, count: width - bytes.count))
        return Data(bytes)
    }

    static func string(_ bytes: [UInt8], _ offset: Int, _ width: Int) -> String {
        let slice = bytes[offset..<min(bytes.count, offset + width)].prefix { $0 != 0 }
        return String(decoding: slice, as: UTF8.self)
    }
}
