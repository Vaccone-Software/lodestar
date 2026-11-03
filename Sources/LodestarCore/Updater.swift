import Foundation
import Stoic
import StoicStore

/// Self-update, the pure half: feed parsing, version ordering, and the
/// quiet gate. The effectful half — network, codesign verification, bundle
/// swaps — is UpdateController in the app target; everything here is
/// deterministic and tested.
public enum Updater {
    public struct Release: Equatable, Sendable {
        public let tag: String
        public let version: [Int]
        public let zipName: String
        public let zipURL: String
        /// What GitHub says the zip hashes to, `sha256:<hex>`. Preview is
        /// not taken without one. The file is checked against it before it
        /// is unpacked; the codesign checks are the gate on what was unpacked.
        public let zipDigest: String?

        public init(tag: String, version: [Int], zipName: String, zipURL: String, zipDigest: String? = nil) {
            self.tag = tag
            self.version = version
            self.zipName = zipName
            self.zipURL = zipURL
            self.zipDigest = zipDigest
        }
    }

    /// Which releases this Mac takes. Preview is every build the moment it
    /// is published, read from GitHub's releases list. Stable is the build
    /// the site says has soaked: the promotion rule lives there and nowhere
    /// else, so fixing it or changing its timings is a site deploy and never
    /// waits on every installed copy updating. One stream, two distances
    /// behind its head.
    public enum Channel: String, CaseIterable, Equatable, Sendable {
        case stable, preview
    }

    /// The site's answer for stable. It only names a build: the zip still
    /// comes from GitHub, and the staged bundle must still carry this
    /// team's Developer ID and the tag's version, so the most a wrong
    /// answer from here can do is hold an update back (a wrong digest
    /// included: the zip would fail it, and the update with it).
    public static let stableURL = URL(string: "https://lodestar.vaccone.software/api/stable")!

    /// Where every release's files live. A zip URL, stable or preview, is
    /// accepted only when it is exactly the one GitHub serves for that tag.
    static let downloads = Lodestar.repository + "/releases/download/"

    /// `lodestar-<version>.zip` at `downloads/<tag>/`. One rule for both
    /// channels, so a preview asset is not a second way to name a host.
    static func acceptsReleaseZip(name: String, url: String, tag: String, version: String) -> Bool {
        let zip = "lodestar-\(version).zip"
        return name == zip && url == downloads + tag + "/" + zip
    }

    /// `v1.47.1` and `1.47.1` name one version. The caller has already
    /// required `parseVersion` to accept the tag.
    static func versionLabel(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// The release a channel's answer points at, or nil for anything that
    /// is not a clean answer: then this check is a failed one, and the
    /// usual retry asks again.
    public static func parse(_ data: Data, channel: Channel) -> Release? {
        switch channel {
        case .preview: return parseFeed(data)
        case .stable: return parseStable(data)
        }
    }

    /// The site's stable answer, believed only when it names one of
    /// Lodestar's own releases the way GitHub names it: tag v<version>,
    /// zip lodestar-<version>.zip, at that tag's download path on
    /// github.com. Fields the updater does not need (pending lines, the
    /// policy, preview) are the terminal's and the workflow's to read.
    public static func parseStable(_ data: Data) -> Release? {
        struct Zip: Decodable {
            let name: String
            let url: String
            let digest: String?
        }
        struct Answer: Decodable {
            let tag: String
            let version: String
            let zip: Zip
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data),
              let version = parseVersion(answer.version),
              answer.tag == "v" + answer.version,
              acceptsReleaseZip(name: answer.zip.name, url: answer.zip.url,
                                tag: answer.tag, version: answer.version)
        else { return nil }
        return Release(tag: answer.tag, version: version, zipName: answer.zip.name, zipURL: answer.zip.url,
                       zipDigest: answer.zip.digest)
    }

    /// The newest release carrying this app's zip: the preview channel,
    /// from the releases list (releases?per_page=10 — never
    /// releases/latest, which excludes prereleases, and every release
    /// before 1.0 is one). The whole list rather than the first entry, so
    /// the skip can skip: a newest entry with no acceptable zip, or a tag
    /// that is not a version, falls through to the one before it. An
    /// acceptable zip is the same one stable accepts — the tag's own
    /// download URL — and it carries a sha256.
    public static func parseFeed(_ data: Data) -> Release? {
        releases(in: data).first
    }

    /// Every installable release in the list, in the list's order (newest
    /// first, as GitHub answers).
    static func releases(in data: Data) -> [Release] {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
            /// `sha256:<hex>`; null for an asset from before GitHub kept one.
            let digest: String?
        }
        struct Entry: Decodable {
            let tag_name: String
            let draft: Bool?
            let assets: [Asset]?
        }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries.compactMap { entry in
            guard entry.draft != true, let version = parseVersion(entry.tag_name) else { return nil }
            let label = versionLabel(entry.tag_name)
            guard let zip = (entry.assets ?? []).first(where: {
                acceptsReleaseZip(name: $0.name, url: $0.browser_download_url,
                                  tag: entry.tag_name, version: label)
                    && UpdateArchive.isSHA256($0.digest)
            }) else { return nil }
            return Release(tag: entry.tag_name, version: version,
                           zipName: zip.name, zipURL: zip.browser_download_url, zipDigest: zip.digest)
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

    /// `retryDelay`, spread so that Macs whose checks failed in the same
    /// outage do not all come back to the feed in the same minute. Equal
    /// jitter (half to all of the delay): the schedule keeps its shape, a
    /// quarter of an hour and then an hour at the most, and never waits
    /// longer than it used to.
    public static func jitteredRetryDelay(afterFailures failures: Int,
                                          random: RandomSource = .system) -> TimeInterval? {
        guard let delay = retryDelay(afterFailures: failures) else { return nil }
        var stepper = Schedule.fixed(.seconds(delay)).jittered(.equal)
            .makeStepper(random: random.generator(discriminator: UInt64(failures)))
        guard let jittered = stepper.next(elapsed: .zero) else { return delay }
        return TimeInterval(jittered.components.seconds) + TimeInterval(jittered.components.attoseconds) / 1e18
    }

    /// Write a marker the updater, the watchdog script or the next boot
    /// reads: the same bytes `write(atomically:)` left, but through
    /// Stoic's `AtomicFile`, so a power cut leaves the old marker or the
    /// new one and never a torn or missing file, and a failure is thrown
    /// where the caller can say so. No checksum envelope: the watchdog
    /// script reads some of these with `cat`. A directory sync that fails
    /// after the rename leaves the new marker in place and is not a failure.
    public static func writeMarker(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try DurableFile.acceptingUnknownDurability(of: url.lastPathComponent) {
            try AtomicFile(options: .init(envelope: false)).write(Array(text.utf8), to: url.path)
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
    ///
    /// The path is standardized before the comparison: `.` and `..` are
    /// collapsed, and nothing is asked of the disk, so
    /// `/Applications/../tmp/lodestar.app` is not an install.
    public static func isInstalled(bundlePath: String, home: String) -> Bool {
        guard bundlePath.hasPrefix("/") else { return false }
        let path = standardPath(bundlePath)
        guard path.hasSuffix("lodestar.app"), !path.contains("/AppTranslocation/") else { return false }
        if path.hasPrefix("/Applications/") { return true }
        guard home.hasPrefix("/") else { return false }
        return path.hasPrefix(standardPath(home) + "/Applications/")
    }

    /// `.` and `..` and repeated separators collapsed. A relative path is
    /// returned unchanged, which `isInstalled` has already refused: this
    /// does not prepend the working directory, and it does not follow a link.
    static func standardPath(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
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
