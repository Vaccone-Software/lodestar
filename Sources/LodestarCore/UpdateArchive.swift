import CryptoKit
import Darwin
import Foundation

/// The update zip, opened only after its sha256 matches and only into a
/// fresh directory. `ditto -x` writes whatever paths the archive names
/// before codesign ever runs; a path with `..` or an absolute path would
/// land outside staging, and the signature check would arrive too late.
/// This unpacks the archive itself and refuses any name that would leave
/// the directory it was given.
public enum UpdateArchive {
    public enum ExtractError: Error, Equatable, Sendable, CustomStringConvertible {
        case unreadable
        case notAZip
        case unsafePath(String)
        case unsupported(String)
        case corrupt
        case tooLarge

        public var description: String {
            switch self {
            case .unreadable: return "the zip could not be read"
            case .notAZip: return "not a zip"
            case .unsafePath(let path): return "the zip names a path outside staging (\(path))"
            case .unsupported(let why): return "the zip is not one this updater unpacks (\(why))"
            case .corrupt: return "the zip is corrupt"
            case .tooLarge: return "the zip is larger than an update may be"
            }
        }
    }

    /// `sha256:` and 64 hex digits, the shape GitHub puts on an asset.
    /// Upper and lower hex are the same digest. Anything else — missing,
    /// `md5:`, a short string — is not a check this app can make.
    public static func isSHA256(_ digest: String?) -> Bool {
        guard let digest else { return false }
        let prefix = "sha256:"
        guard digest.hasPrefix(prefix) else { return false }
        let hex = digest.dropFirst(prefix.count)
        return hex.utf8.count == 64 && hex.utf8.allSatisfy { byte in
            switch byte {
            case 0x30...0x39, 0x41...0x46, 0x61...0x66: return true
            default: return false
            }
        }
    }

    /// The file is exactly `digest`. A missing or malformed digest is a
    /// mismatch: unpacking does not start without one, and the bytes are
    /// hashed before a single entry is written.
    public static func matches(file: URL, digest: String?) -> Bool {
        guard isSHA256(digest), let digest else { return false }
        let expected = String(digest.dropFirst("sha256:".count)).lowercased()
        guard let actual = sha256Hex(of: file) else { return false }
        return actual == expected
    }

    /// Replaces `destination` with a new directory holding the archive.
    /// The archive is parsed first, and a name that would leave the
    /// directory fails before anything is created. Writes then go into an
    /// empty sibling, through `openat` without following links, and that
    /// sibling becomes `destination` only when every entry has been
    /// written. On any failure the sibling is removed and `destination`
    /// is left as it was.
    public static func extract(_ zip: URL, replacing destination: URL) throws {
        let data = try contents(of: zip)
        let items = try entries(in: data)
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let scratch = parent.appendingPathComponent(destination.lastPathComponent + ".incoming", isDirectory: true)
        if FileManager.default.fileExists(atPath: scratch.path) {
            try FileManager.default.removeItem(at: scratch)
        }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        do {
            let root = scratch.path.withCString { lodestarOpenDir($0) }
            guard root >= 0 else { throw ExtractError.unreadable }
            defer { _ = Darwin.close(root) }
            for item in items {
                let bytes = try materialized(item, in: data)
                // ditto stores Finder metadata and provenance as `._` files
                // beside the real ones. Left in the bundle they are the
                // detritus codesign refuses; they are not the app.
                if item.parts.last?.hasPrefix("._") == true { continue }
                try write(item, bytes, root: root)
            }
            // The old tree moves aside and comes back if the new one cannot
            // take its place. Removing it first would leave nothing when
            // that rename failed. A leftover aside, from a swap that stopped
            // between the two renames, is the tree and goes back first.
            let outgoing = parent.appendingPathComponent(destination.lastPathComponent + ".outgoing", isDirectory: true)
            if !FileManager.default.fileExists(atPath: destination.path),
               FileManager.default.fileExists(atPath: outgoing.path) {
                try FileManager.default.moveItem(at: outgoing, to: destination)
            }
            if FileManager.default.fileExists(atPath: outgoing.path) {
                try FileManager.default.removeItem(at: outgoing)
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.moveItem(at: destination, to: outgoing)
            }
            do {
                try FileManager.default.moveItem(at: scratch, to: destination)
            } catch {
                if !FileManager.default.fileExists(atPath: destination.path),
                   FileManager.default.fileExists(atPath: outgoing.path) {
                    try? FileManager.default.moveItem(at: outgoing, to: destination)
                }
                throw error
            }
            try? FileManager.default.removeItem(at: outgoing)
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }
    }

    // MARK: - Hash

    private static func sha256Hex(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var total = 0
        let chunk = 1 << 20
        while true {
            let data = handle.readData(ofLength: chunk)
            if data.isEmpty { break }
            total += data.count
            if total > UpdateDownload.byteLimit { return nil }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func contents(of zip: URL) throws -> Data {
        let values = try? zip.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        if values?.isRegularFile == false { throw ExtractError.unreadable }
        if let size = values?.fileSize, size > UpdateDownload.byteLimit { throw ExtractError.tooLarge }
        let data: Data
        do {
            data = try Data(contentsOf: zip)
        } catch {
            throw ExtractError.unreadable
        }
        if data.count > UpdateDownload.byteLimit { throw ExtractError.tooLarge }
        return data
    }

    // MARK: - Names

    /// Components of a zip name that stay inside the staging directory.
    /// Absolute paths, `..`, empty components, and backslashes are refused.
    /// Nil is the refusal.
    static func safeComponents(_ name: String) -> [String]? {
        if name.isEmpty || name.count > 1024 || name.hasPrefix("/") || name.hasPrefix("~") { return nil }
        if name.contains("\\") || name.contains("\0") { return nil }
        let directory = name.hasSuffix("/")
        let trimmed = directory ? String(name.dropLast()) : name
        if trimmed.isEmpty { return nil }
        var parts: [String] = []
        for part in trimmed.split(separator: "/", omittingEmptySubsequences: false) {
            if part.isEmpty || part == "." || part == ".." || part.count > 255 { return nil }
            parts.append(String(part))
        }
        if parts.isEmpty || parts.count > 64 { return nil }
        return parts
    }

    /// A symlink target resolved against the link's directory, still inside
    /// the staging root. `..` may climb within the archive and no further.
    private static func symlinkStaysInside(_ parts: [String], _ target: String) -> Bool {
        if target.isEmpty || target.hasPrefix("/") || target.hasPrefix("~") { return false }
        if target.contains("\\") || target.contains("\0") { return false }
        var stack = Array(parts.dropLast())
        for piece in target.split(separator: "/", omittingEmptySubsequences: false) {
            if piece.isEmpty { return false }
            if piece == "." { continue }
            if piece == ".." {
                if stack.isEmpty { return false }
                stack.removeLast()
                continue
            }
            if piece.count > 255 { return false }
            stack.append(String(piece))
        }
        return true
    }

    private static func shown(_ name: String) -> String {
        name.count <= 180 ? name : String(name.prefix(180))
    }

    // MARK: - Zip

    private struct Item {
        var name: String
        var parts: [String]
        var method: Int
        var flag: Int
        var crc: UInt32
        var compressedSize: Int
        var uncompressedSize: Int
        var dataOffset: Int
        var unixMode: UInt32
        var directory: Bool
        var symlink: Bool
    }

    private static let ifmt: UInt32 = 0o170000
    private static let ifdir: UInt32 = 0o040000
    private static let iflnk: UInt32 = 0o120000
    private static let entryCap = 100_000

    private static func entries(in data: Data) throws -> [Item] {
        guard let eocd = endOfCentralDirectory(in: data) else { throw ExtractError.notAZip }
        let disk = try u16(data, eocd + 4)
        let total = try u16(data, eocd + 10)
        let cdSize = try u32(data, eocd + 12)
        let cdOffset = try u32(data, eocd + 16)
        let cdDisk = try u16(data, eocd + 6)
        if disk != 0 || cdDisk != 0 || total == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            throw ExtractError.unsupported("zip64")
        }
        if total > entryCap { throw ExtractError.tooLarge }
        let cdEnd = try rangeEnd(cdOffset, cdSize, data.count)
        var offset = cdOffset
        var items: [Item] = []
        var uncompressed = 0
        items.reserveCapacity(total)
        for _ in 0..<total {
            guard offset + 46 <= cdEnd else { throw ExtractError.corrupt }
            guard try u32(data, offset) == 0x02014b50 else { throw ExtractError.corrupt }
            let flag = try u16(data, offset + 8)
            let method = try u16(data, offset + 10)
            guard let crc = UInt32(exactly: try u32(data, offset + 16)),
                  let external = UInt32(exactly: try u32(data, offset + 38)) else { throw ExtractError.corrupt }
            let compressedSize = try u32(data, offset + 20)
            let uncompressedSize = try u32(data, offset + 24)
            let nameLen = try u16(data, offset + 28)
            let extraLen = try u16(data, offset + 30)
            let commentLen = try u16(data, offset + 32)
            let localOffset = try u32(data, offset + 42)
            if flag & 1 != 0 { throw ExtractError.unsupported("encrypted") }
            if method != 0 && method != 8 { throw ExtractError.unsupported("method \(method)") }
            if compressedSize == 0xFFFF_FFFF || uncompressedSize == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                throw ExtractError.unsupported("zip64")
            }
            if compressedSize > UpdateDownload.byteLimit || uncompressedSize > UpdateDownload.byteLimit {
                throw ExtractError.tooLarge
            }
            uncompressed += uncompressedSize
            if uncompressed > UpdateDownload.byteLimit { throw ExtractError.tooLarge }
            let nameStart = offset + 46
            let nameData = try slice(data, nameStart, nameLen)
            guard !nameData.contains(0), let name = String(data: nameData, encoding: .utf8) else {
                throw ExtractError.unsafePath("(unreadable name)")
            }
            guard let parts = safeComponents(name) else { throw ExtractError.unsafePath(shown(name)) }
            let unix = external >> 16
            let kind = unix & Self.ifmt
            let directory = name.hasSuffix("/") || kind == ifdir
            let symlink = kind == iflnk
            if directory && symlink { throw ExtractError.corrupt }
            if directory && uncompressedSize != 0 { throw ExtractError.corrupt }
            let dataOffset = try localDataOffset(data, localOffset, name: nameData, method: method, flag: flag,
                                                  compressed: compressedSize, uncompressed: uncompressedSize)
            items.append(Item(name: name, parts: parts, method: method, flag: flag, crc: crc,
                              compressedSize: compressedSize, uncompressedSize: uncompressedSize,
                              dataOffset: dataOffset, unixMode: unix, directory: directory, symlink: symlink))
            offset = try rangeEnd(nameStart, nameLen + extraLen + commentLen, cdEnd)
        }
        return items
    }

    /// Where the entry's bytes start. The local header's name has to be
    /// the central directory's name: an archive that advertises a safe
    /// name and stores another is refused.
    private static func localDataOffset(_ data: Data, _ offset: Int, name: Data, method: Int, flag: Int,
                                        compressed: Int, uncompressed: Int) throws -> Int {
        guard offset + 30 <= data.count else { throw ExtractError.corrupt }
        guard try u32(data, offset) == 0x04034b50 else { throw ExtractError.corrupt }
        let localFlag = try u16(data, offset + 6)
        let localMethod = try u16(data, offset + 8)
        if localMethod != method || localFlag != flag { throw ExtractError.corrupt }
        if flag & 0x8 == 0 {
            // Sizes have to agree when the local header claims to know them.
            // A data descriptor (flag bit 3) leaves zeros here; the central
            // directory is what says how long the bytes are.
            let localCompressed = try u32(data, offset + 18)
            let localUncompressed = try u32(data, offset + 22)
            if localCompressed != compressed || localUncompressed != uncompressed { throw ExtractError.corrupt }
        }
        let nameLen = try u16(data, offset + 26)
        let extraLen = try u16(data, offset + 28)
        let nameStart = offset + 30
        let localName = try slice(data, nameStart, nameLen)
        if localName != name { throw ExtractError.corrupt }
        let start = try rangeEnd(nameStart, nameLen + extraLen, data.count)
        _ = try rangeEnd(start, compressed, data.count)
        return start
    }

    private static func materialized(_ item: Item, in data: Data) throws -> Data {
        if item.uncompressedSize == 0 {
            if item.crc != 0 || item.compressedSize != 0 { throw ExtractError.corrupt }
            return Data()
        }
        let compressed = try slice(data, item.dataOffset, item.compressedSize)
        let bytes: Data
        if item.method == 0 {
            if item.compressedSize != item.uncompressedSize { throw ExtractError.corrupt }
            bytes = compressed
        } else {
            bytes = try inflate(compressed, size: item.uncompressedSize)
        }
        if crc32(bytes) != item.crc { throw ExtractError.corrupt }
        return bytes
    }

    private static func inflate(_ src: Data, size: Int) throws -> Data {
        var dst = Data(count: size)
        let ok: Bool = dst.withUnsafeMutableBytes { dstRaw in
            src.withUnsafeBytes { srcRaw in
                guard let dstPtr = dstRaw.bindMemory(to: UInt8.self).baseAddress,
                      let srcPtr = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return false }
                return lodestarRawInflate(srcPtr, src.count, dstPtr, size) == 0
            }
        }
        if !ok { throw ExtractError.corrupt }
        return dst
    }

    // MARK: - Writing

    private static func write(_ item: Item, _ bytes: Data, root: Int32) throws {
        if item.directory {
            let (_, opened) = try descend(root, item.parts, name: item.name)
            opened.forEach { _ = Darwin.close($0) }
            return
        }
        let parents = Array(item.parts.dropLast())
        let (dir, opened) = try descend(root, parents, name: item.name)
        defer { opened.forEach { _ = Darwin.close($0) } }
        guard let name = item.parts.last else { throw ExtractError.corrupt }
        if item.symlink {
            guard let target = String(data: bytes, encoding: .utf8), !target.contains("\0"),
                  symlinkStaysInside(item.parts, target) else {
                throw ExtractError.unsafePath(shown(item.name))
            }
            let rc = target.withCString { target in name.withCString { name in lodestarMakeSymlink(dir, name, target) } }
            if rc != 0 { throw ExtractError.corrupt }
            return
        }
        let perm = permissions(item.unixMode)
        let rc: Int32
        if bytes.isEmpty {
            rc = name.withCString { lodestarWriteNewFile(dir, $0, nil, 0, perm) }
        } else {
            rc = bytes.withUnsafeBytes { raw in
                name.withCString { name in
                    lodestarWriteNewFile(dir, name, raw.bindMemory(to: UInt8.self).baseAddress, bytes.count, perm)
                }
            }
        }
        if rc != 0 { throw ExtractError.corrupt }
    }

    /// Opens each directory component without following a link. A link
    /// planted where a directory should be stops the unpack.
    private static func descend(_ root: Int32, _ parts: [String], name: String) throws -> (Int32, [Int32]) {
        var current = root
        var opened: [Int32] = []
        do {
            for part in parts {
                let fd = part.withCString { lodestarMkdirDir(current, $0) }
                if fd < 0 { throw ExtractError.unsafePath(shown(name)) }
                opened.append(fd)
                current = fd
            }
            return (current, opened)
        } catch {
            opened.forEach { _ = Darwin.close($0) }
            throw error
        }
    }

    /// The permission bits the archive asks for, without setuid, setgid, or
    /// a world-writable file. No mode at all is an ordinary file.
    private static func permissions(_ mode: UInt32) -> Int32 {
        let bits = mode & UInt32(0o777)
        if bits == 0 { return 0o644 }
        return Int32(bits & UInt32(0o755))
    }

    // MARK: - Little-endian reads

    private static func endOfCentralDirectory(in data: Data) -> Int? {
        let count = data.count
        guard count >= 22 else { return nil }
        let start = max(0, count - 22 - 65535)
        var offset = count - 22
        while offset >= start {
            if data[offset] == 0x50, data[offset + 1] == 0x4b, data[offset + 2] == 0x05, data[offset + 3] == 0x06 {
                let comment = Int(data[offset + 20]) | (Int(data[offset + 21]) << 8)
                if offset + 22 + comment == count { return offset }
            }
            if offset == 0 { break }
            offset -= 1
        }
        return nil
    }

    private static func u16(_ data: Data, _ offset: Int) throws -> Int {
        guard offset >= 0, offset + 2 <= data.count else { throw ExtractError.corrupt }
        return Int(data[offset]) | (Int(data[offset + 1]) << 8)
    }

    private static func u32(_ data: Data, _ offset: Int) throws -> Int {
        guard offset >= 0, offset + 4 <= data.count else { throw ExtractError.corrupt }
        return Int(data[offset])
            | (Int(data[offset + 1]) << 8)
            | (Int(data[offset + 2]) << 16)
            | (Int(data[offset + 3]) << 24)
    }

    private static func slice(_ data: Data, _ offset: Int, _ count: Int) throws -> Data {
        let end = try rangeEnd(offset, count, data.count)
        return data.subdata(in: offset..<end)
    }

    private static func rangeEnd(_ offset: Int, _ count: Int, _ limit: Int) throws -> Int {
        guard offset >= 0, count >= 0, offset <= limit, count <= limit - offset else { throw ExtractError.corrupt }
        return offset + count
    }

    private static let crcTable: [UInt32] = (0..<256).map { entry in
        var crc = UInt32(entry)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? (0xEDB8_8320 ^ (crc >> 1)) : (crc >> 1)
        }
        return crc
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

@_silgen_name("lodestar_raw_inflate")
private func lodestarRawInflate(_ src: UnsafePointer<UInt8>?, _ srcLen: Int,
                               _ dst: UnsafeMutablePointer<UInt8>?, _ dstLen: Int) -> Int32

@_silgen_name("lodestar_open_dir")
private func lodestarOpenDir(_ path: UnsafePointer<CChar>?) -> Int32

@_silgen_name("lodestar_mkdir_dir")
private func lodestarMkdirDir(_ parent: Int32, _ name: UnsafePointer<CChar>?) -> Int32

@_silgen_name("lodestar_write_new_file")
private func lodestarWriteNewFile(_ parent: Int32, _ name: UnsafePointer<CChar>?,
                                  _ bytes: UnsafePointer<UInt8>?, _ length: Int, _ mode: Int32) -> Int32

@_silgen_name("lodestar_make_symlink")
private func lodestarMakeSymlink(_ parent: Int32, _ name: UnsafePointer<CChar>?,
                                 _ target: UnsafePointer<CChar>?) -> Int32
