import AppKit
import LodestarCore

/// The walk, in the app: feeds `StandCue` the hand's input and the
/// stopping points it makes, and shows the cue when one is earned and the
/// moment is quiet.
///
/// Input is the hand's own: keys from the tap, and clicks and scrolls from
/// global monitors that ignore anything posted by a program. The stopping
/// points are leaving an app worked in for a while, and the draft closing.
/// The cue is a note in Lodestar's voice, carrying the mark lit as far
/// into the hour as the stretch has run: half at thirty minutes, whole at
/// sixty. It asks for nothing, goes on its own, and goes at the next key.
final class StandCueController {
    var enabled: () -> Bool = { true }
    var minutes: () -> Int = { 30 }
    /// Every gate the coach keeps: nothing else on the glass, no lens, no
    /// call, a person present. True when the moment is quiet enough.
    var quiet: () -> Bool = { true }
    var draftOpen: () -> Bool = { false }
    var lastKeyAt: () -> Date = { .distantPast }
    var show: (_ sentence: String, _ detail: String, _ share: Double) -> Void = { _, _, _ in }
    var hide: (_ sentence: String) -> Void = { _ in }

    private var cue = StandCue()
    private var shown: (sentence: String, at: Date)?
    private var timer: Timer?
    private var monitors: [Any] = []
    private var observer: NSObjectProtocol?
    private var activeApp: (pid: pid_t, since: Date)?
    private var draftWasOpen = false
    private var seenKeyAt = Date.distantPast
    private var settle: DispatchWorkItem?
    /// The last cue, until we know whether a break followed it.
    private var pending: (index: Int, at: Date)?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
        for mask: NSEvent.EventTypeMask in [[.leftMouseDown, .rightMouseDown, .otherMouseDown], [.scrollWheel]] {
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
                guard let cg = event.cgEvent, Coach.isHumanOrigin(
                    sourceStateID: cg.getIntegerValueField(.eventSourceStateID),
                    postingPID: cg.getIntegerValueField(.eventSourceUnixProcessID)) else { return }
                DispatchQueue.main.async { self?.input(at: Date()) }
            }) {
                monitors.append(monitor)
            }
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.activated(app)
        }
        activeApp = NSWorkspace.shared.frontmostApplication.map { ($0.processIdentifier, Date()) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }

    /// A key reached the tap from a hand.
    func keyPressed() {
        input(at: Date())
    }

    private func input(at time: Date) {
        if let shown, time.timeIntervalSince(shown.at) > 1 {
            // The next key or click after the cue takes it down.
            hide(shown.sentence)
            self.shown = nil
        }
        let previous = cue.lastInput
        if cue.input(at: time) {
            settleTaken(breakStartedAt: previous, endedAt: time)
        }
    }

    private func activated(_ app: NSRunningApplication?) {
        let now = Date()
        defer { activeApp = app.map { ($0.processIdentifier, now) } }
        guard let app, app.processIdentifier != getpid(),
              let previous = activeApp, previous.pid != app.processIdentifier,
              now.timeIntervalSince(previous.since) >= cue.settings.dwell else { return }
        offer(.appSwitch)
    }

    private func tick() {
        guard enabled() else { return }
        if cue.settings.after != TimeInterval(minutes() * 60) { refreshSettings() }
        // Keys are read from the tap's clock; a key since the last look is
        // input as of its own time.
        let key = lastKeyAt()
        if key > seenKeyAt {
            seenKeyAt = key
            input(at: key)
        }
        // Words into the draft are work too, and the draft closing is a
        // stopping point.
        let open = draftOpen()
        if open { input(at: Date()) }
        if draftWasOpen, !open { offer(.draft) }
        draftWasOpen = open
        if let pending, Date().timeIntervalSince(pending.at) > 600, cue.elapsed(at: Date()) > 0 {
            Log.info("stand", ["cue": pending.index, "taken": false])
            self.pending = nil
        }
        if quiet(), !open, let given = cue.check(at: Date()) {
            present(given)
        }
    }

    /// A stopping point: if a walk is due, wait a moment for the hand to
    /// prove it has stopped, then show it if the moment is still quiet.
    private func offer(_ kind: StandCue.Boundary) {
        guard enabled() else { return }
        guard let due = cue.dueAt(), Date() >= due, cue.elapsed(at: Date()) > 0 else { return }
        settle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.enabled(), self.quiet(), !self.draftOpen(),
                  Date().timeIntervalSince(self.lastKeyAt()) >= 2.5,
                  let given = self.cue.boundary(kind, at: Date()) else { return }
            self.present(given)
        }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    /// The threshold follows the setting; a change starts the count over.
    private func refreshSettings() {
        var settings = StandCue.Settings()
        settings.after = TimeInterval(minutes() * 60)
        cue = StandCue(settings: settings)
    }

    private func present(_ given: StandCue.Cue) {
        let sentence = StandCue.sentence(minutes: given.minutes)
        show(sentence, StandCue.instruction, given.share)
        shown = (sentence, Date())
        pending = (given.index, Date())
        // Counts and timings only: which cue, how long the stretch, what
        // kind of stopping point let it in.
        Log.info("stand", ["cue": given.index, "minutes": given.minutes, "via": given.via.rawValue])
    }

    /// A break began: if it began within ten minutes of a cue, the cue was
    /// taken, and how soon is the measure.
    private func settleTaken(breakStartedAt start: Date?, endedAt end: Date) {
        guard let pending, let start else { return }
        let after = start.timeIntervalSince(pending.at)
        if after <= 600 {
            Log.info("stand", ["cue": pending.index, "taken": true, "after s": Int(max(0, after)),
                               "break s": Int(end.timeIntervalSince(start))])
        } else {
            Log.info("stand", ["cue": pending.index, "taken": false])
        }
        self.pending = nil
    }
}
