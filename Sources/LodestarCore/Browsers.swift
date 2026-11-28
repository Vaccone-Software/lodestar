import Foundation

/// How a browser keeps its profiles, which decides how Lodestar lists them,
/// tells their windows apart and opens them.
public enum BrowserFamily: Equatable, Sendable {
    /// Profiles in Local State's info_cache, windows titled
    /// "… - <Browser> - <Profile>", `open -na … --args --profile-directory=`.
    case chromium
    /// Profiles in File ▸ New Window, windows titled "<Profile> — …", opened
    /// through accessibility. One process for every profile.
    case safari
    /// Profiles in profiles.ini and its profile-group database, one process
    /// per profile (told apart by the lock it holds), `open -na Firefox
    /// --args --profile <dir>`.
    case firefox
}

/// The browsers Lodestar can address by profile. Arc is deliberately
/// absent — it does not stamp profiles into window titles, so summoning
/// could never find its windows honestly.
public enum Browser: String, CaseIterable, Equatable, Sendable {
    case brave, chrome, edge, safari, firefox

    public var family: BrowserFamily {
        switch self {
        case .brave, .chrome, .edge: return .chromium
        case .safari: return .safari
        case .firefox: return .firefox
        }
    }

    /// The browser for an app, by its bundle id.
    public init?(bundleID: String?) {
        guard let bundleID, let browser = Browser.allCases.first(where: { $0.bundleID == bundleID }) else {
            return nil
        }
        self = browser
    }

    /// The app name as installed in /Applications.
    public var appName: String {
        switch self {
        case .brave: return "Brave Browser"
        case .chrome: return "Google Chrome"
        case .edge: return "Microsoft Edge"
        case .safari: return "Safari"
        case .firefox: return "Firefox"
        }
    }

    public var bundleID: String {
        switch self {
        case .brave: return "com.brave.Browser"
        case .chrome: return "com.google.Chrome"
        case .edge: return "com.microsoft.edgemac"
        case .safari: return "com.apple.Safari"
        case .firefox: return "org.mozilla.firefox"
        }
    }

    /// The name Chromium stamps into window titles; nil outside the family.
    var titleName: String? {
        switch self {
        case .brave: return "Brave"
        case .chrome: return "Google Chrome"
        case .edge: return "Microsoft Edge"
        case .safari, .firefox: return nil
        }
    }

    /// Short human label for guides, chips, and flashes.
    public var label: String {
        switch self {
        case .brave: return "Brave"
        case .chrome: return "Chrome"
        case .edge: return "Edge"
        case .safari: return "Safari"
        case .firefox: return "Firefox"
        }
    }

    /// Local State location under ~/Library/Application Support; nil
    /// outside the Chromium family.
    public var localStateSubpath: String? {
        switch self {
        case .brave: return "BraveSoftware/Brave-Browser/Local State"
        case .chrome: return "Google/Chrome/Local State"
        case .edge: return "Microsoft Edge/Local State"
        case .safari, .firefox: return nil
        }
    }

    /// Chromium's title convention. Always false outside the family: a
    /// Safari window is told by its title's prefix against the profiles
    /// Safari lists (`SafariProfiles.profile(ofTitle:among:)`), and a
    /// Firefox window by the profile its process holds.
    public func windowMatches(title: String, profile: String) -> Bool {
        guard let titleName else { return false }
        let lowered = title.lowercased()
        let suffix = "\(titleName.lowercased()) - \(profile.lowercased())"
        return lowered.hasSuffix("- \(suffix)") || lowered == suffix
    }

    /// Profile display name (lowercased) → profile directory, from a Local
    /// State file's bytes. Empty on any malformation — an unreadable
    /// browser simply has no known profiles.
    public static func profileDirectories(fromLocalState data: Data) -> [String: String] {
        var directories: [String: String] = [:]
        for (name, directory) in localStateEntries(data) {
            directories[name.lowercased()] = directory
        }
        return directories
    }

    /// The profile display names exactly as the browser writes them —
    /// casing intact, for every surface a person reads. Matching stays
    /// case-insensitive; showing stays faithful.
    public static func profileNames(fromLocalState data: Data) -> [String] {
        localStateEntries(data).map(\.name)
    }

    /// (display name, directory) for every named entry of info_cache.
    static func localStateEntries(_ data: Data) -> [(name: String, directory: String)] {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            // Malformed bytes are a browser with no known profiles, never a
            // fault: the doctor's "no profile named" is the place it shows.
            return []
        }
        guard let object = json as? [String: Any],
              let profile = object["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else { return [] }
        return cache.compactMap { directory, info in
            guard let name = (info as? [String: Any])?["name"] as? String else { return nil }
            return (name, directory)
        }
    }
}

/// A browser profile, named the way the config references it: the browser
/// and the profile's own display name, written `brave:Xonar`. There is no
/// registry between a reference and the browser — the reference carries
/// everything, and whether the profile actually exists is a ground-truth
/// question the doctor asks the browser.
public struct BrowserProfile: Equatable {
    public let browser: Browser
    public let display: String

    public init(browser: Browser, display: String) {
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
        for browser in Browser.allCases
        where trimmed.lowercased().hasPrefix("\(browser.rawValue):") {
            let name = String(trimmed.dropFirst(browser.rawValue.count + 1))
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return BrowserProfile(browser: browser, display: name)
        }
        return nil
    }
}

/// One profile as its browser lists it: the name a person reads, and what
/// the browser needs to open it — a Chromium profile directory, a Safari
/// menu item's identifier, or a Firefox profile's absolute directory.
public struct ListedProfile: Equatable, Sendable {
    public let name: String
    public let locator: String

    public init(name: String, locator: String) {
        self.name = name
        self.locator = locator
    }
}

/// What reading a browser's profiles found. A refusal is its own answer,
/// never "no profiles": macOS refuses another app's data until the person
/// turns Lodestar on for that browser in Files & Folders, and it never asks.
/// The first refused read is what puts the switch there.
public enum ProfileListing: Equatable, Sendable {
    case profiles([ListedProfile])
    /// The browser's profile list is not on this Mac.
    case notInstalled
    /// macOS refused the read (Privacy & Security → Files & Folders).
    case refused
    /// Safari has not been seen running, so its menu has not been read.
    case notSeen
    /// Firefox profiles are off (`web.firefox-profiles`), so nothing of
    /// Firefox's is read.
    case off
    /// The list is there and readable but not understood.
    case unreadable(String)

    public var profiles: [ListedProfile] {
        if case .profiles(let listed) = self { return listed }
        return []
    }

    /// A refusal or an unreadable list: an answer that can change at any
    /// moment, so it is asked again rather than kept.
    public var isTransient: Bool {
        switch self {
        case .refused, .unreadable: return true
        default: return false
        }
    }

    /// One word for the log and the doctor.
    public var state: String {
        switch self {
        case .profiles(let listed): return "\(listed.count) profiles"
        case .notInstalled: return "not installed"
        case .refused: return "refused"
        case .notSeen: return "not seen"
        case .off: return "off"
        case .unreadable(let reason): return "unreadable: \(reason)"
        }
    }

    /// A file read's failure, sorted: a refusal from one that is simply not
    /// there. Anything else is unreadable, and says what it was.
    public static func failure(_ error: Error) -> ProfileListing {
        let ns = error as NSError
        if let posix = (ns.userInfo[NSUnderlyingErrorKey] as? NSError), posix.domain == NSPOSIXErrorDomain {
            return failure(errno: Int32(posix.code), describing: error)
        }
        if ns.domain == NSPOSIXErrorDomain { return failure(errno: Int32(ns.code), describing: error) }
        if ns.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: ns.code) {
            case .fileReadNoPermission: return .refused
            case .fileReadNoSuchFile, .fileNoSuchFile: return .notInstalled
            default: break
            }
        }
        return .unreadable("\(ns.domain) \(ns.code)")
    }

    public static func failure(errno code: Int32, describing error: Error? = nil) -> ProfileListing {
        switch code {
        case EPERM, EACCES: return .refused
        case ENOENT, ENOTDIR: return .notInstalled
        default: return .unreadable(error.map { "\($0)" } ?? "errno \(code)")
        }
    }

    /// A Chromium browser's profiles, from its Local State.
    public static func chromium(localState url: URL) -> ProfileListing {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return failure(error)
        }
        return .profiles(Browser.localStateEntries(data)
            .map { ListedProfile(name: $0.name, locator: $0.directory) })
    }
}
