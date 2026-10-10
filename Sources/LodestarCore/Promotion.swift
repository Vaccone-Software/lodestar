import Foundation

/// The stable channel, as a pure function of the public release list and
/// the clock.
///
/// Every build ships to preview the moment it is published. Stable is a
/// later point in the same stream: a build reaches it once its line has
/// soaked long enough on the preview Macs. Nothing is flipped and nothing
/// is stored — published releases are immutable, their prerelease flag
/// included — so the app's updater, the Homebrew job and the site's
/// download button each compute the same answer from the same list, and
/// no step can be forgotten or left stuck.
///
/// The rule:
///
///   - A line is a major.minor. Its clock starts when its first build
///     newer than stable is published. Patches never reset it, and a lone
///     patch on the stable line starts a clock of its own.
///   - A new minor soaks for `minorSoak`, a patch line for `patchSoak`.
///   - No build is taken younger than `settle`, whatever its line's clock
///     says. When the newest patch is too young the one before it goes
///     instead, so daily patches can delay nothing.
///   - A release whose title carries "[held]" stops its line: it and every
///     build of that line published at or before it are passed over, and
///     the line's clock starts again at the next build. Stable is computed
///     from scratch, so a late hold steps it back; installed apps never
///     downgrade, but new installs and the cask follow.
///
/// Stable is found by walking time forward from the oldest release in the
/// list: at each step the earliest moment any build becomes eligible, and
/// stable moves to the newest build eligible then. The walk never depends
/// on its own answer, so every reader of the same list agrees.
public enum Promotion {
    /// One published release, as far as promotion cares.
    public struct Build: Equatable {
        public let tag: String
        public let version: [Int]
        public let published: Date
        public let title: String
        public let hasZip: Bool
        public let draft: Bool

        public init(tag: String, version: [Int], published: Date, title: String = "",
                    hasZip: Bool = true, draft: Bool = false) {
            self.tag = tag
            self.version = version
            self.published = published
            self.title = title
            self.hasZip = hasZip
            self.draft = draft
        }

        /// The release's major.minor: the unit a clock runs on.
        public var line: [Int] { [version.first ?? 0, version.count > 1 ? version[1] : 0] }

        public var isHeld: Bool { title.range(of: "[held]", options: .caseInsensitive) != nil }
    }

    /// How long each kind of line waits. In one place, so the app, the
    /// command line and the tests all read the same three numbers (the
    /// site keeps a copy, checked against the shared fixture).
    public struct Policy: Equatable {
        public var minorSoak: TimeInterval
        public var patchSoak: TimeInterval
        public var settle: TimeInterval

        public init(minorSoak: TimeInterval, patchSoak: TimeInterval, settle: TimeInterval) {
            self.minorSoak = minorSoak
            self.patchSoak = patchSoak
            self.settle = settle
        }

        public static let standard = Policy(minorSoak: 7 * 86_400, patchSoak: 3 * 86_400, settle: 86_400)
    }

    /// A line still on its way to stable, for `channel --status`.
    public struct Pending: Equatable {
        public let line: [Int]
        /// A new minor, or patches on the stable line.
        public let isPatch: Bool
        /// When its clock started: its first build newer than stable.
        public let since: Date
        /// When it first reaches stable, and with which build — as the
        /// list stands now; a later patch can change the build, never
        /// delay the moment.
        public let promotes: Date
        public let build: Build
    }

    /// The stable release at `now`, or nil when the list holds no build
    /// that could ever be stable.
    public static func stable(_ builds: [Build], now: Date, policy: Policy = .standard) -> Build? {
        walk(builds, now: now, policy: policy).stable
    }

    /// Every line newer than stable, soonest first.
    public static func pending(_ builds: [Build], now: Date, policy: Policy = .standard) -> [Pending] {
        let (stable, pool) = walk(builds, now: now, policy: policy)
        guard let stable else { return [] }
        let candidates = pool.filter { Updater.isNewer($0.version, than: stable.version) }
        return lines(of: candidates).map { line, members in
            let isPatch = line == stable.line
            let since = members.map(\.published).min()!
            let soak = isPatch ? policy.patchSoak : policy.minorSoak
            let promotes = members.map { eligible($0, since: since, soak: soak, policy: policy) }.min()!
            let build = members.filter { eligible($0, since: since, soak: soak, policy: policy) <= promotes }
                .max { Updater.isNewer($1.version, than: $0.version) }!
            return Pending(line: line, isPatch: isPatch, since: since, promotes: promotes, build: build)
        }.sorted { $0.promotes < $1.promotes }
    }

    // MARK: - The walk

    private static func walk(_ builds: [Build], now: Date, policy: Policy) -> (stable: Build?, pool: [Build]) {
        let pool = usable(builds, now: now)
        guard var stable = pool.first else { return (nil, pool) }
        var time = stable.published
        while true {
            let candidates = pool.filter { Updater.isNewer($0.version, than: stable.version) }
            var soonest: Date?
            var eligibleAt: [(Build, Date)] = []
            for (line, members) in lines(of: candidates) {
                let since = members.map(\.published).min()!
                let soak = line == stable.line ? policy.patchSoak : policy.minorSoak
                for build in members {
                    let at = eligible(build, since: since, soak: soak, policy: policy)
                    eligibleAt.append((build, at))
                    soonest = min(soonest ?? at, at)
                }
            }
            guard let soonest else { break }
            let moment = max(soonest, time)
            guard moment <= now else { break }
            stable = eligibleAt.filter { $0.1 <= moment }.map(\.0)
                .max { Updater.isNewer($1.version, than: $0.version) }!
            time = moment
        }
        return (stable, pool)
    }

    /// The earliest moment a build may be stable: its line has soaked, and
    /// it has itself been out for the settle.
    private static func eligible(_ build: Build, since: Date, soak: TimeInterval, policy: Policy) -> Date {
        max(since.addingTimeInterval(soak), build.published.addingTimeInterval(policy.settle))
    }

    /// The builds promotion may consider, oldest version first: published
    /// by now, not drafts, carrying the zip the updater installs, and not
    /// passed over by a hold.
    private static func usable(_ builds: [Build], now: Date) -> [Build] {
        let shipped = builds.filter { !$0.draft && $0.hasZip && $0.published <= now }
        var lastHold: [[Int]: Date] = [:]
        for build in shipped where build.isHeld {
            lastHold[build.line] = max(lastHold[build.line] ?? build.published, build.published)
        }
        return shipped
            .filter { build in lastHold[build.line].map { build.published > $0 } ?? true }
            .sorted { Updater.isNewer($1.version, than: $0.version) }
    }

    private static func lines(of builds: [Build]) -> [[Int]: [Build]] {
        Dictionary(grouping: builds, by: \.line)
    }

    // MARK: - The feed

    /// The releases list as promotion reads it: the same GitHub feed the
    /// updater asks (`releases?per_page=100`). Entries whose tag is not a
    /// version are skipped; nil only when the answer is not a list.
    public static func parseFeed(_ data: Data) -> [Build]? {
        struct Asset: Decodable { let name: String }
        struct Entry: Decodable {
            let tag_name: String
            let name: String?
            let draft: Bool?
            let published_at: String?
            let assets: [Asset]?
        }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return nil }
        let iso = ISO8601DateFormatter()
        return entries.compactMap { entry in
            guard let version = Updater.parseVersion(entry.tag_name),
                  let stamp = entry.published_at, let published = iso.date(from: stamp) else { return nil }
            let hasZip = (entry.assets ?? []).contains {
                $0.name.hasPrefix("lodestar-") && $0.name.hasSuffix(".zip")
            }
            return Build(tag: entry.tag_name, version: version, published: published,
                         title: entry.name ?? "", hasZip: hasZip, draft: entry.draft ?? false)
        }
    }
}
