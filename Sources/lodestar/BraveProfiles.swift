import AppKit
import Foundation
import LodestarCore

/// Brave profile handling. Windows are matched by Brave's title suffix
/// ("… - Brave - <ProfileName>"), launches go through
/// `open -na … --args --profile-directory=<dir>`, with the display-name →
/// directory mapping read from Brave's Local State.
enum BraveProfiles {
    static let bundleID = "com.brave.Browser"
    static let appName = "Brave Browser"

    private static var directoryByName: [String: String] = [:]
    private static var loaded = false

    static func directory(forProfileNamed name: String) -> String? {
        loadIfNeeded()
        if let exact = directoryByName[name.lowercased()] { return exact }
        return nil
    }

    static func windowMatches(title: String, profile: String) -> Bool {
        title.lowercased().hasSuffix("- brave - \(profile.lowercased())")
            || title.lowercased() == "brave - \(profile.lowercased())"
    }

    /// Best alive window of this profile from the model.
    static func window(for profile: String, in model: WindowModel) -> WindowModel.Window? {
        let candidates = model.windows.values.filter {
            $0.isAlive && $0.bundleID == bundleID && windowMatches(title: $0.title, profile: profile)
        }
        if let focused = model.focusedWindow, candidates.contains(where: { $0.id == focused.id }) {
            return focused
        }
        return candidates.first
    }

    /// Open a new window of the profile (also launches Brave if needed).
    static func openWindow(profile: String) -> Bool {
        launch(profileDirectoryArgsFor: profile, url: nil)
    }

    /// Open a URL in the profile — Chromium hands it to an existing window
    /// of that profile as a new tab, or creates the window.
    static func openURL(_ url: String, profileDisplay: String) -> Bool {
        launch(profileDirectoryArgsFor: profileDisplay, url: url)
    }

    /// Display names the browser actually has right now, lowercased —
    /// ground truth for validating the config registry.
    static func knownDisplayNames() -> Set<String> {
        loadIfNeeded()
        return Set(directoryByName.keys)
    }

    private static func launch(profileDirectoryArgsFor profile: String, url: String?) -> Bool {
        guard let dir = directory(forProfileNamed: profile) else {
            Log.error("brave: no profile directory for '\(profile)'")
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        var arguments = ["-na", appName, "--args", "--profile-directory=\(dir)"]
        if let url { arguments.append(url) }
        process.arguments = arguments
        do {
            try process.run()
            return true
        } catch {
            Log.error("brave: open failed: \(error)")
            return false
        }
    }

    private static func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let localState = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BraveSoftware/Brave-Browser/Local State")
        guard let data = try? Data(contentsOf: localState),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else {
            Log.error("brave: could not read Local State")
            return
        }
        for (dir, info) in cache {
            guard let info = info as? [String: Any], let name = info["name"] as? String else { continue }
            directoryByName[name.lowercased()] = dir
        }
        Log.info("brave: profiles \(directoryByName)")
    }
}
