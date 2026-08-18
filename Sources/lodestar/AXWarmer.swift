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
enum AXWarmer {
    private static var warmedAt: [pid_t: Date] = [:]

    static func warm(_ pid: pid_t) {
        let now = Date()
        if let last = warmedAt[pid], now.timeIntervalSince(last) < 30 { return }
        warmedAt[pid] = now
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString,
                                     kCFBooleanTrue)
    }
}
