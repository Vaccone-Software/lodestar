import AppKit
import Foundation

/// What a copy put on the board, read in one pass: every item's types,
/// its plain text, its file address and the bytes of each richer form,
/// with the board's change count at the read. It is what the clipboard
/// reader (an XPC service in the app's bundle) answers, so it is plain
/// data: AppKit's pasteboard is main-thread only, and a lazily provided
/// type (a promise, a Finder file, a copy from another device) can make a
/// read wait seconds on the app or network behind it, so the read happens
/// on the service's main thread, never on the app's.
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

    public init(changeCount: Int, items: [Item], refusal: String? = nil, sourceURL: String? = nil) {
        self.changeCount = changeCount
        self.items = items
        self.refusal = refusal
        self.sourceURL = sourceURL
    }
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

/// The reader's XPC interface. Requests and answers cross as property
/// lists of the Codable types above.
@objc public protocol PasteboardReaderXPC {
    func read(_ request: Data, reply: @escaping @Sendable (Data?) -> Void)
}

public enum PasteboardRead {
    /// The XPC service's bundle identifier, in `Contents/XPCServices`.
    public static let serviceName = "com.vaccone.lodestar.clipboard-reader"

    /// The board read in one pass: types for every item first, so one
    /// concealed item conceals the whole copy before any content is read.
    /// Main thread only, as AppKit's pasteboard is.
    public static func snapshot(of board: NSPasteboard, sourceBundleID: String?,
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
}

/// The object the XPC service exports. Each read runs on the service's
/// main thread. A read that has not answered by `wedgedAfter` ends the
/// service (`onWedged`): a client cannot end a service, and one whose main
/// thread is stuck would hold every later read behind it, so the service
/// ends itself, the client hears of it through its error handler, and
/// launchd starts a fresh one for the next message.
public final class PasteboardReaderService: NSObject, PasteboardReaderXPC, @unchecked Sendable {
    public static let wedgedAfter: TimeInterval = 10

    private let wedgedAfter: TimeInterval?
    private let onWedged: @Sendable () -> Void

    public init(wedgedAfter: TimeInterval? = PasteboardReaderService.wedgedAfter,
                onWedged: @escaping @Sendable () -> Void = { exit(1) }) {
        self.wedgedAfter = wedgedAfter
        self.onWedged = onWedged
    }

    public func read(_ request: Data, reply: @escaping @Sendable (Data?) -> Void) {
        guard let request = try? PropertyListDecoder().decode(PasteboardReadRequest.self, from: request) else {
            return reply(nil)
        }
        let answered = Answered()
        if let wedgedAfter {
            let onWedged = self.onWedged
            DispatchQueue.global().asyncAfter(deadline: .now() + wedgedAfter) {
                if !answered.value { onWedged() }
            }
        }
        DispatchQueue.main.async {
            let board = NSPasteboard(name: NSPasteboard.Name(request.boardName))
            let snapshot = PasteboardRead.snapshot(of: board, sourceBundleID: request.sourceBundleID,
                                                   excludedApps: Set(request.excludedApps))
            answered.value = true
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            reply(try? encoder.encode(snapshot))
        }
    }

    private final class Answered: @unchecked Sendable {
        private let lock = NSLock()
        private var answered = false
        var value: Bool {
            get { lock.withLock { answered } }
            set { lock.withLock { answered = newValue } }
        }
    }
}
