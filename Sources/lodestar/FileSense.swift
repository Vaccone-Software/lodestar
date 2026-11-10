import AppKit
import AVFoundation
import ImageIO
import LodestarCore
import PDFKit
import QuickLookThumbnailing
import Stoic
import Synchronization
import UniformTypeIdentifiers

/// What a copied file is and what it looks like, read once at the copy and
/// kept, so a card is drawn without touching the file and keeps its look
/// after the file has moved.
///
/// Everything here runs off the main thread, and nothing here trusts the
/// disk to answer: a network volume, a dead mount or a file that iCloud has
/// evicted can make a stat or a page count wait for as long as it likes, and
/// the card must not. Every read of a file is given a short deadline; the one
/// that overruns is answered with what is known without it (a name, a type's
/// icon) and left behind. No file's content is ever kept, and no name or path
/// is ever logged.
///
/// The waiting is Stoic's `abandoningAfter` (a read that blocks) and
/// `abandoningAsyncAfter` (one that awaits), each under a label of what is
/// read. A read that overruns is left running as before, but it holds its
/// place under its label until it returns, no label holds more than `slots`
/// of them, they are counted (`AbandonedWork`), and once all of a label's
/// are held by reads that have not come back the next is refused at once and
/// answered as one that overran: a dead mount strands a few threads, not one
/// for every copy until the pool is gone. The callers are synchronous (a
/// queue of the store, the paste on the main thread), so each read is asked
/// of Stoic from a task that the caller waits for.
enum FileSense {
    /// The reads that are told apart, one label each: a wedged one does not
    /// refuse the others. Names of kinds of read, never of a file or a volume.
    enum Read {
        /// A file's facts: its attributes, where it came from, its pages or pixels.
        static let facts = "file.facts"
        /// The length of a sound or film.
        static let duration = "file.duration"
        /// The system's thumbnail of a file.
        static let picture = "file.picture"
        /// Where a file is now: its bookmark, made or followed.
        static let place = "file.place"
    }

    /// How many reads of one label may be running or abandoned at once. Four:
    /// the store's files queue, its pruning queue, a paste and a preview are
    /// the callers that read at the same time, one each, so four are never
    /// refused for being busy, and four that have not come back are a
    /// volume that is not answering.
    static let slots = 4

    /// How long one read of one file may take before the card goes on
    /// without it. A seam for the tests.
    static var deadline: TimeInterval {
        get { seams.withLock { $0.deadline } }
        set { seams.withLock { $0.deadline = newValue } }
    }
    /// The seams that are plain values, behind one lock: a read on a pool
    /// thread meets a test's write at once, never half of it.
    private struct Seams {
        var deadline: TimeInterval = 2
        var backstop: TimeInterval = 1
        var clock: AnyClock?
    }
    private static let seams = Mutex(Seams())

    /// A picture is 240 points at twice the pixels, as an image's thumbnail is.
    static let side = 480

    /// The clock the deadlines are on; nil is Stoic's ambient one. A seam for
    /// the tests, which give a read the deadline they say it has and no other
    /// by moving a clock of their own, so a slow machine cannot make one overrun.
    static var clock: AnyClock? {
        get { seams.withLock { $0.clock } }
        set { seams.withLock { $0.clock = newValue } }
    }

    /// The system's thumbnail of a file, or nil. A seam for the tests, which
    /// stand in for QuickLook so a slow volume can be made to happen.
    // stoic:allow(nonisolated-unsafe): a test seam that only tests assign, on the main thread before the read that uses it begins (LeakGuard puts it back after); production never writes it, so every read sees the initial value or the one a test set before it
    nonisolated(unsafe) static var thumbnailer: (URL) async -> CGImage? = quickLook

    /// Whether a file's content is somewhere else. A seam for the tests, which
    /// cannot make a file iCloud has evicted.
    // stoic:allow(nonisolated-unsafe): a test seam that only tests assign, on the main thread before the read that uses it begins (LeakGuard puts it back after); production never writes it, so every read sees the initial value or the one a test set before it
    nonisolated(unsafe) static var dataless: (URL, URLUbiquitousItemDownloadingStatus?) -> Bool = isDataless

    struct Picture {
        let png: Data
        /// The file's own face (a first page, a poster frame), not its icon.
        let pictured: Bool
    }

    // MARK: - The facts

    /// One file's name, folder, kind, size and one line more.
    static func fact(for url: URL) -> Clipboard.FileFact {
        let names = Clipboard.fileNames(of: url)
        guard let read = withDeadline(deadline, label: Read.facts, { basics(of: url) }) else {
            return Clipboard.FileFact(name: names.name, folder: names.folder, kind: "Document")
        }
        var fact = read.fact
        // Where a download came from is the Mac's own note on the file, not
        // anything in it, and is read even for a file not on this Mac yet.
        fact.site = withDeadline(deadline, label: Read.facts) { site(of: url) }
        // A file that is not on this Mac yet is described by what is known;
        // opening it to count its pages would download it.
        if !read.dataless, let type = read.type, !read.isFolder,
           let described = withDeadline(deadline, label: Read.facts, { detail(of: url, type: type) }) {
            fact.detail = described.detail
            fact.title = described.title
        }
        return fact
    }

    /// The host of the page or address a downloaded file came from, as the
    /// Mac recorded it at the download: `kMDItemWhereFroms`, kept on the
    /// file as an extended attribute (read here directly, so the answer
    /// does not wait on Spotlight having seen the folder), the address
    /// first. The host alone: a download's address can carry a private
    /// token, and the card has no use for one.
    static func site(of url: URL) -> String? {
        let name = "com.apple.metadata:kMDItemWhereFroms"
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0, size < 64 << 10 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, name, &bytes, size, 0, 0) == size,
              let froms = try? PropertyListSerialization.propertyList(from: Data(bytes), format: nil) as? [String]
        else { return nil }
        return Clipboard.siteName(froms)
    }

    private struct Basics {
        var fact: Clipboard.FileFact
        var type: UTType?
        var isFolder: Bool
        var dataless: Bool
    }

    private static func basics(of url: URL) -> Basics {
        let names = Clipboard.fileNames(of: url)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentTypeKey,
                                         .localizedTypeDescriptionKey, .ubiquitousItemDownloadingStatusKey]
        let values = try? url.resourceValues(forKeys: keys)
        let type = values?.contentType
        // A package (an app, a bundle) is one thing to the hand, whatever
        // it is made of; a folder holds things, counted one level deep and
        // never beneath, which is what the Finder says and what stays quick.
        let isFolder = values?.isDirectory == true && values?.isPackage != true
        // The Finder's own word for it ("Plain Text Document", "Folder"),
        // which is capitalised and what the hand has seen; a type's
        // description is the lowercase fallback when the system has none.
        let described = values?.localizedTypeDescription
            ?? type?.localizedDescription.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        var fact = Clipboard.FileFact(name: names.name, folder: names.folder, kind: described ?? "Document",
                                      type: type?.identifier)
        if isFolder {
            fact.items = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles))?.count
        } else {
            fact.bytes = values?.fileSize
        }
        return Basics(fact: fact, type: type, isFolder: isFolder,
                      dataless: dataless(url, values?.ubiquitousItemDownloadingStatus))
    }

    /// Whether the file's content is somewhere else: evicted from iCloud, or
    /// a placeholder a file provider has not filled. Reading it would fetch it.
    static func isDataless(_ url: URL, _ status: URLUbiquitousItemDownloadingStatus?) -> Bool {
        if let status, status != .current { return true }
        var info = stat()
        guard stat(url.path, &info) == 0 else { return false }
        return info.st_flags & 0x4000_0000 != 0  // SF_DATALESS
    }

    /// Pages for a PDF (and its title, when its maker gave it one), pixels
    /// for an image, minutes and seconds for sound and film. Header reads,
    /// every one: no content comes with them.
    private static func detail(of url: URL, type: UTType) -> (detail: String?, title: String?)? {
        if type.conforms(to: .pdf) {
            guard let document = PDFDocument(url: url) else { return nil }
            let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (Clipboard.pagesDetail(document.pageCount), title?.isEmpty == false ? title : nil)
        }
        if type.conforms(to: .image) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  var width = properties[kCGImagePropertyPixelWidth] as? Int,
                  var height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
            // Orientations 5 to 8 are turned on their side: the picture is
            // the way up it is shown, not the way it is stored.
            if let turn = properties[kCGImagePropertyOrientation] as? Int, (5...8).contains(turn) { swap(&width, &height) }
            return (Clipboard.dimensionsDetail(width: width, height: height), nil)
        }
        if type.conforms(to: .audiovisualContent) {
            return (duration(of: url).flatMap(Clipboard.durationDetail), nil)
        }
        return nil
    }

    /// A film's or a sound's length. The load awaits, so it is the async
    /// form that gives up on it.
    private static func duration(of url: URL) -> Double? {
        withAsyncDeadline(deadline, label: Read.duration) {
            guard let time = try? await AVURLAsset(url: url).load(.duration) else { return nil }
            return CMTimeGetSeconds(time)
        }
    }

    // MARK: - The picture

    /// A file's picture as PNG: the system's thumbnail of it when there is
    /// one in time (a PDF's first page, a video's poster frame, an image
    /// itself), otherwise its icon, drawn at the same size. Nil only when
    /// not even an icon could be drawn.
    static func picture(of url: URL) -> Picture? {
        if !dataless(url, nil),
           let image = withAsyncDeadline(deadline, label: Read.picture, { [thumbnailer] in await thumbnailer(url) }),
           let png = png(image) {
            return Picture(png: png, pictured: true)
        }
        guard let icon = icon(of: url), let png = png(icon) else { return nil }
        return Picture(png: png, pictured: false)
    }

    /// QuickLook's thumbnail, awaited. Cancelled (at the deadline, by the wait
    /// around it), the request is cancelled with QuickLook and the read is
    /// answered at once with nothing, whether or not QuickLook ever calls back.
    static func quickLook(_ url: URL) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side / 2, height: side / 2),
                                                   scale: 2, representationTypes: .thumbnail)
        return await awaiting(
            start: { answer in
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                    answer(representation?.cgImage)
                }
            },
            cancel: { QLThumbnailGenerator.shared.cancel(request) })
    }

    /// A call that answers by callback, awaited, and given up on when the
    /// task is cancelled: `cancel` is called and the answer is nil at once,
    /// and a callback that comes after that is ignored. The callback may come
    /// on any thread, once or never.
    static func awaiting<T: Sendable>(start: (@escaping @Sendable (T?) -> Void) -> Void,
                                      cancel: @escaping @Sendable () -> Void) async -> T? {
        let pending = Pending<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if pending.wait(continuation) { start { pending.answer($0) } }
            }
        } onCancel: {
            cancel()
            pending.answer(nil)
        }
    }

    /// The one answer of a callback-style call: the first of the callback and
    /// the cancellation resumes the continuation, the other does nothing.
    private final class Pending<T: Sendable>: Sendable {
        private struct State {
            var continuation: CheckedContinuation<T?, Never>?
            var answered = false
            var early: T?
        }
        private let state = Mutex(State())

        /// Holds the continuation until there is an answer; false (and it is
        /// resumed here) when the answer, a cancellation's, is already in.
        func wait(_ continuation: CheckedContinuation<T?, Never>) -> Bool {
            let early: T?? = state.withLock { state in
                if state.answered { return .some(state.early) }
                state.continuation = continuation
                return nil
            }
            guard let early else { return true }
            continuation.resume(returning: early)
            return false
        }

        func answer(_ value: T?) {
            let waiting: CheckedContinuation<T?, Never>? = state.withLock { state in
                guard !state.answered else { return nil }
                state.answered = true
                state.early = value
                defer { state.continuation = nil }
                return state.continuation
            }
            waiting?.resume(returning: value)
        }
    }

    /// The icon the Finder would show, drawn into the same square a
    /// thumbnail is: the system hands out icons of every size, and the
    /// store keeps one size.
    private static func icon(of url: URL) -> CGImage? {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        var rect = NSRect(x: 0, y: 0, width: side, height: side)
        guard let drawn = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(drawn, in: CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }

    private static func png(_ image: CGImage) -> Data? {
        guard let out = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    // MARK: - A deadline

    /// `work` on a thread of Dispatch's, given `seconds`, under `label`
    /// (at most `limit` of its reads running or abandoned at once). What
    /// overruns is left running and forgotten; the caller has its answer,
    /// which is nil. So is the answer when the label is wedged (every place
    /// under it held by a read that has not come back) and the read is
    /// refused without being begun, and when the read never got its turn.
    static func withDeadline<T: Sendable>(_ seconds: TimeInterval, label: String, limit: Int = slots,
                                          _ work: @escaping @Sendable () -> T?) -> T? {
        blocking(seconds) { clock in
            do throws(PolicyError<Never>) {
                return try await abandoningAfter(.seconds(seconds), label: label, limit: limit, clock: clock,
                                                 qos: .utility, operation: work)
            } catch {
                return nil
            }
        }
    }

    /// The same for a read that awaits (a callback, an asset's load): it
    /// runs as a task, is cancelled at the deadline in case it looks, and
    /// holds its place under the label until it returns, cancelled or not.
    static func withAsyncDeadline<T: Sendable>(_ seconds: TimeInterval, label: String, limit: Int = slots,
                                               _ work: @escaping @concurrent @Sendable () async -> T?) -> T? {
        blocking(seconds) { clock in
            do throws(PolicyError<Never>) {
                return try await abandoningAsyncAfter(.seconds(seconds), label: label, limit: limit, clock: clock,
                                                      operation: work)
            } catch {
                return nil
            }
        }
    }

    /// What `ask` answers, for a caller that is not async. The wait is on a
    /// task that Stoic's wait answers by its deadline at the latest, so the
    /// caller is not held past it; an ordinary Task, so the ambient context
    /// of the caller (where Stoic's events go) comes with it. It needs a
    /// thread of the cooperative pool for the moment it takes to start the
    /// read, as `UpdateController.run`'s bridge does, and a pool with none to
    /// give must not hold the caller for ever (one caller is the main
    /// thread): on the real clock the caller waits `backstop` past the
    /// read's deadline and no longer, and has nothing. On a test's clock the
    /// deadline is the test's to move, and there is no other.
    private static func blocking<T: Sendable>(_ seconds: TimeInterval,
                                              _ ask: @escaping @Sendable (AnyClock?) async -> T?) -> T? {
        let handoff = Handoff<T>()
        let clock = Self.clock
        start { handoff.finish(await ask(clock)) }
        guard clock == nil else { return handoff.wait() }
        guard let answer = handoff.wait(for: seconds + backstop) else {
            Log.error("file read: the read was not begun or answered \(backstop) s past its deadline, so its caller went on without it")
            return nil
        }
        return answer
    }

    /// How long past a read's deadline its caller waits for the task that
    /// asked for it, when that task has not answered. A seam for the tests.
    static var backstop: TimeInterval {
        get { seams.withLock { $0.backstop } }
        set { seams.withLock { $0.backstop = newValue } }
    }

    /// How the task that asks for a read is started. A seam for the tests,
    /// which stand in for a pool that never starts it.
    // stoic:allow(nonisolated-unsafe): a test seam that only tests assign, on the main thread before the read that uses it begins (LeakGuard puts it back after); production never writes it, so every read sees the initial value or the one a test set before it
    nonisolated(unsafe) static var start: (@escaping @Sendable () async -> Void) -> Void = { work in
        Task { await work() }
    }

    /// An answer handed from the task to the thread waiting for it.
    private final class Handoff<T: Sendable>: Sendable {
        private let stored = Mutex<T?>(nil)
        private let done = DispatchSemaphore(value: 0)
        func finish(_ value: T?) { stored.withLock { $0 = value }; done.signal() }
        func wait() -> T? { done.wait(); return stored.withLock { $0 } }
        /// The answer if it came within `seconds`; a wait that ran out is
        /// told from an answer of nothing by the outer nil.
        func wait(for seconds: TimeInterval) -> T?? {
            guard done.wait(timeout: .now() + seconds) == .success else { return nil }
            return .some(stored.withLock { $0 })
        }
    }
}
