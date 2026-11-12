import AppKit
import LodestarCore
import Stoic
import StoicHTTP

/// The daily count's effectful half: the notice, the wait and the one
/// request (the rules are `DailyCount`'s). Main thread only.
///
/// A use (`used`) is the hook the engine, the editor and the draft call. It
/// is cheap after the day's first: one comparison against the next UTC
/// midnight, because the engine calls it from the key tap.
///
/// The record lives in the machine-owned state, so a count waits for the
/// state to be read (`stateKnown`): an empty state read as "never seen the
/// notice, never counted" would ask again and count again.
final class DailyCountController {
    /// Whether this copy may count at all (`DailyCount.eligible`), fixed
    /// for the life of the process.
    private let eligible: Bool
    private let clock: Clock
    private let client: HTTPClient
    private let random: RandomSource

    /// `app.daily-count`. Turning it off forgets a waiting day at once.
    var enabled = true {
        didSet {
            guard enabled != oldValue else { return }
            if !enabled {
                cancelSend()
                if stateKnown() {
                    var record = read()
                    record.pending = nil
                    write(record)
                }
            }
            handledUntil = nil
        }
    }

    var channel: () -> Updater.Channel = { .stable }
    /// The last moment a hand (not a posted event) was at the keys.
    var lastHumanKeyAt: () -> Date = { .distantPast }
    /// Whether nothing is in front of the hand: no chain, no bar, no chip,
    /// no screen being shared. The notice waits for it.
    var quiet: () -> Bool = { false }
    var stateKnown: () -> Bool = { false }
    var read: () -> DailyCount.Record = { DailyCount.Record() }
    var write: (DailyCount.Record) -> Void = { _ in }
    /// What the Mac kept that says when Lodestar first ran here.
    var evidence: () -> [Date?] = { [] }
    var showNotice: (String) -> Void = { _ in }

    /// Uses are ignored until this moment: the day's count is already
    /// settled (waiting, sent, or off), so the tap pays one comparison.
    private var handledUntil: Date?
    private var sendWork: DispatchWorkItem?
    private var sending = false
    /// The try now going, for a test to wait on rather than guess at.
    private(set) var inFlight: Task<Void, Never>?
    private var failures = 0
    private var noticeShownAt: Date?
    private var noticeWait: DispatchWorkItem?
    private var wakeObserver: NSObjectProtocol?

    init(eligible: Bool = DailyCount.thisProcessIsEligible(), clock: Clock = .live,
         client: HTTPClient = DailyCount.client(), random: RandomSource = .system) {
        self.eligible = eligible
        self.clock = clock
        self.client = client
        self.random = random
    }

    deinit {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    /// Launch: a day left waiting by the last run is taken up again if it is
    /// still that day, and a Mac that slept through its moment sends on
    /// waking. Call once the state has been read.
    func start() {
        guard eligible, wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.resume()
        }
        resume()
    }

    /// The machine-owned state was read after launch: a waiting day can be
    /// taken up now.
    func stateSettled() {
        guard wakeObserver != nil else { return }
        resume()
    }

    /// A deliberate use: a lode gesture from a hand, a fix taken, words
    /// landed. `byHand` is the tap's own reading for a gesture; a fix or a
    /// dictation counts when a hand was at the keys within the last minutes.
    func used(byHand: Bool? = nil) {
        guard eligible, enabled else { return }
        let now = clock.now()
        if let handledUntil, now < handledUntil { return }
        // The notice is waiting to be drawn, or was drawn lately and not
        // seen: the tap pays nothing more until it may be drawn again.
        if noticeWait != nil { return }
        if let shown = noticeShownAt, now.timeIntervalSince(shown) < Self.noticeSpacing { return }
        let human = byHand ?? (now.timeIntervalSince(lastHumanKeyAt()) <= DailyCount.handWindow)
        guard human, stateKnown() else { return }
        var record = read()
        if record.installedAt == nil {
            record.installedAt = DailyCount.installedAt(evidence: evidence(), now: now)
            write(record)
        }
        let delay = Double.random(in: 0...DailyCount.maximumDelay, using: &generator)
        switch DailyCount.use(record, now: now, enabled: enabled, delay: delay) {
        case .nothing:
            handledUntil = Self.nextUTCMidnight(after: now)
        case .showNotice:
            offerNotice()
        case .schedule(let pending):
            record.pending = pending
            write(record)
            handledUntil = Self.nextUTCMidnight(after: now)
            Log.info("daily-count", ["waiting-minutes": Int(pending.due.timeIntervalSince(now) / 60)])
            scheduleSend(at: pending.due)
        }
    }

    private lazy var generator = random.generator()

    // MARK: - The notice

    /// The notice waits until nothing is in front of the hand, for up to
    /// ten minutes, then stands as a flash until the next key. It counts as
    /// seen only when a key comes while it stands; otherwise the next use
    /// shows it again.
    private func offerNotice() {
        guard noticeWait == nil else { return }
        if let shown = noticeShownAt, clock.now().timeIntervalSince(shown) < Self.noticeSpacing { return }
        tryNotice(attempt: 0)
    }

    static let noticeSpacing: TimeInterval = 30 * 60
    static let noticeTries = 200
    static let noticePoll: TimeInterval = 3

    private func tryNotice(attempt: Int) {
        noticeWait = nil
        guard enabled, eligible, attempt < Self.noticeTries else { return }
        guard quiet() else {
            let work = DispatchWorkItem { [weak self] in self?.tryNotice(attempt: attempt + 1) }
            noticeWait = work
            clock.after(Self.noticePoll, work)
            return
        }
        let shownAt = clock.now()
        noticeShownAt = shownAt
        showNotice(DailyCount.notice)
        Log.info("daily-count", ["notice": "shown"])
        // HUD.heldCeiling, and a breath past it: the flash is gone by then
        // either way, and a key while it stood is what was asked.
        let work = DispatchWorkItem { [weak self] in self?.readNotice(shownAt: shownAt) }
        noticeWait = work
        clock.after(HUD.heldCeiling + 1, work)
    }

    private func readNotice(shownAt: Date) {
        noticeWait = nil
        let key = lastHumanKeyAt()
        guard key.timeIntervalSince(shownAt) > 0.6, key.timeIntervalSince(shownAt) <= HUD.heldCeiling,
              stateKnown() else {
            Log.info("daily-count", ["notice": "not seen"])
            return
        }
        var record = read()
        record.noticeSeenAt = key
        write(record)
        Log.info("daily-count", ["notice": "seen"])
        // The use that brought the notice is today's use.
        noticeShownAt = nil
        used(byHand: true)
    }

    // MARK: - Sending

    private func resume() {
        guard eligible, enabled, stateKnown() else { return }
        let now = clock.now()
        var record = read()
        let live = DailyCount.live(record.pending, now: now)
        if live != record.pending {
            record.pending = live
            write(record)
        }
        guard let live else { return }
        handledUntil = Self.nextUTCMidnight(after: now)
        // After a launch or a wake, give the network a minute to come back.
        scheduleSend(at: max(live.due, now.addingTimeInterval(Self.settle)))
    }

    static let settle: TimeInterval = 60

    private func scheduleSend(at due: Date) {
        sendWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sendIfDue() }
        sendWork = work
        clock.after(max(0, due.timeIntervalSince(clock.now())), work)
    }

    private func cancelSend() {
        sendWork?.cancel()
        sendWork = nil
        failures = 0
    }

    private func sendIfDue() {
        sendWork = nil
        guard eligible, enabled, !sending, stateKnown() else { return }
        let now = clock.now()
        let record = read()
        guard DailyCount.isDue(record.pending, now: now), let pending = record.pending else {
            // The day passed while it waited: it goes uncounted.
            if record.pending != nil, DailyCount.live(record.pending, now: now) == nil {
                var cleared = record
                cleared.pending = nil
                write(cleared)
            }
            return
        }
        guard let installedAt = record.installedAt else { return }
        let payload = DailyCount.Payload(channel: channel(), age: DailyCount.Age(installedAt: installedAt, now: now))
        sending = true
        let client = client
        inFlight = Task { @MainActor [weak self] in
            let outcome: DailyCount.Outcome
            do {
                outcome = DailyCount.classify(try await client.send(payload.httpRequest))
            } catch {
                outcome = DailyCount.classify(error)
            }
            self?.finish(outcome, day: pending.day)
        }
    }

    private func finish(_ outcome: DailyCount.Outcome, day: String) {
        sending = false
        Log.info("daily-count", ["outcome": "\(outcome)"])
        guard stateKnown() else { return }
        var record = read()
        switch outcome {
        case .counted, .refused:
            // A refusal is a bug in what was sent; sending it again would
            // be refused again, so the day is settled either way.
            failures = 0
            if outcome == .counted { record.lastSentDay = max(record.lastSentDay ?? "", day) }
            if record.pending?.day == day { record.pending = nil }
            write(record)
        case .later:
            failures += 1
            guard let delay = DailyCount.retryDelay(afterFailures: failures, random: random) else {
                failures = 0
                return
            }
            scheduleSend(at: clock.now().addingTimeInterval(delay))
        }
    }

    static func nextUTCMidnight(after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? date.addingTimeInterval(86_400)
    }
}
