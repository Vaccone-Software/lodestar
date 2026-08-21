import AppKit
import CoreGraphics
import CoreMediaIO
import LodestarCore

/// Is any camera live? The one interruptibility signal worth a system
/// call: a meeting is the moment the coach must never pick. Public
/// CoreMediaIO only, cached briefly because boundaries arrive far more
/// often than cameras change state.
enum CameraProbe {
    private static var cached = false
    private static var cachedAt = Date.distantPast

    static func anyCameraRunning(now: Date = Date()) -> Bool {
        if now.timeIntervalSince(cachedAt) < 30 { return cached }
        cachedAt = now
        cached = probe()
        return cached
    }

    private static func probe() -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var dataSize: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize) == 0,
              dataSize > 0 else { return false }
        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        var devices = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, dataSize, &used,
                                        &devices) == 0 else { return false }
        var running = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        for device in devices {
            var value: UInt32 = 0
            var valueUsed: UInt32 = 0
            let size = UInt32(MemoryLayout<UInt32>.size)
            if CMIOObjectGetPropertyData(device, &running, 0, nil, size, &valueUsed,
                                         &value) == 0, value != 0 {
                return true
            }
        }
        return false
    }
}

/// Is anyone there to read it? A navigation boundary proves a machine is
/// being used; it does not prove a person is watching.
///
/// The system's own idle clock cannot answer this, and the measurement is
/// worth recording because it is the whole reason this exists: events
/// posted with `CGEventPost` reset `secondsSinceLastEventType` to zero,
/// through either tap, under both `.hidSystemState` and
/// `.combinedSessionState`. An agent driving the machine therefore holds
/// the system idle clock at zero all day — it reports a present user most
/// confidently in precisely the case where nobody is there.
///
/// So the clock is kept here instead. The tap stamps `lastHumanInputAt`
/// only for hardware-origin events, and that stamp is what this reads. The
/// rest are the ordinary ways a screen stops being watched. Uncached on
/// purpose, and reached only when an offer is actually standing.
enum PresenceProbe {
    /// Reads the machine; `Coach.isPresent` decides. No session dictionary
    /// is an API failing rather than an absent user, so those two facts
    /// default to their harmless readings — the coach stays possible instead
    /// of silently switching itself off.
    static func userIsPresent(humanIdle: TimeInterval) -> Bool {
        var locked = false
        var onConsole = true
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
            // The lock key is absent entirely while the screen is unlocked.
            locked = (session["CGSSessionScreenIsLocked"] as? Int ?? 0) != 0
            onConsole = (session["kCGSSessionOnConsoleKey"] as? Int ?? 1) != 0
        }
        return Coach.isPresent(humanIdle: humanIdle, screenLocked: locked,
                               displayAsleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0,
                               onConsole: onConsole)
    }
}

/// The coach's coat: clocks, cameras, glass, and the two gestures. Every
/// decision — which suggestion, whether now, what the chip says, how "no"
/// is remembered — lives in `Coach` (LodestarCore), pure and tested; this
/// class only carries those decisions to the screen and back.
final class CoachController {
    /// coach.enabled. Off hides everything and offers nothing.
    var enabled = true {
        didSet { if !enabled { dismissChip(record: false) } }
    }
    var observations: ObservationStore?

    // Wired by the app delegate.
    /// Everything a recommendation pass needs, gathered on the main thread.
    var contextInputs: () -> (observations: Observations,
                              leaves: [Advisor.Leaf],
                              webRoutes: [String: String],
                              profileKeys: [String: String],
                              meetingsEnabled: Bool)? = { nil }
    /// Perform the one config line. Returns an error string, or nil.
    var applyEdit: (ConfigEdit) -> String? = { _ in "coach is not wired" }
    /// The engine's stillness — no chain, no bars, no peek.
    var engineQuiet: () -> Bool = { false }

    /// The walk holds the floor while it is up: two teachers speaking at
    /// once is worse than either, and both share the lode-lode grammar, so
    /// an assent meant for one must never be readable by the other.
    var suppressed: () -> Bool = { false }
    /// Did a person type the navigation that reached this boundary? Yes by
    /// default: an unwired coach must not silence itself.
    var inputWasHuman: () -> Bool = { true }
    /// How long since hardware input last reached the tap. Zero by default,
    /// for the same reason.
    var humanIdle: () -> TimeInterval = { 0 }
    var showChip: (Coach.Chip) -> Void = { _ in }
    var hideChip: () -> Void = {}
    var flash: (String) -> Void = { _ in }
    /// The parked offer changed; the menu item re-reads it.
    var onParkedChange: () -> Void = {}

    /// How long a cue-having suggestion waits for its cue before going out
    /// at any quiet boundary instead.
    static let cueWaitDays = 4.0
    /// Recommendations are recomputed at most this often.
    static let refreshInterval: TimeInterval = 30 * 60

    private var standing: Recommendation?
    private var standingSince = Date.distantPast
    private var chipVisible = false
    private var chipHide: DispatchWorkItem?
    private var chipSeen: DispatchWorkItem?
    private var lastShownAt = Date.distantPast
    /// One line per hold kind per standing suggestion, not per boundary.
    /// Silence must say why, or the one veto that could be miscalibrated
    /// (a keyboard remapper reposts events too) can never be found.
    private var loggedHolds: Set<Coach.Hold> = []
    /// The suggestion in the slot has already spent a showing. Cleared when
    /// a pass puts a different suggestion there.
    private var offerCounted = false
    private var refreshedAt = Date.distantPast
    private var refreshing = false

    #if DEBUG
    /// A rehearsal is in progress: the standing offer is synthetic, so no
    /// ledger events are written — the config write on accept stays real,
    /// because the write is the thing being rehearsed.
    private var demo = false
    #endif

    private var isDemo: Bool {
        #if DEBUG
        return demo
        #else
        return false
        #endif
    }

    #if DEBUG
    /// Debug builds only: seed a synthetic offer so the whole path — chip,
    /// gestures, write — can be walked before the first real finding
    /// exists. The cue wait is treated as already over, so the next quiet
    /// boundary shows it; every veto still applies, because the vetoes are
    /// part of what is being rehearsed.
    func armDemo(_ rec: Recommendation) {
        standing = rec
        standingSince = .distantPast
        offerCounted = false
        loggedHolds = []
        demo = true
        onParkedChange()
    }
    #endif

    /// The suggestion waiting in the menu, if one has been shown and not
    /// yet answered.
    var parkedHeadline: String? {
        guard enabled, !chipVisible, let standing, let observations else { return nil }
        guard isDemo || observations.observations.ledger.contains(where: {
            $0.id == "\(standing.kind.rawValue):\(standing.target)" && $0.offers > 0
        }) else { return nil }
        return Coach.chip(for: standing, observations: observations.observations).headline
    }

    // MARK: - Moments

    /// A navigation completed; the app it reached, lowercased.
    func noteBoundary(app: String?) {
        refreshIfStale()
        considerShowing(cueApp: app, cueHost: nil)
    }

    /// A destination opened at a host.
    func noteWebOpen(host: String?) {
        refreshIfStale()
        considerShowing(cueApp: nil, cueHost: host)
    }

    /// The engine took the glass — a chain started, a bar opened. The chip
    /// yields instantly and its decay counts as "later".
    func surfaceClaimed() {
        dismissChip(record: false)
    }

    // MARK: - The two gestures

    /// Tap lode twice: assent to the standing offer. A no-op when nothing
    /// is on offer, which is what keeps the gesture safe to own.
    func lodeDoubleTapped() {
        guard enabled, chipVisible, let rec = standing, let edit = rec.edit else { return }
        dismissChip(record: false)
        if let problem = applyEdit(edit) {
            flash("✕ \(problem)")
            return
        }
        // The write path's own ✓ flash is the receipt; the config reload it
        // triggers re-runs the advisor against the new world.
        if !isDemo { observations?.coach(action: "accepted", rec: rec) }
        endDemo()
        standing = nil
        onParkedChange()
        scheduleRefresh(after: 5)
    }

    /// lode ⌫ while the chip is up: not this one. Swallows the key only
    /// when it acted, so the gesture means nothing anywhere else. The
    /// small flash is the difference between "declined" and "missed" —
    /// a no that might not have registered would get pressed twice.
    func lodeDelete() -> Bool {
        guard enabled, chipVisible, let rec = standing else { return false }
        dismissChip(record: false)
        if !isDemo { observations?.coach(action: "never", rec: rec) }
        endDemo()
        flash("⌖ noted · not that one")
        standing = nil
        onParkedChange()
        return true
    }

    private func endDemo() {
        #if DEBUG
        demo = false
        #endif
    }

    /// The menu item was clicked: the user asked, so the cue wait is over —
    /// and a viewing they requested is not an interruption, so it spends
    /// nothing from the suggestion's budget of showings.
    func presentParked() {
        guard enabled, let rec = standing else { return }
        show(rec, countable: false)
    }

    // MARK: - Deciding

    private func considerShowing(cueApp: String?, cueHost: String?) {
        // Nothing standing is the common answer, and the only one worth
        // short-circuiting: the probes below are reached a handful of times
        // a week, not a handful of times a minute.
        guard let rec = standing, !suppressed() else { return }
        let now = Date()
        // A rehearsal ignores the real ledger's clocks: the pacing is the
        // curriculum's, and the demo exists to walk the surface.
        let ledger = isDemo ? [] : (observations?.observations.ledger ?? [])
        let entry = ledger.first { $0.id == "\(rec.kind.rawValue):\(rec.target)" }
        let answered = ledger.compactMap(\.lastAnsweredAt).max()
        let offered = ledger.map(\.lastOfferedAt).filter { $0 != .distantPast }.max()
        let thisOffered = entry.flatMap {
            $0.lastOfferedAt == .distantPast ? nil : $0.lastOfferedAt
        }
        let moment = Coach.Moment(
            enabled: enabled, chipVisible: chipVisible, offerSpent: offerCounted,
            sinceLastShown: now.timeIntervalSince(lastShownAt),
            sinceAnswered: answered.map(now.timeIntervalSince) ?? .infinity,
            sinceOffered: offered.map(now.timeIntervalSince) ?? .infinity,
            sinceThisOffered: thisOffered.map(now.timeIntervalSince) ?? .infinity,
            channelOffers: ledger.reduce(0) { $0 + $1.offers },
            thisOffers: entry?.offers ?? 0,
            engineQuiet: engineQuiet(), cameraRunning: CameraProbe.anyCameraRunning(),
            present: PresenceProbe.userIsPresent(humanIdle: humanIdle()),
            inputWasHuman: inputWasHuman())
        let hold = Coach.hold(moment)
        guard hold == .speak else {
            // Once per hold kind per standing suggestion, so a machine
            // driven all afternoon does not fill the log — but every kind
            // of silence leaves one line, because "why is the coach quiet"
            // must be answerable from here.
            if loggedHolds.insert(hold).inserted {
                Log.info("coach", ["held": "\(hold)", "target": rec.target])
            }
            return
        }
        // A cue-having suggestion holds out for its cue for a few days;
        // after that, or for suggestions with no cue, any quiet boundary
        // will do. Proactive either way — nothing waits forever.
        if let cue = Coach.cue(for: rec),
           Date().timeIntervalSince(standingSince) < Self.cueWaitDays * 86_400 {
            switch cue {
            case .app(let name): guard cueApp == name.lowercased() else { return }
            case .host(let host): guard cueHost == host.lowercased() else { return }
            case .meeting:
                // Seconds after a manual join — the one moment the claim
                // is verifiable from what the hands just did.
                let appHit = cueApp.map { Meetings.meetingApps.contains($0) } ?? false
                let hostHit = cueHost.map { Meetings.isMeetingHost($0) } ?? false
                guard appHit || hostHit else { return }
            }
        }
        show(rec)
    }

    private func show(_ rec: Recommendation, countable: Bool = true) {
        guard let observations else { return }
        let chip = Coach.chip(for: rec, observations: observations.observations)
        chipVisible = true
        lastShownAt = Date()
        showChip(chip)
        onParkedChange()
        // An offer is spent by being read, not by being drawn — and never
        // by a viewing the user summoned themselves.
        if countable {
            let seen = DispatchWorkItem { [weak self] in self?.countOffer(rec) }
            chipSeen?.cancel()
            chipSeen = seen
            DispatchQueue.main.asyncAfter(deadline: .now() + Coach.seenSeconds, execute: seen)
        }
        let work = DispatchWorkItem { [weak self] in self?.dismissChip(record: true) }
        chipHide?.cancel()
        chipHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Coach.chipSeconds, execute: work)
    }

    /// The chip stood long enough to be read: the ledger learns of the
    /// offer now. The slot then holds still until the next pass, so one
    /// standing suggestion cannot spend three offers in a single stretch of
    /// navigation — `maxOffers` governs what is issued, and this is what
    /// keeps showings from outrunning it.
    private func countOffer(_ rec: Recommendation) {
        guard chipVisible, !offerCounted else { return }
        // The screen locked, the display slept, or the chair emptied while it
        // stood: nothing was read, so nothing is spent — and it comes down
        // rather than waiting behind a lock screen for a gesture.
        guard PresenceProbe.userIsPresent(humanIdle: humanIdle()) else {
            dismissChip(record: false)
            return
        }
        if !isDemo { observations?.coach(action: "offered", rec: rec) }
        // Only mark the slot spent if it still holds what was shown; a pass
        // that swapped it mid-chip has already cleared the flag itself.
        if rec.kind == standing?.kind, rec.target == standing?.target {
            offerCounted = true
        }
    }

    private func dismissChip(record: Bool) {
        chipHide?.cancel()
        chipHide = nil
        chipSeen?.cancel()
        chipSeen = nil
        guard chipVisible else { return }
        chipVisible = false
        hideChip()
        onParkedChange()
        // Decay IS "later"; whether this showing counted at all was
        // settled at the seen checkpoint, or never happened.
        _ = record
    }

    // MARK: - Recommendations

    /// Recompute off the main thread: the ring is megabytes of JSON and a
    /// keystroke must never wait on it. Inputs are gathered on main; the
    /// log is read from disk by path, so nothing shares mutable state.
    private func refreshIfStale() {
        guard Date().timeIntervalSince(refreshedAt) >= Self.refreshInterval else { return }
        refresh()
    }

    func scheduleRefresh(after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.refresh()
        }
    }

    func refresh() {
        // Never clobber a rehearsal with the real (empty) world.
        guard enabled, !refreshing, !isDemo, let inputs = contextInputs() else { return }
        refreshing = true
        refreshedAt = Date()
        // The ring is flushed and decoded on the pass's own thread — a
        // megabytes-deep JSONL file, and a keystroke must never wait on it.
        let log = observations?.log
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let events = log?.snapshot() ?? []
            let context = Advisor.Context(
                observations: inputs.observations, events: events,
                leaves: inputs.leaves, webRoutes: inputs.webRoutes,
                profileKeys: inputs.profileKeys,
                meetingsEnabled: inputs.meetingsEnabled)
            let recommendations = Advisor.recommend(context)
            let offer = Coach.standingOffer(observations: inputs.observations,
                                            recommendations: recommendations,
                                            now: Date())
            let slotBusy = Coach.slotBusy(observations: inputs.observations, now: Date())
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshing = false
                let changed = offer?.target != self.standing?.target
                    || offer?.kind != self.standing?.kind
                if changed {
                    // A chip on the glass must be the standing offer, never
                    // a memory of one: left up through a swap, the two
                    // gestures would answer a suggestion the user never read.
                    if self.chipVisible { self.dismissChip(record: false) }
                    self.standing = offer
                    self.standingSince = Date()
                    self.offerCounted = false
                    self.loggedHolds = []
                    self.onParkedChange()
                    // The slot's story, told at every change of occupant:
                    // this line and the held lines above are what make
                    // "why is the coach quiet" answerable from the log.
                    if let offer {
                        Log.info("coach", [
                            "standing": "\(offer.kind.rawValue):\(offer.target)",
                            "seconds": "\(Int(offer.secondsPerWeek.rounded()))",
                            "candidates": "\(recommendations.count)",
                        ])
                    } else {
                        Log.info("coach", [
                            "standing": "none",
                            "why": slotBusy ? "a habit is still being learned"
                                : "no candidate cleared the gates",
                            "candidates": "\(recommendations.count)",
                        ])
                    }
                }
            }
        }
    }
}
