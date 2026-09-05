import Foundation

/// Version identity — the single source of truth. make-app.sh stamps the
/// bundle's Info.plist from `version`; boot logs it; the state file
/// carries its own format version, and the config records the release
/// that wrote it, so future lodestars can migrate old files instead of
/// guessing what "unversioned" meant.
public enum Lodestar {
    public static let version = "0.30.14"

    /// Repository home — swap to the company org at the public split.
    public static let repository = "https://github.com/Vaccone-Software/lodestar"
    public static let issuesURL = repository + "/issues/new"

    /// The Developer ID team every release is signed under. The updater
    /// refuses any download whose signature chains to anyone else.
    public static let teamID = "2PZMN57974"

    /// Who we are, as a constant rather than a question.
    ///
    /// `Bundle.main.bundleIdentifier` is the obvious way to ask and it is
    /// `nil` for a binary run outside a .app — which is how this project is
    /// developed. Every self-check spelled `handler != Bundle.main
    /// .bundleIdentifier` therefore *passed* under a `swift build` binary,
    /// because Swift promotes the comparison to Optional and
    /// `"com.vaccone.lodestar" != nil` is true. One of those guards stood in
    /// front of the write that records your default browser, so a dev run
    /// wrote Lodestar down as the browser to hand links to, and from then on
    /// every clicked link came back to us and re-activated us, thousands of
    /// times a minute, until the app was quit. A constant cannot be nil, and
    /// the compiler now types these comparisons `String` to `String`.
    ///
    /// packaging/Info.plist carries the same string; this is its other half.
    public static let bundleID = "com.vaccone.lodestar"

    /// Bump when PersistedState's shape changes; StateMigrations carries
    /// old files forward on load.
    public static let stateVersion = 1

    /// Identifies this boot, for state whose meaning does not outlive one.
    ///
    /// Window ids are the case: the window server reissues them from a
    /// fresh sequence each session, so a parked id read back after a
    /// restart can name a completely different window. Boot time is the
    /// cheapest honest answer and, unlike a generated UUID, it is the same
    /// for a successor process taking over from a self-update — which must
    /// inherit the parking map, not discard it.
    public static let bootSession: String = {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else {
            return "unknown"
        }
        // Seconds only. The microseconds are noise, and the kernel nudges
        // boottime whenever the wall clock is stepped (NTP), which would
        // make an exact match fail inside a single session.
        return "\(boot.tv_sec)"
    }()

    /// Whether a recorded session marker names the boot we are in now.
    ///
    /// Compared with slack, for the same reason: a clock correction moves
    /// boottime by seconds, while an actual reboot moves it by at least
    /// the previous session's uptime. Getting this wrong in the lenient
    /// direction costs nothing worse than what the marker already guards.
    public static func isCurrentBootSession(_ recorded: String?) -> Bool {
        guard let recorded, recorded != "unknown", bootSession != "unknown" else { return false }
        guard let then = Double(recorded), let now = Double(bootSession) else {
            return recorded == bootSession
        }
        return abs(now - then) < 120
    }
}

/// The state-file migration chain. Each step lifts raw JSON one version;
/// load runs every step between the file's version and current. Steps are
/// pure Data transforms so they are testable without a filesystem.
public enum StateMigrations {
    /// version → transform lifting that version to the next.
    static var steps: [Int: (inout [String: Any]) -> Void] = [:]

    /// Lift raw state JSON to the current version. Returns the data
    /// unchanged when it is already current or unreadable (the caller's
    /// decode will surface unreadability).
    public static func lift(_ data: Data) -> Data {
        lift(data, through: steps, to: Lodestar.stateVersion)
    }

    /// The chain itself, with both of its inputs handed in.
    ///
    /// The table and the target used to be read straight off the globals,
    /// which made the promise above — "pure Data transforms, testable without
    /// a filesystem" — one this could not keep. With `steps` empty and
    /// `stateVersion` at 1 there was no way to exercise a real step, so the
    /// code that will one day carry every saved layout on every machine
    /// forward had only ever been run as a no-op. Passing them in costs
    /// nothing at the call site and lets the chain be tested at any length,
    /// which is the point: the first time this does real work, it will do it
    /// to everybody at once.
    static func lift(_ data: Data, through steps: [Int: (inout [String: Any]) -> Void],
                     to target: Int) -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return data
        }
        var version = object["version"] as? Int ?? 0
        guard version < target else { return data }
        while version < target {
            steps[version]?(&object)
            version += 1
        }
        object["version"] = target
        return (try? JSONSerialization.data(withJSONObject: object)) ?? data
    }
}
