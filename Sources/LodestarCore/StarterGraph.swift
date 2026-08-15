import Foundation

/// The graph Lodestar offers a new user, drafted from the apps they actually
/// have open.
///
/// The empty graph is the real blocker after the permission grant: not "how do
/// I bind an address" but "which addresses would I even want". What is running
/// while somebody installs a window manager is their working set, which is a
/// better guess than anything the system's own usage counters can supply
/// (Spotlight's `kMDItemUseCount` reads null for anything Homebrew installed
/// and single digits for a browser opened every day, so a graph built on it
/// would omit precisely the apps you live in).
///
/// It is a proposal, never a write: the address exists because somebody
/// accepted it, which is what keeps the graph deterministic.
public enum StarterGraph {
    public struct Proposal: Equatable {
        public let letter: String
        public let app: String

        public init(letter: String, app: String) {
            self.letter = letter
            self.app = app
        }
    }

    /// Apps that are running on any Mac and mean nothing about how you work.
    static let uninteresting: Set<String> = [
        "lodestar", "finder", "system settings", "system preferences",
        "installer", "loginwindow", "dock", "systemuiserver", "controlcenter",
        "notificationcenter", "spotlight", "archive utility",
    ]

    /// One letter each, first come first served, for as many as `limit`.
    ///
    /// The letter is the app's initial where that is free, because an address
    /// you can guess is an address you learn in one use. Where it is taken the
    /// next unused letter of the name is tried, and where the whole name is
    /// spoken for the app is skipped rather than given something arbitrary: a
    /// random letter is worse than no address, since it has to be memorised
    /// instead of recalled.
    public static func propose(running: [String], existing: GraphNode,
                               reserved: Set<String> = [], limit: Int = 5) -> [Proposal] {
        var taken = Set(existing.children.keys.map { $0.lowercased() })
        taken.formUnion(reserved.map { $0.lowercased() })
        let alreadyBound = Set(existing.leaves().map { $0.target.label.lowercased() })

        var proposals: [Proposal] = []
        for app in running {
            guard proposals.count < limit else { break }
            let name = app.trimmingCharacters(in: .whitespaces)
            let lowered = name.lowercased()
            guard !lowered.isEmpty, !uninteresting.contains(lowered),
                  !alreadyBound.contains(lowered) else { continue }
            guard let letter = freeLetter(for: lowered, taken: taken) else { continue }
            taken.insert(letter)
            proposals.append(Proposal(letter: letter, app: name))
        }
        return proposals
    }

    /// The initial, then any other letter the name itself offers. Nothing from
    /// outside the name: an address should be a shortening of what you would
    /// have typed.
    private static func freeLetter(for name: String, taken: Set<String>) -> String? {
        for character in name where character.isASCII && character.isLetter {
            let letter = String(character)
            if !taken.contains(letter) { return letter }
        }
        return nil
    }
}
