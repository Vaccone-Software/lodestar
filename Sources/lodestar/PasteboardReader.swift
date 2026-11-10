import AppKit
import LodestarCore
import Stoic
import StoicXPC

/// Where the clipboard's reads happen: here, on the caller's thread (the
/// tests' default, whose copies are read the moment they are made), or in
/// the clipboard reader, an XPC service in the app's bundle.
///
/// AppKit's pasteboard is one-queue only — measured: threads reading a
/// named board while main wrote it crashed in `_updateTypeCacheIfNeeded`
/// in three runs of three — and a read can wait: a lazily provided type,
/// a Finder file, a copy from another device, makes `data(forType:)` wait
/// on the app or network behind it (3.2 s measured, the main thread 3.3 s
/// late). So the read happens on the service's main queue, the way Apple
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

/// Reads through the clipboard reader service. One read at a time.
///
/// The transport is an `XPCPeer` (StoicXPC, design/25), and the method
/// declares what a read is (`PasteboardReaderAPI.read`): read-only, so a read
/// lost with its service is made again by the next; fifteen seconds in all,
/// the deadline the operation carries; and ending the service when a read
/// its caller gave up on stays unanswered. What is Lodestar's own is left:
/// after three reads fail running (the service is not there, will not
/// start, or keeps failing), the reads go back to the main thread for the
/// rest of the run, because a clipboard that stopped recording is the worse
/// failure. The library's breaker cannot say that: it closes again, and this
/// does not.
final class XPCPasteboardReader: PasteboardReading {
    /// The one peer of the reader in this process (design/25, rule 2),
    /// made where the first reader is, with the ambient it is made in.
    static let peer = XPCPeer(service: PasteboardRead.serviceName, build: Build.id)

    private let boardName: String
    private let peer: XPCPeer
    private let fallback: InProcessPasteboardReader
    private var nextID = 0
    private var pending: (id: Int, done: (PasteboardSnapshot?) -> Void, task: Task<Void, Never>)?
    private var failures = 0
    private(set) var fellBack = false
    static let failuresBeforeFallingBack = 3

    init(boardName: String, peer: XPCPeer = XPCPasteboardReader.peer,
         fallback: InProcessPasteboardReader = InProcessPasteboardReader()) {
        self.boardName = boardName
        self.peer = peer
        self.fallback = fallback
    }

    var busy: Bool { pending != nil }

    func read(sourceBundleID: String?, excludedApps: Set<String>,
              done: @escaping (PasteboardSnapshot?) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        if fellBack { return fallback.read(sourceBundleID: sourceBundleID, excludedApps: excludedApps, done: done) }
        guard pending == nil else { return done(nil) }
        let request = PasteboardReadRequest(boardName: boardName, sourceBundleID: sourceBundleID,
                                            excludedApps: excludedApps.sorted())
        nextID += 1
        let id = nextID
        // The answer is decoded where it arrives, off the main thread (a
        // copy can be twenty megabytes), and the reader is only ever touched
        // on main.
        let peer = self.peer
        let task = Task { [weak self] in
            let snapshot: PasteboardSnapshot?
            var why: String?
            do throws(OperationError<XPCCallError<Never>>) {
                // At the interactive urgency, whose deadline for a long call
                // to a system backend is the fifteen seconds the reader has
                // always waited (design/22): a copy not read is a copy the
                // strip does not show, and the next ones queue behind it.
                snapshot = try await withUrgency(.interactive) { () async throws(OperationError<XPCCallError<Never>>) -> PasteboardSnapshot in
                    try await peer.call(PasteboardReaderAPI.read, request)
                }
            } catch {
                snapshot = nil
                why = "\(error)"
                if error.rejection?.reason == .deadlineExceeded {
                    Log.error("clipboard: the reader did not answer in time")
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if let snapshot { self.finish(id, snapshot) } else { self.failed(id, why ?? "cancelled") }
            }
        }
        pending = (id, done, task)
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
        guard let pending else { return }
        pending.task.cancel()
        finish(pending.id, nil)
    }
}
