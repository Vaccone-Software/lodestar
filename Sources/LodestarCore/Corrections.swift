import Foundation

/// What a hand's correction of dictated text teaches the vocabulary.
///
/// A word written over words the recognizer heard is learned when it is a
/// mishearing, not a change of mind: "Kindora" over "can Dora" is the same
/// sound spelled right, "Tuesday" over "Monday" is a different thought.
/// The test is the matcher's own: the correction is learned when a matcher
/// knowing only the new word would have repaired the old words into it.
/// The same logic that will do the repairing decides what to learn, so
/// the two cannot disagree, and one correction is enough — no count, no
/// threshold to tune.
public enum Corrections {
    /// The longest correction read as one: a name heard as a few words,
    /// written as one or two. Longer edits are rewriting, not respelling.
    static let maxOld = 4
    static let maxNew = 3

    /// The words to learn from `before` becoming `after` by the hand.
    /// `known` is the vocabulary already held, compared case-insensitively.
    public static func learned(before: String, after: String, known: Set<String>, pronouncer: Pronouncer,
                               isCommon: @escaping @Sendable (String) -> Bool,
                               isFrequent: (@Sendable (String) -> Bool)? = nil) -> [String] {
        let known = Set(known.map { $0.lowercased() })
        var out: [String] = []
        for hunk in replacements(from: tokens(before), to: tokens(after)) {
            guard hunk.old.count <= maxOld, hunk.new.count <= maxNew else { continue }
            let term = trim(hunk.new.joined(separator: " "))
            let said = trim(hunk.old.joined(separator: " "))
            guard !term.isEmpty, !said.isEmpty, term.contains(where: \.isLetter) else { continue }
            // Only spacing or case changed: formatting (a code name joined
            // up), not a word the recognizer could not hear.
            func folded(_ s: String) -> String { s.lowercased().filter { !$0.isWhitespace } }
            guard folded(term) != folded(said) else { continue }
            // Every word ordinary: "their" over "there" teaches nothing a
            // vocabulary should hold.
            let words = term.split(separator: " ").map { $0.lowercased() }
            guard !words.allSatisfy({ isCommon($0) }) else { continue }
            guard !known.contains(term.lowercased()), !out.contains(term) else { continue }
            let matcher = NameMatcher(terms: [NameMatcher.Term(term)], pronouncer: pronouncer,
                                      isCommon: isCommon, isFrequent: isFrequent)
            let repaired = matcher.apply(said)
            guard !repaired.edits.isEmpty, repaired.text.contains(term) else { continue }
            out.append(term)
        }
        return out
    }

    /// Words as written, split on whitespace.
    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// The edge punctuation a word carries in a sentence, taken off.
    static func trim(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"'()[]{}“”‘’…").union(.whitespaces))
    }

    /// Where `new` replaces words of `old`: each run of words removed that
    /// has words written in its place. Pure insertions and deletions are
    /// not corrections of a hearing. Compared without edge punctuation, so
    /// a period moved is not a change.
    static func replacements(from old: [String], to new: [String]) -> [(old: [String], new: [String])] {
        let a = old.map { trim($0).lowercased() }, b = new.map { trim($0).lowercased() }
        var start = 0
        while start < a.count, start < b.count, a[start] == b[start] { start += 1 }
        var endA = a.count, endB = b.count
        while endA > start, endB > start, a[endA - 1] == b[endB - 1] { endA -= 1; endB -= 1 }
        let midA = Array(a[start..<endA]), midB = Array(b[start..<endB])
        // Longest common subsequence over what differs; a correction is a
        // few words, so the middle is small even in a long draft.
        guard midA.count * midB.count <= 250_000 else { return [] }
        var table = Array(repeating: Array(repeating: 0, count: midB.count + 1), count: midA.count + 1)
        for i in stride(from: midA.count - 1, through: 0, by: -1) {
            for j in stride(from: midB.count - 1, through: 0, by: -1) {
                table[i][j] = midA[i] == midB[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var hunks: [(old: [String], new: [String])] = []
        var i = 0, j = 0
        var pendingOld: [String] = [], pendingNew: [String] = []
        func flush() {
            if !pendingOld.isEmpty, !pendingNew.isEmpty { hunks.append((pendingOld, pendingNew)) }
            pendingOld = []; pendingNew = []
        }
        while i < midA.count || j < midB.count {
            if i < midA.count, j < midB.count, midA[i] == midB[j] {
                flush(); i += 1; j += 1
            } else if j < midB.count, i == midA.count || table[i][j + 1] >= table[i + 1][j] {
                pendingNew.append(new[start + j]); j += 1
            } else {
                pendingOld.append(old[start + i]); i += 1
            }
        }
        flush()
        return hunks
    }
}
