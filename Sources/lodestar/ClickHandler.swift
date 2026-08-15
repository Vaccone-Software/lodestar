import AppKit
import LodestarCore

/// Links clicked in other apps, once Lodestar stands as the http handler.
///
/// The whole premise is invisibility: same browser, same window, same speed,
/// until a rule you wrote diverts one. So this is written for the boring case
/// first. A link that matches nothing is handed to your saved browser with no
/// arguments and no new instance, which is one Apple Event to an app that is
/// already running — about as cheap as an indirection gets. Only a matched
/// rule pays for a profile launch, and only because targeting a Chromium
/// profile needs a command line, which needs a process.
///
/// Three rules hold this path together, and each of them is load-bearing:
///
/// - **Never `NSWorkspace.open(url)` without naming the app.** That goes back
///   through LaunchServices, which would hand the URL straight back to us,
///   forever. Every open here names its target.
/// - **Never touch the window model.** AX calls block on the target app's
///   event loop, so consulting the model would let one wedged app delay
///   somebody's link by seconds. Config and LaunchServices only.
/// - **Never place the window.** The web bar's opens are tiled because you
///   asked for them. A link someone sent you is not a request to rearrange
///   your layout.
final class ClickHandler {
    /// Rebuilt per link, so a config reload takes effect with nothing wired.
    var context: () -> WebContext = { WebContext() }
    /// Bundle id of the browser that was default before Lodestar took over.
    var savedBrowser: () -> String = { "" }
    var trace: () -> Bool = { false }
    var flash: (String) -> Void = { _ in }
    /// Receiving a link at all is proof we hold the browser role. If nothing
    /// recorded that — someone picked Lodestar in System Settings rather than
    /// through the menu — this adopts it before the link is routed, so even
    /// the first one lands where your rules say.
    var adoptIfUnconfigured: () -> Void = {}

    /// Every macOS install has Safari, so the chain always ends somewhere.
    /// A link must never simply vanish.
    private static let lastResort = "com.apple.Safari"

    func open(_ urls: [URL]) {
        for url in urls { open(url) }
    }

    private func open(_ url: URL) {
        var live = context()
        // Nothing recorded and no browser saved: never configured, rather than
        // deliberately stood down (which keeps its saved browser). Adopt, then
        // read again — the write applies the config synchronously.
        if !live.handlesClicks, savedBrowser().isEmpty {
            adoptIfUnconfigured()
            live = context()
        }
        switch ClickRouter.route(url.absoluteString, in: live) {
        case .passThrough:
            traceIfAsked(url, profile: nil, pattern: nil)
            handOff(url)
        case .profile(let profile, let pattern):
            traceIfAsked(url, profile: profile, pattern: pattern)
            // The proven path, unchanged: the same mechanism the web bar has
            // always used. It costs a process launch that Chromium forwards
            // and exits, which is the price of naming a profile at all.
            if !ChromiumProfiles.openURL(url.absoluteString, in: profile) {
                // The profile is gone from the browser. The link still has to
                // open, so it takes the ordinary road.
                handOff(url)
            }
        }
    }

    /// The ordinary road: your browser, the URL untouched, brought forward
    /// exactly as a click always did.
    private func handOff(_ url: URL) {
        guard let application = browserURL() else {
            // Nothing installed to hand it to at all. Say so rather than
            // swallowing a click.
            flash("✕ no browser to open that link — set web.clicks.browser")
            Log.error("click", ["handoff": "no browser"])
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: application,
                                configuration: configuration) { [flash] _, error in
            guard let error else { return }
            flash("✕ could not open that link")
            Log.error("click", ["handoff-failed": error.localizedDescription])
        }
    }

    private func browserURL() -> URL? {
        let saved = savedBrowser()
        if !saved.isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: saved) {
            return url
        }
        // Nothing recorded: somebody picked Lodestar in System Settings rather
        // than through the menu, so the step that saves your browser never
        // ran. Ask the system what else could have handled this.
        if let discovered = Self.discoverBrowser() { return discovered }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.lastResort)
    }

    /// The app that would have opened a link if Lodestar were not here:
    /// LaunchServices' own ranking of everything registered for https, minus
    /// ourselves. It is a guess — once we hold the role, the previous default
    /// is no longer distinguishable from any other candidate — so it is used
    /// to keep links working, and the boot check says so rather than leaving
    /// you to wonder where they went.
    static func discoverBrowser() -> URL? {
        guard let probe = URL(string: "https://example.com") else { return nil }
        let ours = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.urlsForApplications(toOpen: probe).first {
            Bundle(url: $0)?.bundleIdentifier != ours
        }
    }

    /// Off by default, and even on it records the host rather than the URL:
    /// the log is paste-able, and a path carries far more about you than a
    /// host does.
    private func traceIfAsked(_ url: URL, profile: BrowserProfile?, pattern: String?) {
        guard trace() else { return }
        Log.info("click", [
            "host": url.host() ?? "?",
            "profile": profile?.display ?? "pass-through",
            "matched": pattern ?? "-",
        ])
    }
}
