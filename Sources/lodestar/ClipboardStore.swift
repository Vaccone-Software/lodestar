import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import LodestarCore
import StoicSealed
import Synchronization

/// Clipboard history: the clips held in memory, and their bytes sealed on disk
/// (`SealedClipboard`: an index journal of small operations, a sealed blob and
/// thumbnail per clip under the clip's own key).
///
/// The index carries previews only — never content — so opening the strip
/// touches no files and searching is a scan of memory. Content is read at
/// the one moment it is needed, which is the paste.
///
/// **The history opens off the main thread** (`Phase`). The strip shows an
/// honest empty state until the journal has been read and decoded, and a copy
/// that arrives meanwhile is queued and applied after, in order: never lost,
/// never written before the index is open. Boot no longer waits for the index.
///
/// **Writes.** A copy appends a record of a few hundred bytes, on the
/// existing half-second debounce, instead of rewriting the whole index; the
/// blob is complete before the record that names it is appended (both go
/// through the one serial queue, the blob first). The log is folded into a
/// snapshot, rotating the ring's key, when it has grown, at idle; and **two
/// seconds after a delete** (`deletionDelay`), which is what makes a deleted
/// clip unrecoverable: until then its record, and the key in it, can still be
/// opened by the ring.
final class ClipboardStore {
    enum Phase: Equatable {
        /// Being read, off the main thread.
        case opening
        case ready
        /// Nothing is open: the history was cleared, and the next copy opens a new one
        /// (and makes a new ring).
        case closed
        /// Paused for this launch: no capture, no reads, no writes, no deletes.
        case unavailable(SealedClipboard.Unavailable)
    }

    /// How long after the last delete the log is folded and the key rotated.
    nonisolated(unsafe) static var deletionDelay: TimeInterval = 2
    /// How long after the last write the log is folded once it has grown (at idle).
    nonisolated(unsafe) static var foldDelay: TimeInterval = 5
    /// The most a queue of copies, waiting for the index to open, may hold.
    static let queuedByteLimit = 512_000_000

    private let root: URL
    private let ring: Vault.Ring
    private let disk: SealedClipboard
    /// Every change to the index moves this on, so what is derived from the
    /// clips can be kept for as long as they do not change.
    private(set) var generation = 0
    private var index = [Clipboard.Clip]() { didSet { generation &+= 1 } }
    private(set) var phase = Phase.opening
    /// Each clip's file name and key, by id. Only in memory and in sealed records.
    private struct Ref {
        var storage: String
        var blobKey: Data
        var key: SealingKey? { SealingKey(importing: [UInt8](blobKey)) }
    }
    private var refs: [String: Ref] = [:]
    private var pendingOps: [ClipboardOp] = []
    private var pendingSave: DispatchWorkItem?
    private var compactionWork: DispatchWorkItem?
    /// A delete whose key has not been rotated away yet.
    private var deletionOwed = false
    /// Folds that have finished (rotating the key), for the tests.
    private(set) var compactions = 0
    /// Bumped by a clear, so an opening that was already under way when it
    /// happened is not taken for what the history now is.
    private var epoch = 0
    /// Surfaced once at boot, the way a corrupt state file is.
    private(set) var bootWarning: String?
    /// What the person is told once, when the history has been moved aside
    /// or damaged: the strip's flash, the log, and `diagnose`.
    var onNotice: ((String) -> Void)?
    /// A compaction retired the ring's old keys: whatever else is sealed
    /// under the ring (a draft in flight) is sealed again under the new one.
    var onCompacted: (() -> Void)?
    /// Whether anything sealed under the ring may be written now: the key
    /// policy has been settled, and it did not pause the history.
    let sealing = Mutex(false)

    private struct Queued {
        var id: String
        var kind: Clipboard.Kind
        var items: [Item]
        var imageData: Data?
        var preview: String
        var sourceBundleID: String?
        var sourceAppName: String?
        var sourceHost: String?
        var lines: Int?
        var characters: Int?
        var created: Date
        var bytes: Int
    }
    private var queued: [Queued] = []
    private var queuedBytes = 0
    /// Blobs being written now, by storage name, so a read of one waits.
    private var inFlight: [String: Int] = [:]
    /// Blobs whose write failed: the record that names one is never appended.
    private let unwritten = Mutex<Set<String>>([])

    private let io = DispatchQueue(label: "lodestar.clipboard.io", qos: .utility)
    /// Every recognizer run goes through this one queue, a screenshot at a
    /// time. Each pass is most of a second of the neural engine and a
    /// decoded copy of the picture, so a burst of screenshots must wait in
    /// line, not run side by side.
    private let ocr = DispatchQueue(label: "lodestar.clipboard.ocr", qos: .utility)
    /// The length of a long text is counted here, a text at a time.
    private let counting = DispatchQueue(label: "lodestar.clipboard.counts", qos: .utility)
    /// A copy of files is read here: what each file is, and its picture.
    /// Concurrent, because one file on a dead mount must not hold up the
    /// next copy, and off the io queue, which is writing blobs.
    private let filing = DispatchQueue(label: "lodestar.clipboard.files", qos: .utility, attributes: .concurrent)
    /// Whether a file card's files are still where they were, asked off
    /// the main thread and kept for as long as the strip is showing.
    private let checking = DispatchQueue(label: "lodestar.clipboard.presence", qos: .utility, attributes: .concurrent)
    private var presence: [String: [Bool]] = [:]
    private var presenceAsked: Set<String> = []
    /// Bumped each time the strip opens, so an answer to a question asked
    /// of an earlier showing is not taken for this one's.
    private var presenceEpoch = 0
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

    var clips: [Clipboard.Clip] { index }

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
        let now = Derived(generation: generation, recents: Clipboard.recents(index),
                          pins: Clipboard.pins(index), sources: Clipboard.sourceCounts(index))
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
        index.contains { $0.id == id }
    }

    // MARK: The files, for the tests and the report

    /// Where a clip's blob and thumbnail are, and the key that opens them.
    /// Nothing in the app reads these: they are the tests' (and the benchmark's) way to the files.
    func blobURL(for id: String) -> URL? { refs[id].map { disk.files.itemURL($0.storage) } }
    func thumbURL(for id: String) -> URL? { refs[id].map { disk.files.thumbURL($0.storage) } }
    func sealedKey(for id: String) -> SealingKey? { refs[id]?.key }
    func storageName(of id: String) -> String? { refs[id]?.storage }
    var files: ClipboardFiles { disk.files }

    /// Opens the history **off the main thread** and returns at once: the
    /// strip is empty ("opening") until `onThumbnail` fires after the load.
    init(root: URL = Paths.clipboard, vault: Vault) {
        self.root = root
        ring = vault.ring(.clipboard)
        disk = SealedClipboard(root: root, ring: ring)
        beginOpening()
    }

    deinit {
        let disk = disk
        io.async { disk.close() }
    }

    /// Left by `lodestar clipboard clear` so a running instance drops its
    /// in-memory index too — otherwise the history it holds would go on being
    /// appended to, and its next copy would put it back.
    var clearRequestFile: URL { root.appendingPathComponent("clear-requested") }

    // MARK: - Opening

    private func beginOpening() {
        phase = .opening
        let opening = epoch
        io.async { [weak self] in
            guard let self else { return }
            let result = self.disk.open()
            DispatchQueue.main.async { self.finishOpening(result, epoch: opening) }
        }
    }

    /// Main. The journal has been read (and an older history taken in) off the
    /// main thread: publish it, and apply the copies that came while it opened.
    private func finishOpening(_ result: SealedClipboard.OpenResult, epoch opening: Int) {
        guard opening == epoch, phase == .opening else { return }
        switch result {
        case .unavailable(let why):
            phase = .unavailable(why)
            sealing.withLock { $0 = false }
            if !queued.isEmpty {
                Log.error("clipboard: \(queued.count) copies made while the history was opening are not kept — it is unavailable",
                          ["why": why.words])
            }
            queued.removeAll()
            queuedBytes = 0
            Log.error("clipboard: the history is unavailable for this launch — \(why.words)")
            onThumbnail?()
        case .ready(let opened):
            index = opened.entries.map(\.clip)
            refs = Dictionary(opened.entries.map { ($0.clip.id, Ref(storage: $0.storage, blobKey: $0.blobKey)) },
                              uniquingKeysWith: { first, _ in first })
            phase = .ready
            sealing.withLock { $0 = true }
            if let quarantine = opened.quarantined {
                bootWarning = "clipboard history could not be read, the old index is kept beside it"
                Log.error("clipboard: the older index was set aside as \(quarantine)")
            }
            if let folder = opened.movedAside {
                let notice = "The clipboard history could not be opened: its key is gone. It is kept, unreadable, in \(folder), and a new history starts now"
                bootWarning = notice
                onNotice?(notice)
            }
            // Five places became four: a keepsake from the fifth moves to the
            // highest free place, once, and is written back that way.
            let settledSlots = Clipboard.settlingSlots(index)
            if settledSlots != index {
                for (position, clip) in settledSlots.enumerated() where clip != index[position] {
                    index[position] = clip
                    commitChange(at: position)
                }
                Log.info("clipboard", ["keepsakes": "settled into four places"])
            }
            Log.info("clipboard: loaded \(index.count) clips", ["seconds": String(format: "%.2f", opened.seconds),
                                                                "unreadable": opened.unreadable])
            pruneGoneFilesSoon(after: Self.prunePeriod / 10)
            let waiting = queued
            queued.removeAll()
            queuedBytes = 0
            for pending in waiting { apply(pending) }
            if !waiting.isEmpty { Log.info("clipboard: applied \(waiting.count) copies made while it opened") }
            if disk.removalsOwed {
                // A delete that a crash cut short: its key is still in a record that opens.
                deletionOwed = true
                scheduleCompaction(after: Self.deletionDelay)
            } else if disk.needsCompaction {
                scheduleCompaction(after: Self.foldDelay)
            }
            onThumbnail?()
        }
    }

    /// For the tests and the benchmark: the main run loop turns until the
    /// history has opened (or the time is up).
    @discardableResult
    func waitUntilOpen(timeout: TimeInterval = 30) -> Phase {
        let deadline = Date().addingTimeInterval(timeout)
        while phase == .opening, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
        return phase
    }

    /// What the strip says instead of cards while there is nothing to show
    /// because of the state of the key, and nil when the history is simply empty.
    var statusLine: String? {
        switch phase {
        case .opening:
            return "⌂ clipboard history is opening — a moment"
        case .unavailable(let why):
            if why.keychain {
                return "⌂ clipboard history is unavailable — the keychain didn't open\n"
                    + (why.retryable ? "try again after unlocking, or at the next launch" : "it is tried again at the next launch")
            }
            return "⌂ clipboard history is unavailable — \(why.words)\nit is tried again at the next launch"
        case .ready, .closed:
            return nil
        }
    }

    /// Nothing is read from the pasteboard while this is true: the history is paused.
    var isPaused: Bool {
        if case .unavailable = phase { return true }
        return false
    }

    /// The screen unlocked: a keychain that was only locked is asked again.
    func retryAfterUnlock() {
        guard case .unavailable(let why) = phase, why.retryable, ring.retry() else { return }
        Log.info("clipboard: the keychain may have unlocked — opening the history again")
        beginOpening()
    }

    // MARK: - Writing the index

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

    private func commit(_ op: ClipboardOp) {
        pendingOps.append(op)
        saveSoon()
    }

    private func entry(for clip: Clipboard.Clip) -> ClipEntry? {
        refs[clip.id].map { ClipEntry(clip: clip, storage: $0.storage, blobKey: $0.blobKey) }
    }

    /// The card at `position`, as it now stands, recorded.
    private func commitChange(at position: Int) {
        guard let entry = entry(for: index[position]) else { return }
        commit(.set(entry))
    }

    /// Hand the operations so far to the io queue, behind every blob already
    /// queued: the blobs a record names are complete before it is appended.
    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard !pendingOps.isEmpty else { return }
        let ops = pendingOps
        pendingOps = []
        io.async { [weak self] in
            guard let self else { return }
            let failed = self.unwritten.withLock { $0 }
            let todo = failed.isEmpty ? ops : ops.filter { $0.storages.allSatisfy { !failed.contains($0) } }
            switch self.disk.append(todo) {
            case .appended:
                if self.disk.needsCompaction { DispatchQueue.main.async { self.scheduleCompaction(after: Self.foldDelay) } }
            case .closed:
                Log.error("clipboard: \(todo.count) changes were not written — the history is not open")
            case .failed(let why):
                Log.error("clipboard: \(todo.count) changes could not be written (\(why)) — tried again shortly")
                let store = self
                DispatchQueue.main.async {
                    store.pendingOps.insert(contentsOf: todo, at: 0)
                    store.pendingSave?.cancel()
                    let work = DispatchWorkItem { [weak store] in store?.saveNow() }
                    store.pendingSave = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
                }
            }
        }
    }

    // MARK: - Folding the log, and making a deletion real

    private func scheduleCompaction(after delay: TimeInterval) {
        compactionWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.compactNow() }
        compactionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Main. The log is folded into a snapshot on the io queue, **rotating the
    /// ring's key** so that every record written before — and the per-clip key
    /// of each clip deleted since — can no longer be opened by anyone.
    private func compactNow() {
        compactionWork = nil
        guard phase == .ready else { return }
        saveNow()
        io.async { [weak self] in
            guard let self else { return }
            let started = Date()
            switch self.disk.compact(rotatingKey: true) {
            case .compacted(let records, let bytes):
                Log.info("clipboard: folded \(records) records into a snapshot of \(bytes / 1024) KB",
                         ["ms": Int(Date().timeIntervalSince(started) * 1000)])
                DispatchQueue.main.async {
                    self.deletionOwed = false
                    self.compactions += 1
                    self.onCompacted?()
                }
            case .notShredded(let why):
                Log.error("clipboard: folded, but the old keys could not be retired (\(why)) — tried again in a minute")
                DispatchQueue.main.async { self.scheduleCompaction(after: 60); self.onCompacted?() }
            case .refused(let unreadable):
                Log.error("clipboard: not folded — \(unreadable) sealed values do not open and would be lost")
            case .failed(let why):
                Log.error("clipboard: could not fold the log (\(why)) — tried again in a minute")
                DispatchQueue.main.async { self.scheduleCompaction(after: 60) }
            case .closed:
                break
            }
        }
    }

    /// Quit: the last copy's record is on disk before the process ends, and a
    /// delete whose key is still owed is made real now. The index was written
    /// half a second after a copy, on a background queue, and quit never
    /// waited for either.
    func finishForQuit() {
        if phase == .opening { waitUntilOpen(timeout: 5) }
        saveNow()
        flushIO()
        if (deletionOwed || compactionWork != nil) && phase == .ready {
            compactionWork?.cancel()
            compactionWork = nil
            let done = io.sync { () -> Bool in
                if case .compacted = self.disk.compact(rotatingKey: true) { return true }
                return false
            }
            if done { deletionOwed = false }
        }
    }

    /// For the tests and the benchmark: fold the log now, on the io queue, and wait.
    func compactAndWait() -> Bool {
        saveNow()
        return io.sync {
            if case .compacted = self.disk.compact(rotatingKey: true) { return true }
            return false
        }
    }

    /// Stop using the files (the tests', and a store about to be replaced by another over the same folder).
    func close() {
        saveNow()
        io.sync { self.disk.close() }
    }

    // MARK: - Content addressing

    static func identity(for data: Data) -> String {
        SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// One pasteboard item as it is stored and put back: the plain text
    /// form, and every richer form the source app offered beside it.
    typealias Item = ClipboardContent.Item

    // MARK: - Recording

    /// Seal a copy's representations, then fold it into the index. The
    /// plain form is what a bare label pastes; the natives are what ⇧label
    /// pastes, stored richest first exactly as the source app offered them.
    ///
    /// A copy is a list of items rather than one thing, because the
    /// pasteboard is: three files selected in Finder arrive as three items,
    /// and each of them has its own forms to keep.
    ///
    /// The index is updated here and now, so the strip can draw the moment
    /// a copy lands; the bytes are sealed and written on the io queue, because
    /// a large screenshot is tens of megabytes and this is called from a timer
    /// on the main thread.
    ///
    /// A copy of something already in the history only rises to the top.
    /// The id is the content, so the blob is there: it is compared with what
    /// arrived and sealed again only if it differs (a source can offer the
    /// same text with a different rich form), the thumbnail is made only
    /// if it is missing, and the recognizer is not run again — the card
    /// keeps the caption it has, or the one still on its way.
    ///
    /// While the history is opening the copy is **queued** and applied after,
    /// in order; while it is unavailable it is not kept.
    func record(id: String, kind: Clipboard.Kind, items: [Item],
                imageData: Data?, preview: String,
                sourceBundleID: String?, sourceAppName: String?,
                sourceHost: String? = nil, lines: Int? = nil, characters: Int? = nil) {
        guard !items.isEmpty else { return }
        var bytes = 0
        for item in items {
            bytes += item.plain?.count ?? 0
            for native in item.natives { bytes += native.data.count }
        }
        let arrival = Queued(id: id, kind: kind, items: items, imageData: imageData, preview: preview,
                             sourceBundleID: sourceBundleID, sourceAppName: sourceAppName, sourceHost: sourceHost,
                             lines: lines, characters: characters, created: Date(), bytes: bytes)
        switch phase {
        case .ready:
            apply(arrival)
        case .opening, .closed:
            guard queuedBytes + bytes <= Self.queuedByteLimit else {
                Log.error("clipboard: a copy was not kept — too much is waiting for the history to open")
                return
            }
            queued.append(arrival)
            queuedBytes += bytes
            if phase == .closed { beginOpening() }
        case .unavailable:
            return
        }
    }

    private func apply(_ arrival: Queued) {
        let id = arrival.id
        let known = contains(id) && refs[id] != nil
        let ref = refs[id] ?? Ref(storage: ClipboardSealed.newStorage(),
                                  blobKey: Data(SealingKey.generate().exportedForWrapping()))
        refs[id] = ref
        let items = arrival.items
        let imageData = arrival.imageData
        let imageTypes = items.first?.natives.map(\.type) ?? []
        let files = disk.files
        inFlight[ref.storage, default: 0] += 1
        io.async { [weak self] in
            guard let self else { return }
            defer { DispatchQueue.main.async { self.finishedWriting(ref.storage) } }
            guard let key = ref.key else { return }
            // Sealed only if it is not there as it arrived.
            var needsWrite = true
            if known, case .items(let stored) = files.readBlob(storage: ref.storage, key: key),
               ClipboardContent.sameBytes(stored, items) { needsWrite = false }
            if needsWrite {
                do {
                    try files.writeBlob(storage: ref.storage, key: key, items: items)
                } catch {
                    Log.error("clipboard: could not write a clip (\(error))")
                    if !known {
                        self.unwritten.withLock { _ = $0.insert(ref.storage) }
                        DispatchQueue.main.async { self.dropUnwritten(id) }
                    }
                    return
                }
            }
            // A copy of files is read off the main thread and off this queue:
            // a file can be anywhere, and nothing about it is worth a write
            // waiting. The card is on screen already, with the names its
            // preview has; the rest arrives a beat after.
            if arrival.kind == .file {
                let urls = Clipboard.fileURLs(in: items)
                if !urls.isEmpty { self.filing.async { self.readFiles(id, urls: urls, items: items, ref: ref) } }
            }
            // An image says what it shows: the recognizer reads it once,
            // off the main thread and off this queue — the accurate pass
            // on a screenshot is most of a second, and the writes must not
            // wait behind it — and the card learns its caption a beat
            // after it exists. A screenshot of an error is found by the
            // error. The job holds the clip's name, not its bytes: a queue
            // of screenshots must not be a queue of decoded-size buffers,
            // so it reads the blob just written when its turn comes.
            if imageData != nil, !known { self.ocr.async { self.caption(id, types: imageTypes, ref: ref) } }
            guard let imageData else { return }
            if known, files.hasThumb(storage: ref.storage) { return }
            guard let thumbnail = Self.thumbnail(from: imageData) else { return }
            try? files.writeThumb(storage: ref.storage, key: key, png: thumbnail)
            // Decoded here, so the first draw has nothing left to decode.
            let image = Self.decodedImage(from: thumbnail)
            DispatchQueue.main.async {
                if let image { self.cache(image, for: id) }
                self.onThumbnail?()
            }
        }

        let clip = Clipboard.Clip(
            id: id, kind: arrival.kind, created: arrival.created,
            sourceBundleID: arrival.sourceBundleID, sourceAppName: arrival.sourceAppName,
            preview: arrival.preview, bytes: arrival.bytes,
            nativeTypes: imageTypes,
            otherItemTypes: items.dropFirst().map { $0.natives.map(\.type) },
            sourceHost: arrival.sourceHost, lines: arrival.lines, characters: arrival.characters
        )
        index = Clipboard.merging(index, with: clip)
        if let merged = entry(for: index[0]) { commit(.front(merged)) }
    }

    private func finishedWriting(_ storage: String) {
        let left = (inFlight[storage] ?? 1) - 1
        inFlight[storage] = left > 0 ? left : nil
    }

    /// A new clip whose blob could not be written is not a card: nothing
    /// could be pasted from it, and no record of it was kept.
    private func dropUnwritten(_ id: String) {
        guard let ref = refs[id], unwritten.withLock({ $0.contains(ref.storage) }) else { return }
        index.removeAll { $0.id == id }
        refs[id] = nil
        pendingOps.removeAll { $0.storages.contains(ref.storage) }
        onThumbnail?()
    }

    // MARK: - Files

    /// What each file of a copy is, then a picture of each of the first
    /// four, on the files queue. The facts are handed over as soon as they
    /// are known, so the card has its names before it has its pictures; a
    /// picture that cannot be had in time is the file's icon.
    private func readFiles(_ id: String, urls: [URL], items: [ClipboardContent.Item], ref: Ref) {
        guard let key = ref.key else { return }
        let files = disk.files
        // First what finds the files again, while every one of them is
        // surely where the copy said: a bookmark per item, in item order.
        let bookmarks: [Data?] = items.prefix(Clipboard.fileBookmarksKept).map { item in
            guard let url = Clipboard.fileAddress(in: item).flatMap(Clipboard.fileURL(from:)) else { return nil }
            return FileSense.withDeadline(FileSense.deadline) { Clipboard.bookmark(for: url) }
        }
        DispatchQueue.main.async { self.bookmarksMade(id, bookmarks, storage: ref.storage) }
        var facts = urls.prefix(Clipboard.fileFactsKept).map { FileSense.fact(for: $0) }
        let early = facts
        DispatchQueue.main.async { self.filesRead(id, facts: early, storage: ref.storage) }
        var pictures = 0
        for (position, url) in urls.prefix(Clipboard.thumbnailedFiles).enumerated() {
            guard let picture = FileSense.picture(of: url) else { continue }
            do {
                try files.writeThumb(storage: ref.storage, key: key, png: picture.png, index: position)
            } catch {
                Log.error("clipboard: could not write a file's picture (\(error))")
                continue
            }
            facts[position].pictured = picture.pictured
            pictures += 1
            // Decoded here, so the first draw has nothing left to decode.
            let image = Self.decodedImage(from: picture.png)
            DispatchQueue.main.async {
                if let image, self.refs[id]?.storage == ref.storage { self.cache(image, for: Self.thumbKey(id, position)) }
                self.refreshSoon()
            }
        }
        let done = facts
        DispatchQueue.main.async { self.filesRead(id, facts: done, storage: ref.storage) }
        // Counts only: what a file is called is nobody's business but the card's.
        Log.info("clipboard", ["files read": urls.count, "pictures": pictures])
    }

    /// Main. A copy's files are known. A clip deleted while they were being
    /// read takes the pictures that landed after it with it.
    private func filesRead(_ id: String, facts: [Clipboard.FileFact], storage: String) {
        guard refs[id]?.storage == storage, let position = index.firstIndex(where: { $0.id == id }),
              index[position].kind == .file else {
            if refs.values.allSatisfy({ $0.storage != storage }) {
                let files = disk.files
                io.async { files.remove(storages: [storage]) }
            }
            return
        }
        var facts = facts
        // Until a file's picture has been made again, the card keeps the
        // face it had: the first answer must not turn a page into an icon.
        let known = index[position].fileFacts ?? []
        for at in facts.indices where facts[at].pictured == nil && known.indices.contains(at) && known[at].name == facts[at].name {
            facts[at].pictured = known[at].pictured
        }
        guard facts != known else { return }
        index[position].fileFacts = facts
        commitChange(at: position)
        refreshSoon()
    }

    /// For a file card: whether each of its files is still where it was,
    /// per file in copy order. Nil until the answer is in, and the question
    /// goes to another thread the first time it is asked, so drawing never
    /// waits on a disk. The answers are kept until the strip is next opened.
    func filesPresent(_ id: String) -> [Bool]? {
        if let known = presence[id] { return known }
        guard !presenceAsked.contains(id), phase == .ready, let ref = refs[id] else { return nil }
        presenceAsked.insert(id)
        let files = disk.files
        let epoch = presenceEpoch
        let bookmarks = index.first { $0.id == id }?.fileBookmarks ?? []
        checking.async { [weak self] in
            var answer: [Bool]?
            var refreshed: [Int: Data] = [:]
            if let key = ref.key, case .items(let items) = files.readBlob(storage: ref.storage, key: key) {
                // Each item where it is now: a file that can be pasted, from
                // where it stands or from a Trash, keeps its card bright.
                answer = items.enumerated().map { item, content in
                    let found = Clipboard.place(bookmark: bookmarks.indices.contains(item) ? bookmarks[item] : nil,
                                                address: Clipboard.fileAddress(in: content))
                    if let fresh = found.bookmark, item < Clipboard.fileBookmarksKept { refreshed[item] = fresh }
                    return found.place.url != nil
                }
            }
            DispatchQueue.main.async { self?.presenceKnown(id, answer, refreshed: refreshed, epoch: epoch) }
        }
        return nil
    }

    private func presenceKnown(_ id: String, _ answer: [Bool]?, refreshed: [Int: Data], epoch: Int) {
        // A bookmark made afresh is kept whatever showing asked for it.
        if !refreshed.isEmpty, let ref = refs[id] { keepBookmarks(id, refreshed, storage: ref.storage) }
        guard epoch == presenceEpoch else { return }
        // A blob that would not read (its write is still on its way) is
        // asked about again at the next draw, not remembered as an answer.
        guard let answer else { presenceAsked.remove(id); return }
        presence[id] = answer
        refreshSoon()
    }

    /// Main. The bookmarks of a copy's files, made at the copy.
    private func bookmarksMade(_ id: String, _ bookmarks: [Data?], storage: String) {
        guard refs[id]?.storage == storage, let position = index.firstIndex(where: { $0.id == id }),
              index[position].kind == .file, bookmarks.contains(where: { $0 != nil }) else { return }
        index[position].fileBookmarks = bookmarks
        commitChange(at: position)
    }

    /// Main. Bookmarks made again for files found by an old or stale one,
    /// by item number, so a card keeps finding its files.
    private func keepBookmarks(_ id: String, _ fresh: [Int: Data], storage: String) {
        guard refs[id]?.storage == storage, let position = index.firstIndex(where: { $0.id == id }),
              index[position].pastesAsFiles else { return }
        var bookmarks = index[position].fileBookmarks ?? []
        let count = min(index[position].itemCount, Clipboard.fileBookmarksKept)
        if bookmarks.count < count { bookmarks += Array(repeating: nil, count: count - bookmarks.count) }
        for (item, data) in fresh where bookmarks.indices.contains(item) { bookmarks[item] = data }
        guard bookmarks != index[position].fileBookmarks else { return }
        index[position].fileBookmarks = bookmarks
        commitChange(at: position)
    }

    // MARK: - Cards whose files are gone

    /// Whether removing cards must wait: the strip, or a door of it, is
    /// open. A card leaving then would move every card after it, and the
    /// letter under the hand would name another card. The engine says.
    var removalsHeld: () -> Bool = { false }
    /// Off in the tests that are about something else, where a card whose
    /// file a test has just deleted must stay to be pasted.
    var prunesGoneFiles = true
    /// How often the cards of files are looked over when nothing else asks.
    nonisolated(unsafe) static var prunePeriod: TimeInterval = 300
    private var pruneScheduled = false
    private var pruning = false
    private var pruneDue: Date?

    /// Look the cards of files over soon: after a copy, when the strip
    /// closes, and every `prunePeriod` in between.
    func pruneGoneFilesSoon(after delay: TimeInterval = 1) {
        let due = Date().addingTimeInterval(delay)
        guard prunesGoneFiles, !pruneScheduled || due < (pruneDue ?? .distantFuture) else { return }
        pruneScheduled = true
        pruneDue = due
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let planned = self.pruneDue, planned <= Date().addingTimeInterval(0.05) else { return }
            self.pruneScheduled = false
            self.pruneDue = nil
            self.pruneGoneFiles()
        }
    }

    /// A card of files leaves the history once every one of its files is in
    /// a Trash or gone for good: it can paste nothing, and the hand that
    /// deleted the files has no use for it. A keepsake stays, dimmed, until
    /// the hand removes it, because it was kept on purpose. A file on a disk
    /// that is not connected decides nothing, and neither does an old
    /// reference that no longer resolves. Main; the files are asked about
    /// off it, and nothing leaves while the strip is open.
    func pruneGoneFiles(completion: (() -> Void)? = nil) {
        guard prunesGoneFiles, phase == .ready, !pruning else { completion?(); return }
        defer { pruneGoneFilesSoon(after: Self.prunePeriod) }
        guard !removalsHeld() else { completion?(); return }
        let candidates: [(id: String, ref: Ref, bookmarks: [Data?])] = index
            .filter { $0.pastesAsFiles && !$0.isPinned }
            .compactMap { clip in refs[clip.id].map { (clip.id, $0, clip.fileBookmarks ?? []) } }
        guard !candidates.isEmpty else { completion?(); return }
        pruning = true
        let files = disk.files
        checking.async { [weak self] in
            var dead: [(id: String, storage: String)] = []
            var refreshed: [String: [Int: Data]] = [:]
            for candidate in candidates {
                guard let key = candidate.ref.key,
                      case .items(let items) = files.readBlob(storage: candidate.ref.storage, key: key),
                      !items.isEmpty else { continue }
                let found = FileSense.withDeadline(FileSense.deadline) {
                    items.enumerated().map { item, content in
                        Clipboard.place(bookmark: candidate.bookmarks.indices.contains(item) ? candidate.bookmarks[item] : nil,
                                        address: Clipboard.fileAddress(in: content))
                    }
                }
                guard let found else { continue }
                for (item, answer) in found.enumerated() {
                    if let fresh = answer.bookmark, item < Clipboard.fileBookmarksKept { refreshed[candidate.id, default: [:]][item] = fresh }
                }
                let goneForGood = found.allSatisfy { answer in
                    if case .trashed = answer.place { return true }
                    return answer.place == .gone
                }
                if goneForGood { dead.append((candidate.id, candidate.ref.storage)) }
            }
            DispatchQueue.main.async { self?.pruned(dead, refreshed: refreshed, completion: completion) }
        }
    }

    private func pruned(_ dead: [(id: String, storage: String)], refreshed: [String: [Int: Data]],
                        completion: (() -> Void)?) {
        pruning = false
        for (id, fresh) in refreshed { if let ref = refs[id] { keepBookmarks(id, fresh, storage: ref.storage) } }
        defer { completion?() }
        // The strip opened while the files were being asked about: nothing
        // moves now, and the next look decides.
        guard !removalsHeld() else { return }
        // Still the same card, and still not kept, now that it is decided.
        let ids = dead.filter { entry in
            refs[entry.id]?.storage == entry.storage && index.first(where: { $0.id == entry.id })?.isPinned == false
        }.map(\.id)
        guard !ids.isEmpty else { return }
        delete(ids)
        // Counts only.
        Log.info("clipboard", ["removed cards of gone files": ids.count])
    }

    /// The strip is opening: what was known about the files is asked again.
    func forgetFilePresence() {
        presence.removeAll()
        presenceAsked.removeAll()
        presenceEpoch &+= 1
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
    /// The blob is sealed and written before the index changes,
    /// synchronously: the strip redraws from the index at once and a paste a
    /// keystroke later reads the file, so the file cannot still be in flight.
    /// Returns the card as it now stands, or nil when the card is gone
    /// or the file could not be written.
    @discardableResult
    func replace(_ clip: Clipboard.Clip, withText text: String) -> Clipboard.Clip? {
        guard phase == .ready, let position = index.firstIndex(where: { $0.id == clip.id }) else { return nil }
        // The card as the index holds it now, not as the caller last saw
        // it: a pin made since is the card's, and stays.
        let live = index[position]
        let data = Data(text.utf8)
        let newID = Self.identity(for: data)
        guard newID != live.id else { return live }
        let key = SealingKey.generate()
        let fresh = Ref(storage: ClipboardSealed.newStorage(), blobKey: Data(key.exportedForWrapping()))
        do {
            try disk.files.writeBlob(storage: fresh.storage, key: key, items: [.init(plain: data, natives: [])])
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
        // Another card with these very words is one card with them.
        let storages = [live.id, newID].compactMap { refs[$0]?.storage }
        index = Clipboard.replacing(index, id: live.id, with: replacement)
        if let other = index.indices.first(where: { $0 != position && index[$0].id == newID }) { index.remove(at: other) }
        refs[live.id] = nil
        refs[newID] = fresh
        let now = index.first { $0.id == newID }
        if let now, let entry = entry(for: now) { commit(.replace(old: live.id, entry)) }
        removeFiles(of: [live.id], storages: storages)
        deletionOwed = true
        scheduleCompaction(after: Self.deletionDelay)
        return now
    }

    /// An edit kept as a new card at the top, the original left alone:
    /// the escape ending. It carries the original's source, since that
    /// is where the text came from. Nothing touches the pasteboard.
    @discardableResult
    func fileEdit(from clip: Clipboard.Clip, text: String) -> Clipboard.Clip? {
        guard phase == .ready else { return nil }
        let data = Data(text.utf8)
        guard !data.isEmpty else { return nil }
        let newID = Self.identity(for: data)
        let known = refs[newID]
        let key = known?.key ?? SealingKey.generate()
        let ref = known ?? Ref(storage: ClipboardSealed.newStorage(), blobKey: Data(key.exportedForWrapping()))
        do {
            try disk.files.writeBlob(storage: ref.storage, key: key, items: [.init(plain: data, natives: [])])
        } catch {
            Log.error("clipboard: could not write the kept edit (\(error))")
            return nil
        }
        refs[newID] = ref
        let counted = Clipboard.counts(of: text)
        let kept = Clipboard.Clip(
            id: newID, kind: .text, created: Date(),
            sourceBundleID: clip.sourceBundleID, sourceAppName: clip.sourceAppName,
            preview: Clipboard.preview(of: text), bytes: data.count,
            sourceHost: clip.sourceHost,
            lines: counted.lines, characters: counted.characters)
        index = Clipboard.merging(index, with: kept)
        if let merged = entry(for: index[0]) { commit(.front(merged)) }
        return kept
    }

    /// Text cards recorded before the counts existed learn them once,
    /// off the main thread, so every card can say when it is long.
    func backfillCounts(limit: Int = 2000, completion: (() -> Void)? = nil) {
        guard phase == .ready else { completion?(); return }
        let wanted = index.filter { $0.kind == .text && $0.lines == nil }.prefix(limit)
            .compactMap { clip in refs[clip.id].map { (id: clip.id, ref: $0) } }
        guard !wanted.isEmpty else { completion?(); return }
        let files = disk.files
        io.async { [weak self] in
            guard let self else { return }
            var counted: [String: (lines: Int, characters: Int)] = [:]
            for (id, ref) in wanted {
                guard let text = Self.readPlain(ref, files).flatMap({ String(data: $0, encoding: .utf8) }) else { continue }
                counted[id] = Clipboard.counts(of: text)
            }
            DispatchQueue.main.async {
                for (position, clip) in self.index.enumerated() {
                    guard let counts = counted[clip.id] else { continue }
                    self.index[position].lines = counts.lines
                    self.index[position].characters = counts.characters
                    self.commitChange(at: position)
                }
                if !counted.isEmpty { Log.info("clipboard: counted \(counted.count) cards") }
                completion?()
            }
        }
    }

    /// A long text's length, worked out after its card exists: counted off
    /// the main thread, on a queue of its own so the counting of a 19 MB
    /// copy does not hold up the files of the next one, and written to the
    /// card when it is done. Until then the card has no counts and says what
    /// its preview says.
    func count(id: String, text: String) {
        counting.async { [weak self] in
            let counted = Clipboard.counts(of: text)
            DispatchQueue.main.async { self?.counted(id, counted) }
        }
    }

    private func counted(_ id: String, _ counts: (lines: Int, characters: Int)) {
        guard let position = index.firstIndex(where: { $0.id == id }) else { return }
        index[position].lines = counts.lines
        index[position].characters = counts.characters
        commitChange(at: position)
        onThumbnail?()
    }

    /// Images that were on the strip before it could read them: captioned
    /// once, one at a time on a utility queue, so a history of screenshots
    /// becomes searchable without the first boot after the update paying
    /// for it all at once. Bounded per boot; a second boot takes the rest.
    /// Only images whose preview is still the size line alone are read.
    func captionImagesLackingText(limit: Int = 500) {
        guard phase == .ready else { return }
        let pending = index.filter {
            $0.kind == .image && !$0.preview.contains("\n")
        }.prefix(limit)
        let jobs = pending.compactMap { clip in
            refs[clip.id].map { (id: clip.id, types: clip.itemTypes.first ?? [], ref: $0) }
        }
        guard !jobs.isEmpty else { return }
        captionBacklog(jobs[...], captioned: 0, of: jobs.count)
    }

    /// The backlog goes through the same queue as a fresh copy, one image
    /// per turn, and each turn queues the next only when it is done: a
    /// screenshot copied while the backlog is being read goes next, not
    /// after the other four hundred.
    private func captionBacklog(_ jobs: ArraySlice<(id: String, types: [String], ref: Ref)>,
                                captioned: Int, of total: Int) {
        ocr.async { [weak self] in
            guard let self else { return }
            guard let job = jobs.first else {
                Log.info("clipboard: captioned \(captioned) of \(total) images already in the history")
                return
            }
            let read = self.caption(job.id, types: job.types, ref: job.ref)
            self.captionBacklog(jobs.dropFirst(), captioned: captioned + (read ? 1 : 0), of: total)
        }
    }

    /// Read one stored image and, if it says anything, hand its caption to
    /// the main thread. On the recognizer's queue.
    @discardableResult
    private func caption(_ id: String, types: [String], ref: Ref) -> Bool {
        let offset = types.firstIndex {
            $0 == NSPasteboard.PasteboardType.png.rawValue
                || $0 == NSPasteboard.PasteboardType.tiff.rawValue
        } ?? 0
        guard let key = ref.key, case .items(let items) = disk.files.readBlob(storage: ref.storage, key: key),
              let natives = items.first?.natives, natives.indices.contains(offset),
              let text = readText(natives[offset].data) else { return false }
        DispatchQueue.main.async { [weak self] in self?.caption(id, with: text) }
        return true
    }

    /// An image's text arrived. The size line stays first, so the card is
    /// the card it was; the text under it is what the search reads.
    private func caption(_ id: String, with text: String) {
        guard let position = index.firstIndex(where: { $0.id == id }) else { return }
        index[position].preview = Clipboard.captioned(index[position].preview, with: text)
        commitChange(at: position)
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

    /// The key a decoded picture is cached under: a clip's own id for its
    /// first picture (an image's only one), the id and the picture's number
    /// for the others of a copy of files.
    static func thumbKey(_ id: String, _ index: Int) -> String { index == 0 ? id : "\(id)#\(index)" }

    /// What is decoded, now — or nil, and `onThumbnail` fires when the
    /// card's picture has been read and decoded off the main thread. A
    /// redraw shows what it has and fills in the rest as it lands; it used
    /// to read and decode every missing card on the main thread, with the
    /// strip's key tap waiting. A copy of files has a picture per file,
    /// asked for by its number.
    func thumbnail(for id: String, index picture: Int = 0) -> NSImage? {
        let key = Self.thumbKey(id, picture)
        if let cached = thumbnails[key] {
            cache(cached, for: key)
            return cached
        }
        guard !decoding.contains(key), !thumbnailless.contains(key), let ref = refs[id] else { return nil }
        decoding.insert(key)
        decodes += 1
        let files = disk.files
        decoder.async { [weak self] in
            let image = ref.key.flatMap { files.readThumb(storage: ref.storage, key: $0, index: picture) }
                .flatMap(Self.decodedImage(from:))
            DispatchQueue.main.async { self?.decoded(image, for: id, key: key) }
        }
        return nil
    }

    private func decoded(_ image: NSImage?, for id: String, key: String) {
        decoding.remove(key)
        // A card deleted while its picture was being read stays deleted.
        guard contains(id) else { return }
        guard let image else {
            // Unless the copy's own thumbnail has landed since: it is
            // written after the card exists, and a read that lost the race
            // with it must not outlive it.
            if thumbnails[key] == nil { thumbnailless.insert(key) }
            return
        }
        cache(image, for: key)
        refreshSoon()
    }

    /// A strip's worth of cards arrive within a few milliseconds of one
    /// another; one redraw takes them all.
    private func refreshSoon() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.refreshPending = false
            self?.onThumbnail?()
        }
    }

    /// Most recently used last; the front falls off the end.
    private func cache(_ image: NSImage, for key: String) {
        thumbnailless.remove(key)
        thumbnails[key] = image
        thumbnailOrder.removeAll { $0 == key }
        thumbnailOrder.append(key)
        while thumbnailOrder.count > Self.thumbnailLimit {
            thumbnails.removeValue(forKey: thumbnailOrder.removeFirst())
        }
    }

    // MARK: - Reading back

    /// The whole blob of a clip, opened (the plain forms and every richer
    /// one), or nil when there is no such clip, the history is paused, or the
    /// blob would not open. A blob still being written is waited for: the
    /// queue is serial, so the wait ends when it has landed.
    private func openBlob(_ id: String) -> [Item]? {
        guard phase == .ready, let ref = refs[id], let key = ref.key else { return nil }
        if inFlight[ref.storage] != nil { io.sync {} }
        switch disk.files.readBlob(storage: ref.storage, key: key) {
        case .items(let items):
            return items
        case .missing:
            return nil
        case .unreadable(let why):
            Log.error("clipboard: a clip would not open (\(why))")
            return nil
        }
    }

    /// For a caller on another queue, with the clip's name and key in hand.
    private static func readPlain(_ ref: Ref, _ files: ClipboardFiles) -> Data? {
        guard let key = ref.key, case .items(let items) = files.readBlob(storage: ref.storage, key: key) else { return nil }
        return items.first?.plain
    }

    func plainData(_ id: String, item: Int = 0) -> Data? {
        guard let items = openBlob(id), items.indices.contains(item) else { return nil }
        return items[item].plain
    }

    /// One item's stored representations, richest first — what ⇧label
    /// restores.
    func nativeData(_ clip: Clipboard.Clip, item: Int = 0) -> [(type: String, data: Data)] {
        guard clip.itemTypes.indices.contains(item), let items = openBlob(clip.id), items.indices.contains(item)
        else { return [] }
        return items[item].natives
    }

    /// The whole copy, in the order the board carried it — what a paste
    /// has to put back for three copied files to arrive as three files.
    func itemData(_ clip: Clipboard.Clip) -> [Item] {
        openBlob(clip.id) ?? []
    }

    // MARK: - Mutation

    func pin(_ id: String) -> Bool {
        guard let position = index.firstIndex(where: { $0.id == id }) else { return false }
        guard index[position].pinnedSlot == nil else { return true }
        let taken = Set(index.compactMap(\.pinnedSlot))
        guard let slot = Clipboard.nextFreeSlot(taken: taken) else { return false }
        index[position].pinnedSlot = slot
        commitChange(at: position)
        return true
    }

    /// Letting a keepsake go forgets its name with its place: kept again
    /// later, it is offered the name its words give it.
    func unpin(_ id: String) {
        guard let position = index.firstIndex(where: { $0.id == id }) else { return }
        index[position].pinnedSlot = nil
        index[position].keptName = nil
        commitChange(at: position)
    }

    /// A keepsake's name as the hand left it; an empty one is no name, so
    /// the card shows what its words give it.
    func name(_ id: String, _ name: String?) {
        guard let position = index.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        index[position].keptName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        commitChange(at: position)
    }

    /// A clip kept in a place that is taken: the keepsake there goes back
    /// to being a clip in the history, and this one takes its place.
    /// Returns what was displaced, so it can be put back.
    @discardableResult
    func place(_ id: String, at slot: Int) -> (id: String, name: String?)? {
        guard (1...Clipboard.pinSlots).contains(slot),
              let position = index.firstIndex(where: { $0.id == id }) else { return nil }
        var displaced: (id: String, name: String?)?
        if let other = index.firstIndex(where: { $0.pinnedSlot == slot }), other != position {
            displaced = (index[other].id, index[other].keptName)
            index[other].pinnedSlot = nil
            index[other].keptName = nil
            commitChange(at: other)
        }
        index[position].pinnedSlot = slot
        commitChange(at: position)
        return displaced
    }

    /// Every keepsake's place and name, as they stand.
    func keepsakes() -> [String: (slot: Int, name: String?)] {
        var out: [String: (slot: Int, name: String?)] = [:]
        for clip in index { if let slot = clip.pinnedSlot { out[clip.id] = (slot, clip.keptName) } }
        return out
    }

    /// The keepsakes put back exactly as they were: every place and name
    /// in `snapshot` restored, anything kept since let go. However many
    /// trades a naming made, `esc` undoes all of them.
    func restoreKeepsakes(_ snapshot: [String: (slot: Int, name: String?)]) {
        for position in index.indices {
            if let was = snapshot[index[position].id] {
                guard index[position].pinnedSlot != was.slot || index[position].keptName != was.name else { continue }
                index[position].pinnedSlot = was.slot
                index[position].keptName = was.name
                commitChange(at: position)
            } else if index[position].pinnedSlot != nil {
                index[position].pinnedSlot = nil
                index[position].keptName = nil
                commitChange(at: position)
            }
        }
    }

    /// A keepsake moved to another place, trading with whatever is there,
    /// so no place ever holds two and no keepsake is lost.
    func move(_ id: String, to slot: Int) {
        guard (1...Clipboard.pinSlots).contains(slot),
              let position = index.firstIndex(where: { $0.id == id }),
              let from = index[position].pinnedSlot, from != slot else { return }
        if let other = index.firstIndex(where: { $0.pinnedSlot == slot }) {
            index[other].pinnedSlot = from
            commitChange(at: other)
        }
        index[position].pinnedSlot = slot
        commitChange(at: position)
    }

    func delete(_ id: String) {
        delete([id])
    }

    /// Several clips at once: one pass over the index and one record,
    /// however many go. The blobs are unlinked at once; the key that opens
    /// them is in a record that stays readable until the compaction
    /// `deletionDelay` from now, which is when the deletion is real.
    private func delete(_ ids: [String]) {
        guard phase == .ready else { return }
        let gone = Set(ids)
        let storages = ids.compactMap { refs[$0]?.storage }
        index.removeAll { gone.contains($0.id) }
        for id in ids { refs[id] = nil }
        pendingOps.removeAll { $0.storages.contains { storages.contains($0) } }
        commit(.delete(ids))
        removeFiles(of: ids, storages: storages)
        deletionOwed = true
        scheduleCompaction(after: Self.deletionDelay)
    }

    /// Wait for every file write queued so far — the tests' seam, so a
    /// card seeded a moment ago is on disk before the door reads it.
    func flushIO() { io.sync {} }

    /// The thumbnails dropped and the files of the clips unlinked, off the
    /// main thread.
    private func removeFiles(of ids: [String], storages: [String]) {
        let keys = Set(ids.flatMap { id in (0..<Clipboard.thumbnailedFiles).map { Self.thumbKey(id, $0) } })
        for key in keys {
            thumbnails[key] = nil
            thumbnailless.remove(key)
        }
        for id in ids {
            presence[id] = nil
            presenceAsked.remove(id)
        }
        thumbnailOrder.removeAll { keys.contains($0) }
        let files = disk.files
        io.async { files.remove(storages: storages) }
    }

    /// True once, if a CLI clear happened while this process was running.
    func consumeClearRequest() -> Bool {
        guard FileManager.default.fileExists(atPath: clearRequestFile.path) else { return false }
        try? FileManager.default.removeItem(at: clearRequestFile)
        return true
    }

    func requestClear() {
        Self.requestClearOnDisk(root: root)
    }

    /// The flag a running instance looks for, written by a process that cleared the files.
    static func requestClearOnDisk(root: URL = Paths.clipboard) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? Data().write(to: root.appendingPathComponent("clear-requested"))
    }

    /// The history cleared for good: **the ring destroyed** (what survives on
    /// a disk's blocks is noise), `v2/` and anything an older build left
    /// removed, and a new ring made by the next copy. Pins go with the rest,
    /// as they always have. False, and nothing done, when the history is
    /// paused: nothing is deleted while the key cannot be asked for.
    @discardableResult
    func clearAll() -> Bool {
        if isPaused { return false }
        epoch += 1
        index = []
        refs = [:]
        derived = nil
        queued.removeAll()
        queuedBytes = 0
        pendingOps.removeAll()
        pendingSave?.cancel()
        pendingSave = nil
        compactionWork?.cancel()
        compactionWork = nil
        deletionOwed = false
        thumbnails.removeAll()
        thumbnailOrder.removeAll()
        thumbnailless.removeAll()
        decoding.removeAll()
        forgetFilePresence()
        unwritten.withLock { $0.removeAll() }
        phase = .closed
        io.async { [disk] in
            disk.clear()
        }
        return true
    }

    /// `clearAll`, finished before it returns: the files removed and the ring
    /// destroyed. For a process that exits as soon as it is done.
    @discardableResult
    func clearAllAndWait() -> Bool {
        let cleared = clearAll()
        flushIO()
        return cleared
    }

    /// What `lodestar clipboard clear` does without opening anything: the
    /// ring is asked for (never made), and if it can be, everything is removed
    /// and the ring destroyed. Nothing is deleted while the key cannot be
    /// asked for.
    enum ClearedOnDisk: Equatable {
        case cleared
        /// The files are gone; the key could not be destroyed (it is left, with nothing under it).
        case clearedKeyKept
        case refused(String)
    }

    static func clearOnDisk(root: URL = Paths.clipboard, vault: Vault) -> ClearedOnDisk {
        let ring = vault.ring(.clipboard)
        if ring.existing() == nil, case .paused(let why) = ring.availability { return .refused(why.words) }
        return SealedClipboard(root: root, ring: ring).clear() ? .cleared : .clearedKeyKept
    }

    /// Enforce the ceilings. Pins are exempt; the loose clips absorb it.
    func trim(maxBytes: Int, maxItems: Int) {
        let doomed = Clipboard.trim(index, maxBytes: maxBytes, maxItems: maxItems)
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
