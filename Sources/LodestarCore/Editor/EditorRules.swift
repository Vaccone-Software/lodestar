import Foundation

/// The slips that need no model: a word typed twice, "should of", "alot".
/// Each is a fixed pattern with no real-word reading, so it is marked on
/// every tier, Spelling included, and costs no memory.
///
/// Left out on purpose: "a" and "an", because the rule is about sound, not
/// letters ("a university", "an hour"), and a rule that is wrong on common
/// words is worse than none.
public enum EditorRules {
    /// Words never written twice on purpose. "that that", "had had" and
    /// "is is" are grammatical, and "no no", "very very", "bye bye" are
    /// the writer's, so only the little words that cannot repeat are here.
    static let neverDoubled: Set<String> = [
        "the", "a", "an", "to", "of", "in", "and", "or", "for", "with", "at", "by", "from", "into",
        "i", "we", "you", "he", "she", "they", "it", "my", "your", "our", "their", "his", "its",
        "this", "these", "those", "are", "was", "were", "be", "been", "will", "would", "can", "could",
        "should", "have", "has", "but", "as", "if", "not", "than", "then", "when", "where", "which",
    ]

    static let modals: Set<String> = ["should", "could", "would", "must", "might", "may"]

    public static func issues(in text: String, caret: Int?, protected: [NSRange]) -> [EditorIssue] {
        let ns = text as NSString
        let tokens = EditorText.tokens(in: ns, range: NSRange(location: 0, length: ns.length))
        var out: [EditorIssue] = []
        func unfinished(_ range: NSRange) -> Bool {
            guard let caret else { return false }
            return caret >= range.location && caret <= range.location + range.length
        }
        func guarded(_ range: NSRange) -> Bool {
            protected.contains { NSIntersectionRange($0, range).length > 0 } || unfinished(range)
        }
        for (index, (word, range)) in tokens.enumerated() {
            let bare = EditorText.normalized(word)

            // alot → a lot, the writer's capital kept.
            if bare == "alot", !guarded(range) {
                let lead = String(word.prefix { !$0.isLetter })
                let tail = String(word.reversed().prefix { !$0.isLetter }.reversed())
                let capital = word.first(where: \.isLetter)?.isUppercase == true
                out.append(EditorIssue(range: range, original: word,
                                       replacement: lead + (capital ? "A lot" : "a lot") + tail, kind: .grammar))
                continue
            }

            guard index + 1 < tokens.count else { continue }
            let (next, nextRange) = tokens[index + 1]
            // Same line only: a doubled word across a line break is a list
            // or a layout, and fixing it would join the lines.
            let gap = ns.substring(with: NSRange(location: range.location + range.length,
                                                  length: nextRange.location - range.location - range.length))
            guard !gap.contains(where: \.isNewline) else { continue }
            let span = NSRange(location: range.location, length: nextRange.location + nextRange.length - range.location)

            // The word twice: "the the", "The The", "to to." The first
            // stands, carrying the second's punctuation.
            if bare == EditorText.normalized(next), neverDoubled.contains(bare),
               word.last?.isLetter == true, !guarded(span) {
                let tail = String(next.reversed().prefix { !$0.isLetter }.reversed())
                out.append(EditorIssue(range: span, original: ns.substring(with: span),
                                       replacement: word + tail, kind: .grammar))
                continue
            }

            // should of → should have. Not "could of course": the phrase
            // is right there, and so is anything with a comma between.
            if modals.contains(bare), word.last?.isLetter == true, EditorText.normalized(next) == "of",
               next.lowercased().hasPrefix("of"), !guarded(span) {
                let after = index + 2 < tokens.count ? EditorText.normalized(tokens[index + 2].0) : ""
                guard after != "course" else { continue }
                let tail = String(next.dropFirst(2))
                out.append(EditorIssue(range: span, original: ns.substring(with: span),
                                       replacement: word + " have" + tail, kind: .grammar))
            }
        }
        return out
    }
}
