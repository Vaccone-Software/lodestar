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
        /// A quarter-hour of the hands, as counts and moments only: `keys`,
        /// `backspaces`, `clicks`, `scrolls` (bursts, not wheel events),
        /// `activeMinutes`, and the inter-key interval's sufficient
        /// statistics (`ikN`, `ikSum`, `ikSumSq`). The hard line, stated
        /// once and enforced at the accumulator: **never key identities on
        /// general typing** — per-key or per-digraph timing on arbitrary
        /// text statistically reconstructs content, so the fingers'
        /// metrics are global moments and one anonymous flag (backspace,
        /// the correction key) and nothing else, ever.
        case pulse
        /// A quarter hour of clicks in one app: `app`, `clicks`, `trips`
        /// (clicks whose previous input was a keystroke — the hand left
        /// the keys), and `roles`, a histogram of the clicked element's
        /// accessibility role class. An app name and a role class, never
        /// a label, a title, a coordinate, or a URL: the pool priced at
        /// the grain the focus events already keep, and no finer.
        case clicks
        /// The instrument observing itself: `verb` names a surface's
        /// warmup ("scroll-panes", "retile"), `seconds` what it took —
        /// so a regression in the instrument surfaces the way a
        /// regression in the hand does.
        case latency
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
    public var keys: Int?
    public var backspaces: Int?
    public var clicks: Int?
    public var scrolls: Int?
    public var activeMinutes: Int?
    public var ikN: Int?
    public var ikSum: Double?
    public var ikSumSq: Double?
    public var trips: Int?
    public var roles: [String: Int]?

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
///
/// The ring is sharded by UTC month: the live file holds the open month,
/// and compaction moves every closed month into `events-YYYY-MM.jsonl`
/// beside it. A closed shard is never re-parsed or rewritten — retention
/// retires it by deleting the whole file — which is what keeps a year of
/// raw material from making every boot pay for the archive. Bounded reads
/// (`recent`) open only the shards a window actually touches.
public final class EventLog {
    public static let defaultFile = Paths.data.appendingPathComponent("events.jsonl")
    /// A year of raw material. The monthly shards keep the working set
    /// small — the live file never holds more than the open month — so
    /// retention buys replay depth for models without a boot-time bill.
    public static let retention: TimeInterval = 365 * 86_400
    /// The window handed to the recommendation pass: every generator's
    /// evidence joins live inside it, and a pass that decoded the whole
    /// year on every refresh would pay for history nothing reads.
    public static let advisorWindowDays = 90

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
                Paths.restrict(file)
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
            var events = shardFilesLocked().flatMap { Self.read(file: $0) }
            events.append(contentsOf: Self.read(file: file))
            events.append(contentsOf: pending)
            return events
        }
    }

    /// The last `days` of the ring — the bounded read the recommendation
    /// pass runs on. Only shards the window touches are opened, so a year
    /// of archive costs a ninety-day reader nothing.
    public func recent(days: Int, now: Date = Date()) -> [ObservationEvent] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return io.sync {
            var events = shardFilesLocked()
                .filter { shard in
                    guard let month = Self.shardMonth(of: shard) else { return true }
                    return Self.monthEnd(of: month) >= cutoff
                }
                .flatMap { Self.read(file: $0) }
            events.append(contentsOf: Self.read(file: file))
            events.append(contentsOf: pending)
            return events.filter { $0.t >= cutoff }
        }
    }

    /// Flush-then-read as one step on `io`, so the file the analysis pass
    /// decodes already holds everything buffered — safe from any thread,
    /// which is where the coach's recommendation pass runs it. `days`
    /// bounds the window; nil reads the whole ring.
    public func snapshot(days: Int? = nil, now: Date = Date()) -> [ObservationEvent] {
        io.sync { flushLocked() }
        guard let days else { return readAll() }
        return recent(days: days, now: now)
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

    /// Rotate closed months into shards and drop what has aged out.
    public func compact(now: Date = Date()) {
        io.sync { self.compactLocked(now: now) }
    }

    /// The boot path: same rotation, but launch never waits on it — the
    /// live file is a full decode and rewrite, and the tap should be
    /// standing before the disk has finished settling history.
    public func compactSoon(now: Date = Date()) {
        io.async { self.compactLocked(now: now) }
    }

    /// Two jobs, both cheap because shards are immutable. Closed-month
    /// events leave the live file for their month's shard — appended, so a
    /// month that closes across several compactions accumulates rather
    /// than replacing. Retention deletes whole shard files whose month has
    /// fallen out of the window; a shard straddling the cutoff keeps all
    /// of its events, because rewriting an archive to shave days off its
    /// oldest edge is exactly the kind of churn the shards exist to end.
    private func compactLocked(now: Date) {
        dispatchPrecondition(condition: .onQueue(io))
        let cutoff = now.addingTimeInterval(-Self.retention)
        for shard in shardFilesLocked() {
            guard let month = Self.shardMonth(of: shard) else { continue }
            if Self.monthEnd(of: month) < cutoff {
                try? FileManager.default.removeItem(at: shard)
            }
        }
        let open = Self.monthKey(now)
        let events = Self.read(file: file)
        var keep: [ObservationEvent] = []
        var closing: [String: [ObservationEvent]] = [:]
        for event in events {
            let month = Self.monthKey(event.t)
            if month == open {
                keep.append(event)
            } else if event.t >= cutoff {
                closing[month, default: []].append(event)
            } // else: aged out entirely — dropped.
        }
        guard keep.count < events.count else { return }
        for (month, moved) in closing.sorted(by: { $0.key < $1.key }) {
            let shard = shardFile(for: month)
            let lines = Self.encodeLines(moved)
            if let handle = try? FileHandle(forWritingTo: shard) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: lines)
            } else if !FileManager.default.fileExists(atPath: shard.path) {
                // First write for this month. The existence check is the
                // guard: an open that failed on an existing shard must not
                // fall through to replacing it.
                try? lines.write(to: shard, options: .atomic)
                Paths.restrict(shard)
            }
        }
        try? Self.encodeLines(keep).write(to: file, options: .atomic)
        Paths.restrict(file)
    }

    private static func encodeLines(_ events: [ObservationEvent]) -> Data {
        let encoder = makeEncoder()
        var lines = Data()
        for event in events {
            guard let data = try? encoder.encode(event) else { continue }
            lines.append(data)
            lines.append(0x0A)
        }
        return lines
    }

    public func clear() {
        flushWork?.cancel()
        flushWork = nil
        io.sync {
            pending = []
            try? FileManager.default.removeItem(at: file)
            for shard in shardFilesLocked() {
                try? FileManager.default.removeItem(at: shard)
            }
        }
    }

    // MARK: - Shards

    private static let shardCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    /// "2026-08" for any moment in that UTC month — the same bucketing the
    /// rollup uses, so a shard and an archived month describe one span.
    static func monthKey(_ date: Date) -> String {
        let parts = shardCalendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    /// The last instant a "YYYY-MM" key can contain, for retention.
    static func monthEnd(of key: String) -> Date {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return .distantFuture }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1] + 1
        return shardCalendar.date(from: components) ?? .distantFuture
    }

    /// `events.jsonl` → `events-2026-08.jsonl`, whatever the base name —
    /// a log pointed at a scratch file shards beside that scratch file.
    func shardFile(for month: String) -> URL {
        let base = file.deletingPathExtension().lastPathComponent
        return file.deletingLastPathComponent()
            .appendingPathComponent("\(base)-\(month).jsonl")
    }

    /// The month a shard file carries, from its name; nil for the live file.
    static func shardMonth(of url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.count >= 8 else { return nil }
        let tail = String(name.suffix(7))
        guard tail.count == 7, tail[tail.index(tail.startIndex, offsetBy: 4)] == "-",
              tail.dropFirst(5).allSatisfy(\.isNumber),
              tail.prefix(4).allSatisfy(\.isNumber) else { return nil }
        return tail
    }

    /// Every shard beside the live file, oldest month first. Callers must
    /// already be on `io`.
    private func shardFilesLocked() -> [URL] {
        let directory = file.deletingLastPathComponent()
        let base = file.deletingPathExtension().lastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasPrefix("\(base)-") && $0.hasSuffix(".jsonl") }
            .sorted()
            .map { directory.appendingPathComponent($0) }
            .filter { Self.shardMonth(of: $0) != nil }
    }

    private func scheduleFlush() {
        guard flushWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.flushSoon() }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }
}
