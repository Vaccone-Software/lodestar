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

    /// Which of a harvest's targets wear a chip, by index.
    ///
    /// A label is not free: it is a word the eye must find and the hand
    /// must spell, and the door already has a better address for most of
    /// what a window holds — the text painted on it. So chips are spent
    /// only where typing cannot reach.
    ///
    /// While the whole harvest fits in single letters nothing is spent
    /// and everything wears one: that is the small window's whole
    /// experience — a dialog's three buttons, a popover's rows, answered
    /// the instant the tree does and each on one keystroke. Past that the
    /// chips go to what the screen paints no word on, and that is asked of
    /// the words themselves rather than guessed from how the target was
    /// found: a div that presses, an image that clicks, a text input whose
    /// words are the user's to write, **and the icon button** — named by
    /// role, and just as wordless. Only a target with a word painted
    /// inside it keeps the address it always had: type it.
    public static func chipped(unreachable: [Bool], alphabet: String) -> [Int] {
        let letters = sanitize(alphabet)
        let indices = Array(unreachable.indices)
        let chosen = unreachable.count <= letters.count
            ? indices
            : indices.filter { unreachable[$0] }
        return Array(chosen.prefix(letters.count * letters.count))
    }

    /// Does the screen paint a word inside this target — is there an
    /// address here the grammar can already reach? Asked of the word world
    /// itself, because that is the index the typing searches; the tree's
    /// own name for a target is no answer, since an icon button carries a
    /// name it paints nowhere.
    ///
    /// A word that merely brushes the frame belongs to its neighbour — the
    /// text beside a checkbox is the label's word, not the box's — so most
    /// of the word has to sit inside to count as an address for it.
    public static func paintsWord(target: CGRect, words: [CGRect],
                                  inside share: CGFloat = 0.7) -> Bool {
        guard !target.isNull, !target.isEmpty else { return false }
        return words.contains { word in
            guard !word.isNull, !word.isEmpty, word.intersects(target) else { return false }
            let shared = word.intersection(target)
            guard !shared.isNull else { return false }
            return shared.width * shared.height >= word.width * word.height * share
        }
    }

    /// May the click door spend its chips yet?
    ///
    /// Two sensors answer at different times and the chips need both: the
    /// tree says what the targets are, the screen says which of them carry
    /// a word. The tree is usually first, so spending on its answer alone
    /// would chip everything and then take most of it back — and a chip
    /// that moves under a hand already reading it is worse than a chip
    /// that arrived a little later. So the door waits for the words.
    ///
    /// Two ways out of the wait. A harvest small enough that every target
    /// wears a single letter needs no words to decide anything — that is
    /// the dialog answered the instant the tree does. And a window may
    /// have no words coming at all (an image, a canvas, a tree that never
    /// answers), so the caller forces the decision on a deadline rather
    /// than leaving the door chipless forever.
    public static func spendChipsNow(harvested: Int?, alphabet: Int,
                                     words: Int, forced: Bool) -> Bool {
        guard let harvested else { return false }
        return harvested <= alphabet || words > 0 || forced
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
