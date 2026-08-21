import Foundation

public enum Fuzzy {
    /// Subsequence match score; nil when the query does not match at all.
    /// Rewards starts of words, camel humps, consecutive runs, and short
    /// candidates — tuned for app names, not general text.
    ///
    /// `lengthPenalty` is the per-character cost of being long. It is the one
    /// part of this that does not travel: for app names a short candidate is
    /// a better answer, but for a clipboard preview length says nothing about
    /// relevance, and charging for it ranks a stray word above the paragraph
    /// you were looking for. Callers over long text pass 0.
    public static func score(query: String, candidate: String,
                             lengthPenalty: Double = 0.01) -> Double? {
        if query.isEmpty { return 0 }
        let q = Array(query.lowercased())
        let lower = Array(candidate.lowercased())
        var qi = 0
        var score = 0.0
        var lastMatch = -10

        // One walk, pairing each lowered character with its original: this
        // runs against every candidate on every panel keystroke, and the
        // old shape lowercased the candidate twice and materialized it
        // three times to answer once.
        var i = 0
        var previousOriginal: Character?
        for original in candidate {
            defer { previousOriginal = original; i += 1 }
            guard qi < q.count, i < lower.count, lower[i] == q[qi] else { continue }
            var gain = 1.0
            if i == 0 {
                gain += 3
            } else {
                let previous = lower[i - 1]
                if previous == " " || previous == "-" || previous == "." || previous == "_" {
                    gain += 2.5
                } else if original.isUppercase, previousOriginal?.isLowercase == true {
                    gain += 2
                }
            }
            if i == lastMatch + 1 { gain += 1.5 }
            score += gain
            lastMatch = i
            qi += 1
        }

        guard qi == q.count else { return nil }
        score -= Double(lower.count) * lengthPenalty
        if lower.starts(with: q) { score += 2 }
        return score
    }

    /// Rank candidates by score, best first; non-matches dropped.
    public static func rank<T>(query: String, candidates: [T], key: (T) -> String) -> [T] {
        candidates
            .compactMap { item -> (T, Double)? in
                guard let s = score(query: query, candidate: key(item)) else { return nil }
                return (item, s)
            }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }

    /// How strongly a live window's title answers the title we are looking
    /// for. Zero is no answer; higher is better, and the order is total, so
    /// nothing is left to be settled by chance.
    ///
    /// This is re-matching, not searching. A breath remembers the title a
    /// window had, that window dies, and one of the app's live windows has to
    /// take its place. `score` is the wrong instrument for it: a subsequence
    /// match tuned for typing three letters at an app name will match almost
    /// any full title against almost any other.
    ///
    /// The floor is what makes it honest. Containment was unconditional and
    /// symmetric, so a window titled "a" contained-matched every target with
    /// an "a" in it and could take a saved layout's place from the window
    /// that belonged there. A side shorter than `floor` characters carries no
    /// evidence, so it earns nothing.
    /// The tiers sit `band` apart and each bonus is capped below it, so the
    /// ordering between tiers is arithmetic rather than a hope about how long
    /// a window title can get.
    public static func titleAffinity(of candidate: String, against target: String) -> Int {
        let floor = 4
        let band = 1_000
        let c = candidate.lowercased()
        let t = target.lowercased()
        guard !c.isEmpty, !t.isEmpty else { return 0 }
        if c == t { return 3 * band }
        let overlap = min(c.count, t.count)
        if overlap >= floor, c.contains(t) || t.contains(c) {
            return 2 * band + min(overlap, band - 1)
        }
        let shared = zip(c, t).prefix { $0 == $1 }.count
        return shared >= floor ? band + min(shared, band - 1) : 0
    }
}
