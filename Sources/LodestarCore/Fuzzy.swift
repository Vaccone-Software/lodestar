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
        let original = Array(candidate)
        var qi = 0
        var score = 0.0
        var lastMatch = -10

        for i in 0..<lower.count {
            guard qi < q.count, lower[i] == q[qi] else { continue }
            var gain = 1.0
            if i == 0 {
                gain += 3
            } else {
                let previous = lower[i - 1]
                if previous == " " || previous == "-" || previous == "." || previous == "_" {
                    gain += 2.5
                } else if original[i].isUppercase && original[i - 1].isLowercase {
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
        if candidate.lowercased().hasPrefix(query.lowercased()) { score += 2 }
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
}
