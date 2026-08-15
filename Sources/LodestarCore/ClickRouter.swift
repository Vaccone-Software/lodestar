import Foundation

/// Where a link clicked in another app should go.
///
/// The premise of the whole feature is that nothing changes. Lodestar sitting
/// in front of your browser has to be invisible: same browser, same window,
/// same speed, until a rule you wrote says otherwise. So the interesting
/// answer is the rare one, and doing nothing is the default rather than a
/// safety net bolted on afterwards.
public enum ClickRoute: Equatable {
    /// No rule applies. Hand the URL to the saved browser exactly as macOS
    /// would have, unmodified, unmanaged, and let it look like it always did.
    case passThrough
    /// A rule matched. Open in this profile; `pattern` is what matched, for
    /// the opt-in trace and for nothing else.
    case profile(BrowserProfile, pattern: String)
}

/// The decision for a clicked link. Pure, and deliberately narrow: it reads
/// the route table and the profile registry, and nothing else.
///
/// It is narrow because of what it must never do. This runs on the path
/// between a click and a browser, so it may not touch the window model — AX
/// calls block on the target app's event loop, and one wedged app must never
/// be able to delay somebody's link. It also may not consult `web.fallback`,
/// `most-recent`, or the named links: those exist for text *you typed into
/// the bar*, where you asked Lodestar a question. A clicked link that matches
/// no rule is not a question, and answering it would be the bug.
public enum ClickRouter {
    /// The decision, or `.passThrough` when there isn't one to make.
    public static func route(_ url: String, in context: WebContext) -> ClickRoute {
        // Standing down: still the registered handler, but a transparent one.
        // One config line restores the old world without a trip through
        // System Settings.
        guard context.handlesClicks else { return .passThrough }
        // Only the web. Anything else was never ours, and a scheme we do not
        // recognise is not something to be clever about.
        let lowered = url.lowercased()
        guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") else {
            return .passThrough
        }
        guard let pattern = WebRouting.routePattern(url, routes: context.routes),
              let key = context.routes[pattern] else { return .passThrough }
        // A rule naming a profile that no longer exists — a renamed browser
        // profile, say — is a config problem the doctor reports at reload. It
        // is not a reason to strand the link.
        guard let profile = context.profiles[key] else { return .passThrough }
        return .profile(profile, pattern: pattern)
    }

    /// Does this build actually route?
    ///
    /// Asked at boot, against a synthetic table rather than the user's, so it
    /// checks the code and not the config. The update watchdog blesses a
    /// successor for taking the pid file, which is the right bar for a window
    /// manager: a build that cannot place a window is annoying and obvious.
    /// A build that cannot route a link is neither — it fails silently, in
    /// other people's apps, on a machine where every link now depends on us.
    /// So while Lodestar holds the browser role, "it booted" is not enough:
    /// it has to answer this too, or it gets rolled back.
    public static func selfCheck() -> Bool {
        let profile = BrowserProfile(browser: .brave, display: "Self Check")
        let live = WebContext(routes: ["selfcheck.invalid": "probe"],
                              profiles: ["probe": profile], handlesClicks: true)
        guard route("https://selfcheck.invalid/x", in: live)
            == .profile(profile, pattern: "selfcheck.invalid") else { return false }
        guard route("https://elsewhere.invalid", in: live) == .passThrough else { return false }
        let standingDown = WebContext(routes: ["selfcheck.invalid": "probe"],
                                      profiles: ["probe": profile], handlesClicks: false)
        return route("https://selfcheck.invalid/x", in: standingDown) == .passThrough
    }
}
