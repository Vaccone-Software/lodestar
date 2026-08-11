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
    /// ground truth for validating the config registry. Empty when the
    /// browser is not installed.
    static func knownDisplayNames(for browser: ChromiumBrowser) -> Set<String> {
        Set(directories(for: browser).keys)
    }

    private static func launch(_ profile: BrowserProfile, url: String?) -> Bool {
        guard let dir = directory(for: profile) else {
            Log.error("\(profile.browser.rawValue): no profile directory for '\(profile.display)'")
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
            Log.info("\(browser.rawValue): profiles \(loaded)")
        } else {
            // Referenced in config but not installed (or never launched).
            loaded = [:]
            Log.info("\(browser.rawValue): no Local State — treating as no profiles")
        }
        directoriesByBrowser[browser] = loaded
        return loaded
    }
}
