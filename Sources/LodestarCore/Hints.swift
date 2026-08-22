import Foundation

/// Hint label generation — pure, so the guarantees are testable: labels
/// are prefix-free (typing one can never fire while another remains
/// reachable) and drawn from the user's own alphabet.
public enum HintLabels {
    /// Lowercased, deduplicated, letters only. A config alphabet that
    /// leaves fewer than four usable letters falls back to the home row —
    /// a bad config must degrade, not break.
    public static func sanitize(_ alphabet: String) -> [Character] {
        var seen = Set<Character>()
        var letters: [Character] = []
        for ch in alphabet.lowercased() where ch.isLetter && !seen.contains(ch) {
            seen.insert(ch)
            letters.append(ch)
        }
        return letters.count >= 4 ? letters : Array("asdfghjkl")
    }

    /// Single letters while they suffice; beyond that, uniform two-letter
    /// pairs — never mixed, which is what keeps the set prefix-free.
    /// Capacity is alphabet² ; callers cap their target count to it.
    public static func labels(count: Int, alphabet: String) -> [String] {
        let letters = sanitize(alphabet)
        guard count > 0 else { return [] }
        if count <= letters.count {
            return letters.prefix(count).map(String.init)
        }
        var pairs: [String] = []
        outer: for first in letters {
            for second in letters {
                pairs.append("\(first)\(second)")
                if pairs.count >= count { break outer }
            }
        }
        return pairs
    }

    public static func capacity(alphabet: String) -> Int {
        let n = sanitize(alphabet).count
        return n * n
    }

    public enum Match: Equatable {
        case none
        case partial
        case exact(Int)
    }

    public static func match(typed: String, labels: [String]) -> Match {
        guard !typed.isEmpty else { return labels.isEmpty ? .none : .partial }
        if let index = labels.firstIndex(of: typed) { return .exact(index) }
        return labels.contains { $0.hasPrefix(typed) } ? .partial : .none
    }
}

/// What a hint keystroke did — the seam between grammar and overlay.
public enum HintStep: Equatable {
    /// The letter narrowed the labels; still collecting.
    case pending
    /// A label completed and its element was acted on.
    case fired
    /// A label completed on a text input, which was focused. The mode
    /// ends even in sticky: focusing a field means "my typing goes here
    /// next", and a mode that stayed up would eat that typing as aiming.
    case firedFocus
    /// The letter matched nothing and was dropped.
    case ignored
}
