import AppKit
import Foundation
import LodestarCore

/// Chromium profile handling, per browser. Windows are matched by the
/// title suffix Chromium stamps ("… - <Browser> - <ProfileName>"),
/// launches go through `open -na … --args --profile-directory=<dir>`,
/// with the display-name → directory mapping read from each browser's
/// Local State.
enum ChromiumProfiles {
    private static var directoriesByBrowser: [ChromiumBrowser: [String: String]] = [:]
    private static var namesByBrowser: [ChromiumBrowser: [String]] = [:]

    /// Forget every cached Local State read. Called on config reload so a
    /// menu-bar process that runs for weeks answers with the profiles the
    /// browser has now, not the ones it had at launch — a profile created
    /// yesterday must be offerable today without restarting Lodestar.
    static func invalidate() {
        directoriesByBrowser = [:]
        namesByBrowser = [:]
    }

    static func directory(for profile: BrowserProfile) -> String? {
        directories(for: profile.browser)[profile.display.lowercased()]
    }

    /// Best alive window of this profile from the model: the focused window
    /// if it matches, else the most recently focused match. Candidates come
    /// verified — Chromium never reports window death (FINDINGS §8), so the
    /// model must be asked through the paths that check.
    static func window(for profile: BrowserProfile, in model: WindowModel) -> WindowModel.Window? {
        let candidates = model.aliveWindows(bundleID: profile.browser.bundleID)
            .filter { profile.browser.windowMatches(title: $0.title, profile: profile.display) }
        if let focused = model.focusedWindow, candidates.contains(where: { $0.id == focused.id }) {
            return focused
        }
        return WindowModel.mostCurrent(candidates)
    }

    /// Open a new window of the profile (also launches the browser if needed).
    static func openWindow(_ profile: BrowserProfile) -> Bool {
        launch(profile, url: nil)
    }

    /// Open a URL in the profile — Chromium hands it to an existing window
    /// of that profile as a new tab, or creates the window.
    static func openURL(_ url: String, in profile: BrowserProfile) -> Bool {
        launch(profile, url: url)
    }

    /// Display names the browser actually has right now, lowercased —
    /// ground truth for validating references. Empty when the browser is
    /// not installed.
    static func knownDisplayNames(for browser: ChromiumBrowser) -> Set<String> {
        Set(directories(for: browser).keys)
    }

    /// The same names with the browser's own casing, sorted — for every
    /// surface a person reads.
    static func displayNames(for browser: ChromiumBrowser) -> [String] {
        _ = directories(for: browser) // fills both caches
        return (namesByBrowser[browser] ?? []).sorted {
            $0.lowercased() < $1.lowercased()
        }
    }

    /// Every profile the installed browsers actually have.
    static func detected() -> [BrowserProfile] {
        ChromiumBrowser.allCases.flatMap { browser in
            displayNames(for: browser).map {
                BrowserProfile(browser: browser, display: $0)
            }
        }
    }

    private static func launch(_ profile: BrowserProfile, url: String?) -> Bool {
        guard let dir = directory(for: profile) else {
            Log.error("\(profile.browser.rawValue): no profile directory for '\(profile.display)'")
            return false
        }
        // A trashed browser leaves its Local State behind, so the profile
        // still resolves while `open` has nothing to open — and a routed
        // link must never vanish on a success that was never verified.
        // Asking LaunchServices for the app is the synchronous truth.
        guard NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: profile.browser.bundleID) != nil else {
            Log.error("\(profile.browser.rawValue): app is not installed")
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        var arguments = ["-na", profile.browser.appName, "--args", "--profile-directory=\(dir)"]
        if let url { arguments.append(url) }
        process.arguments = arguments
        do {
            try process.run()
            return true
        } catch {
            Log.error("\(profile.browser.rawValue): open failed: \(error)")
            return false
        }
    }

    private static func directories(for browser: ChromiumBrowser) -> [String: String] {
        if let cached = directoriesByBrowser[browser] { return cached }
        let localState = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(browser.localStateSubpath)")
        let loaded: [String: String]
        if let data = try? Data(contentsOf: localState) {
            loaded = ChromiumBrowser.profileDirectories(fromLocalState: data)
            namesByBrowser[browser] = ChromiumBrowser.profileNames(fromLocalState: data)
            Log.info("\(browser.rawValue): profiles \(loaded)")
        } else {
            // Referenced in config but not installed (or never launched).
            loaded = [:]
            namesByBrowser[browser] = []
            Log.info("\(browser.rawValue): no Local State — treating as no profiles")
        }
        directoriesByBrowser[browser] = loaded
        return loaded
    }
}
