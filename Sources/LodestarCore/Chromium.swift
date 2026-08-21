import Foundation

/// The Chromium family Lodestar can address by profile. Every member
/// shares the upstream behaviors the plumbing relies on: profiles listed
/// in Local State's info_cache, windows titled "… - <Browser> - <Profile>"
/// once several profiles exist, and `open -na … --args
/// --profile-directory=` targeting. Arc is deliberately absent — it does
/// not stamp profiles into window titles, so summoning could never find
/// its windows honestly.
public enum ChromiumBrowser: String, CaseIterable, Equatable {
    case brave, chrome, edge

    /// The app name as installed in /Applications.
    public var appName: String {
        switch self {
        case .brave: return "Brave Browser"
        case .chrome: return "Google Chrome"
        case .edge: return "Microsoft Edge"
        }
    }

    public var bundleID: String {
        switch self {
        case .brave: return "com.brave.Browser"
        case .chrome: return "com.google.Chrome"
        case .edge: return "com.microsoft.edgemac"
        }
    }

    /// The name Chromium stamps into window titles.
    var titleName: String {
        switch self {
        case .brave: return "Brave"
        case .chrome: return "Google Chrome"
        case .edge: return "Microsoft Edge"
        }
    }

    /// Short human label for guides, chips, and flashes.
    public var label: String {
        switch self {
        case .brave: return "Brave"
        case .chrome: return "Chrome"
        case .edge: return "Edge"
        }
    }

    /// Local State location under ~/Library/Application Support.
    public var localStateSubpath: String {
        switch self {
        case .brave: return "BraveSoftware/Brave-Browser/Local State"
        case .chrome: return "Google/Chrome/Local State"
        case .edge: return "Microsoft Edge/Local State"
        }
    }

    public func windowMatches(title: String, profile: String) -> Bool {
        let lowered = title.lowercased()
        let suffix = "\(titleName.lowercased()) - \(profile.lowercased())"
        return lowered.hasSuffix("- \(suffix)") || lowered == suffix
    }

    /// Profile display name (lowercased) → profile directory, from a Local
    /// State file's bytes. Empty on any malformation — an unreadable
    /// browser simply has no known profiles.
    public static func profileDirectories(fromLocalState data: Data) -> [String: String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else { return [:] }
        var directories: [String: String] = [:]
        for (directory, info) in cache {
            guard let info = info as? [String: Any], let name = info["name"] as? String else { continue }
            directories[name.lowercased()] = directory
        }
        return directories
    }

    /// The profile display names exactly as the browser writes them —
    /// casing intact, for every surface a person reads. Matching stays
    /// case-insensitive; showing stays faithful.
    public static func profileNames(fromLocalState data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else { return [] }
        return cache.values.compactMap { ($0 as? [String: Any])?["name"] as? String }
    }
}

/// A browser profile, named the way the config references it: the browser
/// and the profile's own display name, written `brave:Xonar`. There is no
/// registry between a reference and the browser — the reference carries
/// everything, and whether the profile actually exists is a ground-truth
/// question the doctor asks the browser.
public struct BrowserProfile: Equatable {
    public let browser: ChromiumBrowser
    public let display: String

    public init(browser: ChromiumBrowser, display: String) {
        self.browser = browser
        self.display = display
    }

    /// The config line for this profile, casing intact.
    public var reference: String { "\(browser.rawValue):\(display)" }

    /// The lookup key a reference resolves under. Case folds away so
    /// `brave:xonar` and `brave:Xonar` are the same profile — the browser
    /// itself matches names case-insensitively everywhere Lodestar asks.
    public var canonical: String { reference.lowercased() }

    /// A written reference, or nil when it is not `browser:name` for a
    /// browser Lodestar can address.
    public static func parse(reference raw: String) -> BrowserProfile? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        for browser in ChromiumBrowser.allCases
        where trimmed.lowercased().hasPrefix("\(browser.rawValue):") {
            let name = String(trimmed.dropFirst(browser.rawValue.count + 1))
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return BrowserProfile(browser: browser, display: name)
        }
        return nil
    }
}
