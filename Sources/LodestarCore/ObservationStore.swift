import Foundation

/// Owns both halves of the observation system: the event log (the truth)
/// and the aggregate view (the cache). Every semantic method builds one
/// `ObservationEvent`, appends it to the log, and applies it to the view —
/// the same event, the same `apply`, so the two can never drift.
///
/// Files live in `~/.local/share`, beside the clipboard and the state file,
/// deliberately not in `~/.config`, which is what people commit to dotfiles
/// repositories. Writes are coalesced, because this is fed from the event
/// tap and a keystroke must never wait on a disk.
public final class ObservationStore {
    public static let defaultFile = Paths.data.appendingPathComponent("observations.json")

    public let file: URL
    public let log: EventLog
    public private(set) var observations = Observations()
    private var pendingSave: DispatchWorkItem?
    private var enabled = true

    public init(file: URL = ObservationStore.defaultFile, log: EventLog = EventLog()) {
        self.file = file
        self.log = log
    }

    /// Off means nothing is recorded and nothing is written. Somebody who
    /// does not want to be watched by their own window manager should get
    /// exactly that, not a smaller file.
    public func setEnabled(_ on: Bool) {
        enabled = on
    }

    /// Read the store.
    ///
    /// `compacting` is false for read-only callers — the `observations`
    /// CLI, for one. Compaction atomically rewrites `events.jsonl`, and a
    /// short-lived reporting process doing that underneath the running app
    /// discards whatever the app had buffered since it last flushed.
    /// Rotation is the running instance's job.
    public func load(compacting: Bool = true) {
        if compacting { log.compact() }
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode(Observations.self, from: data),
              decoded.version == Observations.currentVersion else {
            // Absent, unreadable, or a previous schema. The log is the
            // truth, so the honest recovery is a replay, not a rescue.
            let events = log.readAll()
            if !events.isEmpty {
                Log.info("observations: rebuilding view from \(events.count) events")
                observations = Observations.rebuild(from: events)
                saveSoon()
            }
            return
        }
        observations = decoded
    }

    // MARK: - Recording

    /// A chain that resolved. `gaps` are the pauses between its keys, index
    /// 0 the trigger→first-letter recall; `peeked` says the map was up
    /// before the first letter landed.
    public func chainCompleted(_ letters: [String], gaps: [TimeInterval], peeked: Bool,
                               at now: Date = Date()) {
        var event = ObservationEvent(t: now, kind: .chain)
        event.chain = letters.map { $0.lowercased() }
        event.gaps = gaps
        event.peeked = peeked
        record(event)
    }

    /// A chain started and escaped out of — the clearest negative signal
    /// there is. `hover` is how long the hand sat on the prefix first:
    /// an instant escape is "wrong tool", a long one is "couldn't recall".
    public func chainAbandoned(_ letters: [String], hover: TimeInterval,
                               at now: Date = Date()) {
        guard !letters.isEmpty else { return }
        var event = ObservationEvent(t: now, kind: .abandon)
        event.chain = letters.map { $0.lowercased() }
        event.hover = hover
        record(event)
    }

    /// A key that was not legal where it was pressed. The key itself is the
    /// evidence: it is the letter the hand believed in.
    public func wrongKey(after letters: [String], pressed: String, at now: Date = Date()) {
        var event = ObservationEvent(t: now, kind: .wrongKey)
        event.chain = letters.map { $0.lowercased() }
        event.pressed = pressed.lowercased()
        record(event)
    }

    /// An app was reached, and by which road. `cost` rides along for the
    /// launcher, where the road's price was actually measured.
    public func reached(_ app: String, via route: Observations.Route,
                        cost: Observations.LauncherCost? = nil, at now: Date = Date()) {
        var event = ObservationEvent(t: now, kind: .reach)
        event.app = app.lowercased()
        event.route = route.rawValue
        if let cost {
            event.typed = cost.typed
            event.queryPrefix = cost.prefix
            event.rank = cost.rank
            event.listLength = cost.listLength
            event.openToFirstKey = cost.openToFirstKey
            event.openToCommit = cost.openToCommit
        }
        record(event)
    }

    /// The launcher opened, took typing, and was escaped without a pick.
    public func launcherAbandoned(typed: Int, at now: Date = Date()) {
        var event = ObservationEvent(t: now, kind: .launcherAbandon)
        event.typed = typed
        record(event)
    }

    /// A select mode ended — counts and timings, never the text.
    public func selected(app: String, action: String, source: String,
                         outcome: String?, typed: Int, seconds: TimeInterval,
                         matches: Int? = nil, at now: Date = Date()) {
        var event = ObservationEvent(t: now, kind: .select)
        event.app = app.lowercased()
        event.action = action
        event.source = source
        event.row = outcome
        event.typed = typed
        event.seconds = seconds
        event.listLength = matches
        record(event)
    }

    public func verbUsed(_ verb: String, at now: Date = Date()) {
        guard !verb.isEmpty else { return }
        var event = ObservationEvent(t: now, kind: .verb)
        event.verb = verb
        record(event)
    }

    /// A destination opened in a browser profile. The host, never the URL:
    /// the path and query are the content, the host is the routing fact.
    public func webOpened(host: String?, profile: String, source: String, row: String? = nil,
                          at now: Date = Date()) {
        var event = ObservationEvent(t: now, kind: .web)
        event.host = host?.lowercased()
        event.profile = profile
        event.source = source
        event.row = row
        record(event)
    }

    /// Focus landed on an app, by any road — Lodestar's or the system's.
    public func focused(app: String, at now: Date = Date()) {
        var event = ObservationEvent(t: now, kind: .focus)
        event.app = app.lowercased()
        record(event)
    }

    /// The meeting chip's life. Provider and decider only — a meeting's
    /// title and link are the content, and the content is nobody's.
    public func meetingChip(action: String, provider: String, decider: String?,
                            lead: Double? = nil, at now: Date = Date()) {
        var event = ObservationEvent(t: now, kind: .meeting)
        event.action = action
        event.app = provider
        event.row = decider
        event.lead = lead
        record(event)
    }

    /// A graph binding changed at config reload. Every edit is a natural
    /// experiment; the epoch stamp is what makes it readable as one.
    public func epochBumped(address letters: [String], change: String, at now: Date = Date()) {
        var event = ObservationEvent(t: now, kind: .epoch)
        event.address = Observations.key(letters)
        event.change = change
        event.epoch = observations.epoch + 1
        record(event)
    }

    /// The coach spoke or was answered. Events like everything else, so
    /// the ledger the curriculum runs on is rebuildable like everything
    /// else. `action` is offered | accepted | never.
    public func coach(action: String, rec: Recommendation, at now: Date = Date()) {
        var event = ObservationEvent(t: now, kind: .coach)
        event.action = action
        event.rec = rec.kind.rawValue
        event.app = rec.target
        event.seconds = rec.secondsPerWeek
        if case .bindTarget(let chain, _)? = rec.edit {
            event.address = Observations.key(chain)
        } else if case .removeChain(let chain)? = rec.edit {
            event.address = Observations.key(chain)
        }
        record(event)
    }

    private func record(_ event: ObservationEvent) {
        guard enabled else { return }
        log.append(event)
        observations.apply(event)
        saveSoon()
    }

    // MARK: - Lifecycle

    public func clear() {
        observations = Observations()
        pendingSave?.cancel()
        pendingSave = nil
        log.clear()
        try? FileManager.default.removeItem(at: file)
    }

    private var clearRequestFile: URL {
        file.deletingLastPathComponent().appendingPathComponent("observations.clear-request")
    }

    /// A CLI clear has to reach the running instance, or the copy it holds
    /// in memory is written straight back over the deletion. The clipboard
    /// learned this first; the handshake is the same file-as-a-flag.
    public func requestClear() {
        try? Data().write(to: clearRequestFile)
    }

    public func consumeClearRequest() -> Bool {
        guard FileManager.default.fileExists(atPath: clearRequestFile.path) else { return false }
        try? FileManager.default.removeItem(at: clearRequestFile)
        return true
    }

    public func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        log.flush()
        save()
    }

    private func saveSoon() {
        guard pendingSave == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSave = nil
            self.log.flush()
            self.save()
        }
        pendingSave = work
        // Longer than the state store's half second: nothing here is worth
        // losing sleep over if a crash takes the last few events with it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func save() {
        guard enabled else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(observations) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
