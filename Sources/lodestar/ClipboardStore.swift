import AppKit
import CryptoKit
import LodestarCore

/// Clipboard history on disk: a small index held in memory and rewritten on
/// a coalesced timer, with each clip's representations as ordinary files
/// beside it.
///
/// The index carries previews only — never content — so opening the strip
/// touches no files and searching is a scan of memory. Content is read at
/// the one moment it is needed, which is the paste.
final class ClipboardStore {
    private struct Index: Codable {
        var version: Int = 1
        var clips: [Clipboard.Clip] = []
    }

    private let root: URL
    private var index = Index()
    private var pendingSave: DispatchWorkItem?
    private let io = DispatchQueue(label: "lodestar.clipboard.io", qos: .utility)
    /// Decoded thumbnails, so a strip of image cards costs no decoding.
    private var thumbnails: [String: NSImage] = [:]

    var clips: [Clipboard.Clip] { index.clips }

    init(root: URL = Paths.clipboard) {
        self.root = root
        try? FileManager.default.createDirectory(at: items, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        load()
    }

    private var indexFile: URL { root.appendingPathComponent("index.json") }
    /// Left by `lodestar clipboard clear` so a running instance drops its
    /// in-memory index too — otherwise the next coalesced save would put
    /// back everything the CLI had just removed.
    var clearRequestFile: URL { root.appendingPathComponent("clear-requested") }
    private var items: URL { root.appendingPathComponent("items", isDirectory: true) }
    private var thumbs: URL { root.appendingPathComponent("thumbs", isDirectory: true) }

    private func load() {
        guard let data = try? Data(contentsOf: indexFile),
              let decoded = try? JSONDecoder().decode(Index.self, from: data) else { return }
        index = decoded
        Log.info("clipboard: loaded \(decoded.clips.count) clips")
    }

    /// Coalesced, like the state store: a burst of copies must not become a
    /// burst of writes.
    private func saveSoon() {
        guard pendingSave == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSave = nil
            self.saveNow()
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = index
        io.async { [indexFile] in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: indexFile, options: .atomic)
        }
    }

    // MARK: - Content addressing

    static func identity(for data: Data) -> String {
        SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func file(_ id: String, _ ext: String) -> URL {
        items.appendingPathComponent("\(id).\(ext)")
    }

    private func typeExtension(_ index: Int) -> String { "type\(index)" }

    // MARK: - Recording

    /// Write a clip's representations, then fold it into the index. The
    /// plain form is what a bare label pastes; the natives are what ⇧label
    /// pastes, stored richest first exactly as the source app offered them.
    func record(id: String, kind: Clipboard.Kind, plain: Data?,
                natives: [(type: String, data: Data)],
                image: NSImage?, preview: String,
                sourceBundleID: String?, sourceAppName: String?) {
        var bytes = plain?.count ?? 0
        if let plain { try? plain.write(to: file(id, "plain")) }
        for (offset, native) in natives.enumerated() {
            bytes += native.data.count
            try? native.data.write(to: file(id, typeExtension(offset)))
        }
        if let image, let thumbnail = thumbnail(from: image),
           let png = thumbnail.pngData() {
            try? png.write(to: thumbs.appendingPathComponent("\(id).png"))
            thumbnails[id] = thumbnail
        }

        let clip = Clipboard.Clip(
            id: id, kind: kind, created: Date(),
            sourceBundleID: sourceBundleID, sourceAppName: sourceAppName,
            preview: preview, bytes: bytes,
            nativeTypes: natives.map(\.type)
        )
        index.clips = Clipboard.merging(index.clips, with: clip)
        saveSoon()
    }

    /// A 240pt thumbnail so a strip of image cards costs no full decodes.
    private func thumbnail(from image: NSImage) -> NSImage? {
        let side: CGFloat = 240
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(side / size.width, side / size.height, 1)
        let target = NSSize(width: size.width * scale, height: size.height * scale)
        let thumb = NSImage(size: target)
        thumb.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target))
        thumb.unlockFocus()
        return thumb
    }

    func thumbnail(for id: String) -> NSImage? {
        if let cached = thumbnails[id] { return cached }
        let url = thumbs.appendingPathComponent("\(id).png")
        guard let image = NSImage(contentsOf: url) else { return nil }
        thumbnails[id] = image
        return image
    }

    // MARK: - Reading back

    func plainData(_ id: String) -> Data? { try? Data(contentsOf: file(id, "plain")) }

    /// Every stored representation, richest first — what ⇧label restores.
    func nativeData(_ clip: Clipboard.Clip) -> [(type: String, data: Data)] {
        clip.nativeTypes.enumerated().compactMap { offset, type in
            guard let data = try? Data(contentsOf: file(clip.id, typeExtension(offset))) else { return nil }
            return (type, data)
        }
    }

    // MARK: - Mutation

    func pin(_ id: String) -> Bool {
        guard let position = index.clips.firstIndex(where: { $0.id == id }) else { return false }
        guard index.clips[position].pinnedSlot == nil else { return true }
        let taken = Set(index.clips.compactMap(\.pinnedSlot))
        guard let slot = Clipboard.lowestFreeSlot(taken: taken) else { return false }
        index.clips[position].pinnedSlot = slot
        saveSoon()
        return true
    }

    func unpin(_ id: String) {
        guard let position = index.clips.firstIndex(where: { $0.id == id }) else { return }
        index.clips[position].pinnedSlot = nil
        saveSoon()
    }

    func delete(_ id: String) {
        index.clips.removeAll { $0.id == id }
        thumbnails[id] = nil
        io.async { [items, thumbs] in
            let fm = FileManager.default
            for url in (try? fm.contentsOfDirectory(at: items, includingPropertiesForKeys: nil)) ?? []
            where url.lastPathComponent.hasPrefix("\(id).") {
                try? fm.removeItem(at: url)
            }
            try? fm.removeItem(at: thumbs.appendingPathComponent("\(id).png"))
        }
        saveSoon()
    }

    /// True once, if a CLI clear happened while this process was running.
    func consumeClearRequest() -> Bool {
        guard FileManager.default.fileExists(atPath: clearRequestFile.path) else { return false }
        try? FileManager.default.removeItem(at: clearRequestFile)
        return true
    }

    func requestClear() {
        try? Data().write(to: clearRequestFile)
    }

    func clearAll() {
        index.clips.removeAll()
        thumbnails.removeAll()
        io.async { [items, thumbs] in
            let fm = FileManager.default
            try? fm.removeItem(at: items)
            try? fm.removeItem(at: thumbs)
            try? fm.createDirectory(at: items, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
            try? fm.createDirectory(at: thumbs, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        }
        saveNow()
    }

    /// Enforce the ceilings. Pins are exempt; the loose clips absorb it.
    func trim(maxBytes: Int, maxItems: Int) {
        let doomed = Clipboard.trim(index.clips, maxBytes: maxBytes, maxItems: maxItems)
        guard !doomed.isEmpty else { return }
        for id in doomed { delete(id) }
        Log.info("clipboard: trimmed \(doomed.count) clips")
    }
}

extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
