import Foundation

extension Draft.Seams {
    /// A hearing that began inside the words before a run, for context,
    /// split where the run begins: the mark the ear wrote at the seam and
    /// the run's own words.
    ///
    /// A run is at most fifteen seconds, and an ear hearing one that stops at
    /// a pause ends it with a period, since it cannot hear what follows: in
    /// the maker's free talk 21 of 32 seams between phrases were not a
    /// sentence's end, and Nemotron's words say nothing either way (every
    /// phrase begins in lower case). The run after the seam is heard from a
    /// few seconds before it, so the ear hears both sides, and its mark at
    /// the seam decides.
    ///
    /// The ear's words are lined up with the last words before the run and
    /// the run's (a longest common subsequence of the words, case and
    /// punctuation aside). The seam is after the last word matched before
    /// the run, carried on over as many unmatched words as the text before
    /// has unmatched at its end (a last word misheard stays the context's).
    /// Nil when fewer than two words before the run, or none of the run's,
    /// were heard: the hearing cannot be split, and is not used.
    public struct ContextSplit: Equatable, Sendable {
        /// The punctuation the ear wrote at the seam: ".", "?", "!", ",", or "".
        public let mark: String
        /// The ear's words for the run.
        public let run: String
    }

    public static func split(heard: String, before: String, run: String) -> ContextSplit? {
        let ear = heard.split(whereSeparator: \.isWhitespace).map(String.init)
        let context = Array(before.split(whereSeparator: \.isWhitespace).suffix(30)).map(String.init)
        let own = run.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !ear.isEmpty, !context.isEmpty, !own.isEmpty else { return nil }
        func key(_ word: String) -> String { word.lowercased().filter { $0.isLetter || $0.isNumber } }
        let a = ear.map(key)
        let b = (context + own).map(key)
        // Longest common subsequence, then walked back into pairs.
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = !a[i].isEmpty && a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(ear: Int, text: Int)] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if !a[i].isEmpty, a[i] == b[j] { pairs.append((i, j)); i += 1; j += 1 }
            else if table[i + 1][j] >= table[i][j + 1] { i += 1 }
            else { j += 1 }
        }
        let inContext = pairs.filter { $0.text < context.count }
        guard inContext.count >= 2, let last = inContext.last,
              let firstOwn = pairs.first(where: { $0.text >= context.count }) else { return nil }
        // The context's unmatched last words take as many unmatched ear words.
        let unmatchedTail = context.count - 1 - last.text
        var seam = last.ear
        while seam + 1 < firstOwn.ear, seam - last.ear < unmatchedTail { seam += 1 }
        let tail = ear[seam]
        let mark = String(tail.reversed().prefix { ".?!,;:".contains($0) }.reversed())
        let words = ear[(seam + 1)...].joined(separator: " ")
        guard !words.isEmpty else { return nil }
        return ContextSplit(mark: mark.contains(where: { ".?!".contains($0) }) ? String(mark.last { ".?!".contains($0) }!)
                                : (mark.contains(",") ? "," : ""),
                            run: words)
    }
}
