import Foundation

/// Self-update, the pure half: feed parsing, version ordering, and the
/// quiet gate. The effectful half — network, codesign verification, bundle
/// swaps — is UpdateController in the app target; everything here is
/// deterministic and tested.
public enum Updater {
    public struct Release: Equatable {
        public let tag: String
        public let version: [Int]
        public let zipName: String
        public let zipURL: String

        public init(tag: String, version: [Int], zipName: String, zipURL: String) {
            self.tag = tag
            self.version = version
            self.zipName = zipName
            self.zipURL = zipURL
        }
    }

    /// Which releases this Mac takes. Preview is every build the moment it
    /// is published; stable is the point `Promotion` computes from the same
    /// list. One stream, two distances behind its head.
    public enum Channel: String, CaseIterable, Equatable, Sendable {
        case stable, preview
    }

    /// The release this Mac's channel points at, from the releases list
    /// (releases?per_page=100 — never releases/latest, which excludes
    /// prereleases, and every release before 1.0 is one; a hundred so the
    /// stable walk sees months of history, not a week of daily patches).
    public static func parseFeed(_ data: Data, channel: Channel, now: Date) -> Release? {
        switch channel {
        case .preview:
            return parseFeed(data)
        case .stable:
            guard let builds = Promotion.parseFeed(data),
                  let stable = Promotion.stable(builds, now: now) else { return nil }
            return releases(in: data).first { $0.tag == stable.tag }
        }
    }

    /// The newest release carrying a lodestar zip: the preview channel.
    /// The whole list rather than the first entry, so the skip can skip: a
    /// newest entry with no zip, or a tag that is not a version, falls
    /// through to the one before it.
    public static func parseFeed(_ data: Data) -> Release? {
        releases(in: data).first
    }

    /// Every installable release in the list, in the list's order (newest
    /// first, as GitHub answers).
    static func releases(in data: Data) -> [Release] {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
        struct Entry: Decodable {
            let tag_name: String
            let draft: Bool?
            let assets: [Asset]?
        }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries.compactMap { entry in
            guard entry.draft != true, let version = parseVersion(entry.tag_name),
                  let zip = (entry.assets ?? []).first(where: {
                      $0.name.hasPrefix("lodestar-") && $0.name.hasSuffix(".zip")
                  }) else { return nil }
            return Release(tag: entry.tag_name, version: version,
                           zipName: zip.name, zipURL: zip.browser_download_url)
        }
    }

    /// When to ask again after a check that failed, by how many have failed
    /// in a row: a quarter of an hour, then an hour, then back to the daily
    /// check. A failed check used to wait for the next day or the next
    /// boot — on 2026-09-28 two timed out on a flaky network and 0.39.4
    /// was only picked up by a check forced by hand.
    public static func retryDelay(afterFailures failures: Int) -> TimeInterval? {
        switch failures {
        case 1: return 15 * 60
        case 2: return 60 * 60
        default: return nil
        }
    }

    /// What is wrong with an HTTP answer, or nil when it is an answer. A
    /// rate limit or an error page used to be read as "no release with a
    /// zip", and a download's error page was unpacked as the update.
    public static func httpProblem(status: Int?) -> String? {
        guard let status else { return nil }
        switch status {
        case 200..<300: return nil
        case 403, 429: return "HTTP \(status), GitHub's rate limit"
        default: return "HTTP \(status)"
        }
    }

    /// Whether a bundle is the installed app — in an Applications folder —
    /// rather than a build under test. Only the installed app writes the
    /// login item and the CLI link, and only it updates itself: a signed
    /// build run from dist/ once pointed the login item at itself, and one
    /// older than the latest release would have replaced itself in dist/.
    public static func isInstalled(bundlePath: String, home: String) -> Bool {
        (bundlePath.hasPrefix("/Applications/") || bundlePath.hasPrefix(home + "/Applications/"))
            && bundlePath.hasSuffix("lodestar.app")
            && !bundlePath.contains("/AppTranslocation/")
    }

    /// "0.9.9" or "v0.9.9" → [0, 9, 9]. Nil for anything that is not
    /// dot-separated numbers.
    public static func parseVersion(_ string: String) -> [Int]? {
        let trimmed = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, !parts.contains(nil) else { return nil }
        return parts.compactMap { $0 }
    }

    /// Strictly newer, place by place — numeric, never lexicographic
    /// (0.9.10 beats 0.9.9). Missing places read as zero, so 0.10 equals
    /// 0.10.0. Equal or older is false: no downgrades, no reinstalls.
    public static func isNewer(_ remote: [Int], than local: [Int]) -> Bool {
        for i in 0..<max(remote.count, local.count) {
            let r = i < remote.count ? remote[i] : 0
            let l = i < local.count ? local[i] : 0
            if r != l { return r > l }
        }
        return false
    }

    /// The last sign that someone may be at the Mac, for the quiet gate:
    /// the latest of the engine's own actions, the last real key through
    /// the tap, and the system's idle clock. The tap sees keys only, so ten
    /// minutes of reading with the mouse read as away; and a process that
    /// had just started knew of no key at all, so an update could swap it
    /// three minutes after a launch with the hand on the trackpad. The
    /// system's clock covers both. Posted events reset it too, which is
    /// why it cannot prove someone is here, but here a false "someone"
    /// only waits longer.
    public static func lastSignOfLife(engineActivity: Date, humanInput: Date,
                                      systemIdleSeconds: TimeInterval?, now: Date) -> Date {
        var latest = max(engineActivity, humanInput)
        if let idle = systemIdleSeconds, idle.isFinite, idle >= 0 {
            latest = max(latest, now.addingTimeInterval(-idle))
        }
        return latest
    }

    /// The quiet gate. A swap restarts the engine — losing the undo
    /// timeline and any pending chain — so it waits for a stretch with no
    /// chain, no panel, and no recent lode activity. Ten minutes of
    /// silence, by default, decides "away or settled".
    public static func mayApply(engineQuiet: Bool, secondsSinceActivity: TimeInterval,
                                minimumQuiet: TimeInterval = 600) -> Bool {
        engineQuiet && secondsSinceActivity >= minimumQuiet
    }

    /// Where an update run stands. One run at a time, ever: a repeated
    /// "Check for Updates" must join the run in flight, never start a
    /// second — two pipelines moving the same bundle destroyed an install
    /// once. `applying` is terminal for the process (the successor's boot
    /// SIGTERMs it); only a failed swap returns to `idle`.
    ///
    /// The version rides on the phase rather than beside it: a run's state
    /// is one value, so no edit can set half of it.
    public enum Phase: Equatable {
        case idle
        case checking
        case ready(version: String)
        case applying(version: String)

        public var version: String? {
            switch self {
            case .ready(let version), .applying(let version): return version
            case .idle, .checking: return nil
            }
        }
    }

    /// What a check request may do in each phase — the single-flight rule.
    public enum CheckDecision: Equatable {
        case startCheck
        case applyStaged
        case refuse(note: String)
    }

    public static func checkDecision(in phase: Phase) -> CheckDecision {
        switch phase {
        case .idle:
            return .startCheck
        case .checking:
            return .refuse(note: "⟲ Already checking for updates")
        case .ready:
            return .applyStaged
        case .applying(let version):
            return .refuse(note: "⟲ Already updating to \(version)\nThe new build takes over on its own")
        }
    }

    /// A swap may begin only with a verified staged build and no swap in
    /// flight — never from `applying`, whatever else happens.
    public static func canBeginApply(in phase: Phase) -> Bool {
        if case .ready = phase { return true }
        return false
    }

    /// A release that already failed its handover once is refused until a
    /// different one ships. Without this, a build that crashes before
    /// taking the pid file is rolled back, found "newer" on the next check,
    /// and applied again — a loop that restarts the engine every cycle.
    ///
    /// Compared as versions, never as strings. The tombstone is written by
    /// the watchdog from `CFBundleShortVersionString` (`0.18.0`) while a
    /// release tag carries the `v` the release script publishes
    /// (`v0.18.0`), so a string compare never matched and this gate — the
    /// one thing standing between a bad build and a daily reinstall loop —
    /// silently did nothing.
    public static func shouldOffer(_ release: Release, refusedTag: String?) -> Bool {
        guard let refusedTag, let refused = parseVersion(refusedTag) else { return true }
        return !sameVersion(release.version, refused)
    }

    /// Can this Mac run a staged build? Nil when it can; otherwise what the
    /// build needs, for the one note the person sees. A build for Apple
    /// silicon alone on an Intel Mac, or one asking a newer macOS, would
    /// fail to launch, be rolled back by the watchdog, and — refused only
    /// by its tag — come back with every later release. Checked from the
    /// staged bundle itself, so it holds for any release after this one.
    public static func incompatibility(architectures: Set<String>, minimumSystem: String?,
                                       appleSilicon: Bool, system: OperatingSystemVersion) -> String? {
        var needs: [String] = []
        let runs = appleSilicon ? !architectures.isDisjoint(with: ["arm64", "x86_64"])
                                : architectures.contains("x86_64")
        if !runs { needs.append("a Mac with Apple silicon") }
        if let minimumSystem, let wanted = parseVersion(minimumSystem),
           isNewer(wanted, than: [system.majorVersion, system.minorVersion, system.patchVersion]) {
            let shown = wanted.count > 1 && wanted[1] == 0 ? "\(wanted[0])" : minimumSystem
            needs.append("macOS \(shown)")
        }
        return needs.isEmpty ? nil : "needs " + needs.joined(separator: " and ")
    }

    /// Place-by-place equality, missing places reading as zero — the same
    /// rule `isNewer` uses, so `0.18` and `0.18.0` are one version.
    public static func sameVersion(_ a: [Int], _ b: [Int]) -> Bool {
        !isNewer(a, than: b) && !isNewer(b, than: a)
    }
}
