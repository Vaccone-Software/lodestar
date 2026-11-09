import AppKit
import LodestarCore

/// Where the clipboard's reads happen: here, on the caller's thread (the
/// tests' default, whose copies are read the moment they are made), or in
/// the clipboard reader, an XPC service in the app's bundle.
///
/// AppKit's pasteboard is main-thread only — measured: threads reading a
/// named board while main wrote it crashed in `_updateTypeCacheIfNeeded`
/// in three runs of three — and a read can wait: a lazily provided type,
/// a Finder file, a copy from another device, makes `data(forType:)` wait
/// on the app or network behind it (3.2 s measured, the main thread 3.3 s
/// late). So the read happens on the service's main thread, the way Apple
/// separates work an app cannot afford to wait on.
protocol PasteboardReading: AnyObject {
    /// Reads the board; `done` runs on the main thread, with nil when no
    /// answer came. In-process, before `read` returns.
    func read(sourceBundleID: String?, excludedApps: Set<String>,
              done: @escaping (PasteboardSnapshot?) -> Void)
    /// A read is under way and has not answered.
    var busy: Bool { get }
    func stop()
}

/// Reads on the caller's thread, which is the main thread.
final class InProcessPasteboardReader: PasteboardReading {
    private let board: () -> NSPasteboard
    init(board: @escaping () -> NSPasteboard = { SystemEvents.pasteboard }) { self.board = board }
    var busy: Bool { false }
    func read(sourceBundleID: String?, excludedApps: Set<String>,
              done: @escaping (PasteboardSnapshot?) -> Void) {
        done(PasteboardRead.snapshot(of: board(), sourceBundleID: sourceBundleID, excludedApps: excludedApps))
    }
    func stop() {}
}

/// Reads through the clipboard reader service. One read at a time. The
/// service ends itself when a read wedges its main thread
/// (`PasteboardReaderService.wedgedAfter`) and launchd starts a fresh one
/// for the next message; this side gives up on an answer at `deadline`
/// as well, and after three failures running hands the reads back to the
/// main thread for the rest of the run, because a clipboard that stopped
/// recording is the worse failure.
final class XPCPasteboardReader: PasteboardReading {
    private let boardName: String
    private let deadline: TimeInterval
    private let connect: () -> NSXPCConnection
    private let fallback: InProcessPasteboardReader
    private var connection: NSXPCConnection?
    private var nextID = 0
    private var pending: (id: Int, done: (PasteboardSnapshot?) -> Void)?
    private var failures = 0
    private(set) var fellBack = false
    static let failuresBeforeFallingBack = 3

    init(boardName: String, deadline: TimeInterval = 15,
         fallback: InProcessPasteboardReader = InProcessPasteboardReader(),
         connect: @escaping () -> NSXPCConnection = {
             NSXPCConnection(serviceName: PasteboardRead.serviceName)
         }) {
        self.boardName = boardName
        self.deadline = deadline
        self.fallback = fallback
        self.connect = connect
    }

    var busy: Bool { pending != nil }

    func read(sourceBundleID: String?, excludedApps: Set<String>,
              done: @escaping (PasteboardSnapshot?) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        if fellBack { return fallback.read(sourceBundleID: sourceBundleID, excludedApps: excludedApps, done: done) }
        guard pending == nil else { return done(nil) }
        let request = PasteboardReadRequest(boardName: boardName, sourceBundleID: sourceBundleID,
                                            excludedApps: excludedApps.sorted())
        guard let body = try? PropertyListEncoder().encode(request) else { return done(nil) }
        nextID += 1
        let id = nextID
        pending = (id, done)
        let proxy = live().remoteObjectProxyWithErrorHandler { [weak self] error in
            DispatchQueue.main.async { self?.failed(id, "\((error as NSError).code)") }
        } as? PasteboardReaderXPC
        guard let proxy else { return failed(id, "no proxy") }
        // The reply arrives on XPC's queue; the reader is only ever touched
        // on main, so it crosses as a weak reference and is read there.
        let owner = MainOnly(self)
        proxy.read(body) { answer in
            // Decoded where it arrives, off the main thread: a copy can be
            // twenty megabytes.
            let snapshot = answer.flatMap { try? PropertyListDecoder().decode(PasteboardSnapshot.self, from: $0) }
            DispatchQueue.main.async {
                guard let self = owner.value else { return }
                if let snapshot { self.finish(id, snapshot) } else { self.failed(id, "no answer") }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + deadline) { [weak self] in
            guard let self, self.pending?.id == id else { return }
            Log.error("clipboard: the reader did not answer in \(Int(self.deadline)) s")
            self.connection?.invalidate()
            self.connection = nil
            self.failed(id, "deadline")
        }
    }

    /// The connection, made when first needed and again after it was
    /// invalidated. An interruption (the service ended) leaves it usable:
    /// the next message starts the service again.
    private func live() -> NSXPCConnection {
        if let connection { return connection }
        let made = connect()
        made.remoteObjectInterface = NSXPCInterface(with: PasteboardReaderXPC.self)
        made.interruptionHandler = { Log.info("clipboard", ["reader": "interrupted"]) }
        made.invalidationHandler = { [weak self, weak made] in
            DispatchQueue.main.async {
                guard let self, let made, self.connection === made else { return }
                self.connection = nil
            }
        }
        made.resume()
        connection = made
        return made
    }

    private func finish(_ id: Int, _ snapshot: PasteboardSnapshot?) {
        guard let pending, pending.id == id else { return }
        self.pending = nil
        if snapshot != nil { failures = 0 }
        pending.done(snapshot)
    }

    private func failed(_ id: Int, _ why: String) {
        guard pending?.id == id else { return }
        failures += 1
        Log.info("clipboard", ["reader": "failed", "why": why, "failures": failures])
        if failures >= Self.failuresBeforeFallingBack, !fellBack {
            fellBack = true
            Log.error("clipboard: the reader failed \(failures) times running, reads stay in Lodestar for this run")
        }
        finish(id, nil)
    }

    func stop() {
        connection?.invalidate()
        connection = nil
        if let pending { finish(pending.id, nil) }
    }

    deinit { connection?.invalidate() }
}

/// A weak reference handed across a queue and read back on main only.
private final class MainOnly<Value: AnyObject>: @unchecked Sendable {
    weak var value: Value?
    init(_ value: Value) { self.value = value }
}
