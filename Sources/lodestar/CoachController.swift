import AppKit
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
                              leaves: [(chain: [String], label: String)],
                              webRoutes: [String: String],
                              profileKeys: [String: String],
                              logFile: URL)? = { nil }
    /// Perform the one config line. Returns an error string, or nil.
    var applyEdit: (ConfigEdit) -> String? = { _ in "coach is not wired" }
    /// The engine's stillness — no chain, no bars, no peek.
    var engineQuiet: () -> Bool = { false }
    var showChip: (Coach.Chip) -> Void = { _ in }
    var hideChip: () -> Void = {}
    var flash: (String) -> Void = { _ in }
    /// The parked offer changed; the menu item re-reads it.
    var onParkedChange: () -> Void = {}

    /// How long a chip stays up before fading to "later".
    static let chipSeconds: TimeInterval = 12
    /// How long a cue-having suggestion waits for its cue before going out
    /// at any quiet boundary instead.
    static let cueWaitDays = 4.0
    /// Recommendations are recomputed at most this often.
    static let refreshInterval: TimeInterval = 30 * 60

    private var standing: Recommendation?
    private var standingSince = Date.distantPast
    private var chipVisible = false
    private var chipHide: DispatchWorkItem?
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

    /// The menu item was clicked: the user asked, so the cue wait is over.
    func presentParked() {
        guard enabled, let rec = standing else { return }
        show(rec)
    }

    // MARK: - Deciding

    private func considerShowing(cueApp: String?, cueHost: String?) {
        guard enabled, !chipVisible, let rec = standing else { return }
        guard engineQuiet(), !CameraProbe.anyCameraRunning() else { return }
        // A cue-having suggestion holds out for its cue for a few days;
        // after that, or for suggestions with no cue, any quiet boundary
        // will do. Proactive either way — nothing waits forever.
        if let cue = Coach.cue(for: rec),
           Date().timeIntervalSince(standingSince) < Self.cueWaitDays * 86_400 {
            switch cue {
            case .app(let name): guard cueApp == name.lowercased() else { return }
            case .host(let host): guard cueHost == host.lowercased() else { return }
            }
        }
        show(rec)
    }

    private func show(_ rec: Recommendation) {
        guard let observations else { return }
        let chip = Coach.chip(for: rec, observations: observations.observations)
        chipVisible = true
        if !isDemo { observations.coach(action: "offered", rec: rec) }
        showChip(chip)
        onParkedChange()
        let work = DispatchWorkItem { [weak self] in self?.dismissChip(record: true) }
        chipHide?.cancel()
        chipHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.chipSeconds, execute: work)
    }

    private func dismissChip(record: Bool) {
        chipHide?.cancel()
        chipHide = nil
        guard chipVisible else { return }
        chipVisible = false
        hideChip()
        onParkedChange()
        _ = record // decay IS "later" — the offered event already counted.
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
        observations?.log.flush()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let events = EventLog.read(file: inputs.logFile)
            let context = Advisor.Context(
                observations: inputs.observations, events: events,
                leaves: inputs.leaves, webRoutes: inputs.webRoutes,
                profileKeys: inputs.profileKeys)
            let recommendations = Advisor.recommend(context)
            let offer = Coach.standingOffer(observations: inputs.observations,
                                            recommendations: recommendations,
                                            now: Date())
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshing = false
                let changed = offer?.target != self.standing?.target
                    || offer?.kind != self.standing?.kind
                if changed {
                    self.standing = offer
                    self.standingSince = Date()
                    self.onParkedChange()
                }
            }
        }
    }
}
