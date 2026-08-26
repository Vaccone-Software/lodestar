import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
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
    /// The index file exists but could not be read at all. Saving over it
    /// would trade a recoverable problem for an unrecoverable one, so
    /// while this is set the store stays read-only.
    private var loadFailed = false
    /// Surfaced once at boot, the way a corrupt state file is.
    private(set) var bootWarning: String?
    private let io = DispatchQueue(label: "lodestar.clipboard.io", qos: .utility)
    /// Decoded thumbnails, so a strip of image cards costs no decoding —
    /// bounded, because a decoded image is far larger than its file and a
    /// menu-bar app runs for weeks. The strip shows at most fourteen at
    /// once, so this only ever has to cover a little scrollback.
    private var thumbnails: [String: NSImage] = [:]
    private var thumbnailOrder: [String] = []
    private static let thumbnailLimit = 32
    /// Fired on the main thread once a clip's thumbnail exists, since the
    /// bytes land after the index does.
    var onThumbnail: (() -> Void)?

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

    /// Read the index, quarantining one that will not decode.
    ///
    /// Returning empty and carrying on meant the next copy wrote an empty
    /// index straight over the file, and every blob under `items/` was
    /// orphaned with nothing left pointing at it. Power loss is not the
    /// realistic trigger — the write is atomic — a schema change to `Clip`
    /// or `Index` is, and that would have zeroed every user's history on
    /// upgrade. The state store already handles this properly; so does
    /// this one now.
    private func load() {
        guard FileManager.default.fileExists(atPath: indexFile.path) else { return }
        guard let data = try? Data(contentsOf: indexFile) else {
            Log.error("clipboard: index unreadable — starting empty, nothing deleted")
            loadFailed = true
            return
        }
        guard let decoded = try? JSONDecoder().decode(Index.self, from: data) else {
            let quarantine = Quarantine.setAside(indexFile)
            Log.error("clipboard: index did not decode — quarantined at \(quarantine.lastPathComponent)")
            bootWarning = "clipboard history could not be read — the old index is kept beside it"
            return
        }
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
        // An index we could not read is not an index we may overwrite.
        guard !loadFailed else { return }
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

    /// Item one keeps the names it has always had on disk, so a history
    /// written before a copy could be several things reads back untouched;
    /// every later item hangs off its index.
    private func itemFile(_ id: String, item: Int, _ ext: String) -> URL {
        file(id, item == 0 ? ext : "i\(item).\(ext)")
    }

    /// One pasteboard item as it is stored and put back: the plain text
    /// form, and every richer form the source app offered beside it.
    struct Item {
        var plain: Data?
        var natives: [(type: String, data: Data)]
    }

    // MARK: - Recording

    /// Write a copy's representations, then fold it into the index. The
    /// plain form is what a bare label pastes; the natives are what ⇧label
    /// pastes, stored richest first exactly as the source app offered them.
    ///
    /// A copy is a list of items rather than one thing, because the
    /// pasteboard is: three files selected in Finder arrive as three
    /// items, and each of them has its own forms to keep.
    ///
    /// The index is updated here and now, so the strip can draw the moment
    /// a copy lands; the bytes go to disk on the io queue, because a large
    /// screenshot is tens of megabytes and this is called from a timer on
    /// the main thread.
    func record(id: String, kind: Clipboard.Kind, items: [Item],
                imageData: Data?, preview: String,
                sourceBundleID: String?, sourceAppName: String?) {
        guard let first = items.first else { return }
        var bytes = 0
        for item in items {
            bytes += item.plain?.count ?? 0
            for native in item.natives { bytes += native.data.count }
        }

        let thumbFile = thumbs.appendingPathComponent("\(id).png")
        io.async { [weak self] in
            guard let self else { return }
            for (index, item) in items.enumerated() {
                if let plain = item.plain {
                    try? plain.write(to: self.itemFile(id, item: index, "plain"))
                }
                for (offset, native) in item.natives.enumerated() {
                    try? native.data.write(
                        to: self.itemFile(id, item: index, self.typeExtension(offset)))
                }
            }
            guard let imageData, let thumbnail = Self.thumbnail(from: imageData) else { return }
            try? thumbnail.write(to: thumbFile)
            DispatchQueue.main.async {
                if let image = NSImage(data: thumbnail) { self.cache(image, for: id) }
                self.onThumbnail?()
            }
        }

        let clip = Clipboard.Clip(
            id: id, kind: kind, created: Date(),
            sourceBundleID: sourceBundleID, sourceAppName: sourceAppName,
            preview: preview, bytes: bytes,
            nativeTypes: first.natives.map(\.type),
            otherItemTypes: items.dropFirst().map { $0.natives.map(\.type) }
        )
        index.clips = Clipboard.merging(index.clips, with: clip)
        saveSoon()
    }

    /// A clip's dimensions, read from the file header. ImageIO answers this
    /// without decoding a pixel, which is the whole point — the alternative
    /// is inflating a 40MB screenshot to ask how wide it is.
    static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// A 240pt thumbnail as PNG bytes, so a strip of image cards costs no
    /// full decodes. ImageIO downsamples straight out of the source rather
    /// than decoding and redrawing, and unlike NSImage it is safe to do off
    /// the main thread — which is where this runs.
    static func thumbnail(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 480,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let out = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                out, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    func thumbnail(for id: String) -> NSImage? {
        if let cached = thumbnails[id] {
            cache(cached, for: id)
            return cached
        }
        let url = thumbs.appendingPathComponent("\(id).png")
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache(image, for: id)
        return image
    }

    /// Most recently used last; the front falls off the end.
    private func cache(_ image: NSImage, for id: String) {
        thumbnails[id] = image
        thumbnailOrder.removeAll { $0 == id }
        thumbnailOrder.append(id)
        while thumbnailOrder.count > Self.thumbnailLimit {
            thumbnails.removeValue(forKey: thumbnailOrder.removeFirst())
        }
    }

    // MARK: - Reading back

    func plainData(_ id: String, item: Int = 0) -> Data? {
        try? Data(contentsOf: itemFile(id, item: item, "plain"))
    }

    /// One item's stored representations, richest first — what ⇧label
    /// restores.
    func nativeData(_ clip: Clipboard.Clip, item: Int = 0) -> [(type: String, data: Data)] {
        guard clip.itemTypes.indices.contains(item) else { return [] }
        return clip.itemTypes[item].enumerated().compactMap { offset, type in
            guard let data = try? Data(contentsOf: itemFile(clip.id, item: item,
                                                            typeExtension(offset)))
            else { return nil }
            return (type, data)
        }
    }

    /// The whole copy, in the order the board carried it — what a paste
    /// has to put back for three copied files to arrive as three files.
    func itemData(_ clip: Clipboard.Clip) -> [Item] {
        clip.itemTypes.indices.map { index in
            Item(plain: plainData(clip.id, item: index), natives: nativeData(clip, item: index))
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
        thumbnailOrder.removeAll { $0 == id }
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
        thumbnailOrder.removeAll()
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
