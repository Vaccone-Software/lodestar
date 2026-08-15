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

    init(store: ClipboardStore = ClipboardStore()) {
        self.store = store
    }

    var history: ClipboardStore { store }

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
        let text = board.string(forType: .string)
        let image = types.contains(NSPasteboard.PasteboardType.tiff.rawValue)
            || types.contains(NSPasteboard.PasteboardType.png.rawValue)
            ? NSImage(pasteboard: board) : nil

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

        let identityData = text.map { Data($0.utf8) }
            ?? natives.first?.data
            ?? Data()
        guard !identityData.isEmpty else { return }
        let id = ClipboardStore.identity(for: identityData)

        let preview = text.map { Clipboard.preview(of: $0) }
            ?? image.map { "image \(Int($0.size.width))×\(Int($0.size.height))" }
            ?? "clip"
        store.record(id: id, kind: image != nil ? .image : .text,
                     plain: text.map { Data($0.utf8) }, natives: natives, image: image,
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
        // The same bargain for an image into a terminal, which no ⌘V can
        // carry. ⌃V is the key that works there, because the program on the
        // far side reads the pasteboard itself rather than the pty.
        if Clipboard.needsPasteHandoff(
            kind: clip.kind,
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        ) {
            flash("⌃V to paste — ⌘V cannot carry an image here")
            return
        }
        synthesizePaste()
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
