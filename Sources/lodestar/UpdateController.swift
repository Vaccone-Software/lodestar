import AppKit
import LodestarCore
import Stoic
import StoicStore
import StoicTime
import Synchronization

/// Silent self-update for the installed app. The cycle: check the releases
/// feed daily, download and unpack the zip in the background, verify it,
/// then swap bundles only in a quiet moment — the engine idle, no panel
/// up, ten minutes since the last gesture — and let the ordinary pid-file
/// takeover hand the session to the new build. A detached watchdog blesses
/// the successor or puts the old bundle back; the successor flashes once,
/// so the change is quiet but never hidden.
///
/// The verification bar: a zip this process downloads carries no
/// quarantine, so Gatekeeper never assesses it — we are the gate. Nothing
/// touches the install path unless codesign verifies the staged bundle
/// strictly AND its signature chains to Apple with this bundle id and
/// this team, AND its Info.plist version matches the release tag.
final class UpdateController {
    /// The install this instance runs from; nil for dev builds and
    /// translocated copies — the updater stands down entirely.
    private let installURL: URL?

    private static let directory = Paths.update
    /// Survives the rolled-back announcement: the tag we refuse to re-apply.
    private static let refusedFile = directory.appendingPathComponent("refused")
    private static let feedURL = Updater.previewURL
    private static let requirement = """
        anchor apple generic and identifier "com.vaccone.lodestar" \
        and certificate leaf[subject.OU] = "\(Lodestar.teamID)"
        """

    /// Turning updates off mid-run also drops anything already staged: a
    /// bundle parked here for weeks would otherwise be installed, stale, by
    /// the next forced check.
    var enabled = true {
        didSet {
            guard !enabled, oldValue else { return }
            if case .ready(let version) = phase {
                standDown(releasing: version, as: .abandon, because: "updates were turned off")
            }
        }
    }
    /// The releases this Mac follows. A switch takes effect at the next
    /// check; a Mac ahead of its new channel stays where it is until the
    /// channel passes it, because the updater never moves backwards.
    var channel = Updater.Channel.stable
    var engineQuiet: () -> Bool = { false }
    /// The last moment a hand was at the keyboard, gesture or not.
    var lastActivity: () -> Date = { .distantPast }
    var flash: (String) -> Void = { _ in }
    /// Lodestar speaking, briefly: a sentence in the voice and a line of
    /// facts beneath it. The four moments the app has something to say
    /// about itself; every failure stays a flash, a fact in the
    /// interface's face.
    /// Every one of them carries the mark, lit as far as the update has
    /// come. `stands` keeps a note up until the next one replaces it, for
    /// the download, whose end is the next thing said.
    var voice: (_ sentence: String, _ detail: String?, _ mark: Double, _ stands: Bool) -> Void = { _, _, _, _ in }
    /// The download's progress, for the mark on the note standing now.
    var lightMark: (Double) -> Void = { _ in }

    /// The words, kept in one place so a test can hold them. Lodestar is
    /// named only where Lodestar is the subject, and never says I.
    enum Voice {
        static func found(_ tag: String) -> (String, String) {
            ("A newer Lodestar is on its way", "\(tag.hasPrefix("v") ? String(tag.dropFirst()) : tag) · downloading")
        }
        static func newest(_ version: String) -> (String, String) {
            ("This is the newest Lodestar", version)
        }
        static func takingOver(_ version: String) -> (String, String) {
            ("The new Lodestar takes over in a moment", "\(version) · downloaded and verified")
        }
        static func updated(_ version: String) -> (String, String) {
            ("Lodestar has updated", "Now \(version)")
        }
    }
    /// Whether a successor has to prove it can route clicked links before the
    /// watchdog blesses it. True exactly while Lodestar holds the http role.
    var requiresRouting: () -> Bool = { false }

    /// True when this launch is the one that completed an update, which is a
    /// bad moment to put anything modal on screen: the swap happens while you
    /// are away.
    private(set) var justUpdated = false

    /// The successor's own voice, at boot: the router answered. Written with
    /// this process's pid so no earlier build's marker can stand in for it.
    func confirmRoutingHealthy() {
        let marker = Self.directory.appendingPathComponent("routes-ok")
        Self.writeMarker("\(ProcessInfo.processInfo.processIdentifier)", to: marker,
                         what: "the routing-healthy marker",
                         consequence: "the watchdog will not bless this build and rolls it back")
    }

    /// Write one of the updater's markers, and say so when it does not
    /// land. These were `try?` writes: the refusal tombstone failing
    /// silently once left a rolled-back release on offer, and the
    /// update-and-rollback went round again every check, a relaunch loop.
    /// A failure is an error in the log, with what it will cost.
    @discardableResult
    static func writeMarker(_ text: String, to url: URL, what: String, consequence: String) -> Bool {
        do {
            try Updater.writeMarker(text, to: url)
            return true
        } catch {
            Log.error("update: could not write \(what) at \(url.path) — \(consequence): \(error)")
            return false
        }
    }

    /// The single-flight rule, main-thread only: one run at a time, and
    /// `applying` is terminal — after a successful swap this process only
    /// waits to be taken over. Two racing pipelines destroyed an install
    /// once; the phase machine is why there can never be two. The version
    /// rides on the phase, so there is no second field to keep in step.
    private var phase: Updater.Phase = .idle
    /// The verified bundle waiting to be swapped in; set only while `.ready`.
    private var stagedBundle: URL?
    private var firstCheck: Timer?
    private var dailyCheck: Timer?
    private var applyPoll: Timer?
    /// The feed's client, bounded in time and in size (see `UpdateFeed`):
    /// URLSession.shared would let a trickling answer hold the run in
    /// `.checking` for days, refusing every later check. (The zip is fetched
    /// by `UpdateDownload`, bounded by a deadline of its own: a transfer that
    /// is moving is not cut at three minutes.)
    private let feedClient = UpdateFeed.client()
    private let downloads = UpdateDownload.client()
    private let worker = DispatchQueue(label: "lodestar.update", qos: .utility)
    /// Stoic's ambient context as it was where this controller was made: the
    /// main thread, inside the launch's `withAmbient`, where `StoicLog` is
    /// among the instrumentation. The staging tools run from `worker`, a
    /// dispatch queue, which sees none of it, so the controller keeps it to
    /// hand them (`runTool`).
    private let ambient = Ambient.current

    /// The record of each release on this Mac, beside the markers (see
    /// `ReleaseRecords`); nil for a build that is not installed, which does
    /// nothing about updates at all.
    private let records: ReleaseRecords?

    /// How long after launch what is owed to the person is said: a relay
    /// exits within a second, so it never says it.
    var announcementDelay: Duration = .seconds(4)

    init() {
        // Only the installed app updates itself. A signed build run from
        // dist/ to be tested, older than the latest release, would have
        // downloaded that release and replaced itself there.
        let installed = Updater.isInstalled(bundlePath: Bundle.main.bundlePath,
                                            home: Paths.userHome.path)
            ? Bundle.main.bundleURL : nil
        installURL = installed
        records = installed == nil ? nil : ReleaseRecords()
    }

    /// For a test: an install of its own choosing, and records kept where it says.
    init(installURL: URL?, records: ReleaseRecords?) {
        self.installURL = installURL
        self.records = installURL == nil ? nil : records
    }

    /// Checks that failed in a row, and the retry waiting on them.
    private var failedChecks = 0
    private var retry: Timer?

    /// A check that failed is asked again soon (`Updater.retryDelay`), not
    /// the next day. Main.
    private func scheduleRetry() {
        failedChecks += 1
        retry?.invalidate()
        guard let delay = Updater.jitteredRetryDelay(afterFailures: failedChecks) else {
            retry = nil
            return
        }
        Log.info("update", ["retry-in-minutes": Int(delay / 60), "failures": failedChecks])
        retry = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.check(force: false)
        }
    }

    func start() {
        // Only the installed app has an update story. A build run from the
        // source tree used to read, judge and retire the person's own markers
        // here, which belong to the install.
        guard installURL != nil else { return }
        boot()
        Log.attempt("update: could not make the update folder") {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        }
        // What this launch clears has nothing behind it: a record still
        // showing a download or a staged build is told so.
        records?.abandonInFlight()
        worker.async { self.clearStaging() }
        // First check well clear of the login rush; the leftover .previous
        // bundle from the last swap is long past its watchdog by then.
        firstCheck = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { [weak self] _ in
            guard let self else { return }
            // Only reap the leftover while nothing is in flight: a forced
            // check early in this session could still be mid-swap, and its
            // watchdog needs that bundle to roll back to.
            if case .idle = self.phase, let install = self.installURL {
                let previous = install.deletingLastPathComponent()
                    .appendingPathComponent("lodestar.app.previous")
                Log.attemptUnlessAbsent("update: could not remove the previous bundle") {
                    try FileManager.default.removeItem(at: previous)
                }
                // And the failed build a rollback set aside, if the
                // watchdog stopped before deleting it.
                Log.attemptUnlessAbsent("update: could not remove the failed bundle a rollback set aside") {
                    try FileManager.default.removeItem(at: previous.appendingPathExtension("failed"))
                }
            }
            self.check(force: false)
        }
        dailyCheck = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            self?.check(force: false)
        }
        applyPoll = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.tryApply(force: false)
        }
    }

    // MARK: - Boot markers (the successor speaks; the watchdog wrote)

    private static let updatedMarker = directory.appendingPathComponent("updated-to")
    private static let rolledBackMarker = directory.appendingPathComponent("rolled-back")

    /// The markers outlive the instance that reads them first. After an
    /// update the successor is a relay: it hands the session to launchd
    /// and bows out within a second, so a marker it consumed was gone
    /// before the resident booted, and the resident never knew it had
    /// updated (every update since readoption said "ready" and nothing
    /// else). The instance that says ready retires them. Only the installed
    /// app has them to read: a build under test left alone judged, and
    /// retired, the person's own.
    func acknowledgeBoot() {
        guard installURL != nil else { return }
        Log.attemptUnlessAbsent("update: could not retire the updated marker") {
            try FileManager.default.removeItem(at: Self.updatedMarker)
        }
        Log.attemptUnlessAbsent("update: could not retire the rolled back marker") {
            try FileManager.default.removeItem(at: Self.rolledBackMarker)
        }
    }

    /// What this launch found of the last handover, and what it makes of it.
    ///
    /// The markers are the protocol between processes and between builds
    /// (the watchdog is a bash script, and a rollback can land on a build
    /// from before records), so every one is read and written as it always
    /// was. Beside them, each is turned into an event on the release's
    /// record (`ReleaseRecords.boot`), and what is owed to the person is said
    /// from the record, once, by whichever instance stays long enough
    /// (`ReleaseRecords.deliver`). With no record to be had it is said from
    /// the marker four seconds in, as before (`sayFromMarkers`).
    func boot() {
        let updated = Self.text(of: Self.updatedMarker)
        let rolledBack = Self.text(of: Self.rolledBackMarker)
        // Read before this launch writes a tombstone of its own: an earlier
        // build's refusal becomes a record, this launch's is the marker's.
        let tombstone = refusedTag
        let here = Lodestar.version
        let sameVersion = updated.map { Self.isThisBuild($0) } ?? false
        if let version = updated {
            if sameVersion {
                justUpdated = true
                Log.info("update", ["phase": "completed", "version": version])
            } else {
                // Applied, relaunched, and still not that version: the
                // release did not change the binary. v0.32.4 (2026-09-14)
                // was 0.32.3's build under a new label, and every check
                // re-applied it — 194 relaunches in a night, each one
                // restoring parked windows on the way out. Refused the way
                // a rollback is refused, until a newer release ships.
                Log.attemptUnlessAbsent("update: could not remove the updated marker of a build that did not change the binary") {
                    try FileManager.default.removeItem(at: Self.updatedMarker)
                }
                Self.writeMarker(version, to: Self.refusedFile, what: "the refusal tombstone",
                                 consequence: "this release will be offered, applied and relaunched again at the next check — a relaunch loop")
                Log.error("update to \(version) did not change the binary — still \(here); refusing it until a newer release ships")
            }
        }
        if let version = rolledBack {
            // The tombstone outlives the announcement: a release that could
            // not take the pid file must not be offered again, or every
            // check re-applies it and the watchdog rolls it back forever.
            // Written by every instance that reads the marker, which is
            // harmless: it holds the same tag.
            Self.writeMarker(version, to: Self.refusedFile, what: "the refusal tombstone",
                             consequence: "this release will be offered and rolled back again at the next check — a relaunch loop")
            Log.error("update rolled back: \(version) never took the pid file — refusing it until a newer release ships")
        }

        guard let records else { return }
        let input = ReleaseRecords.Boot(version: here, pid: ProcessInfo.processInfo.processIdentifier,
                                        tombstone: tombstone, updated: updated, rolledBack: rolledBack)
        let rolledBackMarker = Self.rolledBackMarker
        // Holds nothing of the controller: a relay that exits is a process
        // that is gone, and the work is the records', which outlive it only
        // as far as the process does.
        let booting = Task { () -> ReleaseRecords.BootResult? in
            let result = await records.boot(input)
            // Once the record holds the verdict the marker has done its work.
            // The marker is the only thing a relay can hand the resident, and
            // now the record is too: it is retired when the record has it,
            // not when it is said, and not at all if the record could not
            // take it.
            if rolledBack != nil, result?.rolledBack == .rolledBack {
                Log.attemptUnlessAbsent("update: could not retire the rolled back marker once it was recorded") {
                    try FileManager.default.removeItem(at: rolledBackMarker)
                }
            }
            return result
        }
        let say = presenter()
        let delay = announcementDelay
        onMain(after: delay) { [weak self] in
            // A relay's four seconds never come.
            Task { [weak self] in
                let result = await booting.value
                _ = await records.deliver(onMain: say)
                self?.sayFromMarkers(updated: sameVersion ? updated : nil, rolledBack: rolledBack, recorded: result)
            }
        }
    }

    /// What the markers say that the records could not: the same words as
    /// before there were records, from the marker, for the one that the
    /// record did not take.
    private func sayFromMarkers(updated: String?, rolledBack: String?, recorded: ReleaseRecords.BootResult?) {
        let rolledBackMarker = Self.rolledBackMarker
        DispatchQueue.main.async {
            if let version = updated, recorded?.updated != .running {
                let (sentence, detail) = Voice.updated(version)
                self.voice(sentence, detail, 1, false)
            }
            if let version = rolledBack, recorded?.rolledBack != .rolledBack {
                self.flash("⚠ \(version) did not start, so Lodestar went back to \(Lodestar.version)")
                // The marker is retired when the message is said, not when it is
                // read: an instance that exits before the four seconds (a relay)
                // never says it, and leaves the marker for the one that stays.
                Log.attemptUnlessAbsent("update: could not remove the rolled back marker after announcing it") {
                    try FileManager.default.removeItem(at: rolledBackMarker)
                }
            }
        }
    }

    /// What delivering an announcement does: put the words on screen, from
    /// the main thread. The records carry it there and back (`deliver(onMain:)`);
    /// a controller that is gone leaves it owed, to the instance that stays.
    private func presenter() -> (ReleaseRecords.Delivery) -> DeliveryResult {
        { [weak self] delivery in self?.present(delivery) ?? .keep }
    }

    /// Main thread.
    private func present(_ delivery: ReleaseRecords.Delivery) -> DeliveryResult {
        switch delivery.announcement {
        case .running:
            // Owed by an earlier launch and never said, and this is a later
            // release: "Now 0.54.25" on a Mac that is on 0.54.26 would be wrong.
            guard Self.isThisBuild(delivery.id) else {
                return .discard(reason: "\(delivery.id) is not the release this is")
            }
            let (sentence, detail) = Voice.updated(delivery.id)
            voice(sentence, detail, 1, false)
        case .rolledBack:
            flash("⚠ \(delivery.id) did not start, so Lodestar went back to \(Lodestar.version)")
        }
        return .delivered
    }

    /// Whether `text` names the version this build is, as versions are
    /// compared: `v0.54.25`, `0.54.25` and `0.54.25.0` are one.
    private static func isThisBuild(_ text: String) -> Bool {
        guard let version = Updater.parseVersion(text), let here = Updater.parseVersion(Lodestar.version) else { return false }
        return Updater.sameVersion(version, here)
    }

    private static func text(of url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    /// The tag of a release that already failed its handover, if any.
    private var refusedTag: String? {
        Self.text(of: Self.refusedFile)
    }

    /// Whether a release may be offered: neither the tombstone, which every
    /// build writes, nor the record, which this one keeps, refuses it. The
    /// record's answer is the snapshot its last piece of work left, so the
    /// feed's answer never waits on a file.
    func mayOffer(_ release: Updater.Release) -> Bool {
        Updater.shouldOffer(release, refusedTag: refusedTag) && records?.refuses(release.tag) != true
    }

    // MARK: - Check, download, verify

    /// force: the menu item — check now, tell the user either way, and
    /// apply immediately instead of waiting for quiet. A repeated press
    /// joins the run in flight; it never starts a second one.
    func check(force: Bool) {
        guard let installURL else {
            if force { flash("✕ Updates apply to the installed app only") }
            return
        }
        guard enabled || force else { return }
        switch Updater.checkDecision(in: phase) {
        case .refuse(let note):
            if force { flash(note) }
            return
        case .applyStaged:
            tryApply(force: force)
            return
        case .startCheck:
            break
        }
        // The swap's cheap preconditions, judged before the expensive part:
        // a read-only install directory would otherwise cost a download,
        // an unpack, and two signature passes on every daily check, every
        // day, only to be discarded. They are re-checked at swap time,
        // because a quiet-moment apply can run hours after this.
        guard canSwap(installURL: installURL, force: force) else { return }

        phase = .checking
        // Read here, on the caller's thread, not in the answer's handler.
        let channel = self.channel
        Log.info("update", ["phase": "checking", "force": "\(force)", "channel": channel.rawValue])
        let feed = channel == .stable ? Updater.stableURL : Self.feedURL
        // Who is waiting decides how patiently the feed is asked: the
        // periodic check is nobody's; the menu item was pressed by someone
        // who will wait seconds for the answer (not a tap's instant
        // feedback), which is also the thirty seconds it always had.
        let urgency: Urgency = force ? .userInitiated : .background
        let client = feedClient
        Task { [weak self] in
            guard let self else { return }
            var data: Data?
            var problem: String?
            do {
                data = try await withUrgency(urgency) { try await UpdateFeed.data(from: feed, client: client) }
            } catch {
                problem = UpdateFeed.problem(error)
            }
            self.answered(data, problem: problem, channel: channel, force: force)
        }
    }

    /// The feed's answer, or what went wrong. Called from `check`'s `Task`,
    /// which is off the main thread: the class is not actor-isolated, so the
    /// task inherits no executor and runs on the global one, where the
    /// URLSession completion this replaces also ran. Main-thread state is
    /// reached through `DispatchQueue.main`, as `finishCheck` does.
    private func answered(_ data: Data?, problem: String?, channel: Updater.Channel, force: Bool) {
        guard problem == nil, let data, let release = Updater.parse(data, channel: channel) else {
            finishCheck(force: force, note: "✕ Could not check for updates",
                        log: "\(channel.rawValue) feed unreadable (\(problem ?? "no release with a zip"))", failed: true)
            return
        }
        DispatchQueue.main.async { self.failedChecks = 0 }
        let local = Updater.parseVersion(Lodestar.version) ?? []
        guard Updater.isNewer(release.version, than: local) else {
            finishCheck(force: force, voice: Voice.newest(Lodestar.version), log: nil)
            return
        }
        guard mayOffer(release) else {
            finishCheck(force: force,
                        note: "✓ \(release.tag) already failed to start here\nLodestar waits for a newer release",
                        log: "refusing \(release.tag): it was rolled back once")
            return
        }
        records?.offered(release.tag, because: "the \(channel.rawValue) feed offered it")
        worker.async { self.download(release, force: force) }
    }

    /// Can this process move bundles at all? Cheap stats only.
    private func canSwap(installURL: URL, force: Bool) -> Bool {
        let parent = installURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            Log.error("update: \(parent.path) is not writable — leaving the manual lanes to it")
            if force { flash("✕ Lodestar cannot update where it is installed\nMove it to Applications") }
            return false
        }
        guard FileManager.default.fileExists(atPath: installURL.path) else {
            Log.error("update: nothing at \(installURL.path) — standing down")
            if force { flash("✕ The installed Lodestar is missing\nDownload it again from the site") }
            return false
        }
        return true
    }

    private func finishCheck(force: Bool, note: String, log message: String?, failed: Bool = false) {
        if let message { Log.error("update check: \(message)") }
        DispatchQueue.main.async {
            self.phase = .idle
            if force { self.flash(note) }
            if failed { self.scheduleRetry() }
        }
    }

    /// The check that ends in the voice rather than a fact: nothing newer.
    private func finishCheck(force: Bool, voice words: (String, String), log message: String?) {
        if let message { Log.error("update check: \(message)") }
        DispatchQueue.main.async {
            self.phase = .idle
            if force { self.voice(words.0, words.1, 1, false) }
        }
    }

    /// The zip is where `download.zip` has always been, so staging, the
    /// watchdog and `clearStaging` find it there. Its partial and the record
    /// beside it are `download.zip.partial` and `.resume`: kept from one try
    /// to the next, so a transfer cut off resumes, and replaced by the next
    /// release's, which they are not the same download as.
    static let zipPath = directory.appendingPathComponent("download.zip")

    private func download(_ release: Updater.Release, force: Bool) {
        guard URL(string: release.zipURL) != nil else {
            finishCheck(force: force, note: "✕ Could not check for updates", log: "bad asset url")
            return
        }
        Log.info("update", ["phase": "downloading", "asset": release.zipName,
                            "digest": UpdateDownload.digest(of: release) == nil ? "none" : "sha256"])
        if force {
            let (sentence, detail) = Voice.found(release.tag)
            DispatchQueue.main.async { self.voice(sentence, detail, 0, true) }
        }
        // Only a check someone asked for has a note on screen to light.
        let progress = force ? lightingProgress() : nil
        let client = downloads
        Task { [weak self] in
            do {
                try await UpdateDownload.fetch(release, to: Self.zipPath, client: client, progress: progress)
            } catch {
                self?.downloadFailed(release, error, force: force)
                return
            }
            self?.stage(onWorker: release, force: force)
        }
    }

    private func lightingProgress() -> @Sendable (Double) -> Void {
        let light = MarkLight(self)
        return { share in light.report(share) }
    }

    func downloadFailed(_ release: Updater.Release, _ error: any Error, force: Bool) {
        let problem = UpdateDownload.problem(error, release: release)
        records?.record(.failed, of: release.tag, because: "the download failed: \(problem)")
        finishCheck(force: force, note: "✕ The update did not download",
                    log: "download failed (\(problem))", failed: true)
    }

    private func stage(onWorker release: Updater.Release, force: Bool) {
        worker.async { self.stage(zip: Self.zipPath, release: release, force: force) }
    }

    /// Lights the mark as far as the download has come, from the downloading
    /// task to the main thread, once for each face that changes.
    // stoic:allow(unchecked-sendable): `controller` is weak, set once in `init`, and used only inside `DispatchQueue.main.async`; `shown` is read and written only under `lock`
    private final class MarkLight: @unchecked Sendable {
        private weak var controller: UpdateController?
        private let lock = NSLock()
        private var shown = -1

        init(_ controller: UpdateController) { self.controller = controller }

        func report(_ share: Double) {
            DispatchQueue.main.async { [self] in
                let faces = LitMark.litCount(share)
                guard lock.withLock({ defer { shown = faces }; return faces != shown }) else { return }
                controller?.lightMark(share)
            }
        }
    }

    private func stage(zip: URL, release: Updater.Release, force: Bool) {
        let staging = Self.directory.appendingPathComponent("staged", isDirectory: true)
        Log.attemptUnlessAbsent("update: could not clear the staging folder") {
            try FileManager.default.removeItem(at: staging)
        }
        guard step("unpack", release: release, force: force, "/usr/bin/ditto", "-x", "-k", zip.path, staging.path) else { return }
        Log.attemptUnlessAbsent("update: could not remove the downloaded zip") { try FileManager.default.removeItem(at: zip) }
        let bundle = staging.appendingPathComponent("lodestar.app")

        // The gate, in three locks: integrity, identity, and the version
        // actually being the one the release claims.
        guard step("codesign integrity check", release: release, force: force,
                   "/usr/bin/codesign", "--verify", "--strict", "--deep", bundle.path) else { return }
        guard step("signature check (this team's Developer ID)", release: release, force: force,
                   "/usr/bin/codesign", "--verify", "-R=\(Self.requirement)", bundle.path) else { return }
        let plist = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        guard let stagedVersion = plist?["CFBundleShortVersionString"] as? String,
              let staged = Updater.parseVersion(stagedVersion),
              Updater.sameVersion(staged, release.version) else {
            failStage(release: release, force: force, log: "staged bundle version does not match the release tag")
            return
        }

        // The fourth lock: this Mac can run it. A build it cannot run is
        // refused by its tag, so it is not fetched again, and said once.
        if let why = Updater.incompatibility(
            architectures: Self.architectures(of: bundle),
            minimumSystem: plist?["LSMinimumSystemVersion"] as? String,
            appleSilicon: Self.appleSilicon, system: ProcessInfo.processInfo.operatingSystemVersion) {
            Log.info("update", ["phase": "refused", "version": stagedVersion, "reason": why])
            Self.writeMarker(release.tag, to: Self.refusedFile, what: "the refusal tombstone",
                             consequence: "this release will be downloaded and refused again at the next check")
            records?.record(.incompatible, of: release.tag, because: "this Mac \(why)")
            clearStaging()
            DispatchQueue.main.async {
                self.phase = .idle
                self.flash("⚠ Lodestar \(stagedVersion) \(why), so this Mac stays on \(Lodestar.version)")
            }
            return
        }

        Log.info("update", ["phase": "staged", "version": stagedVersion])
        records?.record(.verified, of: release.tag,
                        because: "its signature, identity and version \(stagedVersion) checked out")
        DispatchQueue.main.async {
            self.stagedBundle = bundle
            self.phase = .ready(version: stagedVersion)
            self.tryApply(force: force)
        }
    }

    private func failStage(release: Updater.Release, force: Bool, log message: String) {
        Log.error("update staging: \(message)")
        records?.record(.failed, of: release.tag, because: message)
        clearStaging()
        DispatchQueue.main.async {
            self.phase = .idle
            if force { self.flash("✕ The update failed its check and was not installed") }
        }
    }

    /// The architectures a bundle's executable was built for.
    static func architectures(of bundle: URL) -> Set<String> {
        let types = Bundle(url: bundle)?.executableArchitectures?.map(\.intValue) ?? []
        return Set(types.compactMap { type -> String? in
            switch type {
            case NSBundleExecutableArchitectureARM64: return "arm64"
            case NSBundleExecutableArchitectureX86_64: return "x86_64"
            default: return nil
            }
        })
    }

    /// Apple silicon, even when this build runs translated.
    static var appleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    private func clearStaging() {
        Log.attemptUnlessAbsent("update: could not clear the downloaded zip") {
            try FileManager.default.removeItem(at: Self.directory.appendingPathComponent("download.zip"))
        }
        Log.attemptUnlessAbsent("update: could not clear the staging folder") {
            try FileManager.default.removeItem(at: Self.directory.appendingPathComponent("staged"))
        }
    }

    /// How long one of the staging tools may take. `ditto` unpacking a
    /// bundle and `codesign` verifying it take seconds; two minutes is far
    /// past any healthy run, and short of leaving the update `.checking`
    /// for ever, which refuses every later check.
    static let toolDeadline: Duration = .seconds(120)

    /// One staging command, and the update failing if it does not pass
    /// or does not finish. Worker queue.
    private func step(_ what: String, release: Updater.Release, force: Bool, _ launchPath: String, _ arguments: String...) -> Bool {
        switch runTool(launchPath, arguments) {
        case .succeeded:
            return true
        case .failed:
            failStage(release: release, force: force, log: "\(what) failed")
        case .timedOut:
            failStage(release: release, force: force, log: "\(what) did not finish in \(Int(Self.toolDeadline.components.seconds)) s")
        }
        return false
    }

    enum RunOutcome: Equatable { case succeeded, failed, timedOut }

    /// A tool that never exits is stopped waiting for. The wait is
    /// Stoic's `abandoningAfter` (the call blocks a thread, so it runs on
    /// Dispatch and holds a slot until it returns); at the deadline the
    /// process is also terminated, which is what lets that thread come
    /// back, killed outright if it ignores the first ask. The calling
    /// thread is the update's worker queue, which blocks here by design.
    /// `ambient` is the Stoic context the work reports in: the caller's own
    /// when none is named, which a dispatch queue has none of (see `runTool`).
    static func run(_ launchPath: String, _ arguments: [String],
                    within deadline: Duration = toolDeadline,
                    ambient: Ambient = .current) -> RunOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let held = HeldProcess(process)
        let outcome = OutcomeBox()
        let finished = DispatchSemaphore(value: 0)
        let name = URL(fileURLWithPath: launchPath).lastPathComponent
        // A task keeps the wait off the calling thread, which is a dispatch
        // queue's and so hands the task no context of its own: what it says
        // (`abandoned.started` for a tool given up on) would reach the unified
        // log alone. The context handed in is bound inside it. The priority
        // is the one a detached task had, named because a task started from
        // a queue otherwise takes the queue's.
        Task(priority: .medium) {
            await withAmbient({ $0 = ambient }) {
                do throws(PolicyError<any Error>) {
                    let status = try await abandoningAfter(deadline, label: "update.\(name)", limit: 2) { () throws -> Int32 in
                        try held.process.run()
                        held.process.waitUntilExit()
                        return held.process.terminationStatus
                    }
                    outcome.set(status == 0 ? .succeeded : .failed)
                } catch {
                    if case .rejected = error {
                        held.stop()
                        outcome.set(.timedOut)
                    } else {
                        outcome.set(.failed)
                    }
                }
            }
            finished.signal()
        }
        finished.wait()
        return outcome.value
    }

    /// `run` in the context this controller was made in, which is what the
    /// worker queue calls it with.
    func runTool(_ launchPath: String, _ arguments: [String],
                 within deadline: Duration = toolDeadline) -> RunOutcome {
        Self.run(launchPath, arguments, within: deadline, ambient: ambient)
    }

    // stoic:allow(unchecked-sendable): an immutable box around one Process: `run()` and `waitUntilExit()` happen on the one task that started it, and the only call made from another thread is `stop()` (`isRunning`, `terminate()`, then a kill by pid), made only once the deadline has given up on that wait, which is how a Process is ended from outside a thread blocked in `waitUntilExit`
    private final class HeldProcess: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
        /// Ask it to stop, and make sure a few seconds on.
        func stop() {
            guard process.isRunning else { return }
            process.terminate()
            let pid = process.processIdentifier
            after(.seconds(5), on: .global()) { [self] in
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    private final class OutcomeBox: Sendable {
        private let stored = Mutex(RunOutcome.failed)
        var value: RunOutcome { stored.withLock { $0 } }
        func set(_ outcome: RunOutcome) { stored.withLock { $0 = outcome } }
    }

    // MARK: - The swap

    private func tryApply(force: Bool) {
        guard case .ready(let version) = phase, let bundle = stagedBundle, let installURL else { return }
        if !force {
            guard enabled, Updater.mayApply(
                engineQuiet: engineQuiet(),
                secondsSinceActivity: Moment.now.date.timeIntervalSince(lastActivity())
            ) else { return }
        }
        guard canSwap(installURL: installURL, force: force) else {
            standDown(releasing: version, as: .abandon, because: "the install can no longer be swapped")
            return
        }
        let parent = installURL.deletingLastPathComponent()

        // Preflight: the swap moves exactly two things, and both slots must
        // look untouched. A lingering .previous means some other actor — a
        // watchdog mid-verdict, a manual reinstall — is still mid-story;
        // deleting it from here is how an install died once. This one is
        // usually transient (a watchdog reaps it within ~45s), so the
        // verified bundle is kept and the 60s poll retries rather than
        // paying for the whole download again.
        let previous = parent.appendingPathComponent("lodestar.app.previous")
        guard !FileManager.default.fileExists(atPath: previous.path) else {
            Log.info("update", ["phase": "deferred", "reason": "an earlier swap is still unresolved"])
            if force { flash("⟲ An earlier update is still finishing\nLodestar tries again on its own") }
            return
        }

        phase = .applying(version: version)
        if force {
            let (sentence, detail) = Voice.takingOver(version)
            voice(sentence, detail, 1, false)
        }
        Log.info("update", ["phase": "applying", "to": version])

        do {
            try Self.swapIn(bundle, at: installURL, keepingOldAt: previous)
        } catch {
            Log.error("update swap failed: \(error)")
            standDown(releasing: version, as: .failed, because: "the swap failed: \(error)",
                      force: force, note: "✕ The update did not install")
            return
        }

        // The build is in place. The record is told now (the watchdog starts
        // after the marker, so it cannot be named here: the pid this process
        // has is the one it watches the pid file for), and the marker and the
        // watchdog follow at once, since the watchdog is what undoes a swap
        // that does not take.
        records?.record(.apply, of: version,
                        because: "swapped in over \(Lodestar.version) by pid \(ProcessInfo.processInfo.processIdentifier); its watchdog follows")
        let marker = Self.directory.appendingPathComponent("updated-to")
        Self.writeMarker(version, to: marker, what: "the updated-to marker",
                         consequence: "the new build will not announce the update")
        spawnWatchdog(app: installURL, previous: previous, version: version)
        stagedBundle = nil
        // The successor confirms the record it finds, so it is launched once
        // the apply is committed, where an apply still queued met a successor
        // that confirmed a staged record and wrote the release's history wrong.
        // Bounded: a record never holds up an update, and the store that does
        // not answer in two seconds leaves the marker to carry it, as before.
        guard let records else {
            launchSuccessor(installURL)
            return
        }
        Task { @MainActor in
            do {
                try await abandoningAsyncAfter(.seconds(2), label: "update.apply-recorded") { await records.settled() }
            } catch {
                Log.warning("update", ["record": "apply not committed before the relaunch", "error": "\(error)",
                                       "consequence": "the successor's marker carries the update"])
            }
            self.launchSuccessor(installURL)
        }
    }

    private func launchSuccessor(_ installURL: URL) {
        // The successor's boot takes over the pid file and SIGTERMs this
        // process — the same handoff every manual reinstall already uses.
        // phase stays .applying: this process is done deciding things.
        //
        // createsNewApplicationInstance is the launch: by default
        // LaunchServices "opens" a running app by activating the running
        // process, so the swapped-in build would never start — the old
        // instance would just come forward, the pid file would never
        // change hands, and the watchdog would roll the swap back.
        SystemEvents.openApplication(at: installURL, configuration: Self.successorLaunch) { _, _ in }
    }

    /// The new build into the install's place, the old one kept at
    /// `previous`. In one step wherever the file system allows it, so there
    /// is no moment with no app at the path: a crash in that moment would
    /// leave no Lodestar to relaunch, and a login agent that reads a missing
    /// app as an uninstall. A failure puts everything back as it was.
    static func swapIn(_ bundle: URL, at install: URL, keepingOldAt previous: URL) throws {
        let files = FileManager.default
        do {
            try PosixFileSystem().exchange(bundle.path, install.path)
        } catch {
            // Another volume, or one that cannot exchange: two moves.
            Log.info("update", ["swap": "two moves", "reason": "\(error)"])
            do {
                try files.moveItem(at: install, to: previous)
                try files.moveItem(at: bundle, to: install)
            } catch {
                if !files.fileExists(atPath: install.path), files.fileExists(atPath: previous.path) {
                    Log.attempt("update: could not put the previous bundle back after a failed swap") {
                        try files.moveItem(at: previous, to: install)
                    }
                }
                throw error
            }
            return
        }
        // The new build is in place, and the old one sits where it was staged.
        do {
            try files.moveItem(at: bundle, to: previous)
        } catch {
            Log.attempt("update: could not exchange the bundles back after a failed move") {
                try PosixFileSystem().exchange(bundle.path, install.path)
            }
            throw error
        }
    }

    /// How the successor is launched. A new instance, for the reason above,
    /// and never activated: brought forward, it was the frontmost app for
    /// the seconds of the handover, and with no window to take a key it
    /// answered every key typed meanwhile with the alert.
    static var successorLaunch: NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        return configuration
    }

    /// Abandon the staged build and return to idle — a fresh check can
    /// start over from a clean slate. The manual check narrates every
    /// outcome, so a forced run that stands down says why.
    func standDown(releasing version: String, as event: ReleaseOnThisMac.Event, because: String,
                   force: Bool = false, note: String? = nil) {
        records?.record(event, of: version, because: because)
        stagedBundle = nil
        phase = .idle
        if force, let note { flash(note) }
        worker.async { self.clearStaging() }
    }

    // MARK: - The watchdog (bless or roll back)

    /// A detached observer, in its own session so neither our exit nor
    /// launchd's process-group cleanup takes it down. It never decides health
    /// itself: the pid file changing hands is the verdict, plus the
    /// successor's word that its router answered when links depend on it.
    private func spawnWatchdog(app: URL, previous: URL, version: String) {
        let path = Self.directory.appendingPathComponent("watchdog.sh")
        Self.writeMarker(Self.watchdogScript, to: path, what: "the watchdog script",
                         consequence: "the swap has no one to roll it back, or an older script runs in its place")
        let pidFile = Paths.pidFile
        DetachedProcess.spawn(["/bin/bash", path.path, app.path, previous.path,
                       "\(ProcessInfo.processInfo.processIdentifier)", version,
                       Self.directory.path, pidFile.path,
                       requiresRouting() ? "1" : "0"])
    }

    /// The watchdog, as text: a static so a test can read what it will
    /// do. Two verdicts bless a successor — the pid file changed hands,
    /// and the successor *answers*. A frozen build writes its pid and
    /// looks alive; it does not answer `state` on its control socket,
    /// because the verb runs on the main thread and that is the thread
    /// that froze. So the probe asks, with a three-second alarm, and a
    /// build that never answers inside the window is rolled back like
    /// one that never booted.
    static let watchdogScript = """
    #!/bin/bash
    # lodestar update watchdog: bless the new build or put the old one back.
    APP="$1"; PREVIOUS="$2"; OLDPID="$3"; VERSION="$4"; MARKERS="$5"; PIDFILE="$6"
    ROUTING="$7"
    CLI="$APP/Contents/MacOS/lodestar"
    for _ in 1 2 3 4 5 6 7 8 9; do
        sleep 5
        PID=$(cat "$PIDFILE" 2>/dev/null)
        if [ -n "$PID" ] && [ "$PID" != "$OLDPID" ] && kill -0 "$PID" 2>/dev/null; then
            # Alive is not enough: the successor has to answer on its
            # control socket, from its main thread, inside three seconds.
            # A frozen main thread holds the pid and answers nothing.
            if ! perl -e 'alarm shift; exec @ARGV' 3 "$CLI" state --json >/dev/null 2>&1; then
                continue
            fi
            # While Lodestar holds the browser role, booting is not proof.
            # The successor has to say its router answered, in its own
            # voice: the marker carries the new pid, so a stale one from
            # the build being replaced cannot bless anything.
            if [ "$ROUTING" = "1" ] && [ "$(cat "$MARKERS/routes-ok" 2>/dev/null)" != "$PID" ]; then
                continue
            fi
            rm -rf "$PREVIOUS"
            exit 0
        fi
    done
    rm -f "$MARKERS/routes-ok"
    # The handover failed, whatever happens next: drop the success
    # marker first, above the rollback gate. Left behind, it would fire
    # a false "updated" flash whenever that version finally does boot.
    rm -f "$MARKERS/updated-to"
    # Roll back only while the old bundle is still there to restore.
    # If .previous is gone, another actor already resolved this swap —
    # deleting the app with nothing to put back is never the answer.
    [ -d "$PREVIOUS" ] || exit 0
    # The failed build steps aside, and is deleted only once the old one
    # stands in its place. Deleting it first left no app at the path for
    # as long as the delete took, and a watchdog stopped inside it left
    # half an app with the old build stranded beside it. If the old build
    # will not move back, the failed one returns: an app at the path,
    # even the wrong one, is still something to launch.
    FAILED="$PREVIOUS.failed"
    rm -rf "$FAILED"
    mv "$APP" "$FAILED" || exit 1
    if ! mv "$PREVIOUS" "$APP"; then
        mv "$FAILED" "$APP"
        exit 1
    fi
    printf '%s' "$VERSION" > "$MARKERS/rolled-back"
    # -n: launch a fresh instance even though the old process may still
    # be running — its boot takes the pid file and announces the marker.
    # -g: behind the app in front, so keys typed meanwhile never reach it.
    open -g -n "$APP"
    rm -rf "$FAILED"
    """
}
