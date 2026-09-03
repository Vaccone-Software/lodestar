import AppKit
import Carbon.HIToolbox
import LodestarCore

/// Watching the pasteboard, and putting things back on it.
///
/// macOS has no pasteboard-change notification, so this polls `changeCount`
/// — an integer read, cheap enough to do several times a second. Everything
/// expensive (writing representations, building thumbnails) happens off the
/// main thread; everything sensitive is refused before it is ever read.
final class ClipboardController {
    private let store: ClipboardStore

    /// A clipboard index that had to be quarantined at boot. Surfaced
    /// beside the state store's warning — history vanishing without a
    /// word is exactly the kind of silence that makes a tool untrustworthy.
    var bootWarning: String? { store.bootWarning }
    private var poll: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var clearPollTick = 0
    /// Our own writes must not read back as new copies, or pasting would
    /// silently reorder the list it is supposed to leave alone.
    private var selfWrittenChangeCount = -1

    var flash: (String) -> Void = { _ in }
    /// Fired after a clip is recorded, so an open strip can show it at once.
    var onCapture: (() -> Void)?
    var excludedApps: Set<String> = []
    var excludedPatterns: [String] = []
    var maxBytes = 500_000_000
    /// A guard on the design, not on the user: the index lives in memory
    /// and a byte ceiling alone does not bound how many text clips fit.
    private let maxItems = 10_000
    private let maxItemBytes = 20_000_000
    /// Temp PNGs written for terminal pastes, oldest first.
    private var handedOverFiles: [URL] = []
    private static let handedOverLimit = 8

    init(store: ClipboardStore = ClipboardStore()) {
        self.store = store
        store.onThumbnail = { [weak self] in self?.onCapture?() }
    }

    var history: ClipboardStore { store }

    /// Follow the config. Turning the clipboard off has to stop the
    /// recording, not just take ⇧⌘V away — a user who disables a clipboard
    /// history and finds it still filing every copy has been told one thing
    /// and given another.
    func setEnabled(_ enabled: Bool) {
        guard enabled != (poll != nil) else { return }
        enabled ? start() : stop()
    }

    func start() {
        // What is already on the pasteboard stays off the record. The
        // app-exclusion promise is "never written", and it can only be
        // kept by asking who is frontmost — an answer that means nothing
        // for a clip copied before this process existed. The clip is
        // still on the pasteboard and pastes as ever; only the history
        // declines it. The price is one absent card after a restart; the
        // alternative recorded from excluded apps whenever a restart
        // followed the copy.
        lastChangeCount = NSPasteboard.general.changeCount
        poll = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.capture()
        }
        // A tenth of a second of slack lets the system fold these three
        // wakeups a second into timers it was firing anyway; a copy is
        // still on a card within half a second.
        poll?.tolerance = 0.1
        // The screenshots already in the history learn their captions
        // once, well after boot has settled and off the main thread.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.store.captionImagesLackingText()
        }
    }

    func stop() {
        poll?.invalidate()
        poll = nil
    }

    // MARK: - Capture

    private func capture() {
        // The clear-request flag is a file stat; at the poll's 0.35s
        // cadence that was three stats a second forever. Every eighth
        // tick keeps a CLI clear landing within ~3 seconds.
        clearPollTick += 1
        if clearPollTick >= 8 {
            clearPollTick = 0
            if store.consumeClearRequest() {
                store.clearAll()
                onCapture?()
                flash("⌂ clipboard history cleared")
            }
        }
        let board = NSPasteboard.general
        let count = board.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard count != selfWrittenChangeCount else { return }
        // A copy is not always one thing. Three files selected in Finder
        // arrive as three items, and reading only the first filed a third
        // of what was copied — a card that pasted one file where three
        // were meant, which is worse than the copy having missed.
        guard let boardItems = board.pasteboardItems, !boardItems.isEmpty else { return }

        // Every item's types before any item's content, so the promise
        // below is kept for the whole copy: one concealed item conceals
        // all of it.
        let types = boardItems.flatMap { $0.types.map(\.rawValue) }
        let source = NSWorkspace.shared.frontmostApplication

        // Before a single byte: a concealed clip, or one from an app the
        // user excluded, is none of our business and must not be read at
        // all — not merely left unwritten.
        if let refusal = Clipboard.refusalBeforeReading(
            types: types, sourceBundleID: source?.bundleIdentifier,
            excludedApps: excludedApps, itemCount: boardItems.count
        ) {
            Log.info("clipboard", ["refused": "\(refusal)"])
            return
        }

        // What each item pastes as text, and — separately — what it can be
        // read and searched by. They part company for a file: its URL is
        // text on the board, so the card can show a path and the search
        // can find it by name, while what gets stored and pasted stays the
        // file itself. Deriving one from the other would turn a copied
        // file into a copied string.
        let plainTexts = boardItems.map { $0.string(forType: .string) }
        let readableTexts = boardItems.enumerated().map { offset, item in
            plainTexts[offset] ?? item.string(forType: .fileURL).flatMap { URL(string: $0)?.path }
        }

        // Our own handover file, coming back around after a terminal paste.
        if boardItems.count == 1, Clipboard.isOwnHandoverPath(
            plainTexts[0], temporaryDirectory: FileManager.default.temporaryDirectory.path
        ) { return }

        // Everything the copy weighs, judged before anything is written.
        var bytes = 0
        var items: [ClipboardStore.Item] = []
        for (offset, boardItem) in boardItems.enumerated() {
            let plain = plainTexts[offset].map { Data($0.utf8) }
            var natives: [(type: String, data: Data)] = []
            for type in boardItem.types.map(\.rawValue)
            where type != NSPasteboard.PasteboardType.string.rawValue {
                guard let data = boardItem.data(forType: NSPasteboard.PasteboardType(type))
                else { continue }
                natives.append((type, data))
                bytes += data.count
            }
            bytes += plain?.count ?? 0
            items.append(.init(plain: plain, natives: natives))
        }

        let readable = readableTexts.compactMap { $0 }.joined(separator: "\n")
        if let refusal = Clipboard.refusal(
            types: types, sourceBundleID: source?.bundleIdentifier,
            text: readableTexts.contains(where: { $0 != nil }) ? readable : nil, bytes: bytes,
            excludedApps: excludedApps, excludedPatterns: excludedPatterns,
            maxItemBytes: maxItemBytes
        ) {
            // Never log the content — only why it was refused.
            Log.info("clipboard", ["refused": "\(refusal)"])
            return
        }

        // The image's own bytes, never a decoded NSImage: the size for the
        // preview comes out of the file header and the thumbnail is
        // downsampled from the same source, so a 40MB screenshot is never
        // fully decoded just to be filed.
        let imageData = items[0].natives.first {
            $0.type == NSPasteboard.PasteboardType.png.rawValue
                || $0.type == NSPasteboard.PasteboardType.tiff.rawValue
        }?.data

        let identity = Clipboard.identityData(items: items.map { item in
            item.plain ?? item.natives.first?.data ?? Data()
        })
        guard !identity.isEmpty else { return }
        let id = ClipboardStore.identity(for: identity)

        // A restore is not a copy. A clipboard manager putting the
        // previous contents back after a paste of its own marks them, and
        // the card is already in the history: promoting it would reorder
        // the list for something the hand never copied.
        if Clipboard.isRestore(types: types), store.contains(id) {
            Log.info("clipboard", ["restore": "kept in place"])
            return
        }

        let preview = readable.isEmpty
            ? (imageData.flatMap { ClipboardStore.pixelSize(of: $0) }
                .map { Clipboard.imagePreview(width: Int($0.width), height: Int($0.height)) }
                ?? "clip")
            : Clipboard.preview(of: readable)
        // The page a browser copy came from, host only — read from the
        // type Chromium leaves beside the copy, and nothing for anything
        // that did not come from a page.
        let sourceHost = Clipboard.sourceHost(fromURL: boardItems[0].string(
            forType: NSPasteboard.PasteboardType(Clipboard.sourceURLType)))
        store.record(id: id, kind: imageData != nil ? .image : .text,
                     items: items, imageData: imageData,
                     preview: preview,
                     sourceBundleID: source?.bundleIdentifier,
                     sourceAppName: source?.localizedName,
                     sourceHost: sourceHost)
        store.trim(maxBytes: maxBytes, maxItems: maxItems)
        onCapture?()
    }

    // MARK: - Pasting

    /// Put the clip on the pasteboard and paste it.
    ///
    /// The pasteboard genuinely changes: ⌘V has to keep working afterwards,
    /// which is the deepest expectation there is. Only the *list* stays put
    /// — copies reorder it, pastes never do.
    func paste(_ clip: Clipboard.Clip, action: PasteAction) {
        // One disk read for every representation this method wants: the
        // native loop, the image fallback, and the file handover all drew
        // from `nativeData`, each paying the read again — for an image
        // near the size ceiling, tens of megabytes re-read inside the tap.
        let stored = store.itemData(clip)
        let board = NSPasteboard.general
        board.clearContents()

        // One board item per item copied, so three copied files arrive as
        // three files rather than as the first one three times.
        var items: [NSPasteboardItem] = []
        for content in stored {
            let item = NSPasteboardItem()
            var wrote = false
            if action == .native {
                for native in content.natives {
                    item.setData(native.data, forType: NSPasteboard.PasteboardType(native.type))
                    wrote = true
                }
            }
            if let plain = content.plain, let text = String(data: plain, encoding: .utf8) {
                item.setString(text, forType: .string)
                wrote = true
            } else if action != .native, let native = content.natives.first {
                // An image has no plain form; both labels paste the image.
                item.setData(native.data, forType: NSPasteboard.PasteboardType(native.type))
                wrote = true
            }
            if wrote { items.append(item) }
        }

        // An image bound for a terminal rides as a file as well. The path is
        // what ⌘V lands there, and the tool on the far side reads the
        // picture back off it. Written after the image data so that stays
        // the richer offer for anything able to take it.
        //
        // One item only: the handover is a single path in a single string,
        // and there is no honest way to say "these three pictures" in one.
        var handedOverAsFile = false
        if items.count == 1, let content = stored.first, Clipboard.pastesAsFilePath(
            kind: clip.kind,
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        ), let file = imageFileForPasting(clip, natives: content.natives) {
            items[0].setString(file.path, forType: .string)
            items[0].setString(file.absoluteString, forType: .fileURL)
            handedOverAsFile = true
        }

        guard !items.isEmpty, board.writeObjects(items) else {
            flash("✕ that clip could not be read")
            return
        }
        selfWrittenChangeCount = board.changeCount
        lastChangeCount = board.changeCount

        // Secure input blocks synthetic keystrokes entirely, so a password
        // field would swallow the paste in silence. The clip is on the
        // pasteboard either way — hand off rather than fail.
        if IsSecureEventInputEnabled() {
            flash("press ⌘V to paste, this field blocks synthetic input")
            return
        }
        // Only when the file could not be written does the last keystroke go
        // back to the user: ⌃V still works, because the reader takes the
        // image off the pasteboard itself.
        if Clipboard.pastesAsFilePath(
            kind: clip.kind,
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        ), !handedOverAsFile {
            flash("press ⌃V to paste, that image could not be written to a file")
            return
        }
        synthesizePaste()
    }

    /// The clip as a real PNG on disk — what a terminal can paste and what
    /// the tool on the far side reads back. Named by content id, so pasting
    /// the same clip twice writes the file once, and living in the temp
    /// directory, so nothing accumulates in the user's data.
    private func imageFileForPasting(_ clip: Clipboard.Clip,
                                     natives: [(type: String, data: Data)]) -> URL? {
        // The same pick capture makes for the thumbnail: natives arrive in
        // pasteboard type order, and a browser copy can lead with HTML.
        guard let first = natives.first(where: {
            $0.type == NSPasteboard.PasteboardType.png.rawValue
                || $0.type == NSPasteboard.PasteboardType.tiff.rawValue
        }) ?? natives.first else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(Clipboard.handoverPrefix)\(clip.id).\(Clipboard.pasteableImageExtension)")
        if FileManager.default.fileExists(atPath: url.path) {
            handedOverFiles.removeAll { $0 == url }
            handedOverFiles.append(url)
            return url
        }

        // The extension has to be honest: the reader checks it, then checks
        // the bytes behind it. A TIFF renamed .png fails both halves.
        let png: Data?
        if first.type == NSPasteboard.PasteboardType.png.rawValue {
            png = first.data
        } else {
            png = NSImage(data: first.data)?.pngData()
        }
        guard let png else { return nil }
        do {
            try png.write(to: url, options: .atomic)
        } catch {
            Log.error("clipboard: could not write \(url.lastPathComponent) (\(error))")
            return nil
        }
        // Full-size copies of images, so they are bounded rather than left
        // to accumulate for whenever the system next clears its temp.
        handedOverFiles.append(url)
        while handedOverFiles.count > Self.handedOverLimit {
            try? FileManager.default.removeItem(at: handedOverFiles.removeFirst())
        }
        return url
    }

    /// ⌘V, built clean. The user very likely still has shift down from
    /// pressing ⇧label; inheriting it would post ⇧⌘V and re-open the strip
    /// we just closed.
    private func synthesizePaste() {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let vCode = Keys.codes["v"] else { return }
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(vCode), keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(vCode), keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        // A beat for the pasteboard to settle: some apps read it lazily, and
        // a paste that lands first inserts the previous clip.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            down?.post(tap: .cgSessionEventTap)
            up?.post(tap: .cgSessionEventTap)
        }
    }

    // MARK: - Card actions

    func saveImage(_ clip: Clipboard.Clip) {
        let natives = store.nativeData(clip)
        // The same pick capture makes for the thumbnail — the first native
        // can be HTML — and the extension has to be honest: undecodable
        // bytes never go to disk wearing .png.
        let native = natives.first {
            $0.type == NSPasteboard.PasteboardType.png.rawValue
                || $0.type == NSPasteboard.PasteboardType.tiff.rawValue
        } ?? natives.first
        guard clip.kind == .image, let native else {
            flash("✕ nothing to save")
            return
        }
        let png = native.type == NSPasteboard.PasteboardType.png.rawValue
            ? native.data : NSImage(data: native.data)?.pngData()
        guard let png else {
            flash("✕ could not save the image")
            return
        }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        guard let target = downloads?.appendingPathComponent("lodestar-\(stamp).png") else { return }
        do {
            try png.write(to: target)
            flash("⌂ saved to Downloads")
        } catch {
            flash("✕ could not save the image")
        }
    }

    func togglePin(_ clip: Clipboard.Clip) {
        if clip.isPinned {
            store.unpin(clip.id)
            flash("⌂ unpinned")
        } else if store.pin(clip.id) {
            flash("⌂ pinned")
        } else {
            flash("✕ all \(Clipboard.pinSlots) pins are taken")
        }
    }

    func excludeApp(of clip: Clipboard.Clip) -> String? {
        guard let bundleID = clip.sourceBundleID else {
            flash("✕ that clip has no source app")
            return nil
        }
        store.delete(clip.id)
        flash("⌂ never saving from \(clip.sourceAppName ?? bundleID) again")
        return bundleID
    }
}
