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

    /// The newest release carrying a lodestar zip, from the releases list
    /// (releases?per_page=1 — never releases/latest, which excludes
    /// prereleases, and every release before 1.0 is one).
    public static func parseFeed(_ data: Data) -> Release? {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
        struct Entry: Decodable {
            let tag_name: String
            let draft: Bool?
            let assets: [Asset]?
        }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return nil }
        for entry in entries where entry.draft != true {
            guard let version = parseVersion(entry.tag_name) else { continue }
            guard let zip = (entry.assets ?? []).first(where: {
                $0.name.hasPrefix("lodestar-") && $0.name.hasSuffix(".zip")
            }) else { continue }
            return Release(tag: entry.tag_name, version: version,
                           zipName: zip.name, zipURL: zip.browser_download_url)
        }
        return nil
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

    /// The quiet gate. A swap restarts the engine — losing the undo
    /// timeline and any pending chain — so it waits for a stretch with no
    /// chain, no panel, and no recent hyper activity. Ten minutes of
    /// silence, by default, decides "away or settled".
    public static func mayApply(engineQuiet: Bool, secondsSinceActivity: TimeInterval,
                                minimumQuiet: TimeInterval = 600) -> Bool {
        engineQuiet && secondsSinceActivity >= minimumQuiet
    }
}
