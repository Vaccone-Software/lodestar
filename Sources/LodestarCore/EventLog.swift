import Foundation
import StoicStore

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
        /// statistics (`ikN`, `ikSum`, `ikSumSq`). No keycodes on general
        /// typing — not as a courtesy but because no analysis wants them;
        /// the discipline lives in what is said and what leaves the
        /// machine (DESIGN, the bouts paragraph) — so the fingers'
        /// metrics are global moments and one anonymous flag (backspace,
        /// the correction key). Beside them the
        /// shape: `holdN`/`holdSum`/`holdSumSq`/`holdHist` for press
        /// durations, `ikHist` for the rhythm's whole distribution,
        /// `ikTailN`/`ikTailSum` for the pauses past the motor ceiling,
        /// and `boutIndex`/`boutSeconds` placing the window inside its
        /// bout of continuous work. All shape, still no identity.
        case pulse
        /// Ninety seconds of presses described exactly by `HoldWindow`:
        /// `window` carries the order statistics, the pair terms by hand
        /// and direction, the counts by kind, and the context the shell
        /// added at close. The presses themselves live in the raw store.
        case window
        /// A quarter hour of clicks in one app: `app`, `clicks`, `trips`
        /// (clicks whose previous input was a keystroke — the hand left
        /// the keys, now superseded by the pointer's measured homing and
        /// kept for older clicks and the KLM fallback), and `roles`, a
        /// histogram of the clicked element's
        /// accessibility role class. An app name and a role class, never
        /// a label, a title, a coordinate, or a URL: the pool priced at
        /// the grain the focus events already keep, and no finer.
        /// `pointer` carries the reaches folded to moments — homing,
        /// travel, settle, press, drag, return, path and displacement,
        /// as seconds and points of distance, never a position — and
        /// `scrolls` with `scrollSeconds` the wheel bursts that landed in
        /// the app and how long they ran.
        case clicks
        /// The instrument observing itself: `verb` names a surface's
        /// warmup ("scroll-panes", "retile"), `seconds` what it took —
        /// so a regression in the instrument surfaces the way a
        /// regression in the hand does.
        case latency
        /// A draft ended: `source` the door (speak | edit), `action` how
        /// (pasted | replaced | copied | cancelled | empty), `row` the
        /// ending or the cancel's reason, `app` the destination, `seconds`
        /// open, `typed` characters typed, `words` spoken words settled,
        /// `backspaces`, `switches` between modes, `openToFirstKey` and
        /// `firstWord` the two hesitations, `warm` whether the model was
        /// already loaded. Never the text.
        case draft
        /// The clipboard strip closed: `action` (pasted | acted |
        /// abandoned), `source` how the card was addressed (label | pin |
        /// search), `row` the paste's form (plain | native) or the panel
        /// verb (pin | delete | save | exclude), `rank` the card's position
        /// or the pin's slot, `typed` search characters, `seconds` open,
        /// `openToFirstKey` the hesitation, `app` where the paste landed.
        /// Never the clip.
        case paste
        /// A scroll mode session ended: `app`, `seconds` in the mode,
        /// `keys` direction presses, `pages` half and full pages, `ends`
        /// jumps to an edge, `aims` times the aim band opened,
        /// `aimsLanded` picks that moved the pointer, `aimsAway` of those
        /// that landed outside the focused window, `action` how the mode
        /// was left (escape | lode | verb | toggle | click | wheel |
        /// reset). Never the word aimed at.
        case scroll
        /// The instrument's own state changed — a new build, a record
        /// format, the input settings, the screens, the keyboard layout:
        /// `era` carries all of it, so a change in the data can be told
        /// from a change in the hand without reading a log.
        case era
        /// The instrument could not see: `blind` carries the kind (secure
        /// input, the tap off, no accessibility, health off, not running,
        /// asleep) and the end, `t` the start. The kind and the edges and
        /// nothing else; never which app held secure input. An analysis
        /// excludes these spans instead of reading them as rest.
        case blind
        /// One spoken draft's voice, as numbers (`VoiceStats`): pitch,
        /// loudness, jitter, shimmer, harmonics-to-noise, pauses and rate,
        /// `app` where it went. Computed in memory once the draft closed;
        /// the audio itself is never kept.
        case voice
        /// A window joined a layout beside others by the hand — a shift
        /// summon, a chord letter, a beside move: `app` the arrival,
        /// `apps` the members it joined. Never a breath restore, which
        /// the breath road records. The evidence a breath offer needs:
        /// the pair is wanted side by side, not merely used in turn.
        case compose
        /// The editor at work: `action` (shown | applied | dismissed |
        /// undone), `rec` the issue's kind (spelling | grammar) or a
        /// dismissal's reach (name: the word
        /// learned · sentence: quiet in that sentence only), `app` where. Counts,
        /// never the words.
        case editor
    }

    /// The kinds that are the health record: what leaves a retired
    /// shard for the health archive instead of dying with it.
    public static let healthKinds: Set<Kind> = [.pulse, .window, .era, .clicks, .blind, .voice]

    public var t: Date
    public var kind: Kind
    public var chain: [String]?
    public var gaps: [Double]?
    public var peeked: Bool?
    public var hover: Double?
    public var pressed: String?
    public var app: String?
    /// A click pulse's app, by kind (`AppCategory`): Lodestar's class and
    /// what the app declares about itself.
    public var category: String?
    public var declaredCategory: String?
    public var route: String?
    /// A breath restore names every app its layout holds, so the count
    /// follows the combination rather than the letter — rebinding a
    /// breath to a new key must not start its record over.
    public var apps: [String]?
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
    /// Backspace runs by length — single, two to four, five and more —
    /// as run counts and as the backspaces inside them. Still only the
    /// one named key, now counted in bursts: a run is a revision of
    /// thought, a single is a typo, and the two are different budgets.
    public var bsRuns: [Int]?
    public var bsRunKeys: [Int]?
    public var clicks: Int?
    public var scrolls: Int?
    public var activeMinutes: Int?
    public var ikN: Int?
    public var ikSum: Double?
    public var ikSumSq: Double?
    public var trips: Int?
    public var roles: [String: Int]?
    /// The pointer's reaches, folded: `PointerMoments`.
    public var pointer: PointerMoments?
    /// Seconds the wheel bursts ran, beside their count in `scrolls`.
    public var scrollSeconds: Double?
    public var pages: Int?
    public var ends: Int?
    public var aims: Int?
    public var aimsLanded: Int?
    public var aimsAway: Int?
    public var words: Int?
    public var switches: Int?
    public var firstWord: Double?
    /// The strip's search, measured at exit: how many cards answered the
    /// query, how many recents were on show, how many exist, and — for a
    /// paste from the search — how far down the history the card was.
    /// Never the query.
    public var matches: Int?
    public var visible: Int?
    public var recents: Int?
    public var depth: Int?
    /// A focus event: the switch brought its window into view — placed
    /// from parked, minimized, or hidden — rather than focusing one that
    /// already stood on screen.
    public var pulled: Bool?
    /// A select event: the pointer rested over the window that was read.
    public var pointerOn: Bool?
    public var warm: Bool?
    /// A draft: the loudest the microphone read, in dBFS, sampled at the
    /// meter's ten a second. -140 is a deaf device delivering zeros, a
    /// quiet room reads about -60, speech about -30. nil when no audio
    /// arrived at all, or the door never opened the microphone.
    public var peakDb: Double?
    /// Key hold time — press to release, seconds — as moments and as a
    /// histogram. The one keyboard measurement with a clinical track
    /// record behind it, and it needs no key identity to take: how long
    /// a press lasted is not which key it was. Autorepeat-contaminated
    /// presses are excluded upstream, so a key held down is never read
    /// as a very slow keystroke.
    public var holdN: Int?
    public var holdSum: Double?
    public var holdSumSq: Double?
    public var holdHist: Histogram?
    /// The inter-key rhythm's whole shape, not only its first two
    /// moments. `ikN`/`ikSum`/`ikSumSq` still carry the motor band under
    /// the ceiling and mean exactly what they always did; this carries
    /// every gap inside the bout, tail included.
    public var ikHist: Histogram?
    /// Gaps past the motor ceiling and inside the bout: the pauses the
    /// moments deliberately exclude, kept censored rather than dropped,
    /// because a rhythm's lapses are a measurement and not noise.
    public var ikTailN: Int?
    public var ikTailSum: Double?
    /// Where this window sat in its bout — the count of windows before
    /// it, and the seconds from the bout's first input to this window's
    /// start. A bout is continuous work: it ends when the hands stop for
    /// longer than `HealthPulse.boutGap`. Stored as position, never as a
    /// verdict, so any decrement model is fitted at read time.
    public var boutIndex: Int?
    public var boutSeconds: Double?
    /// A window's description.
    public var window: WindowStats?
    public var voice: VoiceStats?
    /// The keyboards attached while the pulse ran, by roster id.
    public var keyboards: [String]?
    /// The instrument watching itself: the callback's clock against the
    /// event's own stamp, seconds, as moments — how late the tap ran —
    /// and how many times the tap had to be re-enabled.
    public var jitterN: Int?
    public var jitterSum: Double?
    public var jitterSumSq: Double?
    public var tapResets: Int?
    /// Time to correction — the last key to the first backspace of a
    /// run — as moments: how fast a slip is noticed, apart from how
    /// often one is made.
    public var fixN: Int?
    public var fixSum: Double?
    public var fixSumSq: Double?
    /// Wheel bursts by kind: precise deltas (trackpad, Magic Mouse) and
    /// bursts that carried momentum (a flick).
    public var scrollPrecise: Int?
    public var scrollMomentum: Int?
    /// Clicks that were posted rather than pressed — Lodestar's own picks
    /// and warps first among them — kept apart from the hand's.
    public var clicksPosted: Int?
    /// The pointing devices attached while the pulse ran, by roster id.
    public var pointers: [String]?
    /// The lid was closed while the pulse ran.
    public var lid: Bool?
    /// An era's description.
    public var era: EraInfo?
    public var blind: BlindSpan?

    public init(t: Date, kind: Kind) {
        self.t = t
        self.kind = kind
    }
}

/// The append-only event file: `events.jsonl`, one event per line, beside the
/// aggregate view. Appends are buffered and coalesced because this is fed
/// from the event tap and a keystroke must never wait on a disk. The ring is
/// bounded by size (`Retention.behavioralBytes`): once it is over, its
/// oldest months retire at compaction, by which time their contribution
/// lives on in the aggregates' running statistics — the raw sample is
/// dropped only once its summary is kept — and their health kinds
/// (`healthKinds`) leave first for `health-YYYY-MM.jsonl.z.sealed` beside
/// the ring, which no bound of the ring's ever touches.
///
/// The ring is sharded by UTC month: the live file holds the open month,
/// and compaction moves every closed month into `events-YYYY-MM` beside it.
/// A closed shard is never re-parsed or rewritten — retention retires it by
/// deleting the whole file — which is what keeps years of raw material from
/// making every boot pay for the archive. Bounded reads (`recent`) open only
/// the shards a window actually touches.
///
/// **At rest the log is sealed.** `file` is the log's *legacy* name
/// (`events.jsonl`, what an earlier build wrote in the clear); its journal is
/// `events.sj`, a shard `events-YYYY-MM.sj` (`LineStore` has the bytes). The
/// ring it is sealed under is the caller's: the logbook's for `events`, the
/// health record's for `health-events`. Reads accept both forms, writes are
/// sealed only, `migrateLegacy` takes the plaintext files in, and with the
/// key unavailable nothing is read, written, retired or deleted: events wait
/// in memory (bounded) for the key.
public final class EventLog {
    public static let defaultFile = Paths.data.appendingPathComponent("events.jsonl")
    /// The window handed to the recommendation pass: every generator's
    /// evidence joins live inside it, and a pass that decoded the whole
    /// year on every refresh would pay for history nothing reads.
    public static let advisorWindowDays = 90
    /// Events held in memory while the key is unavailable, beyond which the
    /// oldest are dropped (and counted): a launch that stays paused must not
    /// grow without bound.
    public static let heldWhilePaused = 20_000

    /// The log's legacy plaintext name, which also names its sealed journal
    /// and its shards.
    public let file: URL
    public let ring: Vault.Ring
    /// The ring the health archive months are sealed under: the health
    /// record's, whichever record this log is (the ring's months retire
    /// into the health record's archive).
    public let archiveRing: Vault.Ring
    private let fileSystem: any FileSystem
    /// The ring's bound, in bytes: `Retention.behavioralBytes` for the
    /// real ring, and whatever a test needs to watch a month retire.
    public var behavioralBound: Int64 = Retention.behavioralBytes
    /// The behavioral ring stays out of backups, one file at a time. The
    /// health log is the part nothing can recompute, so it goes into them.
    public var excludedFromBackup = true
    /// Owns `pending` and every touch of the files. Appends land here
    /// without waiting; the scheduled flush writes here without ever
    /// holding the main thread — the tap shares the main run loop, and a
    /// disk that answers slowly must stall analysis, never a keystroke.
    /// Synchronous entry points (`flush`, `readAll`, `compact`) hop
    /// through it, so callers keep their ordering guarantees.
    private let io = DispatchQueue(label: "lodestar.events", qos: .utility)
    private var pending: [ObservationEvent] = []
    private var flushWork: DispatchWorkItem?
    private var droppedWhilePaused = 0
    /// The open month's journal, held between flushes. Touched on `io` only.
    private var live: LineJournal

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

    public init(file: URL = EventLog.defaultFile, ring: Vault.Ring, archiveRing: Vault.Ring? = nil,
                fileSystem: any FileSystem = OwnerOnly.fileSystem) {
        self.file = file
        self.ring = ring
        self.archiveRing = archiveRing ?? ring
        self.fileSystem = fileSystem
        self.live = LineJournal(plaintext: file, ring: ring, fileSystem: fileSystem)
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
        let lines = Self.encodeLines(pending)
        guard !lines.isEmpty else { pending = []; return }
        let existed = (try? fileSystem.exists(live.path)) == true
        do {
            try live.append(lines: lines)
            // Clearing before the write meant a failed write silently dropped
            // the batch; holding it costs a little memory and loses nothing.
            pending = []
            if !existed { settleNew(live.path) }
        } catch LineJournal.Failure.paused {
            // The key cannot be asked for: nothing is written. The events wait
            // for it, up to a bound.
            let over = pending.count - Self.heldWhilePaused
            if over > 0 {
                pending.removeFirst(over)
                droppedWhilePaused += over
                if droppedWhilePaused == over {
                    Log.warning("events: the key is unavailable — holding \(Self.heldWhilePaused) events, dropping the oldest",
                                ["file": file.lastPathComponent])
                }
            }
        } catch {
            Log.error("events: append to \(SealedPath.name(of: live.path)) failed (\(error)) — batch kept for the next flush")
        }
    }

    /// A file just made: keep it out of backups when the log is behavioral.
    private func settleNew(_ path: String) {
        guard excludedFromBackup else { return }
        for suffix in ["", ".snapshot"] where (try? fileSystem.exists(path + suffix)) == true {
            Paths.excludeFromBackup(URL(fileURLWithPath: path + suffix))
        }
    }

    /// Every event still in the ring, oldest first, pending included.
    public func readAll() -> [ObservationEvent] {
        io.sync {
            var events = shardMonthsLocked().flatMap { readEvents(of: shardFile(for: $0)) }
            events.append(contentsOf: readEvents(of: file))
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
            var events = shardMonthsLocked()
                .filter { Self.monthEnd(of: $0) >= cutoff }
                .flatMap { readEvents(of: shardFile(for: $0)) }
            events.append(contentsOf: readEvents(of: file))
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

    private func readEvents(of url: URL) -> [ObservationEvent] {
        Self.events(in: LineStore.read(plaintext: url, ring: ring, fileSystem: fileSystem).bytes)
    }

    private static func events(in bytes: Data) -> [ObservationEvent] {
        let decoder = makeDecoder()
        return LineStore.lines(bytes).compactMap { try? decoder.decode(ObservationEvent.self, from: $0) }
    }

    /// Static and path-only on purpose: safe for a process that only reads
    /// — the CLI report, tests pointing at a scratch file. `ring` opens
    /// what is sealed (it is never made by a read); nil reads plaintext
    /// remnants only. A sealed record that does not open is counted and
    /// logged (`SealedFailures`), never read as an empty log.
    public static func read(file: URL, ring: Vault.Ring?, fileSystem: any FileSystem = PosixFileSystem()) -> [ObservationEvent] {
        events(in: LineStore.read(plaintext: file, ring: ring, fileSystem: fileSystem).bytes)
    }

    /// The log's lines and how the read went, for a caller that must know
    /// whether it saw everything (`export`, `diagnose`).
    public static func contents(file: URL, ring: Vault.Ring?, fileSystem: any FileSystem = PosixFileSystem())
        -> (events: [ObservationEvent], whole: Bool, unavailable: Bool) {
        let contents = LineStore.read(plaintext: file, ring: ring, fileSystem: fileSystem)
        return (events(in: contents.bytes), contents.whole, contents.unavailable)
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
    /// than replacing. Then the bound: while the ring is over
    /// `Retention.behavioralBytes`, the oldest shard retires — its health
    /// kinds copied to the health archive first, then the whole file
    /// deleted — because rewriting an archive to shave days off its
    /// oldest edge is exactly the kind of churn the shards exist to end.
    ///
    /// Nothing here runs on a log it could not read whole: a sealed value
    /// that does not open, or a key that cannot be asked for, ends the pass
    /// with the files as they were. A closed month is appended to its shard
    /// *before* the live file lets it go, and the live file is rewritten only
    /// if every shard took its lines.
    private func compactLocked(now: Date) {
        dispatchPrecondition(condition: .onQueue(io))
        guard ring.keyring() != nil else { return }
        // Whatever an older build left in the clear joins the journals first,
        // so what is rotated and retired below is the whole log.
        _ = migrateLocked()
        let open = Self.monthKey(now)
        // Lines move as the bytes they are, never decoded and encoded
        // again: a kind or a field this build does not know (one a newer
        // build wrote, before the updater rolled it back) is carried, not
        // dropped. Only a line's month is read, from its stamp; a line
        // without a readable stamp stays in the live file.
        guard let current = replayLive() else { return }
        let decoder = Self.makeDecoder()
        var keep: [Data] = []
        var closing: [String: [Data]] = [:]
        for bytes in LineStore.lines(Data(current.lines)) {
            guard let stamp = try? decoder.decode(Stamp.self, from: bytes) else {
                keep.append(bytes)
                continue
            }
            let month = Self.monthKey(stamp.t)
            if month == open {
                keep.append(bytes)
            } else {
                closing[month, default: []].append(bytes)
            }
        }
        if !closing.isEmpty {
            for (month, moved) in closing.sorted(by: { $0.key < $1.key }) {
                let shard = LineJournal(plaintext: shardFile(for: month), ring: ring, fileSystem: fileSystem)
                let existed = (try? fileSystem.exists(shard.path)) == true
                do {
                    try shard.append(lines: Self.joinLines(moved))
                    shard.close()
                    if !existed { settleNew(shard.path) }
                } catch {
                    shard.close()
                    Log.error("events: could not move \(month) to its shard (\(error)) — the live file keeps it")
                    return
                }
            }
            do {
                try live.replace(with: Self.joinLines(keep), digests: current.digests)
                settleNew(live.path)
            } catch {
                Log.error("events: could not rewrite \(SealedPath.name(of: live.path)) after rotating (\(error)) — months now appear twice until the next pass")
                return
            }
        }
        retireLocked()
    }

    /// The live journal replayed whole, or nil when it could not be: the key
    /// is unavailable, or a value did not open. Callers on `io`.
    private func replayLive() -> LineCodec.Decoded? {
        guard ring.keyring() != nil else { return nil }
        guard (try? fileSystem.exists(live.path)) == true else { return LineCodec.Decoded() }
        do {
            let journal = try live.open()
            let replay = try journal.replay()
            SealedFailures.note(replay.failures, file: SealedPath.name(of: live.path))
            let decoded = LineCodec.decode(replay)
            guard replay.failures.isEmpty, decoded.malformed == 0 else { return nil }
            return decoded
        } catch {
            live.close()
            Log.error("events: could not read \(SealedPath.name(of: live.path)) to rotate it (\(error))")
            return nil
        }
    }

    /// The one field compaction reads from a line: when it happened.
    private struct Stamp: Decodable { let t: Date }

    private static func joinLines(_ lines: [Data]) -> Data {
        var joined = Data()
        for line in lines {
            joined.append(line)
            joined.append(0x0A)
        }
        return joined
    }

    /// The bound, oldest month first. Health leaves before the file does.
    /// Never while plaintext remnants are waiting to be taken in (usage would
    /// count both copies and retire a month early), and never a shard that
    /// did not open whole, or whose health kinds did not reach the archive.
    private func retireLocked() {
        let directory = file.deletingLastPathComponent()
        let base = file.deletingPathExtension().lastPathComponent
        guard !hasPlaintextRemnants() else { return }
        var months = shardMonthsLocked()
        while Retention.behavioralUsage(in: directory, base: base).bytes > behavioralBound, !months.isEmpty {
            let oldest = months.removeFirst()
            let shard = shardFile(for: oldest)
            let contents = LineStore.read(plaintext: shard, ring: ring, fileSystem: fileSystem)
            guard contents.whole else {
                Log.error("events: \(oldest) did not open whole — not retired", ["file": file.lastPathComponent])
                return
            }
            guard archiveHealth(lines: LineStore.lines(contents.bytes), month: oldest) else { return }
            RecordFiles.removeJournal(LineStore.journalPath(forPlaintext: shard), fileSystem: fileSystem)
        }
    }

    private func hasPlaintextRemnants() -> Bool {
        let directory = file.deletingLastPathComponent().path
        let base = file.deletingPathExtension().lastPathComponent
        return RecordFiles.names(in: directory, fileSystem: fileSystem).contains { name in
            name == "\(base).jsonl" || (name.hasPrefix("\(base)-") && name.hasSuffix(".jsonl")
                && Self.shardMonth(of: URL(fileURLWithPath: directory + "/" + name)) != nil)
        }
    }

    // MARK: - The health archive

    /// `health-2026-08.jsonl.z` beside the live file, as an earlier build
    /// wrote it: the pulses, windows and eras of a month, kept once the ring
    /// has let the month go. Sealed now, as `…jsonl.z.sealed`.
    public func healthArchiveFile(for month: String) -> URL {
        Self.archiveFile(for: month, beside: file)
    }

    public func sealedHealthArchiveFile(for month: String) -> URL {
        healthArchiveFile(for: month).appendingPathExtension("sealed")
    }

    private static func archiveFile(for month: String, beside file: URL) -> URL {
        file.deletingLastPathComponent().appendingPathComponent("health-\(month).jsonl.z")
    }

    /// The health kinds of a retiring shard's lines, appended to the month's
    /// archive: read, joined, deflated and sealed, atomically. False when it
    /// did not land (the shard is then kept).
    private func archiveHealth(lines: [Data], month: String) -> Bool {
        let decoder = Self.makeDecoder()
        let health = lines.filter { line in
            (try? decoder.decode(ObservationEvent.self, from: line)).map { ObservationEvent.healthKinds.contains($0.kind) } ?? false
        }
        guard !health.isEmpty else { return true }
        let archive = SealedValueFile(url: sealedHealthArchiveFile(for: month), ring: archiveRing, fileSystem: fileSystem)
        var existing = Data()
        switch archive.read() {
        case .absent:
            break
        case .value(let packed, _):
            guard let inflated = try? (Data(packed) as NSData).decompressed(using: .zlib) as Data else { return false }
            existing = inflated
        case .unavailable, .unreadable:
            return false
        }
        let joined = existing + Self.joinLines(health)
        guard let deflated = try? (joined as NSData).compressed(using: .zlib) as Data else { return false }
        return archive.write([UInt8](deflated)) == .written
    }

    /// One month's archived health events, oldest first; empty when the
    /// month never retired. Sealed, then any plaintext archive an earlier
    /// build left that migration has not taken in.
    public static func healthArchive(month: String, beside file: URL, ring: Vault.Ring?,
                                     fileSystem: any FileSystem = PosixFileSystem()) -> [ObservationEvent] {
        let plain = archiveFile(for: month, beside: file)
        var lines = Data()
        if let ring {
            let sealed = SealedValueFile(url: plain.appendingPathExtension("sealed"), ring: ring, fileSystem: fileSystem)
            if case .value(let packed, _) = sealed.read(),
               let inflated = try? (Data(packed) as NSData).decompressed(using: .zlib) as Data {
                lines.append(inflated)
            }
        }
        if let packed = try? fileSystem.readAll(plain.path),
           let inflated = try? (Data(packed) as NSData).decompressed(using: .zlib) as Data,
           !lines.hasSuffix(of: inflated) {
            lines.append(inflated)
        }
        return events(in: lines)
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

    /// Take every event of `kinds` out of the ring, live file and shards
    /// alike, and hand them back. The one rewrite a closed shard ever
    /// sees: when the health record moved into a log of its own, its old
    /// kinds had to leave the ring, or clearing the ring would have taken
    /// years of baseline with it. Runs on `io`, so appends and compaction
    /// wait their turn rather than racing the rewrite. Every other line,
    /// whether this build can decode it or not, stays as the bytes it is.
    public func extract(kinds: Set<ObservationEvent.Kind>) -> [ObservationEvent] {
        io.sync {
            flushLocked()
            guard ring.keyring() != nil else { return [] }
            _ = migrateLocked()
            var taken: [ObservationEvent] = []
            let decoder = Self.makeDecoder()
            let targets = shardMonthsLocked().map { shardFile(for: $0) } + [file]
            for url in targets {
                let journal = url == file ? live : LineJournal(plaintext: url, ring: ring, fileSystem: fileSystem)
                defer { if url != file { journal.close() } }
                guard (try? fileSystem.exists(journal.path)) == true else { continue }
                do {
                    let replay = try journal.open().replay()
                    SealedFailures.note(replay.failures, file: SealedPath.name(of: journal.path))
                    let decoded = LineCodec.decode(replay)
                    guard replay.failures.isEmpty, decoded.malformed == 0 else { continue }
                    var moving: [ObservationEvent] = []
                    var staying: [Data] = []
                    for line in LineStore.lines(Data(decoded.lines)) {
                        if let event = try? decoder.decode(ObservationEvent.self, from: line), kinds.contains(event.kind) {
                            moving.append(event)
                        } else {
                            staying.append(line)
                        }
                    }
                    guard !moving.isEmpty else { continue }
                    try journal.replace(with: Self.joinLines(staying), digests: decoded.digests)
                    taken.append(contentsOf: moving)
                } catch {
                    Log.error("events: could not extract from \(SealedPath.name(of: journal.path)) (\(error))")
                }
            }
            return taken
        }
    }

    /// Take the plaintext archive months an earlier build left
    /// (`health-YYYY-MM.jsonl.z`) into their sealed form: appended to the sealed
    /// month if there is one (an archive is one stream of lines, and a month
    /// whose lines the sealed one already ends with was taken in before),
    /// read back from disk and compared, and only then removed.
    @discardableResult
    public func migrateArchives() -> RecordMigration {
        io.sync { migrateArchivesLocked() }
    }

    private func migrateArchivesLocked() -> RecordMigration {
        var outcome = RecordMigration()
        let directory = file.deletingLastPathComponent()
        let plain = RecordFiles.names(in: directory.path, fileSystem: fileSystem).sorted().filter { name in
            name.hasPrefix("health-") && name.hasSuffix(".jsonl.z") && name.count == "health-2026-08.jsonl.z".count
                && Self.shardMonth(of: directory.appendingPathComponent(String(name.dropLast(".jsonl.z".count)) + ".jsonl")) != nil
        }
        guard !plain.isEmpty else { return outcome }
        guard archiveRing.keyring() != nil else {
            outcome.paused = true
            outcome.remaining = plain.count
            return outcome
        }
        for name in plain {
            let path = directory.appendingPathComponent(name)
            func fail(_ why: String) {
                outcome.remaining += 1
                outcome.failed.append(name)
                Log.error("events: could not take \(name) into its sealed form (\(why)) — the plaintext was kept")
            }
            guard let stored = try? fileSystem.readAll(path.path),
                  let inflated = try? (Data(stored) as NSData).decompressed(using: .zlib) as Data
            else { fail("it did not inflate"); continue }
            let sealed = SealedValueFile(url: path.appendingPathExtension("sealed"), ring: archiveRing, fileSystem: fileSystem)
            var existing = Data()
            switch sealed.read() {
            case .absent: break
            case .value(let packed, _):
                guard let was = try? (Data(packed) as NSData).decompressed(using: .zlib) as Data else {
                    fail("the sealed month did not inflate")
                    continue
                }
                existing = was
            case .unavailable:
                outcome.paused = true
                outcome.remaining += 1
                continue
            case .unreadable(let why):
                fail("the sealed month did not open: \(why)")
                continue
            }
            let combined = existing.hasSuffix(of: inflated) ? existing : existing + inflated
            if combined != existing {
                guard let deflated = try? (combined as NSData).compressed(using: .zlib) as Data,
                      sealed.write([UInt8](deflated)) == .written else { fail("the sealed month was not written"); continue }
            }
            // Read back from disk, and compared with what is to be kept.
            guard case .value(let back, _) = sealed.read(),
                  let readBack = try? (Data(back) as NSData).decompressed(using: .zlib) as Data,
                  readBack == combined, readBack.hasSuffix(of: inflated)
            else { fail("it did not read back as it was written"); continue }
            do {
                try fileSystem.remove(path.path)
                try fileSystem.syncDirectory(directory.path)
                outcome.files += 1
                outcome.bytes += Int64(stored.count)
            } catch {
                fail("\(error)")
            }
        }
        return outcome
    }

    /// Take the plaintext files an earlier build left (`events.jsonl`, its
    /// shards) into the journals: appended with their digests, read back and
    /// compared, then removed. Resumable at every step; merges what an older
    /// build wrote after this one sealed the month. See `LineJournal.migratePlaintext`.
    @discardableResult
    public func migrateLegacy() -> RecordMigration {
        io.sync { migrateLocked() }
    }

    private func migrateLocked() -> RecordMigration {
        dispatchPrecondition(condition: .onQueue(io))
        var outcome = RecordMigration()
        let plain = plaintextFilesLocked()
        guard !plain.isEmpty else { return outcome }
        guard ring.keyring() != nil else {
            outcome.paused = true
            outcome.remaining = plain.count
            return outcome
        }
        let decoder = Self.makeDecoder()
        let count: (Data) -> Int = { bytes in
            LineStore.lines(bytes).filter { (try? decoder.decode(ObservationEvent.self, from: $0)) != nil }.count
        }
        for url in plain {
            let journal = url == file ? live : LineJournal(plaintext: url, ring: ring, fileSystem: fileSystem)
            let existed = (try? fileSystem.exists(journal.path)) == true
            do {
                if let bytes = try journal.migratePlaintext(decodedCount: count) {
                    outcome.files += 1
                    outcome.bytes += Int64(bytes)
                    if !existed { settleNew(journal.path) }
                }
            } catch LineJournal.Failure.paused {
                outcome.paused = true
                outcome.remaining += 1
            } catch {
                outcome.remaining += 1
                outcome.failed.append(url.lastPathComponent)
                Log.error("events: could not take \(url.lastPathComponent) into its journal (\(error)) — the plaintext was kept")
            }
            if url != file { journal.close() }
        }
        return outcome
    }

    /// The plaintext files of this log: the live file and its shards.
    private func plaintextFilesLocked() -> [URL] {
        let directory = file.deletingLastPathComponent()
        let base = file.deletingPathExtension().lastPathComponent
        var found: [URL] = []
        for name in RecordFiles.names(in: directory.path, fileSystem: fileSystem).sorted() {
            let url = directory.appendingPathComponent(name)
            if name == "\(base).jsonl" {
                found.append(url)
            } else if name.hasPrefix("\(base)-"), name.hasSuffix(".jsonl"), Self.shardMonth(of: url) != nil {
                found.append(url)
            }
        }
        // Shards first, the live file last: the order the log reads in.
        return found.filter { $0 != file } + found.filter { $0 == file }
    }

    /// Delete the log: the live file, every shard, in either form. A
    /// person's explicit act; nothing here needs the key.
    public func clear() {
        flushWork?.cancel()
        flushWork = nil
        io.sync {
            pending = []
            live.close()
            RecordFiles.removeJournal(live.path, fileSystem: fileSystem)
            try? fileSystem.remove(file.path)
            for month in shardMonthsLocked() {
                let shard = shardFile(for: month)
                RecordFiles.removeJournal(LineStore.journalPath(forPlaintext: shard), fileSystem: fileSystem)
                try? fileSystem.remove(shard.path)
            }
        }
    }

    /// Close the journal held open. Shutdown, and a test that wants the
    /// file system to itself.
    public func close() {
        io.sync { live.close() }
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
    /// The legacy plaintext name; the shard's journal is `events-2026-08.sj`.
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

    /// Every month that has a shard beside the live file, sealed or still
    /// plaintext, oldest first. Callers must already be on `io`.
    private func shardMonthsLocked() -> [String] {
        let directory = file.deletingLastPathComponent()
        let base = file.deletingPathExtension().lastPathComponent
        var months: Set<String> = []
        for name in RecordFiles.names(in: directory.path, fileSystem: fileSystem) where name.hasPrefix("\(base)-") {
            let stem: String
            if name.hasSuffix(".jsonl") {
                stem = String(name.dropLast(".jsonl".count))
            } else if name.hasSuffix(RecordFiles.journalSuffix) {
                stem = String(name.dropLast(RecordFiles.journalSuffix.count))
            } else {
                continue
            }
            if let month = Self.shardMonth(of: directory.appendingPathComponent(stem + ".jsonl")) { months.insert(month) }
        }
        return months.sorted()
    }

    private func scheduleFlush() {
        guard flushWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.flushSoon() }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }
}

private extension Data {
    /// Whether this ends with `other`, byte for byte.
    func hasSuffix(of other: Data) -> Bool {
        guard !other.isEmpty, count >= other.count else { return other.isEmpty }
        return suffix(other.count) == other
    }
}
