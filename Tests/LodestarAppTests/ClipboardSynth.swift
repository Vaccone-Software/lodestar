import Foundation
import StoicSealed
import StoicStore
import Synchronization
@testable import LodestarCore

/// A history made the way the clipboard made one before it was sealed, for the
/// tests of the migration, and a file system that dies part-way through.
enum ClipboardSynth {
    /// A marker in every byte of content, so a scan of the disk can tell
    /// plaintext from noise: nothing under the clipboard folder may hold one
    /// once the history is sealed.
    static let marker = "LODESTAR-SYNTH-PLAINTEXT"

    struct Made {
        var clips: [Clipboard.Clip]
        var items: [String: [ClipboardContent.Item]]
        var thumbnails: [String: Data]
    }

    static func identity(_ n: Int) -> String { String(format: "%032x", n &* 2_654_435_761 &+ 1) }

    /// `count` clips, newest first, of every kind a history holds.
    static func make(count: Int = 60, now: Date = Date(timeIntervalSince1970: 1_800_000_000), imageBytes: Int = 4_000) -> Made {
        var made = Made(clips: [], items: [:], thumbnails: [:])
        for n in 0..<count {
            let id = identity(n)
            let created = now.addingTimeInterval(-Double(n) * 60)
            var clip: Clipboard.Clip
            var items: [ClipboardContent.Item]
            switch n % 6 {
            case 1: // rich text
                let text = "\(marker) rich \(n)"
                items = [.init(plain: Data(text.utf8), natives: [("public.html", Data("<b>\(text)</b>".utf8)),
                                                                  ("public.rtf", Data("{\\rtf1 \(text)}".utf8))])]
                clip = Clipboard.Clip(id: id, kind: .text, created: created, sourceBundleID: "com.apple.Safari",
                                      sourceAppName: "Safari", preview: text, bytes: 3 * text.utf8.count,
                                      nativeTypes: ["public.html", "public.rtf"], sourceHost: "github.com",
                                      lines: 1, characters: text.count)
            case 2: // an image with a thumbnail and a caption
                let png = Data("\(marker) png \(n) ".utf8) + Data((0..<imageBytes).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ n) })
                items = [.init(plain: nil, natives: [("public.png", png)])]
                clip = Clipboard.Clip(id: id, kind: .image, created: created, sourceBundleID: "com.apple.screencaptureui",
                                      sourceAppName: "Screenshot",
                                      preview: Clipboard.imagePreview(width: 1440, height: 900, text: "\(marker) caption \(n)"),
                                      bytes: png.count, nativeTypes: ["public.png"])
                made.thumbnails[id] = Data("\(marker) thumb \(n)".utf8)
            case 3: // three files copied at once
                let paths = (0..<3).map { "/Users/x/\(marker)-file-\(n)-\($0).txt" }
                items = paths.map { .init(plain: Data($0.utf8), natives: [("public.file-url", Data("file://\($0)".utf8))]) }
                clip = Clipboard.Clip(id: id, kind: .text, created: created, sourceBundleID: "com.apple.finder",
                                      sourceAppName: "Finder", preview: paths.joined(separator: "\n"), bytes: 400,
                                      nativeTypes: ["public.file-url"],
                                      otherItemTypes: [["public.file-url"], ["public.file-url"]])
            case 4: // a long text
                let text = (0..<2_000).map { "\(marker) line \(n) \($0)" }.joined(separator: "\n")
                items = [.init(plain: Data(text.utf8), natives: [])]
                clip = Clipboard.Clip(id: id, kind: .text, created: created, sourceBundleID: "com.apple.Terminal",
                                      sourceAppName: "Terminal", preview: String(text.prefix(2000)), bytes: text.utf8.count,
                                      lines: 2_000, characters: text.count)
            default: // a short text
                let text = "\(marker) text \(n)"
                items = [.init(plain: Data(text.utf8), natives: [])]
                clip = Clipboard.Clip(id: id, kind: .text, created: created, sourceBundleID: "com.apple.Notes",
                                      sourceAppName: "Notes", preview: text, bytes: text.utf8.count,
                                      lines: 1, characters: text.count)
            }
            made.clips.append(clip)
            made.items[id] = items
        }
        // Keepsakes, named and not.
        made.clips[0].pinnedSlot = 4
        made.clips[0].keptName = "\(marker) the first one"
        if made.clips.count > 5 { made.clips[5].pinnedSlot = 2 }
        return made
    }

    /// Write `made` to `root` as v1: the index and every file.
    static func write(_ made: Made, to root: URL) throws {
        for clip in made.clips {
            try ClipboardV1.write(clip, items: made.items[clip.id] ?? [], thumbnail: made.thumbnails[clip.id], to: root)
        }
        try ClipboardV1.writeIndex(made.clips, to: root)
    }

    /// Every file under `root`, relative, with its bytes.
    static func everything(under root: URL) -> [String: Data] {
        var found: [String: Data] = [:]
        guard let real = realpath(root.path, nil) else { return found }
        defer { free(real) }
        let base = String(cString: real)
        guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: base), includingPropertiesForKeys: [.isRegularFileKey]) else { return found }
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            found[String(url.path.dropFirst(base.count + 1))] = try? Data(contentsOf: url)
        }
        return found
    }

    /// Files under `root` (any depth) that hold the marker, or one of the clips' own words.
    static func plaintextHits(under root: URL, extra: [String] = []) -> [String] {
        let needles = ([marker] + extra).map { Data($0.utf8) }
        return everything(under: root).filter { _, bytes in needles.contains { bytes.range(of: $0) != nil } }.keys.sorted()
    }

    static func modes(under root: URL) -> [String: Int] {
        var found: [String: Int] = [:]
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return found }
        for case let name as String in walker {
            let mode = ((try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(name).path))?[.posixPermissions] as? Int) ?? -1
            found[name] = mode
        }
        return found
    }
}

/// The real file system until it "dies": after `limit` mutating calls every
/// call fails, which leaves on disk exactly what a crash at that point does
/// (nothing a later step would have done), and counts the calls so that a test
/// can sweep every point.
final class DyingFileSystem: FileSystem, @unchecked Sendable {
    private let base: any FileSystem
    private let state = Mutex((count: 0, limit: Int.max))

    init(_ base: any FileSystem = OwnerOnly.fileSystem, dyingAfter limit: Int = .max) {
        self.base = base
        state.withLock { $0.limit = limit }
    }

    var calls: Int { state.withLock { $0.count } }

    private func step() throws(StoreError) {
        let dead = state.withLock { state -> Bool in
            if state.count >= state.limit { return true }
            state.count += 1
            return false
        }
        if dead { throw StoreError(kind: .ioFailure, operation: "dying") }
    }

    func open(_ path: String, mode: OpenMode) throws(StoreError) -> OpenFile {
        if mode != .read { try step() }
        return try base.open(path, mode: mode)
    }
    func setPermissions(_ file: OpenFile, to permissions: UInt16) throws(StoreError) { try base.setPermissions(file, to: permissions) }
    func read(_ file: OpenFile, at offset: Int, count: Int) throws(StoreError) -> [UInt8] { try base.read(file, at: offset, count: count) }
    func write(_ file: OpenFile, _ bytes: [UInt8], at offset: Int) throws(StoreError) { try step(); try base.write(file, bytes, at: offset) }
    func size(of file: OpenFile) throws(StoreError) -> Int { try base.size(of: file) }
    func truncate(_ file: OpenFile, to size: Int) throws(StoreError) { try step(); try base.truncate(file, to: size) }
    func fullSync(_ file: OpenFile) throws(StoreError) { try step(); try base.fullSync(file) }
    func close(_ file: OpenFile) throws(StoreError) { try base.close(file) }
    func syncDirectory(_ directory: String) throws(StoreError) { try step(); try base.syncDirectory(directory) }
    func rename(from source: String, to destination: String) throws(StoreError) { try step(); try base.rename(from: source, to: destination) }
    func remove(_ path: String) throws(StoreError) { try step(); try base.remove(path) }
    func list(directory: String) throws(StoreError) -> [String] { try base.list(directory: directory) }
    func exists(_ path: String) throws(StoreError) -> Bool { try base.exists(path) }
    func freeSpace(at directory: String) throws(StoreError) -> UInt64 { try base.freeSpace(at: directory) }
    func createDirectory(_ path: String) throws(StoreError) { try step(); try base.createDirectory(path) }
    func permissions(of path: String) throws(StoreError) -> UInt16? { try base.permissions(of: path) }
    func readLink(_ path: String) throws(StoreError) -> String? { try base.readLink(path) }
    func exchange(_ first: String, _ second: String) throws(StoreError) { try step(); try base.exchange(first, second) }
    func removeTree(_ path: String) throws(StoreError) { try step(); try base.removeTree(path) }
    func tryLock(_ file: OpenFile) throws(StoreError) -> Bool { try base.tryLock(file) }
    func unlock(_ file: OpenFile) throws(StoreError) { try base.unlock(file) }
}
