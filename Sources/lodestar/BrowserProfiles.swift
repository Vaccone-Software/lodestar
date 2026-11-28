import AppKit
import Foundation
import LodestarCore
import Stoic
import StoicProcess

/// Browser profiles, per browser family: what each browser has, which of
/// its windows belongs to which profile, and how a profile is opened.
///
/// - Chromium (Brave, Chrome, Edge): Local State's info_cache, the title
///   suffix "… - <Browser> - <Profile>", `open -na … --args
///   --profile-directory=<dir>`.
/// - Safari: File ▸ New Window's items, read over accessibility while
///   Safari runs and kept on disk for when it does not; the title prefix
///   "<Profile> — "; a new tab or window typed into through accessibility
///   (`SafariDriver`).
/// - Firefox: profiles.ini and its profile-group database, read only once
///   `web.firefox-profiles` is on; the profile a window's process holds
///   (`FirefoxLocks`); `open -na Firefox --args --profile <dir>`.
///
/// Main thread only, like the window model it reads.
enum BrowserProfiles {
    /// Whether Firefox's profiles are read at all (`web.firefox-profiles`),
    /// set from the config at launch and at every reload.
    static var firefoxEnabled = false {
        didSet { if firefoxEnabled != oldValue { listings[.firefox] = nil; refusedAt[.firefox] = nil } }
    }
    /// A browser's listing changed outside a reload — a refusal lifted,
    /// Safari's menu read — so the config's registry should take the
    /// profiles in. Called on main, a turn after the change.
    static var onChange: (() -> Void)?

    private static var listings: [Browser: ProfileListing] = [:]
    private static var lastState: [Browser: String] = [:]
    /// When each refused or unreadable browser was last asked, and what it
    /// said. Neither is kept as the answer — a refusal can be lifted at any
    /// moment, and a database Firefox is half-way through writing reads
    /// fine a moment later — but each is asked again at most every few
    /// seconds: Firefox's windows are matched through its listing, on every
    /// window event.
    private static var refusedAt: [Browser: (asked: ContinuousClock.Instant, answer: ProfileListing)] = [:]
    private static let refusalPatience: Duration = .seconds(5)

    /// Forget every cached read. Called on config reload so a menu-bar
    /// process that runs for weeks answers with the profiles the browser
    /// has now, not the ones it had at launch — a profile created
    /// yesterday must be offerable today without restarting Lodestar.
    static func invalidate() {
        listings = [:]
        refusedAt = [:]
        FirefoxLocks.forget()
    }

    /// What the browser lists right now.
    static func listing(for browser: Browser) -> ProfileListing {
        if let cached = listings[browser] { return cached }
        let now = ContinuousClock.now
        if let failed = refusedAt[browser], failed.asked.duration(to: now) < refusalPatience {
            return failed.answer
        }
        let read = readListing(browser)
        if read.isTransient {
            refusedAt[browser] = (now, read)
        } else {
            refusedAt[browser] = nil
            // Safari's answer lives in its driver, which is told of a new
            // menu as it reads one.
            if browser.family != .safari { listings[browser] = read }
        }
        note(browser, read)
        return read
    }

    /// Re-read Safari's menu now if it runs: once at launch, since a Safari
    /// already open will not come forward to be read.
    static func readSafariIfRunning() {
        SafariDriver.shared.refresh { note(.safari, SafariDriver.shared.listing()) }
    }

    private static func readListing(_ browser: Browser) -> ProfileListing {
        switch browser.family {
        case .chromium:
            guard let subpath = browser.localStateSubpath else { return .notInstalled }
            return .chromium(localState: Paths.userHome
                .appendingPathComponent("Library/Application Support/\(subpath)"))
        case .firefox:
            guard firefoxEnabled else { return .off }
            return FirefoxProfiles.listing(root: FirefoxProfiles.root(home: Paths.userHome))
        case .safari:
            return SafariDriver.shared.listing()
        }
    }

    /// One log line per change of a browser's answer, and the registry told
    /// when a later read found something the first did not.
    private static func note(_ browser: Browser, _ listing: ProfileListing) {
        let state: String
        switch listing {
        case .profiles(let listed): state = "profiles \(listed.map(\.name).sorted())"
        default: state = listing.state
        }
        let previous = lastState.updateValue(state, forKey: browser)
        guard previous != state else { return }
        Log.info("\(browser.rawValue): \(state)")
        if previous != nil, let onChange {
            DispatchQueue.main.async { onChange() }
        }
    }

    private static var activation: NSObjectProtocol?

    /// Ask again whenever a browser comes to the front. Once, at launch.
    static func observeActivations() {
        guard activation == nil else { return }
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            browserActivated(bundleID: app?.bundleIdentifier)
        }
    }

    /// A browser came to the front: the moment to ask again what it was
    /// refused or never shown, and to read Safari's menu, which only a
    /// running Safari has.
    static func browserActivated(bundleID: String?) {
        guard let browser = Browser(bundleID: bundleID) else { return }
        switch browser.family {
        case .safari:
            SafariDriver.shared.refresh { note(.safari, SafariDriver.shared.listing()) }
        case .chromium, .firefox:
            if listings[browser] == nil { _ = listing(for: browser) }
        }
    }

    /// The listed name a reference means, case folded.
    private static func listed(_ profile: BrowserProfile) -> ListedProfile? {
        let wanted = profile.display.lowercased()
        return listing(for: profile.browser).profiles.first { $0.name.lowercased() == wanted }
    }

    /// What the browser needs to open the profile: Chromium's directory,
    /// Safari's menu item, Firefox's folder.
    static func locator(for profile: BrowserProfile) -> String? {
        listed(profile)?.locator
    }

    /// Display names the browser actually has right now, lowercased —
    /// ground truth for validating references. Empty when the browser is
    /// not installed, refused, or not read.
    static func knownDisplayNames(for browser: Browser) -> Set<String> {
        Set(listing(for: browser).profiles.map { $0.name.lowercased() })
    }

    /// The same names with the browser's own casing, sorted — for every
    /// surface a person reads.
    static func displayNames(for browser: Browser) -> [String] {
        listing(for: browser).profiles.map(\.name).sorted { $0.lowercased() < $1.lowercased() }
    }

    /// Every profile the installed browsers actually have.
    static func detected() -> [BrowserProfile] {
        Browser.allCases.flatMap { browser in
            displayNames(for: browser).map { BrowserProfile(browser: browser, display: $0) }
        }
    }

    // MARK: - Windows

    /// Whether a window belongs to the profile.
    static func matches(_ window: WindowModel.Window, _ profile: BrowserProfile) -> Bool {
        guard window.bundleID == profile.browser.bundleID else { return false }
        switch profile.browser.family {
        case .chromium:
            return profile.browser.windowMatches(title: window.title, profile: profile.display)
        case .safari:
            let names = displayNames(for: .safari)
            guard !names.isEmpty else {
                return window.title.lowercased().hasPrefix(profile.display.lowercased() + " — ")
            }
            return SafariProfiles.profile(ofTitle: window.title, among: names)?.lowercased()
                == profile.display.lowercased()
        case .firefox:
            guard let directory = locator(for: profile) else { return false }
            return FirefoxLocks.directory(of: window.pid) == directory
        }
    }

    /// Best alive window of this profile from the model: the focused window
    /// if it matches, else the most recently focused match. Candidates come
    /// verified — Chromium never reports window death (FINDINGS §8), so the
    /// model must be asked through the paths that check.
    static func window(for profile: BrowserProfile, in model: WindowModel) -> WindowModel.Window? {
        let candidates = model.aliveWindows(bundleID: profile.browser.bundleID)
            .filter { matches($0, profile) }
        if let focused = model.focusedWindow, candidates.contains(where: { $0.id == focused.id }) {
            return focused
        }
        return WindowModel.mostCurrent(candidates)
    }

    // MARK: - Opening

    /// Open a new window of the profile (also launches the browser if
    /// needed). `completion` runs on main with whether it was handed over.
    static func openWindow(_ profile: BrowserProfile, completion: @escaping (Bool) -> Void) {
        open(profile, url: nil, completion: completion)
    }

    /// Open a URL in the profile: a new tab of a window it has, or a new
    /// window. `completion` runs on main — at once for Chromium and
    /// Firefox, whose launches are handed to LaunchServices and not
    /// followed further, and after the tab is typed into for Safari.
    static func openURL(_ url: String, in profile: BrowserProfile, completion: @escaping (Bool) -> Void) {
        open(profile, url: url, completion: completion)
    }

    private static func open(_ profile: BrowserProfile, url: String?, completion: @escaping (Bool) -> Void) {
        let browser = profile.browser
        // A trashed browser leaves its profile list behind, so the profile
        // still resolves while `open` has nothing to open — and a routed
        // link must never vanish on a success that was never verified.
        // Asking LaunchServices for the app is the synchronous truth.
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) != nil else {
            Log.error("\(browser.rawValue): app is not installed")
            completion(false)
            return
        }
        // Safari reads its live menu as it opens, so a profile made since
        // Safari last came forward still opens; the others need the
        // locator from their list.
        guard let locator = browser.family == .safari ? profile.display : locator(for: profile) else {
            Log.error("\(browser.rawValue): no profile named '\(profile.display)' "
                + "(\(listing(for: browser).state))")
            completion(false)
            return
        }
        switch browser.family {
        case .chromium:
            var arguments = ["-na", browser.appName, "--args", "--profile-directory=\(locator)"]
            if let url { arguments.append(url) }
            completion(launch(browser, arguments))
        case .firefox:
            // A running profile takes the hand-off and opens a tab (or,
            // with no URL, a window); one not running starts on its own
            // folder, with no chooser. Never -P (it opens the chooser for
            // a profile-manager profile) and never -no-remote (it breaks
            // the hand-off).
            var arguments = ["-na", browser.appName, "--args", "--profile", locator]
            arguments += url.map { [$0] } ?? ["--new-window", "about:newtab"]
            completion(launch(browser, arguments))
        case .safari:
            SafariDriver.shared.open(profile: profile.display, url: url, completion: completion)
        }
    }

    private static func launch(_ browser: Browser, _ arguments: [String]) -> Bool {
        do {
            // `open` hands the launch to LaunchServices and returns; the
            // browser is not its child, so nothing here can stop it.
            try SystemEvents.start(Programs.quiet("/usr/bin/open", arguments), timeout: .seconds(30),
                                   what: "\(browser.rawValue): open")
            return true
        } catch {
            Log.error("\(browser.rawValue): open failed: \(error)")
            return false
        }
    }
}

/// Which Firefox profile a process runs, by the profile lock it holds.
/// Firefox runs one process per profile under one bundle id, and its
/// window titles name the profile in no fixed place (and not at all with
/// one profile), so the lock is the honest answer. Remembered per process —
/// pid and start time, since a pid is handed out again — and only once
/// found: a process just starting holds its temporary lock before its
/// profile's.
enum FirefoxLocks {
    private static var held: [pid_t: (started: Int64, directory: String)] = [:]
    /// Processes that held no listed profile's lock when last asked, and
    /// when: asked again only after a moment, since every window event of
    /// theirs would otherwise walk all their open files again.
    private static var missed: [pid_t: ContinuousClock.Instant] = [:]
    private static let missPatience: Duration = .seconds(2)

    static func forget() {
        held = [:]
        missed = [:]
    }

    static func directory(of pid: pid_t) -> String? {
        let started = SystemProcesses().identity(of: pid)?.started
        if let hit = held[pid], hit.started == started { return hit.directory }
        let now = ContinuousClock.now
        if let at = missed[pid], at.duration(to: now) < missPatience { return nil }
        let known = Set(BrowserProfiles.listing(for: .firefox).profiles.map(\.locator))
        guard !known.isEmpty,
              let directory = FirefoxProfiles.profileDirectory(lockPaths: FirefoxProfiles.lockPaths(pid: pid),
                                                               known: known) else {
            missed[pid] = now
            return nil
        }
        missed[pid] = nil
        if let started { held[pid] = (started, directory) }
        return directory
    }
}
