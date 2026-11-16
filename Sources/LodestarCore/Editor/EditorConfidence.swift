import Foundation

/// Grammar marks the model barely prefers are not shown.
///
/// A greedy answer is the model's single likeliest reading, and it picks it
/// however narrowly it beat the sentence as written. So each grammar fix in
/// an answer is weighed: how much likelier the model finds the sentence with
/// that one fix as its reply than the sentence as the writer left it (the
/// difference of the two replies' log-likelihoods, `margin`). A fix that wins
/// by less than its model's threshold is dropped, and the answer is rebuilt
/// from the writer's sentence with only the fixes that stand.
///
/// Measured 2026-11-16 (`probe editor gec`, Standard): on the maker's 666
/// dictated sentences, 70 grammar marks were 67% right as shown, 82% with
/// this gate (37 right, 5 wrong, 3 style of 45); every mark that was
/// nonsense ("doors." → "doors. are.", "Line" → "The Line") scored below
/// zero. On the accuracy fixture grammar marks went from 91.5% to 98.1%
/// right, and slips caught from 90% to 88%. A margin's size is the model's
/// own: Full (Qwen 3.6 35B) scored its right fixes mostly between 1 and 4
/// where Standard scored 5 to 25, so Full keeps any fix it prefers at all
/// (fixture: 97.4% → 98.1% right, the false marks on clean sentences gone,
/// slips caught 92% → 88%). Spelling is not weighed: the
/// model's spelling fixes scored far above the line, and the spell checker
/// speaks for them anyway.
public enum EditorConfidence {
    /// The margin, in nats, a grammar fix must win by on Standard.
    public static let standard = 4.0
    /// On Full: any margin at all.
    public static let full = 0.0

    /// What an answer would mark in `sentence`, read as the session reads it
    /// (no guards and nothing protected: the session filters again), and
    /// which of those are grammar. Nil when there is nothing to weigh: the
    /// answer did not read the sentence, it marks no grammar, or two of its
    /// marks touch, which one rebuilt sentence could not keep apart.
    public static func weighable(sentence: String, corrected: String, language: String)
        -> (issues: [EditorIssue], grammar: [Int])? {
        let text = sentence as NSString
        let whole = NSRange(location: 0, length: text.length)
        guard EditorDiff.isReading(text: text, sentence: whole, corrected: corrected) else { return nil }
        let issues = EditorDiff.issues(text: text, sentence: whole, corrected: corrected,
                                       guards: EditorGuards(), protected: [])
        let grammar = issues.indices.filter { !isSpelling(issues[$0], language: language) }
        guard !grammar.isEmpty else { return nil }
        let ordered = issues.sorted { $0.range.location < $1.range.location }
        for (a, b) in zip(ordered, ordered.dropFirst())
        where NSMaxRange(a.range) > b.range.location { return nil }
        return (issues, grammar)
    }

    /// The writer's sentence with this one fix in it: the reply it is
    /// weighed as.
    public static func fixed(_ sentence: String, by issue: EditorIssue) -> String {
        (sentence as NSString).replacingCharacters(in: issue.range, with: issue.replacement)
    }

    /// The answer the session is given: the model's own when every grammar
    /// fix stood, otherwise the writer's sentence with only the fixes that
    /// stood. `margins` follow `grammar`, one each.
    public static func gated(sentence: String, corrected: String, issues: [EditorIssue], grammar: [Int],
                             margins: [Double], threshold: Double) -> (answer: String, dropped: Int) {
        guard margins.count == grammar.count else { return (corrected, 0) }
        let dropped = Set(zip(grammar, margins).filter { $0.1 < threshold }.map(\.0))
        guard !dropped.isEmpty else { return (corrected, 0) }
        var text = sentence as NSString
        for index in issues.indices.sorted(by: { issues[$0].range.location > issues[$1].range.location })
        where !dropped.contains(index) {
            text = text.replacingCharacters(in: issues[index].range, with: issues[index].replacement) as NSString
        }
        return (text as String, dropped.count)
    }

    /// The session's own test: one word for one word, the first not a word.
    static func isSpelling(_ issue: EditorIssue, language: String) -> Bool {
        issue.original.split(whereSeparator: \.isWhitespace).count == 1
            && issue.replacement.split(whereSeparator: \.isWhitespace).count == 1
            && EditorSpelling.isMisspelled(issue.original, language: language)
    }
}
