import Foundation

/// What a copy put on the board, read in one pass: every item's types,
/// its plain text, its file address and the bytes of each richer form,
/// with the board's change count at the read. It is what the clipboard
/// reader hands back across its pipe, so it is plain data and nothing
/// of AppKit: the reading happens in another process, on that process's
/// main thread, because AppKit's pasteboard is main-thread only and a
/// lazily provided type (a promise, a copy from another device) can make
/// a read wait seconds on the app or network behind it.
public struct PasteboardSnapshot: Codable, Sendable, Equatable {
    public struct Native: Codable, Sendable, Equatable {
        public var type: String
        public var data: Data
        public init(type: String, data: Data) {
            self.type = type
            self.data = data
        }
    }

    public struct Item: Codable, Sendable, Equatable {
        /// Every type the item offers, in the board's order.
        public var types: [String]
        /// What the item pastes as text: its `.string` form.
        public var plain: String?
        /// Its file address as text, when it is a file.
        public var fileURL: String?
        /// Every form but `.string`, with its bytes, in the board's order.
        /// Empty when the copy was refused before reading.
        public var natives: [Native]

        public init(types: [String], plain: String? = nil, fileURL: String? = nil, natives: [Native] = []) {
            self.types = types
            self.plain = plain
            self.fileURL = fileURL
            self.natives = natives
        }
    }

    /// The change count the board had when it was read.
    public var changeCount: Int
    public var items: [Item]
    /// Why the copy was refused before a byte was read, in the words the
    /// log uses; nil when it was read.
    public var refusal: String?
    /// The page a browser copy came from, as the first item carried it.
    public var sourceURL: String?

    public init(changeCount: Int, items: [Item], refusal: String? = nil, sourceURL: String? = nil) {
        self.changeCount = changeCount
        self.items = items
        self.refusal = refusal
        self.sourceURL = sourceURL
    }
}

/// What the reader is asked: who was in front when the copy was noticed,
/// and which apps are never read, so a refusal that hangs on the source
/// is decided before any content leaves the board.
public struct PasteboardReadRequest: Codable, Sendable, Equatable {
    public var id: Int
    public var sourceBundleID: String?
    public var excludedApps: [String]

    public init(id: Int, sourceBundleID: String?, excludedApps: [String]) {
        self.id = id
        self.sourceBundleID = sourceBundleID
        self.excludedApps = excludedApps
    }
}

/// The reader's answer to one request, by its id, so an answer from a
/// reader that was given up on can never be taken for a later one.
public struct PasteboardReadAnswer: Codable, Sendable, Equatable {
    public var id: Int
    public var snapshot: PasteboardSnapshot

    public init(id: Int, snapshot: PasteboardSnapshot) {
        self.id = id
        self.snapshot = snapshot
    }
}

/// Length-prefixed frames over a pipe: eight bytes of length, little
/// endian, then a binary property list. A property list carries `Data`
/// as bytes, so a twenty-megabyte image crosses as twenty megabytes.
public enum PipeFrames {
    /// Larger than any copy the clipboard keeps; a length past it is a
    /// broken stream, not a frame.
    public static let maxFrameBytes = 1 << 30

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let body = try encoder.encode(value)
        var length = UInt64(body.count).littleEndian
        var frame = Data(bytes: &length, count: 8)
        frame.append(body)
        return frame
    }

    public static func decode<T: Decodable>(_ type: T.Type, body: Data) throws -> T {
        try PropertyListDecoder().decode(type, from: body)
    }

    /// Writes all of it, or says it could not (the other end is gone).
    public static func write(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var pointer = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                let wrote = Foundation.write(fd, pointer, left)
                if wrote < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                left -= wrote
                pointer += wrote
            }
            return true
        }
    }

    /// The next frame's body, or nil at the end of the stream or on a
    /// frame that cannot be one.
    public static func readBody(from fd: Int32) -> Data? {
        guard let header = readExactly(8, from: fd) else { return nil }
        let length = header.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
        guard length <= UInt64(maxFrameBytes) else { return nil }
        return readExactly(Int(length), from: fd)
    }

    private static func readExactly(_ count: Int, from fd: Int32) -> Data? {
        var data = Data(count: count)
        guard count > 0 else { return data }
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard var pointer = raw.baseAddress else { return false }
            var left = count
            while left > 0 {
                let got = Foundation.read(fd, pointer, left)
                if got < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if got == 0 { return false }
                left -= got
                pointer += got
            }
            return true
        }
        return ok ? data : nil
    }
}
