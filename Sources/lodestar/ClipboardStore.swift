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
    /// Every change to the index moves this on, so what is derived from the
    /// clips can be kept for as long as they do not change.
    private(set) var generation = 0
    private var index = Index() { didSet { generation &+= 1 } }
    private var pendingSave: DispatchWorkItem?
    /// The index file exists but could not be read at all. Saving over it
    /// would trade a recoverable problem for an unrecoverable one, so
    /// while this is set the store stays read-only.
    private var loadFailed = false
    /// Surfaced once at boot, the way a corrupt state file is.
    private(set) var bootWarning: String?
    private let io = DispatchQueue(label: "lodestar.clipboard.io", qos: .utility)
    /// Every recognizer run goes through this one queue, a screenshot at a
    /// time. Each pass is most of a second of the neural engine and a
    /// decoded copy of the picture, so a burst of screenshots must wait in
    /// line, not run side by side.
    private let ocr = DispatchQueue(label: "lodestar.clipboard.ocr", qos: .utility)
    /// What an image says. The recognizer here; a test's own, to count its
    /// calls and watch their order.
    var readText: (Data) -> String? = { OCRSense.readText(imageData: $0) }
    /// Decoded thumbnails, so a strip of image cards costs no decoding —
    /// bounded, because a decoded image is far larger than its file and a
    /// menu-bar app runs for weeks.
    ///
    /// The strip shows twelve cards at most — eight recents and four
    /// keepsakes — and a card is at most 480 pixels on a side, so a decoded
    /// one is 0.6 MB for a screenshot's proportions and 0.9 MB at the very
    /// worst. Forty-eight is four strips' worth: the cards on show and
    /// three more screens of them, which is what typing and deleting in the
    /// search band walks back and forth over, for 28 MB typically and 44 MB
    /// at the worst, held for the weeks the app runs. The 32 it had was
    /// under three strips, and a search that wandered past them decoded the
    /// same cards again.
    private var thumbnails: [String: NSImage] = [:]
    private var thumbnailOrder: [String] = []
    static let thumbnailLimit = 48
    /// Where a thumbnail is read and decoded: not the main thread, which is
    /// drawing, and not the io queue, which may be writing a screenshot.
    private let decoder = DispatchQueue(label: "lodestar.clipboard.thumbnails", qos: .userInitiated)
    /// Ids being decoded now, and ids whose file would not read — asked
    /// for once, not on every redraw.
    private var decoding: Set<String> = []
    private var thumbnailless: Set<String> = []
    private var refreshPending = false
    /// Decodes started, for the tests.
    private(set) var decodes = 0
    /// How many are held, for the tests.
    var cachedThumbnails: Int { thumbnails.count }
    /// Fired on the main thread once a clip's thumbnail exists, since the
    /// bytes land after the index does.
    var onThumbnail: (() -> Void)?

    var clips: [Clipboard.Clip] { index.clips }

    /// What a redraw asks of the whole history: the recents, the keepsakes
    /// and how many clips each app copied. Each used to be a pass over
    /// every clip, three or four of them at every redraw — a key moving
    /// the selection among cards that had not changed. They are derived
    /// once for each state of the index, and the answer kept until a change
    /// moves `generation` on.
    private struct Derived {
        let generation: Int
        let recents: [Clipboard.Clip]
        let pins: [Clipboard.Clip]
        let sources: [String: Int]
    }
    private var derived: Derived?
    /// How often it was derived, for the tests.
    private(set) var derivations = 0

    private func settled() -> Derived {
        if let derived, derived.generation == generation { return derived }
        derivations += 1
        let now = Derived(generation: generation, recents: Clipboard.recents(index.clips),
                          pins: Clipboard.pins(index.clips), sources: Clipboard.sourceCounts(index.clips))
        derived = now
        return now
    }

    /// Newest first, keepsakes excluded: what the cards are drawn from.
    var recents: [Clipboard.Clip] { settled().recents }
    /// The keepsakes, in their places.
    var pins: [Clipboard.Clip] { settled().pins }
    /// How many recents each app copied, for the source list.
    var sourceCounts: [String: Int] { settled().sources }

    func contains(_ id: String) -> Bool {
        index.clips.contains { $0.id == id }
    }

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
            bootWarning = "clipboard history could not be read, the old index is kept beside it"
            return
        }
        index = decoded
        // Five places became four: a keepsake from the fifth moves to the
        // highest free place, once, and is written back that way.
        let settled = Clipboard.settlingSlots(index.clips)
        if settled != index.clips {
            index.clips = settled
            saveSoon()
            Log.info("clipboard", ["keepsakes": "settled into four places"])
        }
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
            DurableFile.save(data, to: indexFile, as: "clipboard", newFileMode: 0o600)
            Paths.restrict(indexFile)
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
    ///
    /// A copy of something already in the history only rises to the top.
    /// The id is the content, so the files are there: each is compared with
    /// what arrived and written only if it differs (a source can offer the
    /// same text with a different rich form), the thumbnail is made only
    /// if it is missing, and the recognizer is not run again — the card
    /// keeps the caption it has, or the one still on its way.
    func record(id: String, kind: Clipboard.Kind, items: [Item],
                imageData: Data?, preview: String,
                sourceBundleID: String?, sourceAppName: String?,
                sourceHost: String? = nil, lines: Int? = nil, characters: Int? = nil) {
        guard let first = items.first else { return }
        var bytes = 0
        for item in items {
            bytes += item.plain?.count ?? 0
            for native in item.natives { bytes += native.data.count }
        }

        let thumbFile = thumbs.appendingPathComponent("\(id).png")
        let imageTypes = first.natives.map(\.type)
        let known = contains(id)
        io.async { [weak self] in
            guard let self else { return }
            for (index, item) in items.enumerated() {
                if let plain = item.plain {
                    self.put(plain, at: self.itemFile(id, item: index, "plain"))
                }
                for (offset, native) in item.natives.enumerated() {
                    self.put(native.data, at: self.itemFile(id, item: index, self.typeExtension(offset)))
                }
            }
            // An image says what it shows: the recognizer reads it once,
            // off the main thread and off this queue — the accurate pass
            // on a screenshot is most of a second, and the writes must not
            // wait behind it — and the card learns its caption a beat
            // after it exists. A screenshot of an error is found by the
            // error. The job holds the clip's name, not its bytes: a queue
            // of screenshots must not be a queue of decoded-size buffers,
            // so it reads the blob just written when its turn comes.
            if imageData != nil, !known { self.ocr.async { self.caption(id, types: imageTypes) } }
            guard let imageData else { return }
            if known, FileManager.default.fileExists(atPath: thumbFile.path) { return }
            guard let thumbnail = Self.thumbnail(from: imageData) else { return }
            try? thumbnail.write(to: thumbFile)
            // Decoded here, so the first draw has nothing left to decode.
            let image = Self.decodedImage(from: thumbnail)
            DispatchQueue.main.async {
                if let image { self.cache(image, for: id) }
                self.onThumbnail?()
            }
        }

        let clip = Clipboard.Clip(
            id: id, kind: kind, created: Date(),
            sourceBundleID: sourceBundleID, sourceAppName: sourceAppName,
            preview: preview, bytes: bytes,
            nativeTypes: first.natives.map(\.type),
            otherItemTypes: items.dropFirst().map { $0.natives.map(\.type) },
            sourceHost: sourceHost, lines: lines, characters: characters
        )
        index.clips = Clipboard.merging(index.clips, with: clip)
        saveSoon()
    }

    /// A file's bytes, unless it already holds exactly these. Size first,
    /// from the directory entry; the bytes only when the sizes agree.
    private func put(_ data: Data, at url: URL) {
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size == data.count, let stored = try? Data(contentsOf: url, options: .mappedIfSafe),
           stored == data { return }
        try? data.write(to: url)
    }

    // MARK: - Editing a card

    /// A text card's whole text, for the clip door — the preview is cut
    /// at its cap, and the door shows all of it.
    func plainText(_ id: String) -> String? {
        plainData(id).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// The card replaced in place with new text: same position, same pin
    /// slot, same age, a new id since the id is the content. Plain text
    /// only — the original's richer forms described text that is gone.
    /// The plain file is written before the index changes, synchronously:
    /// the strip redraws from the index at once and a paste a keystroke
    /// later reads the file, so the file cannot still be in flight.
    /// Returns the card as it now stands, or nil when the card is gone
    /// or the file could not be written.
    @discardableResult
    func replace(_ clip: Clipboard.Clip, withText text: String) -> Clipboard.Clip? {
        guard let position = index.clips.firstIndex(where: { $0.id == clip.id }) else { return nil }
        // The card as the index holds it now, not as the caller last saw
        // it: a pin made since is the card's, and stays.
        let live = index.clips[position]
        let data = Data(text.utf8)
        let newID = Self.identity(for: data)
        guard newID != live.id else { return live }
        do {
            try data.write(to: itemFile(newID, item: 0, "plain"), options: .atomic)
        } catch {
            Log.error("clipboard: could not write the edited card (\(error))")
            return nil
        }
        let counted = Clipboard.counts(of: text)
        let replacement = Clipboard.Clip(
            id: newID, kind: .text, created: live.created,
            sourceBundleID: live.sourceBundleID, sourceAppName: live.sourceAppName,
            preview: Clipboard.preview(of: text), bytes: data.count,
            pinnedSlot: live.pinnedSlot, sourceHost: live.sourceHost,
            lines: counted.lines, characters: counted.characters, keptName: live.keptName)
        index.clips = Clipboard.replacing(index.clips, id: live.id, with: replacement)
        removeFiles(of: [live.id])
        saveSoon()
        return index.clips[position]
    }

    /// An edit kept as a new card at the top, the original left alone:
    /// the escape ending. It carries the original's source, since that
    /// is where the text came from. Nothing touches the pasteboard.
    @discardableResult
    func fileEdit(from clip: Clipboard.Clip, text: String) -> Clipboard.Clip? {
        let data = Data(text.utf8)
        guard !data.isEmpty else { return nil }
        let newID = Self.identity(for: data)
        do {
            try data.write(to: itemFile(newID, item: 0, "plain"), options: .atomic)
        } catch {
            Log.error("clipboard: could not write the kept edit (\(error))")
            return nil
        }
        let counted = Clipboard.counts(of: text)
        let kept = Clipboard.Clip(
            id: newID, kind: .text, created: Date(),
            sourceBundleID: clip.sourceBundleID, sourceAppName: clip.sourceAppName,
            preview: Clipboard.preview(of: text), bytes: data.count,
            sourceHost: clip.sourceHost,
            lines: counted.lines, characters: counted.characters)
        index.clips = Clipboard.merging(index.clips, with: kept)
        saveSoon()
        return kept
    }

    /// Text cards recorded before the counts existed learn them once,
    /// off the main thread, so every card can say when it is long.
    func backfillCounts(limit: Int = 2000, completion: (() -> Void)? = nil) {
        let ids = index.clips.filter { $0.kind == .text && $0.lines == nil }.prefix(limit).map(\.id)
        guard !ids.isEmpty else { completion?(); return }
        io.async { [weak self] in
            guard let self else { return }
            var counted: [String: (lines: Int, characters: Int)] = [:]
            for id in ids {
                guard let text = self.plainText(id) else { continue }
                counted[id] = Clipboard.counts(of: text)
            }
            DispatchQueue.main.async {
                for (position, clip) in self.index.clips.enumerated() {
                    guard let counts = counted[clip.id] else { continue }
                    self.index.clips[position].lines = counts.lines
                    self.index.clips[position].characters = counts.characters
                }
                if !counted.isEmpty {
                    Log.info("clipboard: counted \(counted.count) cards")
                    self.saveSoon()
                }
                completion?()
            }
        }
    }

    /// Images that were on the strip before it could read them: captioned
    /// once, one at a time on a utility queue, so a history of screenshots
    /// becomes searchable without the first boot after the update paying
    /// for it all at once. Bounded per boot; a second boot takes the rest.
    /// Only images whose preview is still the size line alone are read.
    func captionImagesLackingText(limit: Int = 500) {
        let pending = index.clips.filter {
            $0.kind == .image && !$0.preview.contains("\n")
        }.prefix(limit)
        guard !pending.isEmpty else { return }
        let jobs = pending.map { (id: $0.id, types: $0.itemTypes.first ?? []) }
        captionBacklog(jobs[...], captioned: 0, of: jobs.count)
    }

    /// The backlog goes through the same queue as a fresh copy, one image
    /// per turn, and each turn queues the next only when it is done: a
    /// screenshot copied while the backlog is being read goes next, not
    /// after the other four hundred.
    private func captionBacklog(_ jobs: ArraySlice<(id: String, types: [String])>,
                                captioned: Int, of total: Int) {
        ocr.async { [weak self] in
            guard let self else { return }
            guard let job = jobs.first else {
                Log.info("clipboard: captioned \(captioned) of \(total) images already in the history")
                return
            }
            let read = self.caption(job.id, types: job.types)
            self.captionBacklog(jobs.dropFirst(), captioned: captioned + (read ? 1 : 0), of: total)
        }
    }

    /// Read one stored image and, if it says anything, hand its caption to
    /// the main thread. On the recognizer's queue.
    @discardableResult
    private func caption(_ id: String, types: [String]) -> Bool {
        let offset = types.firstIndex {
            $0 == NSPasteboard.PasteboardType.png.rawValue
                || $0 == NSPasteboard.PasteboardType.tiff.rawValue
        } ?? 0
        guard let data = try? Data(contentsOf: itemFile(id, item: 0, typeExtension(offset))),
              let text = readText(data) else { return false }
        DispatchQueue.main.async { [weak self] in self?.caption(id, with: text) }
        return true
    }

    /// An image's text arrived. The size line stays first, so the card is
    /// the card it was; the text under it is what the search reads.
    private func caption(_ id: String, with text: String) {
        guard let position = index.clips.firstIndex(where: { $0.id == id }) else { return }
        index.clips[position].preview = Clipboard.captioned(index.clips[position].preview,
                                                            with: text)
        saveSoon()
        onThumbnail?()
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

    /// A thumbnail's pixels, decoded now rather than at the first draw,
    /// which would be the main thread's. Safe off the main thread, like
    /// `thumbnail(from:)`. The size in points is the size in pixels, as a
    /// PNG that says nothing of its resolution has always been read.
    static func decodedImage(from data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// What is decoded, now — or nil, and `onThumbnail` fires when the
    /// card's picture has been read and decoded off the main thread. A
    /// redraw shows what it has and fills in the rest as it lands; it used
    /// to read and decode every missing card on the main thread, with the
    /// strip's key tap waiting.
    func thumbnail(for id: String) -> NSImage? {
        if let cached = thumbnails[id] {
            cache(cached, for: id)
            return cached
        }
        guard !decoding.contains(id), !thumbnailless.contains(id) else { return nil }
        decoding.insert(id)
        decodes += 1
        let url = thumbs.appendingPathComponent("\(id).png")
        decoder.async { [weak self] in
            let image = (try? Data(contentsOf: url)).flatMap(Self.decodedImage(from:))
            DispatchQueue.main.async { self?.decoded(image, for: id) }
        }
        return nil
    }

    private func decoded(_ image: NSImage?, for id: String) {
        decoding.remove(id)
        // A card deleted while its picture was being read stays deleted.
        guard contains(id) else { return }
        guard let image else {
            // Unless the copy's own thumbnail has landed since: it is
            // written after the card exists, and a read that lost the race
            // with it must not outlive it.
            if thumbnails[id] == nil { thumbnailless.insert(id) }
            return
        }
        cache(image, for: id)
        // A strip's worth of cards arrive within a few milliseconds of one
        // another; one redraw takes them all.
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.refreshPending = false
            self?.onThumbnail?()
        }
    }

    /// Most recently used last; the front falls off the end.
    private func cache(_ image: NSImage, for id: String) {
        thumbnailless.remove(id)
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
        guard let slot = Clipboard.nextFreeSlot(taken: taken) else { return false }
        index.clips[position].pinnedSlot = slot
        saveSoon()
        return true
    }

    /// Letting a keepsake go forgets its name with its place: kept again
    /// later, it is offered the name its words give it.
    func unpin(_ id: String) {
        guard let position = index.clips.firstIndex(where: { $0.id == id }) else { return }
        index.clips[position].pinnedSlot = nil
        index.clips[position].keptName = nil
        saveSoon()
    }

    /// A keepsake's name as the hand left it; an empty one is no name, so
    /// the card shows what its words give it.
    func name(_ id: String, _ name: String?) {
        guard let position = index.clips.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        index.clips[position].keptName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        saveSoon()
    }

    /// A clip kept in a place that is taken: the keepsake there goes back
    /// to being a clip in the history, and this one takes its place.
    /// Returns what was displaced, so it can be put back.
    @discardableResult
    func place(_ id: String, at slot: Int) -> (id: String, name: String?)? {
        guard (1...Clipboard.pinSlots).contains(slot),
              let position = index.clips.firstIndex(where: { $0.id == id }) else { return nil }
        var displaced: (id: String, name: String?)?
        if let other = index.clips.firstIndex(where: { $0.pinnedSlot == slot }), other != position {
            displaced = (index.clips[other].id, index.clips[other].keptName)
            index.clips[other].pinnedSlot = nil
            index.clips[other].keptName = nil
        }
        index.clips[position].pinnedSlot = slot
        saveSoon()
        return displaced
    }

    /// Every keepsake's place and name, as they stand.
    func keepsakes() -> [String: (slot: Int, name: String?)] {
        var out: [String: (slot: Int, name: String?)] = [:]
        for clip in index.clips { if let slot = clip.pinnedSlot { out[clip.id] = (slot, clip.keptName) } }
        return out
    }

    /// The keepsakes put back exactly as they were: every place and name
    /// in `snapshot` restored, anything kept since let go. However many
    /// trades a naming made, `esc` undoes all of them.
    func restoreKeepsakes(_ snapshot: [String: (slot: Int, name: String?)]) {
        for position in index.clips.indices {
            if let was = snapshot[index.clips[position].id] {
                index.clips[position].pinnedSlot = was.slot
                index.clips[position].keptName = was.name
            } else if index.clips[position].pinnedSlot != nil {
                index.clips[position].pinnedSlot = nil
                index.clips[position].keptName = nil
            }
        }
        saveSoon()
    }

    /// A keepsake moved to another place, trading with whatever is there,
    /// so no place ever holds two and no keepsake is lost.
    func move(_ id: String, to slot: Int) {
        guard (1...Clipboard.pinSlots).contains(slot),
              let position = index.clips.firstIndex(where: { $0.id == id }),
              let from = index.clips[position].pinnedSlot, from != slot else { return }
        if let other = index.clips.firstIndex(where: { $0.pinnedSlot == slot }) {
            index.clips[other].pinnedSlot = from
        }
        index.clips[position].pinnedSlot = slot
        saveSoon()
    }

    func delete(_ id: String) {
        delete([id])
    }

    /// Several clips at once: one pass over the index and one look at the
    /// directory, however many go.
    private func delete(_ ids: [String]) {
        let gone = Set(ids)
        index.clips.removeAll { gone.contains($0.id) }
        removeFiles(of: ids)
        saveSoon()
    }

    /// Wait for every file write queued so far — the tests' seam, so a
    /// card seeded a moment ago is on disk before the door reads it.
    func flushIO() { io.sync {} }

    /// Every file the clips left behind, off the main thread. The directory
    /// is listed once for all of them: a trim of fifty used to list it
    /// fifty times, each over every clip's files. Files are named
    /// `<id>.<something>`, so a file is a clip's when what stands before one
    /// of its dots is the id — and one nobody's index names any more (a
    /// form an earlier copy of the clip had) goes with it.
    private func removeFiles(of ids: [String]) {
        let gone = Set(ids)
        for id in ids {
            thumbnails[id] = nil
            thumbnailless.remove(id)
        }
        thumbnailOrder.removeAll { gone.contains($0) }
        io.async { [items, thumbs] in
            let fm = FileManager.default
            for name in (try? fm.contentsOfDirectory(atPath: items.path)) ?? []
            where Self.belongs(name, toOneOf: gone) {
                try? fm.removeItem(at: items.appendingPathComponent(name))
            }
            for id in gone { try? fm.removeItem(at: thumbs.appendingPathComponent("\(id).png")) }
        }
    }

    /// Is `name` one of `<id>.…` for an id in `ids`? An id is hex, but a
    /// test names its clips as it likes, so every dot is tried.
    static func belongs(_ name: String, toOneOf ids: Set<String>) -> Bool {
        var from = name.startIndex
        while let dot = name[from...].firstIndex(of: ".") {
            if ids.contains(String(name[..<dot])) { return true }
            from = name.index(after: dot)
        }
        return false
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
        thumbnailless.removeAll()
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

    /// `clearAll`, finished before it returns: the files removed, the empty
    /// index written. For a process that exits as soon as it is done, which
    /// `lodestar clipboard clear` is — it printed "cleared" and left with
    /// the removal still queued.
    func clearAllAndWait() {
        clearAll()
        flushIO()
    }

    /// Enforce the ceilings. Pins are exempt; the loose clips absorb it.
    func trim(maxBytes: Int, maxItems: Int) {
        let doomed = Clipboard.trim(index.clips, maxBytes: maxBytes, maxItems: maxItems)
        guard !doomed.isEmpty else { return }
        delete(doomed)
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
