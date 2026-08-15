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
    private var poll: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
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
        // What is already on the pasteboard counts: a restart or a quiet
        // auto-update must not lose the clip you copied a moment before it.
        // Every filter still applies, so a concealed clip stays refused.
        lastChangeCount = -1
        capture()
        poll = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.capture()
        }
    }

    func stop() {
        poll?.invalidate()
        poll = nil
    }

    // MARK: - Capture

    private func capture() {
        if store.consumeClearRequest() {
            store.clearAll()
            onCapture?()
            flash("⌂ clipboard history cleared")
        }
        let board = NSPasteboard.general
        let count = board.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard count != selfWrittenChangeCount else { return }
        guard let item = board.pasteboardItems?.first else { return }

        let types = item.types.map(\.rawValue)
        let source = NSWorkspace.shared.frontmostApplication

        // Before a single byte: a concealed clip, or one from an app the
        // user excluded, is none of our business and must not be read at
        // all — not merely left unwritten.
        if let refusal = Clipboard.refusalBeforeReading(
            types: types, sourceBundleID: source?.bundleIdentifier, excludedApps: excludedApps
        ) {
            Log.info("clipboard", ["refused": "\(refusal)"])
            return
        }

        let text = board.string(forType: .string)

        // Our own handover file, coming back around after a terminal paste.
        if Clipboard.isOwnHandoverPath(
            text, temporaryDirectory: FileManager.default.temporaryDirectory.path
        ) { return }

        // Everything a clip weighs, judged before anything is written.
        var bytes = text?.utf8.count ?? 0
        var natives: [(type: String, data: Data)] = []
        for type in types where type != NSPasteboard.PasteboardType.string.rawValue {
            guard let data = item.data(forType: NSPasteboard.PasteboardType(type)) else { continue }
            natives.append((type, data))
            bytes += data.count
        }

        if let refusal = Clipboard.refusal(
            types: types, sourceBundleID: source?.bundleIdentifier, text: text, bytes: bytes,
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
        let imageData = natives.first {
            $0.type == NSPasteboard.PasteboardType.png.rawValue
                || $0.type == NSPasteboard.PasteboardType.tiff.rawValue
        }?.data

        let identityData = text.map { Data($0.utf8) }
            ?? natives.first?.data
            ?? Data()
        guard !identityData.isEmpty else { return }
        let id = ClipboardStore.identity(for: identityData)

        let preview = text.map { Clipboard.preview(of: $0) }
            ?? imageData.flatMap { ClipboardStore.pixelSize(of: $0) }
                .map { "image \(Int($0.width))×\(Int($0.height))" }
            ?? "clip"
        store.record(id: id, kind: imageData != nil ? .image : .text,
                     plain: text.map { Data($0.utf8) }, natives: natives, imageData: imageData,
                     preview: preview,
                     sourceBundleID: source?.bundleIdentifier,
                     sourceAppName: source?.localizedName)
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
        let board = NSPasteboard.general
        board.clearContents()
        let item = NSPasteboardItem()
        var wrote = false

        if action == .native {
            for native in store.nativeData(clip) {
                item.setData(native.data, forType: NSPasteboard.PasteboardType(native.type))
                wrote = true
            }
        }
        if let plain = store.plainData(clip.id), let text = String(data: plain, encoding: .utf8) {
            item.setString(text, forType: .string)
            wrote = true
        } else if action != .native, let native = store.nativeData(clip).first {
            // An image has no plain form; both labels paste the image.
            item.setData(native.data, forType: NSPasteboard.PasteboardType(native.type))
            wrote = true
        }
        // An image bound for a terminal rides as a file as well. The path is
        // what ⌘V lands there, and the tool on the far side reads the
        // picture back off it. Written after the image data so that stays
        // the richer offer for anything able to take it.
        var handedOverAsFile = false
        if Clipboard.pastesAsFilePath(
            kind: clip.kind,
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        ), let file = imageFileForPasting(clip) {
            item.setString(file.path, forType: .string)
            item.setString(file.absoluteString, forType: .fileURL)
            handedOverAsFile = true
            wrote = true
        }

        guard wrote, board.writeObjects([item]) else {
            flash("✕ that clip could not be read")
            return
        }
        selfWrittenChangeCount = board.changeCount
        lastChangeCount = board.changeCount

        // Secure input blocks synthetic keystrokes entirely, so a password
        // field would swallow the paste in silence. The clip is on the
        // pasteboard either way — hand off rather than fail.
        if IsSecureEventInputEnabled() {
            flash("⌘V to paste — this field blocks synthetic input")
            return
        }
        // Only when the file could not be written does the last keystroke go
        // back to the user: ⌃V still works, because the reader takes the
        // image off the pasteboard itself.
        if Clipboard.pastesAsFilePath(
            kind: clip.kind,
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        ), !handedOverAsFile {
            flash("⌃V to paste — that image could not be written to a file")
            return
        }
        synthesizePaste()
    }

    /// The clip as a real PNG on disk — what a terminal can paste and what
    /// the tool on the far side reads back. Named by content id, so pasting
    /// the same clip twice writes the file once, and living in the temp
    /// directory, so nothing accumulates in the user's data.
    private func imageFileForPasting(_ clip: Clipboard.Clip) -> URL? {
        guard let first = store.nativeData(clip).first else { return nil }
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
        guard clip.kind == .image, let native = store.nativeData(clip).first else {
            flash("✕ nothing to save")
            return
        }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        guard let target = downloads?.appendingPathComponent("lodestar-\(stamp).png") else { return }
        let data = NSImage(data: native.data)?.pngData() ?? native.data
        do {
            try data.write(to: target)
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
