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
        guard route("https://selfcheck.invalid/x", in: standingDown) == .passThrough else {
            return false
        }
        // A build that would hand a link back to itself is a build that can
        // take the machine's focus hostage; it does not get to ship either.
        return handoffBrowser(Lodestar.bundleID) == nil
    }

    /// The browser an unrouted link may be handed to, or nil when the
    /// recorded answer is unusable.
    ///
    /// Naming ourselves is not hypothetical. The value is written by an
    /// automatic observation of your default browser, and one bad write is
    /// permanent, because the same write is what stops it happening twice.
    /// What follows is a closed circuit: macOS hands us the link because we
    /// hold the http role, `handOff` hands it straight back to us, and every
    /// lap arrives with `activates: true`. Measured on a real machine, that
    /// ran at eighty-seven laps a second and ended only when Lodestar was
    /// quit. Standing down does not save it either — a transparent Lodestar
    /// still receives the link and still passes it through.
    ///
    /// Nil means "nothing recorded", which is a state the click path already
    /// knows how to survive: discovery, then Safari.
    public static func handoffBrowser(_ saved: String) -> String? {
        guard !saved.isEmpty, saved != Lodestar.bundleID else { return nil }
        return saved
    }
}

/// A ceiling on how often one link may be handed off.
///
/// Every other guard here stops the loop at a cause — a nil-prone
/// comparison, a config value, a write. This one stops it at the symptom,
/// which is the only guard that survives a cause nobody predicted.
///
/// The budget expires on *quiet*, not on elapsed time. Measured from first
/// sighting instead, a self-feeding circuit simply waits out each window and
/// re-arms: the first draft of this throttled the real failure from eighty-
/// seven laps a second to a steady two a second, forever, which is the same
/// complaint at a lower volume. Measured from the last sighting, the circuit
/// keeps its own entry alive, spends the budget once, and dies — and because
/// the feed *is* our own hand-off, refusing it is what makes the next lap
/// never arrive. Nothing then touches the entry, so it ages out on its own.
///
/// The ceiling is set where no person can reach it: twenty opens of one
/// identical URL with never a ten-second pause. A circuit reaches it in
/// under a fifth of a second.
///
/// Pure and time-injected, so the behaviour is testable without waiting.
public struct ClickLoopGuard {
    /// How quiet a link must go before its budget is restored, and how many
    /// hand-offs that budget is worth.
    public static let window: TimeInterval = 10
    public static let limit = 20

    private var spent: [String: (count: Int, last: TimeInterval)] = [:]

    public init() {}

    /// True while this link may still be handed off. A refusal is a fuse and
    /// not a ban: once the laps stop arriving the entry ages out, and the
    /// same link clicked again later opens normally.
    public mutating func admit(_ url: String, at now: TimeInterval) -> Bool {
        spent = spent.filter { now - $0.value.last < Self.window }
        let count = (spent[url]?.count ?? 0) + 1
        spent[url] = (count, now)
        return count <= Self.limit
    }

    /// How many links are being remembered — the pruning rule's own witness.
    public var tracked: Int { spent.count }
}
