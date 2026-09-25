import Foundation

/// The editor scored against sentences whose right answer is known: the
/// fixture the tests hold (Tests/LodestarCoreTests/Fixtures), each case
/// read the way the app reads a field — sentence by sentence, the model's
/// answer through the real session, the spell checker merged in.
public enum EditorBench {
    public struct Case: Codable {
        public var text: String
        public var want: String
        public var kind: String
        public var src: String
        /// Per engine, each sentence the app would ask about and the
        /// model's reply ("" when it gave none).
        public var answers: [String: [String: String]]
    }

    public struct Fixture: Codable {
        public var about: String
        public var cases: [Case]
    }

    public struct Score: CustomStringConvertible {
        public var right = 0, wrong = 0
        public var slips = 0, caught = 0
        public var cleanCases = 0, cleanMarks = 0
        public var misses: [String] = []
        public var falseMarks: [String] = []

        /// Of the marks shown, how many would fix the slip on their own.
        public var precision: Double { Double(right) / Double(max(1, right + wrong)) }
        /// Of the slips, how many got a mark that fixes it.
        public var recall: Double { Double(caught) / Double(max(1, slips)) }
        public var falsePerClean: Double { Double(cleanMarks) / Double(max(1, cleanCases)) }

        public var description: String {
            String(format: "marks right %d/%d (%.0f%%) · slips caught %d/%d (%.0f%%) · false marks per clean sentence %.2f",
                   right, right + wrong, 100 * precision, caught, slips, 100 * recall, falsePerClean)
        }
    }

    /// The sentences the app would send the model for this text.
    public static func questions(_ text: String) -> [String] {
        EditorSession().sentencesToCheck(text: text, caret: nil, paused: true)
    }

    public static func score(_ cases: [Case], engine: String, guards: EditorGuards = EditorGuards()) -> Score {
        var score = Score()
        for item in cases {
            let session = EditorSession()
            session.guards = guards
            for (sentence, reply) in item.answers[engine] ?? [:] {
                session.record(sentence: sentence, corrected: reply.isEmpty ? nil : reply)
            }
            let issues = session.issues(text: item.text, caret: nil)
            if item.text == item.want {
                score.cleanCases += 1
                score.cleanMarks += issues.count
                score.wrong += issues.count
                score.falseMarks += issues.map { "\($0.original) → \($0.shown) · \(item.text)" }
                continue
            }
            score.slips += 1
            // Some slips take two marks ("Me and him" → "He and I"): when
            // every mark together fixes the sentence, each was right.
            var all = item.text as NSString
            for issue in issues.sorted(by: { $0.range.location > $1.range.location }) {
                all = all.replacingCharacters(in: issue.range, with: issue.replacement) as NSString
            }
            if !issues.isEmpty, normalized(all as String) == normalized(item.want) {
                score.right += issues.count
                score.caught += 1
                continue
            }
            var fixed = false
            for issue in issues {
                let alone = (item.text as NSString).replacingCharacters(in: issue.range, with: issue.replacement)
                if normalized(alone) == normalized(item.want) {
                    score.right += 1
                    fixed = true
                } else {
                    score.wrong += 1
                    score.falseMarks.append("\(issue.original) → \(issue.shown) · \(item.text)")
                }
            }
            if fixed { score.caught += 1 } else { score.misses.append("\(item.kind): \(item.text)") }
        }
        return score
    }

    /// Two readings are the same when their words are: case and the
    /// punctuation around words aside, commas counted.
    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: \.isWhitespace)
            .map { token in String(token.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "," }) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}
