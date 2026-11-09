import AppKit
import LodestarCore

/// Reading the board, away from the main thread that the key tap needs.
///
/// AppKit's pasteboard is main-thread only — measured: four threads reading
/// a named board while main wrote it crashed in `_updateTypeCacheIfNeeded`
/// in three runs of three, even with a handle of their own, since AppKit
/// keeps one instance per name; the older Pasteboard Manager says "not
/// thread safe" on every call. And a read can wait: a lazily provided
/// type, a Finder file, a copy arriving from another device, makes
/// `data(forType:)` wait on the app or network behind it with no timeout
/// of ours (3.2 s measured, a file copy, the main thread 3.3 s late).
///
/// So the read happens on another process's main thread. Lodestar runs
/// itself as `lodestar __clipboard-reader <board>`, asks it over a pipe,
/// and the answer comes back as a `PasteboardSnapshot`. A read that waits
/// makes the reader wait, never the tap.
enum PasteboardRead {
    /// The board read in one pass: types for every item first, so one
    /// concealed item conceals the whole copy before any content is read.
    static func snapshot(of board: NSPasteboard, sourceBundleID: String?,
                         excludedApps: Set<String>) -> PasteboardSnapshot {
        let changeCount = board.changeCount
        guard let boardItems = board.pasteboardItems, !boardItems.isEmpty else {
            return PasteboardSnapshot(changeCount: changeCount, items: [])
        }
        let types = boardItems.map { $0.types.map(\.rawValue) }
        if let refusal = Clipboard.refusalBeforeReading(
            types: types.flatMap { $0 }, sourceBundleID: sourceBundleID,
            excludedApps: excludedApps, itemCount: boardItems.count
        ) {
            return PasteboardSnapshot(changeCount: changeCount,
                                      items: types.map { PasteboardSnapshot.Item(types: $0) },
                                      refusal: "\(refusal)")
        }
        let items = boardItems.enumerated().map { offset, item in
            var natives: [PasteboardSnapshot.Native] = []
            for type in types[offset] where type != NSPasteboard.PasteboardType.string.rawValue {
                guard let data = item.data(forType: NSPasteboard.PasteboardType(type)) else { continue }
                natives.append(.init(type: type, data: data))
            }
            return PasteboardSnapshot.Item(types: types[offset],
                                           plain: item.string(forType: .string),
                                           fileURL: item.string(forType: .fileURL),
                                           natives: natives)
        }
        let sourceURL = boardItems[0].string(forType: NSPasteboard.PasteboardType(Clipboard.sourceURLType))
        return PasteboardSnapshot(changeCount: changeCount, items: items, sourceURL: sourceURL)
    }

    /// The reader's whole life: a request in, a snapshot out, until the
    /// pipe closes. It never logs (stdout is the pipe) and leaves the
    /// moment Lodestar is gone, even with a read still waiting on its main
    /// thread, so no reader outlives the app it served.
    static func runReader(boardName: String) -> Never {
        signal(SIGPIPE, SIG_IGN)
        let parent = getppid()
        Thread.detachNewThread {
            while true {
                Thread.sleep(forTimeInterval: 1)
                if getppid() != parent { exit(0) }
            }
        }
        let board = boardName == NSPasteboard.Name.general.rawValue
            ? NSPasteboard.general : NSPasteboard(name: NSPasteboard.Name(boardName))
        while let body = PipeFrames.readBody(from: STDIN_FILENO) {
            guard let request = try? PipeFrames.decode(PasteboardReadRequest.self, body: body) else { exit(2) }
            let snapshot = snapshot(of: board, sourceBundleID: request.sourceBundleID,
                                    excludedApps: Set(request.excludedApps))
            guard let frame = try? PipeFrames.encode(PasteboardReadAnswer(id: request.id, snapshot: snapshot)),
                  PipeFrames.write(frame, to: STDOUT_FILENO) else { exit(3) }
        }
        exit(0)
    }
}

/// Where the clipboard's reads happen: here, on the caller's thread (the
/// tests, whose copies are read the moment they are made), or in the
/// reader process.
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

/// Reads in `lodestar __clipboard-reader`. One read at a time; a reader
/// that does not answer inside `deadline` is ended and the next copy
/// starts a fresh one; a reader that keeps failing hands the reads back
/// to the main thread for the rest of the run, because a clipboard that
/// stopped recording is the worse failure.
final class ProcessPasteboardReader: PasteboardReading {
    private let executable: URL
    private let boardName: String
    private let deadline: TimeInterval
    private let fallback: InProcessPasteboardReader
    private var process: Process?
    private var input: FileHandle?
    private var nextID = 0
    private var pending: (id: Int, done: (PasteboardSnapshot?) -> Void)?
    private var failures = 0
    private(set) var fellBack = false
    static let failuresBeforeFallingBack = 3

    init(executable: URL, boardName: String, deadline: TimeInterval = 15,
         fallback: InProcessPasteboardReader = InProcessPasteboardReader()) {
        self.executable = executable
        self.boardName = boardName
        self.deadline = deadline
        self.fallback = fallback
    }

    var busy: Bool { pending != nil }

    /// The reader's process id, for the tests.
    var pid: pid_t? { process?.isRunning == true ? process?.processIdentifier : nil }

    func read(sourceBundleID: String?, excludedApps: Set<String>,
              done: @escaping (PasteboardSnapshot?) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        if fellBack { return fallback.read(sourceBundleID: sourceBundleID, excludedApps: excludedApps, done: done) }
        guard pending == nil else { return done(nil) }
        guard let input = running() else {
            fail("start")
            return done(nil)
        }
        nextID += 1
        let id = nextID
        let request = PasteboardReadRequest(id: id, sourceBundleID: sourceBundleID,
                                            excludedApps: excludedApps.sorted())
        guard let frame = try? PipeFrames.encode(request),
              PipeFrames.write(frame, to: input.fileDescriptor) else {
            end()
            fail("write")
            return done(nil)
        }
        pending = (id, done)
        DispatchQueue.main.asyncAfter(deadline: .now() + deadline) { [weak self] in
            guard let self, self.pending?.id == id else { return }
            Log.error("clipboard: the reader did not answer in \(Int(self.deadline)) s, a fresh one reads the next copy")
            self.end()
            self.fail("deadline")
            self.finish(id: id, nil)
        }
    }

    private func finish(id: Int, _ snapshot: PasteboardSnapshot?) {
        guard let pending, pending.id == id else { return }
        self.pending = nil
        if snapshot != nil { failures = 0 }
        pending.done(snapshot)
    }

    private func fail(_ why: String) {
        failures += 1
        Log.info("clipboard", ["reader": "failed", "why": why, "failures": failures])
        if failures >= Self.failuresBeforeFallingBack, !fellBack {
            fellBack = true
            Log.error("clipboard: the reader failed \(failures) times running, reads stay in Lodestar for this run")
        }
    }

    /// The reader, started if it is not running; its stdin, or nil.
    private func running() -> FileHandle? {
        if let process, process.isRunning, let input { return input }
        end()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["__clipboard-reader", boardName]
        let toReader = Pipe(), fromReader = Pipe()
        process.standardInput = toReader
        process.standardOutput = fromReader
        process.standardError = FileHandle.nullDevice
        let output = fromReader.fileHandleForReading
        process.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            DispatchQueue.main.async {
                guard let self, self.process === ended else { return }
                Log.info("clipboard", ["reader": "ended", "status": status])
                self.process = nil
                self.input = nil
                if let pending = self.pending {
                    self.fail("ended")
                    self.finish(id: pending.id, nil)
                }
            }
        }
        do { try process.run() } catch {
            Log.error("clipboard: the reader would not start (\(error))")
            return nil
        }
        // The pipe's far ends belong to the reader now.
        try? toReader.fileHandleForReading.close()
        try? fromReader.fileHandleForWriting.close()
        self.process = process
        self.input = toReader.fileHandleForWriting
        Log.info("clipboard", ["reader": "started", "pid": process.processIdentifier])
        // Its answers, read on a thread of their own and handed to main.
        let fd = output.fileDescriptor
        Thread.detachNewThread { [weak self] in
            while let body = PipeFrames.readBody(from: fd) {
                guard let answer = try? PipeFrames.decode(PasteboardReadAnswer.self, body: body) else { break }
                DispatchQueue.main.async { self?.finish(id: answer.id, answer.snapshot) }
            }
            try? output.close()
        }
        return input
    }

    /// Ends the reader, if one runs.
    private func end() {
        try? input?.close()
        input = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
    }

    func stop() {
        end()
        if let pending { finish(id: pending.id, nil) }
    }

    deinit { end() }
}
