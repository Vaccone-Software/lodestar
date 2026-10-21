import Darwin
import Foundation

/// Version identity — the single source of truth. make-app.sh stamps the
/// bundle's Info.plist from `version`; boot logs it; the state file
/// carries its own format version, and the config records the release
/// that wrote it, so future lodestars can migrate old files instead of
/// guessing what "unversioned" meant.
public enum Lodestar {
    public static let version = "0.52.0"

    /// Repository home — swap to the company org at the public split.
    public static let repository = "https://github.com/Vaccone-Software/lodestar"

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

    /// Identifies this login, for state whose window ids must not outlive it.
    ///
    /// A `CGWindowID` is recycled when the window server starts, which is a
    /// login, not a reboot: `kern.boottime` stays put across a logout, so a
    /// parked id read back after one can name a different window. The
    /// console's login time is the same for a relaunch — a crash, a kill,
    /// the successor a self-update starts — and a different one after the
    /// next login. When the console record cannot be read, the boot stands
    /// in, which is the coarser answer this used before.
    public static let loginSession: String = {
        if let login = consoleLoginSeconds() { return "login:\(login)" }
        return "boot:\(bootSession)"
    }()

    /// Whether parked window ids recorded as `session` still name this
    /// login's windows.
    ///
    /// A login id matches exactly. A bare boot time is what an older build
    /// wrote: it still names this login while this boot is that one, and
    /// the next save rewrites it as a login id so a logout cannot inherit it.
    public static func parksBelongToThisLogin(_ session: String?) -> Bool {
        guard let session, !session.isEmpty, session != "unknown" else { return false }
        if session == loginSession { return true }
        if session.hasPrefix("login:") || session.hasPrefix("boot:") { return false }
        return isCurrentBootSession(session)
    }

    /// The GUI login's start, in seconds, from the console's utmpx record.
    private static func consoleLoginSeconds() -> Int? {
        setutxent()
        defer { endutxent() }
        var latest: Int?
        while let entry = getutxent() {
            // Copy before reading fields. The next `getutxent` reuses the
            // pointer the library just handed back.
            var record = entry.pointee
            guard Int(record.ut_type) == Int(USER_PROCESS) else { continue }
            guard cString(of: &record) == "console" else { continue }
            let seconds = Int(record.ut_tv.tv_sec)
            if let known = latest, seconds <= known { continue }
            latest = seconds
        }
        return latest
    }

    /// `ut_line` is a fixed C char array. Stop at the terminator, or at the
    /// end of the array when the terminator is missing.
    private static func cString(of record: inout utmpx) -> String {
        withUnsafeBytes(of: &record.ut_line) { raw in
            let bytes = Array(raw)
            let end = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: bytes[..<end], as: UTF8.self)
        }
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
