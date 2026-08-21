import Foundation

/// Which profile a web destination opens in, and — just as important — what
/// decided that. A surface showing only the answer leaves you unable to tell
/// a choice you made from something inferred, and only one of those can
/// change tomorrow.
public struct ProfileResolution: Equatable {
    /// What decided it, in precedence order.
    public enum Source: Equatable {
        /// The link carries a pinned profile.
        case pinned
        /// A rule matched, and this is the pattern that did it.
        case route(String)
        /// `web.fallback` names a profile.
        case fallback
        /// The profile of the browser window you were in last.
        case recent
        /// Nothing to go on: no rules, no fallback, no browser open.
        case none

        /// One word, for a chip.
        public var label: String {
            switch self {
            case .pinned: return "pinned"
            case .route: return "route"
            case .fallback: return "fallback"
            case .recent: return "recent"
            case .none: return "default"
            }
        }

        /// The same answer with room to say which rule — for the line that
        /// explains rather than labels.
        public var phrase: String {
            switch self {
            case .pinned: return "pinned"
            case .route(let pattern): return "matched \(pattern)"
            case .fallback: return "fallback"
            case .recent: return "most recent browser"
            case .none: return "default"
            }
        }

        /// The pattern that matched, when a rule is what decided this.
        public var routePattern: String? {
            if case .route(let pattern) = self { return pattern }
            return nil
        }
    }

    public let profile: BrowserProfile
    public let source: Source

    public init(profile: BrowserProfile, source: Source) {
        self.profile = profile
        self.source = source
    }
}

/// Everything the web bar's resolution and its ⌘K card need from the config,
/// gathered explicitly. Smaller than `Config`, and buildable in a test
/// without a config file.
public struct WebContext {
    public let links: [Config.WebLink]
    public let routes: [String: String]
    /// Canonical reference (`brave:xonar`) → profile: everything the
    /// config references plus everything the machine has.
    public let profiles: [String: BrowserProfile]
    public let fallback: String
    /// The profile of the most recently focused browser window, if any.
    public let mostRecent: BrowserProfile?
    /// Whether clicked links are ours to route at all.
    public let handlesClicks: Bool

    public init(links: [Config.WebLink] = [], routes: [String: String] = [:],
                profiles: [String: BrowserProfile] = [:], fallback: String = "most-recent",
                mostRecent: BrowserProfile? = nil, handlesClicks: Bool = false) {
        self.links = links
        self.routes = routes
        self.profiles = profiles
        self.fallback = fallback
        self.mostRecent = mostRecent
        self.handlesClicks = handlesClicks
    }

    public init(config: Config, mostRecent: BrowserProfile?) {
        self.init(links: config.webLinks, routes: config.webRoutes,
                  profiles: config.browserProfiles, fallback: config.webFallback,
                  mostRecent: mostRecent, handlesClicks: config.webHandleClicks)
    }

    /// Canonical references, sorted — the digit list's order, stable
    /// across opens.
    public var profileKeys: [String] { profiles.keys.sorted() }

    /// The profile a destination opens in: explicit pin, then rules (longest
    /// substring match), then the fallback, then the browser you were last
    /// in. The last resort is any known profile, so a destination always
    /// has somewhere to go.
    public func resolve(pinned: String?, routedOn text: String) -> ProfileResolution {
        if let pinned, let profile = profiles[pinned] {
            return ProfileResolution(profile: profile, source: .pinned)
        }
        if let pattern = WebRouting.routePattern(text, routes: routes),
           let key = routes[pattern], let profile = profiles[key] {
            return ProfileResolution(profile: profile, source: .route(pattern))
        }
        if fallback != "most-recent", let profile = profiles[fallback] {
            return ProfileResolution(profile: profile, source: .fallback)
        }
        if let recent = mostRecent {
            return ProfileResolution(profile: recent, source: .recent)
        }
        let any = profiles.values.min { $0.display < $1.display }
            ?? BrowserProfile(browser: .brave, display: "Default")
        return ProfileResolution(profile: any, source: .none)
    }
}
