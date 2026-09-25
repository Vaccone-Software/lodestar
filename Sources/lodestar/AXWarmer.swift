import AppKit
import ApplicationServices
import Foundation

/// Chromium and Electron build no accessibility tree until an assistive
/// client announces itself — and then they build it *lazily*, over
/// seconds, and **tear it down again after idle minutes** (measured: a
/// window that answered two thousand nodes at noon answered four by
/// night). So warming is not an event, it is a pulse: the flag is
/// re-asserted on every focus change, throttled to one AX call per app
/// per half-minute. By the time anyone enters a text mode, the tree has
/// been standing for as long as the app has been in use. Harmless on
/// apps that never needed it.
///
/// Two callers now: the focus observer, for the app that just arrived,
/// and the prewarmer, for the apps predicted to arrive next — from a
/// background queue. So the throttle is behind a lock, and the AX call
/// carries its own short messaging timeout: warming is a courtesy, and a
/// wedged app must never hold whichever thread extended it.
enum AXWarmer {
    /// One warming per app per this long.
    private static let interval: TimeInterval = 30
    /// The most a single warm may wait on the app. A responsive app
    /// answers in microseconds; a hung one is not worth a quarter second.
    private static let timeout: Float = 0.25
    private static var warmedAt: [pid_t: Date] = [:]
    private static let lock = NSLock()

    /// Returns whether an AX call was actually made — false when the
    /// throttle answered instead.
    @discardableResult
    static func warm(_ pid: pid_t) -> Bool {
        let now = Date()
        lock.lock()
        // Pruned on the way in rather than grown for the life of the process.
        // An entry older than the interval can only ever answer "warm it
        // again", so keeping it bought nothing and cost a slot for every pid
        // this machine has ever focused — unbounded, in an app that runs for
        // weeks. What survives the filter is exactly what the throttle needs.
        warmedAt = warmedAt.filter { now.timeIntervalSince($0.value) < interval }
        guard warmedAt[pid] == nil else {
            lock.unlock()
            return false
        }
        warmedAt[pid] = now
        lock.unlock()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        ask(app, pid: pid)
        return true
    }

    /// The flag that builds the tree, for the app that answers it. Electron
    /// apps answer `AXManualAccessibility`. Chromium browsers do not:
    /// measured on Brave (2026-09-24), that flag is refused (-25205) and the
    /// window keeps 51 nodes and no web area, while `AXEnhancedUserInterface`
    /// — the flag VoiceOver sets — builds the page at once. So a browser
    /// gets that one too. Its one side effect, macOS animating a window
    /// moved through accessibility, the window mover already undoes by
    /// dropping the flag around each move. Unthrottled: the doors call it
    /// as they open.
    static func ask(_ app: AXUIElement, pid: pid_t) {
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if let bundle = NSRunningApplication(processIdentifier: pid)?.bundleURL, isChromiumBrowser(bundle) {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    nonisolated(unsafe) private static var browserBundles: [String: Bool] = [:]

    /// A Chromium browser: renderer helpers inside its frameworks, and no
    /// Electron framework (Electron apps answer the manual flag).
    static func isChromiumBrowser(_ bundle: URL) -> Bool {
        if let known = lock.withLock({ browserBundles[bundle.path] }) { return known }
        let frameworks = bundle.appendingPathComponent("Contents/Frameworks")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: frameworks.path)) ?? []
        var chromium = false
        if !names.contains("Electron Framework.framework") {
            for name in names where name.hasSuffix(" Framework.framework") {
                let versions = frameworks.appendingPathComponent(name).appendingPathComponent("Versions")
                for version in (try? FileManager.default.contentsOfDirectory(atPath: versions.path)) ?? [] {
                    let helpers = versions.appendingPathComponent(version).appendingPathComponent("Helpers")
                    let apps = (try? FileManager.default.contentsOfDirectory(atPath: helpers.path)) ?? []
                    if apps.contains(where: { $0.hasSuffix("Helper (Renderer).app") }) { chromium = true }
                }
            }
        }
        lock.withLock { browserBundles[bundle.path] = chromium }
        return chromium
    }
}
