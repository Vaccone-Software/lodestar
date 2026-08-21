import Foundation

/// One observed event, flat on purpose: every field the analysis layer will
/// ever ask about is a column here, and a JSONL line is the whole record.
///
/// The log is the **source of truth**; `Observations` is a materialized view
/// over it. The lesson of v1 is baked into this split: v1 aggregated at write
/// time (a median of a chain's gaps), and when the aggregation turned out to
/// confound chain length with fluency, the raw signal was gone. Events keep
/// the raw signal, so the views — and every model over them — can be
/// rewritten and replayed against history instead of starting blind.
public struct ObservationEvent: Codable, Equatable {
    public enum Kind: String, Codable {
        /// A chain resolved: `chain` letters, `gaps` between its keys (index
        /// 0 is trigger→first letter), `peeked` if the map was up first.
        case chain
        /// A chain escaped out of: `chain` is the prefix at escape, `hover`
        /// the seconds since the last key.
        case abandon
        /// An illegal key mid-chain: `chain` is the prefix, `pressed` the key
        /// the hand believed in.
        case wrongKey
        /// An app reached: `app`, `route`, and — for the launcher — what the
        /// search cost (`typed`, `queryPrefix`, `rank`, `listLength`,
        /// `openToFirstKey`, `openToCommit`).
        case reach
        /// The launcher opened and was escaped without a pick.
        case launcherAbandon
        /// A verb fired, so a dead feature can say so.
        case verb
        /// A destination opened in a browser profile: `host`, `profile`,
        /// `source` (typed | clicked), `row` (link | domain | search).
        case web
        /// Focus moved to an app, by any road — the transition structure.
        case focus
        /// A graph binding changed at config reload: `address`, `change`
        /// (added | removed | retargeted), and the new global `epoch`.
        case epoch
        /// The meeting chip's life: `action` (offered | joined | dismissed),
        /// `app` the provider, `row` the deciding rule, `lead` the join's
        /// distance from the start in seconds (negative is early). Titles
        /// and URLs are never kept.
        case meeting
        /// The coach spoke or was answered: `action` (offered | accepted |
        /// never), `rec` (the recommendation kind), `app` (its target),
        /// `address` (the proposed chain, when there is one), `seconds`
        /// (the predicted weekly saving at the time).
        case coach
        /// A select mode ended: `action` (completed | abandoned), `app`,
        /// `source` (ocr | ax), `row` (native | grounded | held for
        /// completions), `typed` (query characters), `seconds` in mode.
        case select
    }

    public var t: Date
    public var kind: Kind
    public var chain: [String]?
    public var gaps: [Double]?
    public var peeked: Bool?
    public var hover: Double?
    public var pressed: String?
    public var app: String?
    public var route: String?
    public var typed: Int?
    public var queryPrefix: String?
    public var rank: Int?
    public var listLength: Int?
    public var openToFirstKey: Double?
    public var openToCommit: Double?
    public var verb: String?
    public var host: String?
    public var profile: String?
    public var source: String?
    public var row: String?
    public var address: String?
    public var change: String?
    public var epoch: Int?
    public var action: String?
    public var rec: String?
    public var lead: Double?
    public var seconds: Double?

    public init(t: Date, kind: Kind) {
        self.t = t
        self.kind = kind
    }
}

/// The append-only event file: `events.jsonl`, one event per line, beside the
/// aggregate view. Appends are buffered and coalesced because this is fed
/// from the event tap and a keystroke must never wait on a disk. The ring is
/// bounded by age: events older than `retention` fall off at compaction, by
/// which time their contribution lives on in the aggregates' running
/// statistics — the raw sample is dropped only once its summary is kept.
public final class EventLog {
    public static let defaultFile = Paths.data.appendingPathComponent("events.jsonl")
    /// Ninety days of raw material. Old enough for every curve to keep its
    /// beginning within an epoch, small enough that the file stays a working
    /// set rather than an archive.
    public static let retention: TimeInterval = 90 * 86_400

    public let file: URL
    /// Owns `pending` and every touch of the file. Appends land here
    /// without waiting; the scheduled flush writes here without ever
    /// holding the main thread — the tap shares the main run loop, and a
    /// disk that answers slowly must stall analysis, never a keystroke.
    /// Synchronous entry points (`flush`, `readAll`, `compact`) hop
    /// through it, so callers keep their ordering guarantees.
    private let io = DispatchQueue(label: "lodestar.events", qos: .utility)
    private var pending: [ObservationEvent] = []
    private var flushWork: DispatchWorkItem?

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    public init(file: URL = EventLog.defaultFile) {
        self.file = file
    }

    public func append(_ event: ObservationEvent) {
        io.async { self.pending.append(event) }
        scheduleFlush()
    }

    /// Synchronous: everything buffered is on disk when this returns.
    /// Shutdown and tests want exactly this; the steady state never calls
    /// it — the scheduled flush stays off the calling thread entirely.
    public func flush() {
        flushWork?.cancel()
        flushWork = nil
        io.sync { self.flushLocked() }
    }

    /// The coalesced path: the write happens on `io`, and whoever
    /// scheduled it has long since moved on.
    public func flushSoon() {
        flushWork?.cancel()
        flushWork = nil
        io.async { self.flushLocked() }
    }

    /// Callers must already be on `io`.
    private func flushLocked() {
        dispatchPrecondition(condition: .onQueue(io))
        guard !pending.isEmpty else { return }
        let encoder = Self.makeEncoder()
        var lines = Data()
        for event in pending {
            guard let data = try? encoder.encode(event) else { continue }
            lines.append(data)
            lines.append(0x0A)
        }
        guard !lines.isEmpty else { pending = []; return }
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        var appended = false
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            let start = (try? handle.seekToEnd()) ?? 0
            do {
                try handle.write(contentsOf: lines)
                appended = true
            } catch {
                // A write can fail part-way (a full disk takes what it
                // can). Rewinding the file to where the batch started
                // keeps the retained batch the only copy of those events,
                // instead of duplicating them and leaving a torn line at
                // the seam for the reader to trip over.
                try? handle.truncate(atOffset: start)
                Log.error("events: append failed (\(error)) — rewound, batch kept for the next flush")
            }
        } else if !fm.fileExists(atPath: file.path) {
            // Only ever a first write. The open can also fail on a file
            // that does exist — too many descriptors, a permission change
            // — and this branch used to replace ninety days of events with
            // the last few seconds of them.
            do {
                try lines.write(to: file, options: .atomic)
                appended = true
            } catch {
                Log.error("events: could not create \(file.lastPathComponent) (\(error))")
            }
        } else {
            Log.error("events: \(file.lastPathComponent) exists but could not be opened — batch kept")
        }
        // Clearing before the write meant a failed write silently dropped
        // the batch; holding it costs a little memory and loses nothing.
        if appended { pending = [] }
    }

    /// Every event still in the ring, oldest first, pending included.
    public func readAll() -> [ObservationEvent] {
        io.sync {
            var events = Self.read(file: file)
            events.append(contentsOf: pending)
            return events
        }
    }

    /// Flush-then-read as one step on `io`, so the file the analysis pass
    /// decodes already holds everything buffered — safe from any thread,
    /// which is where the coach's recommendation pass runs it.
    public func snapshot() -> [ObservationEvent] {
        io.sync {
            flushLocked()
            var events = Self.read(file: file)
            events.append(contentsOf: pending)
            return events
        }
    }

    /// Static and path-only on purpose: safe for a process that only reads
    /// — the CLI report, tests pointing at a scratch file.
    public static func read(file: URL) -> [ObservationEvent] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = makeDecoder()
        return data.split(separator: 0x0A).compactMap {
            try? decoder.decode(ObservationEvent.self, from: Data($0))
        }
    }

    /// Drop what has aged out of the ring, rewriting the file.
    public func compact(now: Date = Date()) {
        io.sync { self.compactLocked(now: now) }
    }

    /// The boot path: same rotation, but launch never waits on it — a
    /// ninety-day ring is a full decode and rewrite, and the tap should be
    /// standing before the disk has finished settling history.
    public func compactSoon(now: Date = Date()) {
        io.async { self.compactLocked(now: now) }
    }

    private func compactLocked(now: Date) {
        dispatchPrecondition(condition: .onQueue(io))
        let cutoff = now.addingTimeInterval(-Self.retention)
        let events = Self.read(file: file)
        let kept = events.filter { $0.t >= cutoff }
        guard kept.count < events.count else { return }
        let encoder = Self.makeEncoder()
        var lines = Data()
        for event in kept {
            guard let data = try? encoder.encode(event) else { continue }
            lines.append(data)
            lines.append(0x0A)
        }
        try? lines.write(to: file, options: .atomic)
    }

    public func clear() {
        flushWork?.cancel()
        flushWork = nil
        io.sync {
            pending = []
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func scheduleFlush() {
        guard flushWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.flushSoon() }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }
}
