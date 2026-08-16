import Foundation

/// Version identity — the single source of truth. make-app.sh stamps the
/// bundle's Info.plist from `version`; boot logs it; the state file
/// carries its own format version, and the config records the release
/// that wrote it, so future lodestars can migrate old files instead of
/// guessing what "unversioned" meant.
public enum Lodestar {
    public static let version = "0.11.5"

    /// Repository home — swap to the company org at the public split.
    public static let repository = "https://github.com/Vaccone-Software/lodestar"
    public static let issuesURL = repository + "/issues/new"

    /// The Developer ID team every release is signed under. The updater
    /// refuses any download whose signature chains to anyone else.
    public static let teamID = "2PZMN57974"

    /// Bump when PersistedState's shape changes; StateMigrations carries
    /// old files forward on load.
    public static let stateVersion = 1
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
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return data
        }
        var version = object["version"] as? Int ?? 0
        guard version < Lodestar.stateVersion else { return data }
        while version < Lodestar.stateVersion {
            steps[version]?(&object)
            version += 1
        }
        object["version"] = Lodestar.stateVersion
        return (try? JSONSerialization.data(withJSONObject: object)) ?? data
    }
}
