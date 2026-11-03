import AppKit
import LodestarCore
import Stoic

/// Silent self-update for the installed app. The cycle: check the releases
/// feed daily, download and unpack the zip in the background, verify it,
/// then swap bundles only in a quiet moment — the engine idle, no panel
/// up, ten minutes since the last gesture — and let the ordinary pid-file
/// takeover hand the session to the new build. A detached watchdog blesses
/// the successor or puts the old bundle back; the successor flashes once,
/// so the change is quiet but never hidden.
///
/// The verification bar: a zip this process downloads carries no
/// quarantine, so Gatekeeper never assesses it — we are the gate. The
/// zip's sha256 is checked before it is unpacked. The unpack writes only
/// inside a fresh staging directory. Nothing is moved into place unless
/// codesign then verifies that bundle strictly AND its signature chains
/// to Apple with this bundle id and this team, AND its Info.plist version
/// matches the release tag.
final class UpdateController {
    /// The install this instance runs from; nil for dev builds and
    /// translocated copies — the updater stands down entirely.
    private let installURL: URL?

    private static let directory = Paths.update
    /// Survives the rolled-back announcement: the tag we refuse to re-apply.
    private static let refusedFile = directory.appendingPathComponent("refused")
    private static let feedURL = URL(string: Lodestar.repository
        .replacingOccurrences(of: "https://github.com/", with: "https://api.github.com/repos/")
        + "/releases?per_page=10")!
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
            if case .ready = phase { standDown() }
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
    /// The feed's session, bounded: URLSession.shared would let a trickling
    /// answer hold the run in `.checking` for days, refusing every later
    /// check. (The zip is fetched by `UpdateDownload`, bounded by a deadline
    /// of its own: a transfer that is moving is not cut at three minutes.)
    private let network: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        return URLSession(configuration: configuration)
    }()
    private let downloads = UpdateDownload.client()
    private let worker = DispatchQueue(label: "lodestar.update", qos: .utility)

    init() {
        // Only the installed app updates itself. A signed build run from
        // dist/ to be tested, older than the latest release, would have
        // downloaded that release and replaced itself there.
        installURL = Updater.isInstalled(bundlePath: Bundle.main.bundlePath,
                                         home: Paths.userHome.path)
            ? Bundle.main.bundleURL : nil
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
        announceMarkers()
        guard installURL != nil else { return }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
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
                try? FileManager.default.removeItem(at: previous)
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
    /// else). The instance that says ready retires them.
    func acknowledgeBoot() {
        try? FileManager.default.removeItem(at: Self.updatedMarker)
        try? FileManager.default.removeItem(at: Self.rolledBackMarker)
    }

    private func announceMarkers() {
        let updated = Self.updatedMarker
        let rolledBack = Self.rolledBackMarker
        if let version = try? String(contentsOf: updated, encoding: .utf8) {
            if version == Lodestar.version {
                justUpdated = true
                Log.info("update", ["phase": "completed", "version": version])
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [voice] in
                    let (sentence, detail) = Voice.updated(version)
                    voice(sentence, detail, 1, false)
                }
            } else {
                // Applied, relaunched, and still not that version: the
                // release did not change the binary. v0.32.4 (2026-09-14)
                // was 0.32.3's build under a new label, and every check
                // re-applied it — 194 relaunches in a night, each one
                // restoring parked windows on the way out. Refused the way
                // a rollback is refused, until a newer release ships.
                try? FileManager.default.removeItem(at: updated)
                Self.writeMarker(version, to: Self.refusedFile, what: "the refusal tombstone",
                                 consequence: "this release will be offered, applied and relaunched again at the next check — a relaunch loop")
                Log.error("update to \(version) did not change the binary — still \(Lodestar.version); refusing it until a newer release ships")
            }
        }
        if let version = try? String(contentsOf: rolledBack, encoding: .utf8) {
            try? FileManager.default.removeItem(at: rolledBack)
            // The tombstone outlives the announcement: a release that could
            // not take the pid file must not be offered again, or every
            // check re-applies it and the watchdog rolls it back forever.
            Self.writeMarker(version, to: Self.refusedFile, what: "the refusal tombstone",
                             consequence: "this release will be offered and rolled back again at the next check — a relaunch loop")
            Log.error("update rolled back: \(version) never took the pid file — refusing it until a newer release ships")
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [flash] in
                flash("⚠ \(version) did not start, so Lodestar went back to \(Lodestar.version)")
            }
        }
    }

    /// The tag of a release that already failed its handover, if any.
    private var refusedTag: String? {
        try? String(contentsOf: Self.refusedFile, encoding: .utf8)
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
        var request = URLRequest(url: feed, timeoutInterval: 30)
        request.setValue("lodestar/\(Lodestar.version)", forHTTPHeaderField: "User-Agent")
        // Who is waiting decides how patiently the feed is asked: the
        // periodic check is nobody's; the menu item was pressed by someone
        // who will wait seconds for the answer (not a tap's instant
        // feedback), which is also the thirty seconds it always had.
        let urgency: Urgency = force ? .userInitiated : .background
        Task { [weak self] in
            guard let self else { return }
            var data: Data?
            var problem: String?
            do {
                data = try await withUrgency(urgency) { try await UpdateFeed.data(for: request, session: self.network) }
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
        guard Updater.shouldOffer(release, refusedTag: refusedTag) else {
            finishCheck(force: force,
                        note: "✓ \(release.tag) already failed to start here\nLodestar waits for a newer release",
                        log: "refusing \(release.tag): it was rolled back once")
            return
        }
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
        // Unpacking requires a sha256. Refuse before the fetch so a release
        // that names none — an older stable answer — is held back here.
        guard UpdateArchive.isSHA256(release.zipDigest) else {
            finishCheck(force: force, note: "✕ Could not check for updates",
                        log: "the release names no sha256")
            return
        }
        Log.info("update", ["phase": "downloading", "asset": release.zipName, "digest": "sha256"])
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

    private func downloadFailed(_ release: Updater.Release, _ error: any Error, force: Bool) {
        finishCheck(force: force, note: "✕ The update did not download",
                    log: "download failed (\(UpdateDownload.problem(error, release: release)))", failed: true)
    }

    private func stage(onWorker release: Updater.Release, force: Bool) {
        worker.async { self.stage(zip: Self.zipPath, release: release, force: force) }
    }

    /// Lights the mark as far as the download has come, from the downloading
    /// task to the main thread, once for each face that changes.
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
        // The digest is checked before a byte of the archive is written.
        // The download checked the same digest as it arrived; this is the
        // gate, so a file swapped in afterwards never gets unpacked.
        guard UpdateArchive.matches(file: zip, digest: release.zipDigest) else {
            failStage(force: force, log: "the zip has no sha256, or it does not match")
            return
        }
        let staging = Self.directory.appendingPathComponent("staged", isDirectory: true)
        do {
            try UpdateArchive.extract(zip, replacing: staging)
        } catch {
            failStage(force: force, log: "unpack failed (\(error))")
            return
        }
        try? FileManager.default.removeItem(at: zip)
        let bundle = staging.appendingPathComponent("lodestar.app")

        // The signature, then the version, then whether this Mac can run
        // it. Nothing is moved into place until these pass. The unpack
        // wrote only inside the fresh staging directory.
        guard step("codesign integrity check", force: force,
                   "/usr/bin/codesign", "--verify", "--strict", "--deep", bundle.path) else { return }
        guard step("signature check (this team's Developer ID)", force: force,
                   "/usr/bin/codesign", "--verify", "-R=\(Self.requirement)", bundle.path) else { return }
        let plist = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        guard let stagedVersion = plist?["CFBundleShortVersionString"] as? String,
              let staged = Updater.parseVersion(stagedVersion),
              Updater.sameVersion(staged, release.version) else {
            failStage(force: force, log: "staged bundle version does not match the release tag")
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
            clearStaging()
            DispatchQueue.main.async {
                self.phase = .idle
                self.flash("⚠ Lodestar \(stagedVersion) \(why), so this Mac stays on \(Lodestar.version)")
            }
            return
        }

        Log.info("update", ["phase": "staged", "version": stagedVersion])
        DispatchQueue.main.async {
            self.stagedBundle = bundle
            self.phase = .ready(version: stagedVersion)
            self.tryApply(force: force)
        }
    }

    private func failStage(force: Bool, log message: String) {
        Log.error("update staging: \(message)")
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
        try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent("download.zip"))
        try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent("staged"))
        try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent("staged.incoming"))
        try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent("staged.outgoing"))
    }

    /// How long one of the staging tools may take. `codesign` verifying a
    /// bundle takes seconds; two minutes is far past any healthy run, and
    /// short of leaving the update `.checking` for ever, which refuses
    /// every later check.
    static let toolDeadline: Duration = .seconds(120)

    /// One staging command, and the update failing if it does not pass
    /// or does not finish. Worker queue.
    private func step(_ what: String, force: Bool, _ launchPath: String, _ arguments: String...) -> Bool {
        switch Self.run(launchPath, arguments) {
        case .succeeded:
            return true
        case .failed:
            failStage(force: force, log: "\(what) failed")
        case .timedOut:
            failStage(force: force, log: "\(what) did not finish in \(Int(Self.toolDeadline.components.seconds)) s")
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
    static func run(_ launchPath: String, _ arguments: [String],
                    within deadline: Duration = toolDeadline) -> RunOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let held = HeldProcess(process)
        let outcome = OutcomeBox()
        let finished = DispatchSemaphore(value: 0)
        let name = URL(fileURLWithPath: launchPath).lastPathComponent
        Task.detached {
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
            finished.signal()
        }
        finished.wait()
        return outcome.value
    }

    private final class HeldProcess: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
        /// Ask it to stop, and make sure a few seconds on.
        func stop() {
            guard process.isRunning else { return }
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [process] in
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = RunOutcome.failed
        var value: RunOutcome { lock.withLock { stored } }
        func set(_ outcome: RunOutcome) { lock.withLock { stored = outcome } }
    }

    // MARK: - The swap

    private func tryApply(force: Bool) {
        guard case .ready(let version) = phase, let bundle = stagedBundle, let installURL else { return }
        if !force {
            guard enabled, Updater.mayApply(
                engineQuiet: engineQuiet(),
                secondsSinceActivity: Date().timeIntervalSince(lastActivity())
            ) else { return }
        }
        guard canSwap(installURL: installURL, force: force) else {
            standDown()
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
            // `bundle` was unpacked into an empty staging directory and
            // codesign verified it before this phase became `.ready`.
            // These two moves are the first time anything is put in place.
            try FileManager.default.moveItem(at: installURL, to: previous)
            try FileManager.default.moveItem(at: bundle, to: installURL)
        } catch {
            // Put the world back exactly as it was and stand down.
            if !FileManager.default.fileExists(atPath: installURL.path),
               FileManager.default.fileExists(atPath: previous.path) {
                try? FileManager.default.moveItem(at: previous, to: installURL)
            }
            Log.error("update swap failed: \(error)")
            standDown(force: force, note: "✕ The update did not install")
            return
        }

        let marker = Self.directory.appendingPathComponent("updated-to")
        Self.writeMarker(version, to: marker, what: "the updated-to marker",
                         consequence: "the new build will not announce the update")
        spawnWatchdog(app: installURL, previous: previous, version: version)
        stagedBundle = nil
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
    private func standDown(force: Bool = false, note: String? = nil) {
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
        spawnDetached(["/bin/bash", path.path, app.path, previous.path,
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
    rm -rf "$APP"
    mv "$PREVIOUS" "$APP"
    printf '%s' "$VERSION" > "$MARKERS/rolled-back"
    # -n: launch a fresh instance even though the old process may still
    # be running — its boot takes the pid file and announces the marker.
    # -g: behind the app in front, so keys typed meanwhile never reach it.
    open -g -n "$APP"
    """

    /// posix_spawn with SETSID: the child leads its own session, immune to
    /// the process-group teardown launchd performs when this job exits.
    private func spawnDetached(_ arguments: [String]) {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        let result = posix_spawn(&pid, arguments[0], nil, &attributes, &argv, environ)
        argv.forEach { free($0) }
        posix_spawnattr_destroy(&attributes)
        if result != 0 { Log.error("update watchdog spawn failed (\(result))") }
    }
}
