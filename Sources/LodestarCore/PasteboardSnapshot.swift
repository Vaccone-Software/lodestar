import AppKit
import Foundation
import Stoic
import StoicXPC

/// What a copy put on the board, read in one pass: every item's types,
/// its plain text, its file address and the bytes of each richer form,
/// with the board's change count at the read. It is what the clipboard
/// reader (an XPC service in the app's bundle) answers, so it is plain
/// data: AppKit's pasteboard is read on one queue only, and a lazily
/// provided type (a promise, a Finder file, a copy from another device) can
/// make a read wait seconds on the app or network behind it, so the read
/// happens on the service's main queue, never on the app's.
public struct PasteboardSnapshot: Codable, Sendable, Equatable {
    public struct Native: Codable, Sendable, Equatable {
        public var type: String
        public var data: Data
        public init(type: String, data: Data) {
            self.type = type
            self.data = data
        }
    }

    public struct Item: Codable, Sendable, Equatable {
        /// Every type the item offers, in the board's order.
        public var types: [String]
        /// What the item pastes as text: its `.string` form.
        public var plain: String?
        /// Its file address as text, when it is a file.
        public var fileURL: String?
        /// Every form but `.string`, with its bytes, in the board's order.
        /// Empty when the copy was refused before reading.
        public var natives: [Native]

        public init(types: [String], plain: String? = nil, fileURL: String? = nil, natives: [Native] = []) {
            self.types = types
            self.plain = plain
            self.fileURL = fileURL
            self.natives = natives
        }
    }

    /// The change count the board had when it was read.
    public var changeCount: Int
    public var items: [Item]
    /// Why the copy was refused before a byte was read, in the words the
    /// log uses; nil when it was read.
    public var refusal: String?
    /// The page a browser copy came from, as the first item carried it.
    public var sourceURL: String?
    /// The app that wrote the copy, in its own words: the bundle id an app
    /// puts in `org.nspasteboard.source` so clipboard tools can say whose a
    /// copy is. Read even for a refused copy, since it is the writer's name
    /// and not its content; it is how a refusal says which app marked it.
    public var declaredSource: String?

    public init(changeCount: Int, items: [Item], refusal: String? = nil, sourceURL: String? = nil,
                declaredSource: String? = nil) {
        self.changeCount = changeCount
        self.items = items
        self.refusal = refusal
        self.sourceURL = sourceURL
        self.declaredSource = declaredSource
    }

    public static let declaredSourceType = "org.nspasteboard.source"
}

/// What the reader is asked: which board (the general one in the app, a
/// test run's own under the tests), who was in front when the copy was
/// noticed, and which apps are never read, so a refusal that hangs on the
/// source is decided before any content leaves the board.
public struct PasteboardReadRequest: Codable, Sendable, Equatable {
    public var boardName: String
    public var sourceBundleID: String?
    public var excludedApps: [String]

    public init(boardName: String, sourceBundleID: String?, excludedApps: [String]) {
        self.boardName = boardName
        self.sourceBundleID = sourceBundleID
        self.excludedApps = excludedApps
    }
}

public enum PasteboardRead {
    /// The XPC service's bundle identifier, in `Contents/XPCServices`.
    public static let serviceName = "com.vaccone.lodestar.clipboard-reader"

    /// The board read in one pass: types for every item first, so one
    /// concealed item conceals the whole copy before any content is read.
    /// On one queue only, as AppKit's pasteboard is: the app's main thread in
    /// process, the service's main queue in the reader.
    public static func snapshot(of board: NSPasteboard, sourceBundleID: String?,
                                excludedApps: Set<String>) -> PasteboardSnapshot {
        let changeCount = board.changeCount
        guard let boardItems = board.pasteboardItems, !boardItems.isEmpty else {
            return PasteboardSnapshot(changeCount: changeCount, items: [])
        }
        let types = boardItems.map { $0.types.map(\.rawValue) }
        let declared = types[0].contains(PasteboardSnapshot.declaredSourceType)
            ? boardItems[0].string(forType: NSPasteboard.PasteboardType(PasteboardSnapshot.declaredSourceType))
                .map { String($0.prefix(200)) }
            : nil
        if let refusal = Clipboard.refusalBeforeReading(
            types: types.flatMap { $0 }, sourceBundleID: sourceBundleID,
            excludedApps: excludedApps, itemCount: boardItems.count
        ) {
            return PasteboardSnapshot(changeCount: changeCount,
                                      items: types.map { PasteboardSnapshot.Item(types: $0) },
                                      refusal: "\(refusal)", declaredSource: declared)
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
        return PasteboardSnapshot(changeCount: changeCount, items: items, sourceURL: sourceURL,
                                  declaredSource: declared)
    }
}

// MARK: - The service

extension Backend {
    /// The clipboard reader: one read at a time is all the board can give.
    public static let clipboardReader = Backend.system("clipboard.reader")
}

/// The clipboard reader's one method, declared for the app and the service.
///
/// A read changes nothing on the board (a lazily provided type is asked of
/// its owner, and the board's change count does not move), so it is
/// `readOnly`: a read lost with its service is made again by the next one,
/// which is the clipboard's own wish, a copy read late rather than lost.
/// It is `.long`, so the attempt is bounded by the call's deadline and not
/// by a two-second attempt timeout a copy from another device would miss:
/// the deadline a `system` backend gives a long call at interactive urgency
/// is fifteen seconds (design/22), the reader's, so no timer here counts it.
///
/// A read its caller gave up on and that has not answered means the
/// service's main thread is stuck inside the board (a lazily provided type
/// whose owner never answers): the service holds nothing worth keeping and
/// no client can unstick it, so the service is ended the moment the caller
/// leaves (`.zero`). The host's watchdog is the same decision from inside, for
/// a sandbox that cannot be signalled.
public enum PasteboardReaderAPI {
    public static let read = XPCMethod<PasteboardReadRequest, PasteboardSnapshot, Never>(
        Backend.clipboardReader.readOnly("read", length: .long), ifStuck: .endService(after: .zero))
}

/// The handler the clipboard reader's host runs: each read happens on the
/// main dispatch queue, where AppKit's pasteboard is read.
///
/// Under `XPCHost.run()` the process's main thread is parked in
/// `dispatchMain()`, which services the main *queue* and runs no run loop
/// (measured: the queue's blocks run on a worker thread, `Thread.isMainThread`
/// is false there, and a read of a type another process provides lazily
/// still completes). What matters to the board is that every access is
/// serialized on one queue, as it was on the main thread before.
///
/// The read waits for the queue and does not stop for its caller's
/// cancellation: a read wedged in the board stays unanswered, which is what
/// the host's watchdog and the app's `ifStuck` look for.
public final class PasteboardReaderService: Sendable {
    /// Reads the request's board and says what is on it.
    public typealias Reader = @Sendable (PasteboardReadRequest) -> PasteboardSnapshot

    public static let systemRead: Reader = { request in
        let board = NSPasteboard(name: NSPasteboard.Name(request.boardName))
        return PasteboardRead.snapshot(of: board, sourceBundleID: request.sourceBundleID,
                                       excludedApps: Set(request.excludedApps))
    }

    /// - Parameters:
    ///   - queue: Where the board is read: the main queue in the service.
    ///   - read: What a read does on it; a test's own to see where it ran.
    public init(host: XPCHost, queue: DispatchQueue = .main, read: @escaping Reader = PasteboardReaderService.systemRead) {
        host.handle(PasteboardReaderAPI.read) { request, _ in
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: read(request)) }
            }
        }
    }
}
