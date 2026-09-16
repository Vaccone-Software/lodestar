import Foundation

/// The raw record of the pointer, beneath the folded reaches: every
/// report the device made on the way to a target, every press with what
/// made it and what it was made on, every wheel burst. Kept for the same
/// reason the presses are — a smoothness or tremor measure nobody has
/// chosen yet cannot be derived from three band sums — and bounded the
/// same way, by disk and not by squeamishness. Counts and seconds only:
/// a delta has no screen on it, and a click's position is never kept.
///
/// One `DayFile` per local day, the header naming the pointing devices
/// attached. Records are sixteen bytes, the first byte the kind; a reach
/// record is followed inline by its samples, six bytes each — tenths of
/// a millisecond since the previous sample, then the device's own dx and
/// dy — and then its end. A torn tail loses at most the reach it fell in.
public final class PointerStore {
    public static let version: UInt16 = 1
    public static let recordSize = 16
    public static let sampleSize = 6
    public static let magic: [UInt8] = Array("LDP1".utf8)
    public static let flushThreshold = 64
    public static let subdirectory = "pointer"
    static let prefix = "pointer"

    /// Who pressed the button.
    public enum Source: UInt8, Codable, Equatable {
        case unknown = 0
        /// A hand, by the event's provenance.
        case human = 1
        /// Lodestar itself: a pick, a warp, the click door.
        case lodestar = 2
        /// Another process posted it.
        case posted = 3
    }

    /// What the button was on.
    public enum DeviceKind: UInt8, Codable, Equatable {
        case unknown = 0
        case trackpad = 1
        case mouse = 2
    }

    public struct Sample: Equatable {
        /// Seconds since the previous sample, or since the reach's start
        /// for the first.
        public var dt: Double
        public var dx: Int
        public var dy: Int
        public init(dt: Double, dx: Int, dy: Int) {
            self.dt = dt
            self.dx = dx
            self.dy = dy
        }
    }

    public enum Record: Equatable {
        case reach(start: Date, screen: Int, samples: [Sample], end: Date)
        case click(at: Date, button: Int, source: Source, device: DeviceKind, index: Int,
                   stage: Int, pressure: Double)
        case release(at: Date, button: Int, press: Double)
        case scroll(start: Date, seconds: Double, precise: Bool, momentum: Bool,
                    device: DeviceKind, index: Int)

        var moment: Date {
            switch self {
            case .reach(let start, _, _, _): return start
            case .click(let at, _, _, _, _, _, _): return at
            case .release(let at, _, _): return at
            case .scroll(let start, _, _, _, _, _): return start
            }
        }
    }

    public let directory: URL
    public let installID: String
    public let appVersion: String
    private let calendar: Calendar
    private let queue = DispatchQueue(label: "lodestar.pointer", qos: .utility)
    private var buffer: [(record: Record, roster: [String])] = []
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

    /// Any thread. Buffered; the tap never waits on the disk.
    public func append(_ record: Record, roster: [String] = []) {
        lock.lock()
        buffer.append((record, roster))
        let due = buffer.count >= Self.flushThreshold
        lock.unlock()
        if due { flush() }
    }

    public func flush() {
        lock.lock()
        let pending = buffer
        buffer.removeAll()
        lock.unlock()
        guard !pending.isEmpty else { return }
        queue.async { [self] in write(pending) }
    }

    public func flushSync() {
        flush()
        queue.sync {}
    }

    private func write(_ pending: [(record: Record, roster: [String])]) {
        var runs: [(day: String, roster: [String], records: [Record])] = []
        for entry in pending {
            let day = DayFile.day(of: entry.record.moment, calendar: calendar)
            if let last = runs.last, last.day == day, last.roster == entry.roster {
                runs[runs.count - 1].records.append(entry.record)
            } else {
                runs.append((day, entry.roster, [entry.record]))
            }
        }
        var newest = ""
        for run in runs {
            var bytes = Data()
            for record in run.records { bytes.append(contentsOf: Self.encode(record)) }
            DayFile.append(bytes, prefix: Self.prefix, day: run.day,
                           header: header(for: run.day, roster: run.roster), in: directory)
            newest = max(newest, run.day)
        }
        if !newest.isEmpty { DayFile.compress(prefix: Self.prefix, before: newest, in: directory) }
    }

    func header(for day: String, roster: [String]) -> DayFile.Header {
        let start = DayFile.dayStart(of: day, calendar: calendar) ?? Date()
        return DayFile.Header(
            magic: Self.magic, version: Self.version, recordSize: UInt16(Self.recordSize),
            tzOffset: Int32(calendar.timeZone.secondsFromGMT(for: start)),
            dayStart: UInt64(max(0, start.timeIntervalSince1970 * 1e6)),
            install: installID, appVersion: appVersion, roster: roster, bodyOffset: 0)
    }

    // MARK: - Reading

    public static func days(in directory: URL, compressed: Bool? = nil) -> [String] {
        DayFile.days(prefix: prefix, in: directory, compressed: compressed)
    }

    /// One day's records in the order they were written, across segments.
    public static func records(day: String, in directory: URL) -> [Record] {
        DayFile.segments(prefix: prefix, in: directory)
            .filter { $0.day == day }
            .flatMap { (try? read(url: $0.url).records) ?? [] }
    }

    public static func read(url: URL) throws -> (header: DayFile.Header, records: [Record]) {
        let (header, body) = try DayFile.read(url: url)
        guard header.magic == magic else { return (header, []) }
        return (header, decode(body))
    }

    // MARK: - Encoding

    static func micros(_ date: Date) -> UInt64 { UInt64(max(0, date.timeIntervalSince1970 * 1e6)) }
    static func date(_ micros: UInt64) -> Date { Date(timeIntervalSince1970: Double(micros) / 1e6) }

    static func encode(_ record: Record) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: recordSize)
        func stamp(_ date: Date) { out.replaceSubrange(8..<16, with: DayFile.leBytes(micros(date))) }
        switch record {
        case .reach(let start, let screen, let samples, let end):
            out[0] = 1
            out[1] = UInt8(min(255, max(0, screen)))
            let count = min(samples.count, 65_535)
            out.replaceSubrange(2..<4, with: DayFile.leBytes(UInt16(count)))
            stamp(start)
            for sample in samples.prefix(count) {
                let tenths = UInt16(min(65_535, max(0, (sample.dt * 10_000).rounded())))
                out.append(contentsOf: DayFile.leBytes(tenths))
                out.append(contentsOf: DayFile.leBytes(Int16(clamping: sample.dx)))
                out.append(contentsOf: DayFile.leBytes(Int16(clamping: sample.dy)))
            }
            var trailer = [UInt8](repeating: 0, count: recordSize)
            trailer[0] = 3
            trailer.replaceSubrange(8..<16, with: DayFile.leBytes(micros(end)))
            out.append(contentsOf: trailer)
        case .click(let at, let button, let source, let device, let index, let stage, let pressure):
            out[0] = 4
            out[1] = UInt8(min(255, max(0, button)))
            out[2] = source.rawValue
            out[3] = device.rawValue
            out[4] = UInt8(min(255, max(0, index)))
            out[5] = UInt8(min(255, max(0, stage)))
            out.replaceSubrange(6..<8, with: DayFile.leBytes(UInt16(min(65_535, max(0, (pressure * 1000).rounded())))))
            stamp(at)
        case .release(let at, let button, let press):
            out[0] = 5
            out[1] = UInt8(min(255, max(0, button)))
            out.replaceSubrange(4..<8, with: DayFile.leBytes(UInt32(min(Double(UInt32.max), max(0, press * 1e6)))))
            stamp(at)
        case .scroll(let start, let seconds, let precise, let momentum, let device, let index):
            out[0] = 6
            out[1] = (precise ? 1 : 0) | (momentum ? 2 : 0)
            out[2] = device.rawValue
            out[3] = UInt8(min(255, max(0, index)))
            out.replaceSubrange(4..<8, with: DayFile.leBytes(UInt32(min(Double(UInt32.max), max(0, seconds * 1000)))))
            stamp(start)
        }
        return out
    }

    /// The stream, stopping at the first record the tail cannot complete.
    static func decode(_ bytes: [UInt8]) -> [Record] {
        var out: [Record] = []
        var offset = 0
        func slice(_ at: Int, _ length: Int) -> [UInt8]? {
            guard at + length <= bytes.count else { return nil }
            return Array(bytes[at..<(at + length)])
        }
        while let head = slice(offset, recordSize) {
            let stamp = date(DayFile.readLE(head, 8, UInt64.self))
            switch head[0] {
            case 1:
                let count = Int(DayFile.readLE(head, 2, UInt16.self))
                let body = offset + recordSize
                guard let raw = slice(body, count * sampleSize) else { return out }
                var samples: [Sample] = []
                samples.reserveCapacity(count)
                for i in 0..<count {
                    let s = Array(raw[(i * sampleSize)..<((i + 1) * sampleSize)])
                    samples.append(Sample(
                        dt: Double(DayFile.readLE(s, 0, UInt16.self)) / 10_000,
                        dx: Int(Int16(bitPattern: DayFile.readLE(s, 2, UInt16.self))),
                        dy: Int(Int16(bitPattern: DayFile.readLE(s, 4, UInt16.self)))))
                }
                var end = stamp.addingTimeInterval(samples.reduce(0) { $0 + $1.dt })
                var next = body + count * sampleSize
                if let trailer = slice(next, recordSize), trailer[0] == 3 {
                    end = date(DayFile.readLE(trailer, 8, UInt64.self))
                    next += recordSize
                }
                out.append(.reach(start: stamp, screen: Int(head[1]), samples: samples, end: end))
                offset = next
            case 4:
                out.append(.click(at: stamp, button: Int(head[1]),
                                  source: Source(rawValue: head[2]) ?? .unknown,
                                  device: DeviceKind(rawValue: head[3]) ?? .unknown,
                                  index: Int(head[4]), stage: Int(head[5]),
                                  pressure: Double(DayFile.readLE(head, 6, UInt16.self)) / 1000))
                offset += recordSize
            case 5:
                out.append(.release(at: stamp, button: Int(head[1]),
                                    press: Double(DayFile.readLE(head, 4, UInt32.self)) / 1e6))
                offset += recordSize
            case 6:
                out.append(.scroll(start: stamp,
                                   seconds: Double(DayFile.readLE(head, 4, UInt32.self)) / 1000,
                                   precise: head[1] & 1 != 0, momentum: head[1] & 2 != 0,
                                   device: DeviceKind(rawValue: head[2]) ?? .unknown,
                                   index: Int(head[3])))
                offset += recordSize
            default:
                // A stray trailer or an unknown kind: step past it.
                offset += recordSize
            }
        }
        return out
    }
}
